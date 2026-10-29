#!/usr/bin/env bash
# Shared config + helpers for the per-codebase Incus workflow.
# Source this from the other scripts.

set -euo pipefail

LIB_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
: "${ASSETS_DIR:=$LIB_DIR/assets}"        # files pushed verbatim into instances

# --- config (override via env) ---
: "${REPO_ROOT:=/mnt/wsl/code}"           # canonical repos: cross-distro shared VHD
                                          # (dev-host + docker-host see the SAME path)
: "${POOL:=default}"                      # incus storage pool
: "${POOL_DIR:=/home/colin/incus}"        # pool backing location (fast ext4)
: "${POOL_SIZE:=60GiB}"                    # btrfs loop size
: "${NETWORK:=incusbr0}"                   # outbound-only NAT bridge
: "${PROFILE:=dev}"                        # profile applied to every instance
: "${IMAGE_ALIAS:=dev-golden}"             # golden image alias
: "${BASE_IMAGE:=images:ubuntu/24.04}"     # base for the golden image
# Repos are PARITY-mounted: the in-VM path equals the host path ($REPO_ROOT/<name>)
# so `docker -v "$(pwd)":...` resolves identically on the remote docker-host daemon.
: "${HOST_UID:=1000}"                      # host/sub-VM colin uid (shared-disk owner)

# --- incus daemon responsiveness ---
# The daemon usually answers in ~20ms but can stall (5m17s observed once, then
# 0.02s on every retry). Bound the wait so a stall reports itself instead of
# looking like a hung script.
: "${INCUS_TIMEOUT:=15}"                   # max seconds to wait for the daemon
: "${INCUS_SLOW_AFTER:=2}"                 # seconds before printing a "waiting" notice

# --- docker-host (sibling WSL2 distro) access ---
: "${DH_KEYDIR:=$HOME/.config/docker-host}"  # keypair + known_hosts (NOT in repo)
: "${DH_ADDR:=10.126.115.1}"                 # stable incusbr0 gateway (shared WSL netns)
: "${DH_PORT:=2222}"                         # sshd port on docker-host
: "${DH_USER:=colin}"                        # docker-host login user

# --- GitHub access (PAT for git push + gh) ---
# PATs are PER INSTANCE. Each token is a 0600 file on the host, never in this
# repo and never baked into the golden image:
#
#   ~/.config/github/pat.d/<instance>   <- used for that instance only
#   ~/.config/github/pat                <- optional fallback for instances
#                                          without their own file
#
# A token needs Contents: Read and write (plus Pull requests: Read and write for
# `gh pr`) on its repos, and org approval for org-owned repos.
: "${GH_PATDIR:=$HOME/.config/github/pat.d}"
: "${GH_PATFILE:=$HOME/.config/github/pat}"

# Which token file applies to an instance. Prints the path, or fails if none.
gh_patfile_for() {
  local name="$1"
  if [ -s "$GH_PATDIR/$name" ]; then printf '%s' "$GH_PATDIR/$name"; return 0; fi
  if [ -s "$GH_PATFILE" ];      then printf '%s' "$GH_PATFILE";      return 0; fi
  return 1
}

# --- kiro-cli auth seeding ---
# The whole session (IAM Identity Center tokens) lives in one sqlite db. Copying
# it into a new instance avoids a per-container browser login. Injected at
# create time, never baked into the golden image (it's a live, expiring token).
: "${KIRO_STATE_DB:=$HOME/.local/share/kiro-cli/data.sqlite3}"
: "${KIRO_STATE_DIR_IN_VM:=/home/colin/.local/share/kiro-cli}"

# --- output helpers ---
info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarn:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# --- guards ---
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }

# Run an incus command with a bounded wait, quietly. Exit status is the
# command's own, except 124 which means `timeout` killed it.
incus_probe() {
  if command -v timeout >/dev/null 2>&1; then
    timeout "$INCUS_TIMEOUT" incus "$@" >/dev/null 2>&1
  else
    incus "$@" >/dev/null 2>&1
  fi
}

# Guard: incus is installed AND its daemon actually answers.
#
# Why this is more than a one-liner: the daemon normally answers in ~20ms, but it
# has been observed taking **5m17s** on this host (transient; every retry was
# 0.02s). This guard runs before any output, so a stalled daemon made every `cb`
# command — `cb tui` especially — look like a hung script with a blinking cursor
# and no message. So: nag while waiting, cap the wait, and say what to do next.
need_incus() {
  command -v incus >/dev/null 2>&1 || die "incus not installed; run scripts/host-bootstrap.sh"

  local nag=""
  if [ -t 2 ]; then
    ( sleep "$INCUS_SLOW_AFTER"
      printf '\033[1;33mwaiting:\033[0m incus daemon has not answered yet — giving it %ss…\n' \
        "$INCUS_TIMEOUT" >&2 ) &
    nag=$!
  fi
  local rc=0
  incus_probe info || rc=$?
  if [ -n "$nag" ]; then kill "$nag" 2>/dev/null || true; wait "$nag" 2>/dev/null || true; fi

  case "$rc" in
    0) return 0 ;;
    124) die "incus daemon did not answer within ${INCUS_TIMEOUT}s ('incus info' timed out).
  This has been transient here before — try again first.
  If it persists:  systemctl status incus incus.socket
                   sudo systemctl restart incus
  If this host is simply slow:  INCUS_TIMEOUT=60 $(basename "${0:-cb}") ..." ;;
    *) die "cannot talk to incus ('incus info' exited $rc).
  Usually the group membership isn't active in this shell:
    exec bash -l        # picks up incus-admin
  Otherwise:  systemctl status incus" ;;
  esac
}

# The shared code VHD is host-owned and mounted by Windows (wsl --mount). If it
# isn't mounted, sub-VMs would boot with an empty workspace — refuse and ask the
# operator to mount it (do NOT try to mount from inside this distro).
need_shared_code() {
  mountpoint -q "$REPO_ROOT" 2>/dev/null && return 0
  # Distinguish "VHD not attached to the WSL VM" from "attached but the mount is
  # gone" (seen after a distro restart: wsl --mount then reports "already
  # attached", so re-running the mount script looks like a no-op).
  if [ -e /dev/disk/by-label/shared-code ]; then
    die "shared code disk is ATTACHED ($(readlink -f /dev/disk/by-label/shared-code)) but NOT MOUNTED at $REPO_ROOT.
  This happens after a WSL/distro restart. On Windows, detach and re-mount it:
    wsl --unmount <path-to-shared-code.vhdx>
    wsl --mount --vhd <path-to-shared-code.vhdx> --name code
  Do NOT mount it from inside this distro: docker-host would not see the mount."
  fi
  die "shared code disk not attached (no /dev/disk/by-label/shared-code) and not mounted at $REPO_ROOT — ask the Windows operator to run mount-shared-code.ps1"
}

# Sanitize an arg into a consistent instance name: lowercase, [a-z0-9-] only.
instance_name() {
  local raw="${1:?name required}"
  raw="$(basename "$raw")"
  printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-' \
    | sed -E 's/-+/-/g; s/^-+//; s/-+$//'
}

instance_exists() { incus info "$1" >/dev/null 2>&1; }

image_exists() { incus image info "$IMAGE_ALIAS" >/dev/null 2>&1; }

# Create a directory inside an instance with explicit ownership. Works whether
# the instance is running or stopped (no `incus exec`, so no agent needed).
instance_mkdir() {
  local name="$1" path="$2" mode="${3:-0755}" uid="${4:-$HOST_UID}" gid="${5:-$HOST_UID}"
  incus file create -p -f --type=directory --uid "$uid" --gid "$gid" --mode "$mode" \
    "$name$path" >/dev/null 2>&1 || true
}

# Inject docker-host SSH access into an instance (key is never baked into the
# golden image or committed to the repo). Idempotent, and safe on a STOPPED
# instance — everything goes through `incus file`, never `incus exec`.
inject_docker_host() {
  local name="$1"
  if [ ! -f "$DH_KEYDIR/id_ed25519" ] || [ ! -f "$DH_KEYDIR/known_hosts" ]; then
    warn "docker-host key/known_hosts not in $DH_KEYDIR — skipping docker-host wiring."
    warn "  (provision docker-host first: see scripts/docker-host-setup.sh)"
    return 0
  fi
  instance_mkdir "$name" /home/colin/.ssh 0700
  incus file push "$DH_KEYDIR/id_ed25519"  "$name/home/colin/.ssh/docker-host_ed25519"     --uid "$HOST_UID" --gid "$HOST_UID" --mode 0600
  incus file push "$DH_KEYDIR/known_hosts" "$name/home/colin/.ssh/docker-host_known_hosts" --uid "$HOST_UID" --gid "$HOST_UID" --mode 0600
  printf 'Host %s\n    Port %s\n    User %s\n    IdentityFile ~/.ssh/docker-host_ed25519\n    UserKnownHostsFile ~/.ssh/docker-host_known_hosts\n    IdentitiesOnly yes\n    StrictHostKeyChecking yes\n' \
    "$DH_ADDR" "$DH_PORT" "$DH_USER" \
    | incus file push - "$name/home/colin/.ssh/config" --uid "$HOST_UID" --gid "$HOST_UID" --mode 0600
  printf 'export DOCKER_HOST=ssh://%s@%s:%s\n' "$DH_USER" "$DH_ADDR" "$DH_PORT" \
    | incus file push - "$name/etc/profile.d/docker-host.sh" --uid 0 --gid 0 --mode 0644
  info "wired docker-host access: DOCKER_HOST=ssh://$DH_USER@$DH_ADDR:$DH_PORT"
}

# Seed the host's kiro-cli session into an instance so it doesn't need a fresh
# browser login. Auth lives entirely in one sqlite db; we snapshot it with the
# sqlite backup API (consistent copy of a live db) and push it as colin.
# Deliberately NOT baked into the golden image: it's a live token that expires.
# Safe on a STOPPED instance. Re-run after a token rotation: cb kiro-setup <name>.
inject_kiro_auth() {
  local name="$1"
  if [ ! -f "$KIRO_STATE_DB" ]; then
    warn "no kiro-cli state at $KIRO_STATE_DB — skipping kiro auth injection."
    return 0
  fi
  command -v python3 >/dev/null 2>&1 || { warn "python3 missing — skipping kiro auth injection."; return 0; }
  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/kiro-auth.XXXXXX")"
  chmod 600 "$tmp"
  if ! python3 -c '
import sqlite3, sys
src, dst = sys.argv[1], sys.argv[2]
s = sqlite3.connect(f"file:{src}?mode=ro", uri=True)
d = sqlite3.connect(dst)
s.backup(d)
d.close(); s.close()
' "$KIRO_STATE_DB" "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    warn "could not snapshot kiro-cli db — skipping kiro auth injection."
    return 0
  fi
  instance_mkdir "$name" /home/colin/.local 0755
  instance_mkdir "$name" /home/colin/.local/share 0755
  instance_mkdir "$name" "$KIRO_STATE_DIR_IN_VM" 0755
  incus file push "$tmp" "$name$KIRO_STATE_DIR_IN_VM/data.sqlite3" \
    --uid "$HOST_UID" --gid "$HOST_UID" --mode 0600
  rm -f "$tmp"
  info "seeded kiro-cli auth (re-run 'cb kiro-setup $name' if the session expires)"
}

# Resolve a token's GitHub login (needed for gh's hosts.yml). The token is fed
# to curl via --config on stdin so it never appears on argv. No caching: each
# instance may carry a different token.
gh_pat_login() {
  local patfile="$1"
  command -v curl >/dev/null 2>&1 || return 1
  [ -s "$patfile" ] || return 1
  local body
  body="$(printf 'header = "Authorization: Bearer %s"\nurl = "https://api.github.com/user"\nsilent\n' \
            "$(tr -d '\r\n' <"$patfile")" | curl --config - --max-time 10 2>/dev/null)" || return 1
  printf '%s' "$body" \
    | sed -n 's/.*"login"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1
}

# Wire GitHub auth into one instance so `git push` and `gh` work unattended.
#
# Design notes, both learned the hard way:
#
#  * Interactive `git push` MUST still prompt. Setting GIT_TERMINAL_PROMPT=0
#    globally breaks the normal human workflow. So it is set ONLY for
#    non-interactive bash, via BASH_ENV -- which interactive shells don't read.
#    You get prompts; the agent gets a fast error instead of an invisible
#    deadlock on /dev/tty that looks exactly like resource contention.
#  * Tokens are per instance (see GH_PATDIR). Inside the container the token
#    always lands at the same path, so the helper stays dead simple.
#
# Idempotent, and safe on a STOPPED instance: everything goes through
# `incus file`, never `incus exec`.
inject_github_pat() {
  local name="$1" patfile

  [ -f "$ASSETS_DIR/git-credential-github-pat" ] && incus file push \
    "$ASSETS_DIR/git-credential-github-pat" "$name/usr/local/bin/git-credential-github-pat" \
    --uid 0 --gid 0 --mode 0755 >/dev/null
  [ -f "$ASSETS_DIR/git-agent-guard.sh" ] && incus file push \
    "$ASSETS_DIR/git-agent-guard.sh" "$name/etc/git-agent-guard.sh" \
    --uid 0 --gid 0 --mode 0644 >/dev/null
  printf 'export BASH_ENV=/etc/git-agent-guard.sh\n' \
    | incus file push - "$name/etc/profile.d/git-agent-guard.sh" --uid 0 --gid 0 --mode 0644 >/dev/null

  # System scope, so a user's own ~/.gitconfig is never touched. No username is
  # pinned here: if the token is ever missing, git prompts normally.
  printf '[credential "https://github.com"]\n\thelper = github-pat\n' \
    | incus file push - "$name/etc/gitconfig" --uid 0 --gid 0 --mode 0644 >/dev/null

  if ! patfile="$(gh_patfile_for "$name")"; then
    warn "no PAT for '$name' — write one to $GH_PATDIR/$name (chmod 600), then:"
    warn "  scripts/cb github-setup $name"
    warn "  (until then git will prompt interactively, as it does by default)"
    return 0
  fi

  instance_mkdir "$name" /home/colin/.config 0755
  instance_mkdir "$name" /home/colin/.config/github 0700
  incus file push "$patfile" "$name/home/colin/.config/github/pat" \
    --uid "$HOST_UID" --gid "$HOST_UID" --mode 0600 >/dev/null

  # gh reads hosts.yml; write it directly so this works on a stopped instance.
  # printf is a shell builtin, so the token never lands on an external argv.
  local login
  login="$(gh_pat_login "$patfile")" || login=""
  if [ -n "$login" ]; then
    instance_mkdir "$name" /home/colin/.config/gh 0700
    printf 'github.com:\n    users:\n        %s:\n            oauth_token: %s\n    oauth_token: %s\n    user: %s\n    git_protocol: https\n' \
      "$login" "$(tr -d '\r\n' <"$patfile")" "$(tr -d '\r\n' <"$patfile")" "$login" \
      | incus file push - "$name/home/colin/.config/gh/hosts.yml" \
        --uid "$HOST_UID" --gid "$HOST_UID" --mode 0600 >/dev/null
    info "wired GitHub auth for '$name' as $login ($(basename "$(dirname "$patfile")")/$(basename "$patfile"))"
  else
    warn "token for '$name' installed, but api.github.com didn't confirm a login."
    warn "  git will use it; gh may not. Check the token is valid and unexpired."
  fi
}
