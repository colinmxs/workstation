#!/usr/bin/env bash
# Installed on the docker-host distro at /usr/local/sbin/ensure-incus-forwarding.sh
# and run by docker-incus-forwarding.service after docker.service.
#
# Why: all WSL2 distros share ONE network namespace. When dockerd starts it sets
# the iptables FORWARD policy to DROP for the whole VM, which silently kills
# outbound traffic from Incus containers on the dev-host's incusbr0 (DNS still
# answers because dnsmasq is local; new TCP flows just time out). Docker gives
# admins the DOCKER-USER chain for exactly this; rules there survive dockerd's
# own rule churn but not a reboot, hence the systemd unit.
set -euo pipefail

ensure_rule() {
  local direction="$1" iface="$2"
  iptables -C DOCKER-USER "$direction" "$iface" -j ACCEPT 2>/dev/null || \
    iptables -I DOCKER-USER 1 "$direction" "$iface" -j ACCEPT
}

iptables -N DOCKER-USER 2>/dev/null || true
ensure_rule -i incusbr0
ensure_rule -o incusbr0
