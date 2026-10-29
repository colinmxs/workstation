#!/usr/bin/env bash
# Bulk-import Azure DevOps repos: one stopped container per repo.
#
#   azdo-import.sh [--dry-run] [--refresh] [--limit N] [--only NAME]...
#                  [--min-free-mb N] [--pause SEC]
#
# For each git repo in the AzDO project: clone it host-side into
# $REPO_ROOT/<instance> (the shared VHD), then create a STOPPED container with
# the repo parity-mounted, docker-host access, and kiro-cli auth seeded.
#
# Deliberately serial: clones are nice/ionice'd and containers are never
# started, so the job stays cheap no matter how many repos there are.
# Resumable: completed repos are recorded and skipped on re-run.
#
# Repo names/URLs and the PAT stay OUT of this git repo (state lives under
# $AZDO_STATE_DIR, default ~/.local/state/azdo-import).

set -euo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

usage() { sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

# --- config (override via env) ---
: "${AZDO_STATE_DIR:=$HOME/.local/state/azdo-import}"
: "${AZDO_PAT_FILE:=$HOME/.config/azdo/pat}"
: "${AZDO_SKIP:=}"                         # comma-separated ORIGINAL repo names to skip
: "${AZDO_NAME_MAP:=}"                     # comma-separated Original=instance renames
: "${MIN_FREE_MB:=5120}"                   # refuse to clone below this free space
: "${PAUSE:=0}"                            # seconds to idle between repos

REPOS_TSV="$AZDO_STATE_DIR/repos.tsv"
DONE_TSV="$AZDO_STATE_DIR/done.tsv"
FAILED_TSV="$AZDO_STATE_DIR/failed.tsv"
LOG="$AZDO_STATE_DIR/import.log"

dry_run=0 refresh=0 limit=0 pause="$PAUSE"
declare -a only=()
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)     dry_run=1;;
    --refresh)     refresh=1;;
    --limit)       limit="${2:?N}"; shift;;
    --only)        only+=("${2:?NAME}"); shift;;
    --min-free-mb) MIN_FREE_MB="${2:?N}"; shift;;
    --pause)       pause="${2:?SEC}"; shift;;
    -h|--help)     usage 0;;
    *)             die "unknown argument: $1";;
  esac
  shift
done

log() { printf '%s %s\n' "$(date -Is)" "$*" >>"$LOG"; }

# --- preflight ---
need_cmd git; need_cmd python3; need_incus; need_shared_code
image_exists || die "image '$IMAGE_ALIAS' missing; run scripts/build-golden.sh"
[ -s "$AZDO_PAT_FILE" ] || [ -n "${AZDO_PAT:-}" ] \
  || die "no PAT: set \$AZDO_PAT or write it to $AZDO_PAT_FILE (chmod 600)"
mkdir -p "$AZDO_STATE_DIR"; chmod 700 "$AZDO_STATE_DIR"
touch "$DONE_TSV" "$FAILED_TSV" "$LOG"

# PAT is exported for git's credential helper only; never echoed, never written
# into a remote URL, never passed as an argument.
if [ -z "${AZDO_PAT:-}" ]; then
  AZDO_PAT="$(tr -d '\r\n' <"$AZDO_PAT_FILE")"
fi
export AZDO_PAT
# Feeds the PAT to git over stdout of a shell function, so it stays off argv.
CRED_HELPER='!f() { test "$1" = get && printf "username=pat\npassword=%s\n" "$AZDO_PAT"; }; f'

# --- discovery ---
if [ "$refresh" = 1 ] || [ ! -s "$REPOS_TSV" ]; then
  info "enumerating repos from Azure DevOps"
  tmp="$(mktemp)"
  if ! python3 "$HERE/azdo-list-repos.py" >"$tmp"; then rm -f "$tmp"; die "repo enumeration failed"; fi
  mv "$tmp" "$REPOS_TSV"; chmod 600 "$REPOS_TSV"
fi
[ -s "$REPOS_TSV" ] || die "no repos discovered"

# --- helpers ---
lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

is_skipped() {
  local want; want="$(lc "$1")" IFS=,
  local entry; for entry in $AZDO_SKIP; do [ "$(lc "$entry")" = "$want" ] && return 0; done
  return 1
}

mapped_name() {  # honor AZDO_NAME_MAP overrides, else the sanitized default
  local want; want="$(lc "$1")" IFS=,
  local entry; for entry in $AZDO_NAME_MAP; do
    [ "$(lc "${entry%%=*}")" = "$want" ] && { printf '%s' "${entry#*=}"; return 0; }
  done
  printf '%s' "$2"
}

wanted() {  # with --only, restrict to the named repos/instances
  [ "${#only[@]}" -eq 0 ] && return 0
  local o; for o in "${only[@]}"; do
    [ "$(lc "$o")" = "$(lc "$1")" ] || [ "$(lc "$o")" = "$(lc "$2")" ] && return 0
  done
  return 1
}

already_done() { grep -qF "$(printf '%s\t' "$1")" "$DONE_TSV" 2>/dev/null; }

free_mb() { df --output=avail -BM "$REPO_ROOT" 2>/dev/null | tail -1 | tr -dc '0-9'; }

nice_git() {
  if command -v ionice >/dev/null 2>&1; then
    nice -n 10 ionice -c3 git "$@"
  else
    nice -n 10 git "$@"
  fi
}

clone_repo() {  # $1=url $2=dest  (clone to a .partial dir, then move into place)
  local url="$1" dest="$2" partial="${2%/*}/.partial-${2##*/}"
  rm -rf "$partial"
  GIT_TERMINAL_PROMPT=0 nice_git -c credential.helper= -c credential.helper="$CRED_HELPER" \
    clone --quiet "$url" "$partial" || return 1
  rmdir "$dest" 2>/dev/null || true          # cb/mkdir may have left it empty
  mv "$partial" "$dest"
}

ensure_parity_device() {  # idempotent: add the workspace disk if absent
  local name="$1" dir="$2" src
  src="$(incus config device get "$name" workspace source 2>/dev/null || true)"
  if [ -z "$src" ]; then
    incus config device add "$name" workspace disk source="$dir" path="$dir" >/dev/null
    info "  added parity device -> $dir"
  elif [ "$src" != "$dir" ]; then
    warn "  '$name' workspace device points at $src (expected $dir) — left alone"
  fi
}

process_repo() {  # $1=repo $2=inst $3=url
  local repo="$1" inst="$2" url="$3" dir="$REPO_ROOT/$2"

  # 1. clone (skip if a working tree is already there)
  if [ -d "$dir/.git" ]; then
    info "  repo already cloned"
  elif [ -d "$dir" ] && [ -n "$(ls -A "$dir" 2>/dev/null)" ]; then
    warn "  $dir is non-empty but not a git repo — leaving it, container only"
  else
    local avail; avail="$(free_mb)"
    [ "${avail:-0}" -ge "$MIN_FREE_MB" ] \
      || { warn "  only ${avail}MB free on $REPO_ROOT (min $MIN_FREE_MB) — aborting run"; return 2; }
    info "  cloning"
    clone_repo "$url" "$dir" || { warn "  clone failed"; return 1; }
  fi

  # 2. container (stopped), parity mount, docker-host + kiro auth
  if instance_exists "$inst"; then
    info "  instance exists — reusing"
    ensure_parity_device "$inst" "$dir"
    inject_docker_host "$inst" >/dev/null
    inject_kiro_auth "$inst" >/dev/null
  else
    info "  creating stopped container"
    "$HERE/cb" create "$inst" --no-start >/dev/null || { warn "  container create failed"; return 1; }
  fi

  # 3. sanity: no credential leaked into the remote URL
  if [ -d "$dir/.git" ]; then
    local remote; remote="$(git -C "$dir" remote get-url origin 2>/dev/null || true)"
    case "$remote" in *:*@*) warn "  remote URL contains credentials — scrubbing";
      git -C "$dir" remote set-url origin "$url";; esac
  fi
  return 0
}

# --- plan ---
declare -a plan_repo=() plan_inst=() plan_url=()
skipped=0 done_already=0
while IFS=$'\t' read -r repo inst url size; do
  [ -n "${repo:-}" ] || continue
  inst="$(mapped_name "$repo" "$inst")"
  wanted "$repo" "$inst" || continue
  if is_skipped "$repo"; then skipped=$((skipped+1)); continue; fi
  if already_done "$inst"; then done_already=$((done_already+1)); continue; fi
  plan_repo+=("$repo"); plan_inst+=("$inst"); plan_url+=("$url")
done <"$REPOS_TSV"

total="${#plan_repo[@]}"
if [ "$limit" -gt 0 ] && [ "$total" -gt "$limit" ]; then total="$limit"; fi

info "plan: $total to process | $skipped skipped by config | $done_already already done"
info "free space on $REPO_ROOT: $(free_mb)MB (min $MIN_FREE_MB)"
if [ "$dry_run" = 1 ]; then
  for ((i=0; i<total; i++)); do
    printf '  %2d. %-44s -> %-44s %s\n' "$((i+1))" "${plan_repo[i]}" "${plan_inst[i]}" \
      "$([ -d "$REPO_ROOT/${plan_inst[i]}/.git" ] && echo '[cloned]')$(instance_exists "${plan_inst[i]}" && echo '[instance]')"
  done
  info "dry run — nothing changed"
  exit 0
fi

# --- run ---
ok=0 failed=0
for ((i=0; i<total; i++)); do
  repo="${plan_repo[i]}"; inst="${plan_inst[i]}"; url="${plan_url[i]}"
  info "[$((i+1))/$total] $repo -> $inst"
  log "start $inst ($repo)"
  rc=0; process_repo "$repo" "$inst" "$url" || rc=$?
  case "$rc" in
    0) printf '%s\t%s\t%s\n' "$inst" "$repo" "$(date -Is)" >>"$DONE_TSV"
       ok=$((ok+1)); log "ok $inst";;
    2) log "abort (disk) $inst"; warn "stopping early — re-run after freeing space"; break;;
    *) printf '%s\t%s\t%s\n' "$inst" "$repo" "$(date -Is)" >>"$FAILED_TSV"
       failed=$((failed+1)); log "FAILED $inst";;
  esac
  [ "$pause" != 0 ] && sleep "$pause"
done

info "done: $ok ok, $failed failed (log: $LOG)"
[ "$failed" -gt 0 ] && warn "failures recorded in $FAILED_TSV — re-run to retry them"
exit 0
