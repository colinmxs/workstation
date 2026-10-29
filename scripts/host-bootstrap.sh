#!/usr/bin/env bash
# Once per host: install Incus and initialize pool, network, and profile.
# Idempotent where practical. Requires sudo. Asks before installing.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

info "This will: apt-get install incus + btrfs-progs, add 'colin' to incus-admin+kvm,"
info "and create pool '$POOL', network '$NETWORK', and profile '$PROFILE'."
read -rp "Proceed? [y/N] " ans; [[ "$ans" =~ ^[Yy]$ ]] || die "aborted"

# 1) packages
if ! command -v incus >/dev/null 2>&1; then
  info "installing incus + btrfs-progs"
  sudo apt-get update
  sudo apt-get install -y incus btrfs-progs zstd
else
  info "incus already installed: $(incus --version)"
fi

# 2) groups (apply on next login)
info "adding colin to incus-admin + kvm"
sudo usermod -aG incus-admin,kvm colin

# Run incus admin as root for the remaining init so we don't depend on the
# new group membership in this shell.
SUDO_INCUS=(sudo incus)

# 2b) permit mapping host uid/gid $HOST_UID into unprivileged containers.
# Required for `raw.idmap both $HOST_UID $HOST_UID` so files on the parity-mounted
# shared code disk (owned by host colin) line up as colin inside the container.
# Without this, container start fails: "newuidmap: uid range ... not allowed".
for f in /etc/subuid /etc/subgid; do
  if ! grep -qE "^root:$HOST_UID:1$" "$f" 2>/dev/null; then
    info "allowing root to map host id $HOST_UID in $f"
    echo "root:$HOST_UID:1" | sudo tee -a "$f" >/dev/null
  fi
done

# 3) storage pool (btrfs loop, fallback dir)
if "${SUDO_INCUS[@]}" storage info "$POOL" >/dev/null 2>&1; then
  info "pool '$POOL' already exists"
else
  mkdir -p "$POOL_DIR"
  created=0
  # Prefer btrfs (CoW clones/snapshots) via an Incus-managed loop image.
  # Passing only size= lets Incus create+format+loop-mount the image itself
  # (source=<path> makes it expect an existing btrfs and fails in WSL).
  info "attempting btrfs pool '$POOL' (Incus-managed loop, $POOL_SIZE)"
  if "${SUDO_INCUS[@]}" storage create "$POOL" btrfs size="$POOL_SIZE"; then
    created=1
    info "btrfs pool created"
  else
    warn "btrfs pool failed; falling back to dir backend at $POOL_DIR/dir"
    mkdir -p "$POOL_DIR/dir"
    "${SUDO_INCUS[@]}" storage create "$POOL" dir source="$POOL_DIR/dir"
    created=1
    info "dir pool created"
  fi
fi

# 4) outbound-only NAT network
if "${SUDO_INCUS[@]}" network info "$NETWORK" >/dev/null 2>&1; then
  info "network '$NETWORK' already exists"
else
  info "creating outbound-only NAT bridge '$NETWORK'"
  "${SUDO_INCUS[@]}" network create "$NETWORK" ipv4.address=auto ipv4.nat=true ipv6.address=none
fi

# 5) profile
if "${SUDO_INCUS[@]}" profile show "$PROFILE" >/dev/null 2>&1; then
  info "profile '$PROFILE' already exists"
else
  info "creating profile '$PROFILE'"
  "${SUDO_INCUS[@]}" profile create "$PROFILE"
  "${SUDO_INCUS[@]}" profile device add "$PROFILE" root disk pool="$POOL" path=/
  "${SUDO_INCUS[@]}" profile device add "$PROFILE" eth0 nic network="$NETWORK" name=eth0
  "${SUDO_INCUS[@]}" profile set "$PROFILE" raw.idmap "both $HOST_UID $HOST_UID"
  "${SUDO_INCUS[@]}" profile set "$PROFILE" limits.cpu=4 limits.memory=4GiB
fi

# 6) put `cb` on PATH (~/.local/bin is on the default login PATH)
mkdir -p "$HOME/.local/bin"
ln -sf "$HERE/cb" "$HOME/.local/bin/cb"
info "linked cb -> ~/.local/bin/cb"

info "done. Run 'exec bash -l' to pick up the incus-admin group, then scripts/build-golden.sh"
