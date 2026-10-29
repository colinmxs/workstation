#!/usr/bin/env bash
# Build the 'dev-golden' image: a system container with the common toolchain,
# then publish it as a local image alias. Re-runnable.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"
need_incus

BUILDER="golden-build"

if image_exists; then
  read -rp "Image '$IMAGE_ALIAS' exists. Rebuild it? [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]] || die "aborted"
  incus image delete "$IMAGE_ALIAS"
fi

# clean any stale builder
instance_exists "$BUILDER" && incus delete "$BUILDER" --force

info "launching base $BASE_IMAGE as $BUILDER"
incus launch "$BASE_IMAGE" "$BUILDER" -p "$PROFILE"

info "waiting for network in the container"
for _ in $(seq 1 30); do
  incus exec "$BUILDER" -- getent hosts archive.ubuntu.com >/dev/null 2>&1 && break
  sleep 2
done

x() { incus exec "$BUILDER" -- bash -lc "$*"; }

info "installing base apt packages"
x 'export DEBIAN_FRONTEND=noninteractive; apt-get update && apt-get install -y \
   git curl ca-certificates build-essential openssh-client ripgrep fd-find jq vim tmux unzip python3'

info "creating colin at uid/gid 1000 with passwordless sudo"
# The Ubuntu cloud image ships a default 'ubuntu' user at uid 1000. Remove it so
# colin can own uid/gid 1000, which is what `raw.idmap both 1000 1000` maps the
# host's colin to. Otherwise shared-disk files show as the wrong user inside.
x 'set -e; \
   userdel -r ubuntu 2>/dev/null || true; \
   groupadd -g 1000 colin 2>/dev/null || true; \
   id colin >/dev/null 2>&1 || useradd -m -u 1000 -g 1000 -s /bin/bash colin; \
   usermod -aG sudo colin; \
   install -m 0440 /dev/stdin /etc/sudoers.d/colin <<<"colin ALL=(ALL) NOPASSWD:ALL"'

info "installing Node.js LTS + npm + aws-cdk"
x 'curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - && apt-get install -y nodejs && npm i -g aws-cdk'

info "installing AWS CLI v2"
x 'cd /tmp && curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip \
   && unzip -q awscliv2.zip && ./aws/install && rm -rf aws awscliv2.zip'

info "installing uv (as colin)"
incus exec "$BUILDER" -- sudo -u colin bash -lc 'curl -fsSL https://astral.sh/uv/install.sh | sh'

# Docker CLIENT only (cli + buildx + compose, NO daemon). The daemon lives on the
# sibling 'docker-host' WSL2 distro; containers drive it remotely over SSH. The
# SSH key is NOT baked here — it is injected at container-create time by scripts/cb.
info "installing Docker client (cli + buildx + compose; no daemon)"
x 'install -m 0755 -d /etc/apt/keyrings && \
   curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc && \
   chmod a+r /etc/apt/keyrings/docker.asc && \
   . /etc/os-release && \
   echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $VERSION_CODENAME stable" > /etc/apt/sources.list.d/docker.list && \
   apt-get update && apt-get install -y docker-ce-cli docker-buildx-plugin docker-compose-plugin'

info "defaulting DOCKER_HOST to the docker-host distro (stable incusbr0 gateway)"
x 'echo "export DOCKER_HOST=ssh://colin@10.126.115.1:2222" > /etc/profile.d/docker-host.sh'

# kiro-cli: copy the host binaries into the image if present.
KIRO_BIN="$HOME/.local/bin"
if ls "$KIRO_BIN"/kiro-cli* >/dev/null 2>&1; then
  info "pushing host kiro-cli binaries into the image"
  x 'install -d -o colin -g colin /home/colin/.local/bin'
  for f in "$KIRO_BIN"/kiro-cli "$KIRO_BIN"/kiro-cli-chat "$KIRO_BIN"/kiro-cli-term; do
    [ -f "$f" ] && incus file push "$f" "$BUILDER/home/colin/.local/bin/" --uid 1000 --gid 1000 --mode 0755
  done
else
  warn "kiro-cli not found at $KIRO_BIN; skipping. Install it in the image later, or set KIRO_BIN."
fi

# Self-update to the latest release so the image never inherits a stale host
# binary (the host copy is only a seed). No auth needed for `update`; the
# session db is injected per-container by scripts/cb, never baked here.
if [ "${KIRO_SELF_UPDATE:-1}" = 1 ]; then
  info "updating kiro-cli in the image to the latest release"
  incus exec "$BUILDER" -- sudo -u colin bash -lc \
    'PATH=$HOME/.local/bin:$PATH; kiro-cli update -y' || warn "kiro-cli update failed; image keeps the host version"
  incus exec "$BUILDER" -- sudo -u colin bash -lc \
    'PATH=$HOME/.local/bin:$PATH; kiro-cli --version'
  # `update` creates a fresh state db + telemetry/run scratch as a side effect.
  # Drop it: auth is injected at create time and must never be baked.
  incus exec "$BUILDER" -- sudo -u colin bash -lc \
    'rm -rf ~/.local/share/kiro-cli/{data.sqlite3,run,run-receipts,knowledge_bases,telemetry-export-drops.lock} /tmp/kiro-log'
fi

info "ensuring ~/.local/bin on PATH for colin"
x 'grep -q ".local/bin" /home/colin/.bashrc || echo "export PATH=\$HOME/.local/bin:\$PATH" >> /home/colin/.bashrc'

info "installing GitHub CLI (gh)"
x 'install -m 0755 -d /etc/apt/keyrings && \
   curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
     -o /etc/apt/keyrings/githubcli-archive-keyring.gpg && \
   chmod a+r /etc/apt/keyrings/githubcli-archive-keyring.gpg && \
   echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
     > /etc/apt/sources.list.d/github-cli.list && \
   apt-get update && apt-get install -y gh'

# Non-interactive git auth. The PAT itself is NOT baked here -- scripts/cb
# injects a per-instance token at create time.
#
# GIT_TERMINAL_PROMPT is set only for NON-INTERACTIVE bash, via BASH_ENV, so a
# human at `cb login` still gets the normal credential prompt while an agent's
# `bash -c` gets a fast error instead of an invisible /dev/tty deadlock.
info "wiring git credential helper + agent prompt guard"
incus file push "$ASSETS_DIR/git-credential-github-pat" \
  "$BUILDER/usr/local/bin/git-credential-github-pat" --uid 0 --gid 0 --mode 0755
incus file push "$ASSETS_DIR/git-agent-guard.sh" \
  "$BUILDER/etc/git-agent-guard.sh" --uid 0 --gid 0 --mode 0644
printf 'export BASH_ENV=/etc/git-agent-guard.sh\n' \
  | incus file push - "$BUILDER/etc/profile.d/git-agent-guard.sh" --uid 0 --gid 0 --mode 0644
printf '[credential "https://github.com"]\n\thelper = github-pat\n' \
  | incus file push - "$BUILDER/etc/gitconfig" --uid 0 --gid 0 --mode 0644

info "cleaning apt caches"
x 'apt-get clean && rm -rf /var/lib/apt/lists/*'

info "publishing image as '$IMAGE_ALIAS'"
incus stop "$BUILDER"
incus publish "$BUILDER" --alias "$IMAGE_ALIAS" --compression zstd
incus delete "$BUILDER" --force

info "done. Create a codebase container with: scripts/cb create <name>"
