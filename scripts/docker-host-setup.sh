#!/usr/bin/env bash
# Run this INSIDE the `docker-host` WSL2 distro:  wsl -d docker-host
#   bash /mnt/wsl/docker-host-setup/setup.sh
#
# Sets up authenticated SSH access so Incus dev containers (in the Ubuntu-26.04
# distro) can use DOCKER_HOST=ssh://colin@<addr>:2222 to drive this Docker host,
# and installs the firewall hook that keeps Incus container outbound working
# while dockerd is running (shared WSL2 netns; see assets/ensure-incus-forwarding.sh).
#
# Prerequisites on docker-host (not done here): Ubuntu 24.04 with systemd on
# (/etc/wsl.conf [boot] systemd=true), Docker Engine installed from the official
# apt repo, and `colin` in the `docker` group.
#
# Stage from the Ubuntu-26.04 distro first (/mnt/wsl is shared by all distros):
#   S=/mnt/wsl/docker-host-setup; mkdir -p "$S"
#   cp ~/.config/docker-host/id_ed25519.pub            "$S/authorized_keys"
#   cp scripts/docker-host-setup.sh                    "$S/setup.sh"
#   cp scripts/assets/ensure-incus-forwarding.sh       "$S/"
#   cp scripts/assets/docker-incus-forwarding.service  "$S/"
# Afterwards it leaves ssh_host_ed25519_key.pub in $S for building known_hosts.
# Idempotent: safe to re-run.

set -euo pipefail
SSH_PORT=2222
STAGE="/mnt/wsl/docker-host-setup"

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarn:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[ -f "$STAGE/authorized_keys" ] || die "missing $STAGE/authorized_keys — stage it from Ubuntu-26.04 first"
command -v docker >/dev/null 2>&1 || die "docker not installed on this distro — install Docker Engine first (see README)"

info "network identity of this distro (compare eth0 to the Ubuntu-26.04 eth0 to confirm shared-netns):"
ip -br addr show eth0 || true

info "installing openssh-server"
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -qq
sudo apt-get install -y -qq openssh-server

info "configuring sshd on port ${SSH_PORT}, pubkey-only"
sudo install -d -m 0755 /etc/ssh/sshd_config.d
sudo tee /etc/ssh/sshd_config.d/10-docker-host.conf >/dev/null <<EOF
Port ${SSH_PORT}
ListenAddress 0.0.0.0
PasswordAuthentication no
PubkeyAuthentication yes
PermitRootLogin no
AllowUsers colin
EOF

info "installing authorized_keys for colin"
install -d -m 0700 -o colin -g colin "$HOME/.ssh"
install -m 0600 -o colin -g colin "$STAGE/authorized_keys" "$HOME/.ssh/authorized_keys"

info "enabling + starting sshd"
if pidof systemd >/dev/null 2>&1; then
  sudo systemctl enable ssh 2>/dev/null || true
  sudo systemctl restart ssh
  sudo systemctl --no-pager --full status ssh | head -5 || true
else
  sudo service ssh restart || sudo /usr/sbin/sshd
fi

info "publishing this host's SSH host key back to the shared mount (for known_hosts)"
sudo cp /etc/ssh/ssh_host_ed25519_key.pub "$STAGE/ssh_host_ed25519_key.pub"
sudo chmod 644 "$STAGE/ssh_host_ed25519_key.pub"

# dockerd sets the VM-wide FORWARD policy to DROP, which blocks outbound from the
# dev-host's Incus containers. Accept incusbr0 traffic in DOCKER-USER after every
# docker.service start (the rules do not survive a reboot on their own).
if [ -f "$STAGE/ensure-incus-forwarding.sh" ] && [ -f "$STAGE/docker-incus-forwarding.service" ]; then
  info "installing incusbr0 forwarding hook (DOCKER-USER accept rules after docker.service)"
  sudo install -m 0755 -o root -g root "$STAGE/ensure-incus-forwarding.sh" /usr/local/sbin/ensure-incus-forwarding.sh
  sudo install -m 0644 -o root -g root "$STAGE/docker-incus-forwarding.service" /etc/systemd/system/docker-incus-forwarding.service
  if pidof systemd >/dev/null 2>&1; then
    sudo systemctl daemon-reload
    sudo systemctl enable --now docker-incus-forwarding.service
    sudo iptables -S DOCKER-USER | sed 's/^/  /'
  else
    warn "no systemd: run /usr/local/sbin/ensure-incus-forwarding.sh after each docker start"
  fi
else
  warn "forwarding hook assets not staged in $STAGE — Incus container outbound will break while dockerd runs"
fi

info "docker sanity"
docker version --format '  client {{.Client.Version}} / server {{.Server.Version}}' 2>/dev/null || docker version || true
id colin | tr ',' '\n' | grep -q docker && echo "  colin is in docker group: OK"

info "DONE. sshd listening on 0.0.0.0:${SSH_PORT}. eth0 above is this distro's address."
