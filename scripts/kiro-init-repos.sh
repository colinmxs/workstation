#!/usr/bin/env bash
# Review + kiro-initialize each imported repo, using the container that owns it.
#
#   kiro-init-repos.sh [--dry-run] [--jobs N] [--only NAME]... [--limit N]
#                      [--timeout SEC] [--force]
#
# For every repo WITHOUT a .kiro/ directory: start its container, run kiro-cli
# non-interactively inside it to code-review the parity-mounted repo and write
# .kiro/steering/{product,tech,structure}.md + .kiro/CODE_REVIEW.md, then stop
# the container again (containers already running are left running).
#
# The agent is restricted to fs_read,fs_write — it cannot run commands, so no
# builds/restores are triggered and nothing is committed or pushed.
# Resumable: state in $KIRO_INIT_STATE_DIR (default ~/.local/state/kiro-init).

set -euo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

usage() { sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

: "${KIRO_INIT_STATE_DIR:=$HOME/.local/state/kiro-init}"
: "${AZDO_STATE_DIR:=$HOME/.local/state/azdo-import}"
: "${JOBS:=3}"                 # concurrent containers (each runs one agent)
: "${TIMEOUT:=1800}"           # per-repo wall clock cap (seconds)
: "${TRUST_TOOLS:=fs_read,fs_write}"
: "${AZDO_SKIP:=}"             # same semantics as azdo-import.sh
: "${AZDO_NAME_MAP:=}"

REPOS_TSV="$AZDO_STATE_DIR/repos.tsv"
DONE_TSV="$KIRO_INIT_STATE_DIR/done.tsv"
FAILED_TSV="$KIRO_INIT_STATE_DIR/failed.tsv"
LOGDIR="$KIRO_INIT_STATE_DIR/logs"

dry_run=0 force=0 limit=0
declare -a only=()
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) dry_run=1;;
    --jobs)    JOBS="${2:?N}"; shift;;
    --limit)   limit="${2:?N}"; shift;;
    --only)    only+=("${2:?NAME}"); shift;;
    --timeout) TIMEOUT="${2:?SEC}"; shift;;
    --force)   force=1;;
    -h|--help) usage 0;;
    *)         die "unknown argument: $1";;
  esac
  shift
done

need_incus; need_shared_code
[ -s "$REPOS_TSV" ] || die "no repo manifest at $REPOS_TSV — run scripts/azdo-import.sh first"
mkdir -p "$LOGDIR"; chmod 700 "$KIRO_INIT_STATE_DIR"
touch "$DONE_TSV" "$FAILED_TSV"

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

# Resolve the actual repo root: usually $REPO_ROOT/<inst>, but a pre-existing
# clone may sit one level down (e.g. <inst>/<OriginalRepoName>).
repo_root() {
  local dir="$REPO_ROOT/$1" sub
  if [ -d "$dir/.git" ]; then printf '%s' "$dir"; return 0; fi
  for sub in "$dir"/*/; do
    [ -d "$sub/.git" ] && { printf '%s' "${sub%/}"; return 0; }
  done
  printf '%s' "$dir"
}

# ---- the prompt -------------------------------------------------------------
# Deliberately explicit about scope, length, and secret hygiene. The agent runs
# unattended, so vague instructions here turn into 80 files of filler.
build_prompt() {
  local repo="$1" root="$2"
  cat <<EOF
You are initializing this repository for Kiro. Work only inside $root.

Repository: $repo (Azure DevOps${AZDO_ORG:+, org $AZDO_ORG}). Read the code before writing.
Read broadly first: solution/project files, entry points (Program.cs, Startup.cs,
app.ts, handlers), configuration, infrastructure-as-code (CDK stacks, templates),
CI definitions (azure-pipelines.yml), data access, and any auth code.

Then create exactly these four files:

1. $root/.kiro/steering/product.md — what this system does, who uses it, the
   problem it solves, and its external integrations. Facts from the code only.
2. $root/.kiro/steering/tech.md — language/framework versions, key dependencies,
   how to build/test/run/deploy, AWS services and IaC used, CI pipeline summary.
3. $root/.kiro/steering/structure.md — directory layout, key modules and their
   responsibilities, naming/architectural conventions actually used here.
4. $root/.kiro/CODE_REVIEW.md — a genuine code review dated $(date +%Y-%m-%d):
   architecture summary; correctness/security concerns (auth, input validation,
   injection, secret handling, IAM breadth); dependency and runtime currency
   (flag EOL frameworks); test coverage and CI/CD state; operational risks;
   and concrete prioritized recommendations.

Hard rules:
- Steering files are loaded on every inference: keep each under 60 lines, terse,
  no filler, no restating the obvious. CODE_REVIEW.md: under 200 lines.
- Cite real file paths for every claim. If you cannot determine something, say
  so plainly instead of guessing.
- NEVER copy secret values (keys, tokens, connection strings, passwords) into
  any file. If you find a committed secret, note the file path and that it needs
  rotating — never the value itself.
- Do NOT modify, refactor, or delete any existing source file. Only create the
  four files above.
- Do NOT run git commands and do NOT commit anything.
- If this repo is nearly empty or is only a pipeline stub, say that briefly in
  each file rather than padding it out.

When the four files exist, reply with the single line: KIRO_INIT_DONE
EOF
}

# ---- per-repo work ---------------------------------------------------------
process_one() {  # $1=repo $2=inst ; returns 0 ok, 1 fail, 3 skip
  local repo="$1" inst="$2" root was_running=0 rc=0
  root="$(repo_root "$inst")"
  local log="$LOGDIR/$inst.log"

  if [ -d "$root/.kiro" ] && [ "$force" = 0 ]; then return 3; fi
  [ -d "$root/.git" ] || { echo "no clone at $root" >>"$log"; return 1; }

  incus info "$inst" >/dev/null 2>&1 || { echo "no such instance" >>"$log"; return 1; }
  [ "$(incus list "$inst" --format csv -c s 2>/dev/null | head -1)" = RUNNING ] && was_running=1

  if [ "$was_running" = 0 ]; then
    incus start "$inst" >/dev/null 2>&1 || { echo "start failed" >>"$log"; return 1; }
    # wait for the agent/exec path to come up
    local i; for i in $(seq 1 30); do incus exec "$inst" -- true >/dev/null 2>&1 && break; sleep 1; done
  fi

  local prompt; prompt="$(build_prompt "$repo" "$root")"
  # Prompt goes in via a file to keep quoting sane and stay off the command line.
  printf '%s' "$prompt" | incus file push - "$inst/tmp/kiro-init-prompt.txt" \
    --uid "$HOST_UID" --gid "$HOST_UID" --mode 0600 >/dev/null 2>&1

  {
    echo "=== $repo -> $inst @ $(date -Is) (root=$root) ==="
    timeout "$TIMEOUT" incus exec "$inst" -- su -l colin -c \
      "cd '$root' && kiro-cli chat --no-interactive --trust-tools='$TRUST_TOOLS' \"\$(cat /tmp/kiro-init-prompt.txt)\"" 2>&1
  } >>"$log" || rc=$?

  incus exec "$inst" -- rm -f /tmp/kiro-init-prompt.txt >/dev/null 2>&1 || true
  [ "$was_running" = 0 ] && incus stop "$inst" >/dev/null 2>&1 || true

  # Success is judged by artifacts on disk, not by the agent's exit code.
  local missing=0 f
  for f in .kiro/steering/product.md .kiro/steering/tech.md .kiro/steering/structure.md .kiro/CODE_REVIEW.md; do
    [ -s "$root/$f" ] || { missing=$((missing+1)); echo "MISSING $f" >>"$log"; }
  done
  [ "$missing" -eq 0 ] || return 1
  [ "$rc" -eq 0 ] || echo "note: agent exit rc=$rc but all artifacts present" >>"$log"
  return 0
}

# ---- plan ------------------------------------------------------------------
wanted() {
  [ "${#only[@]}" -eq 0 ] && return 0
  local o; for o in "${only[@]}"; do
    [ "$(lc "$o")" = "$(lc "$1")" ] || [ "$(lc "$o")" = "$(lc "$2")" ] && return 0
  done
  return 1
}

declare -a p_repo=() p_inst=()
have_kiro=0 already=0
while IFS=$'\t' read -r repo inst url size; do
  [ -n "${repo:-}" ] || continue
  is_skipped "$repo" && continue
  inst="$(mapped_name "$repo" "$inst")"
  wanted "$repo" "$inst" || continue
  if grep -qF "$(printf '%s\t' "$inst")" "$DONE_TSV" 2>/dev/null && [ "$force" = 0 ]; then
    already=$((already+1)); continue
  fi
  if [ -d "$(repo_root "$inst")/.kiro" ] && [ "$force" = 0 ]; then
    have_kiro=$((have_kiro+1)); continue
  fi
  p_repo+=("$repo"); p_inst+=("$inst")
done <"$REPOS_TSV"

total="${#p_repo[@]}"
[ "$limit" -gt 0 ] && [ "$total" -gt "$limit" ] && total="$limit"

info "plan: $total to initialize | $have_kiro already have .kiro (skipped) | $already recorded done"
info "jobs=$JOBS timeout=${TIMEOUT}s tools=$TRUST_TOOLS logs=$LOGDIR"
if [ "$dry_run" = 1 ]; then
  for ((i=0; i<total; i++)); do printf '  %2d. %-42s (%s)\n' "$((i+1))" "${p_inst[i]}" "${p_repo[i]}"; done
  info "dry run — nothing changed"; exit 0
fi

# ---- run (bounded concurrency) --------------------------------------------
declare -A pid_inst=() pid_repo=()
ok=0 failed=0 skipped=0
reap() {
  local pid="$1" rc=0
  wait "$pid" || rc=$?
  local inst="${pid_inst[$pid]}" repo="${pid_repo[$pid]}"
  case "$rc" in
    0) printf '%s\t%s\t%s\n' "$inst" "$repo" "$(date -Is)" >>"$DONE_TSV"; ok=$((ok+1))
       info "  ok: $inst";;
    3) skipped=$((skipped+1)); info "  skip (already has .kiro): $inst";;
    *) printf '%s\t%s\t%s\n' "$inst" "$repo" "$(date -Is)" >>"$FAILED_TSV"; failed=$((failed+1))
       warn "  FAILED: $inst (see $LOGDIR/$inst.log)";;
  esac
  unset "pid_inst[$pid]" "pid_repo[$pid]"
}

for ((i=0; i<total; i++)); do
  while [ "${#pid_inst[@]}" -ge "$JOBS" ]; do
    for pid in "${!pid_inst[@]}"; do
      kill -0 "$pid" 2>/dev/null || { reap "$pid"; break; }
    done
    sleep 2
  done
  info "[$((i+1))/$total] ${p_repo[i]} -> ${p_inst[i]}"
  process_one "${p_repo[i]}" "${p_inst[i]}" &
  pid_inst[$!]="${p_inst[i]}"; pid_repo[$!]="${p_repo[i]}"
done

while [ "${#pid_inst[@]}" -gt 0 ]; do
  for pid in "${!pid_inst[@]}"; do
    kill -0 "$pid" 2>/dev/null || { reap "$pid"; break; }
  done
  sleep 2
done

info "done: $ok initialized, $skipped skipped, $failed failed"
[ "$failed" -gt 0 ] && warn "re-run to retry failures (logs in $LOGDIR)"
exit 0
