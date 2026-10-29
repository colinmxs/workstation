---
name: incus
description: Incus runbook for this host — install/init, golden image, per-codebase container lifecycle, networking, idmap, and troubleshooting. Load when running or debugging Incus commands.
---

# Incus runbook

Detailed recipes for the disposable per-codebase setup. The `scripts/` wrap
these; use raw commands for debugging or one-offs.

## Concepts

- **System container**: full Linux userspace sharing the host kernel. Default
  for every codebase. Lightweight, fast to clone, nspawn-class isolation.
- **VM** (`--vm`): full KVM guest. Only when a codebase needs kernel isolation.
- **Profile `dev`**: nic + root disk + idmap, applied to every instance.
- **Image `dev-golden`**: local published image with the toolchain baked in.

## Install + init (host-bootstrap.sh)

```bash
sudo apt-get update && sudo apt-get install -y incus btrfs-progs zstd
sudo usermod -aG incus-admin,kvm colin   # re-login to apply (exec bash -l)

# Permit mapping host uid/gid 1000 into unprivileged containers (shared code disk).
# Without this, container start aborts: "newuidmap: uid range ... not allowed".
echo "root:1000:1" | sudo tee -a /etc/subuid /etc/subgid

# storage: btrfs via an Incus-managed loop image (size=, NOT source=<file> —
# source= makes Incus expect an existing btrfs and fails in WSL with
# "Inappropriate ioctl for device"). Falls back to a dir pool.
incus storage create default btrfs size=60GiB \
  || incus storage create default dir source=/home/colin/incus/dir
# outbound-only NAT bridge. `auto` picks a random 10.x.y.1/24; lib.sh (DH_ADDR)
# and build-golden.sh (DOCKER_HOST) hard-code 10.126.115.1, so pin it:
incus network create incusbr0 ipv4.address=auto ipv4.nat=true ipv6.address=none
incus network set incusbr0 ipv4.address=10.126.115.1/24
# profile (note: key=value form for `set`)
incus profile create dev
incus profile device add dev root disk pool=default path=/
incus profile device add dev eth0 nic network=incusbr0 name=eth0
incus profile set dev raw.idmap "both 1000 1000"
incus profile set dev limits.cpu=4 limits.memory=4GiB
# put cb on PATH
ln -sf /home/colin/ubuntu-host-vm/scripts/cb ~/.local/bin/cb
```

`zstd` is required because `incus publish` shells out to it for compression.
The btrfs loop image lives under `/var/lib/incus` (ext4 root) — fast.
`host-bootstrap.sh` does everything above except the `network set` pin, which
it leaves to you because an existing bridge may already have instances on it.

## Golden image (build-golden.sh)

What the script does, as raw commands. Run the script rather than this; the
recipe is here so you can debug a step or patch a live image.

```bash
incus launch images:ubuntu/24.04 golden-build -p dev
incus exec golden-build -- bash -c 'apt-get update && apt-get install -y \
  git curl ca-certificates build-essential openssh-client ripgrep fd-find jq vim tmux unzip python3'
# colin pinned to uid/gid 1000 (the cloud image ships a 'ubuntu' user at 1000;
# remove it so colin owns 1000, matching the host idmap) + passwordless sudo
incus exec golden-build -- bash -c 'userdel -r ubuntu 2>/dev/null || true; \
  groupadd -g 1000 colin 2>/dev/null || true; \
  id colin || useradd -m -u 1000 -g 1000 -s /bin/bash colin; \
  usermod -aG sudo colin; echo "colin ALL=(ALL) NOPASSWD:ALL" >/etc/sudoers.d/colin'
# Node LTS (nodesource) + aws-cdk; AWS CLI v2 (zip installer); uv (astral
# installer, as colin); Docker CLIENT only (docker-ce-cli, buildx, compose from
# download.docker.com — no daemon); GitHub CLI (gh, from cli.github.com apt).
# /etc/profile.d/docker-host.sh  -> export DOCKER_HOST=ssh://colin@10.126.115.1:2222
# kiro-cli: no public installer. The script pushes the host's
# ~/.local/bin/kiro-cli* into the image (warns+skips if absent), runs
# `kiro-cli update -y` inside so the image is current (KIRO_SELF_UPDATE=0
# skips), then deletes the state db the update created — auth is injected
# per container, never baked.
# git auth plumbing (token itself is NOT baked):
#   /usr/local/bin/git-credential-github-pat   (assets/)
#   /etc/git-agent-guard.sh + /etc/profile.d/git-agent-guard.sh  (BASH_ENV guard)
#   /etc/gitconfig  -> [credential "https://github.com"] helper = github-pat
incus exec golden-build -- bash -c 'apt-get clean && rm -rf /var/lib/apt/lists/*'
incus stop golden-build
incus publish golden-build --alias dev-golden --compression zstd
incus delete golden-build
```

Rebuild: the script asks, then `incus image delete dev-golden` before building.
Keep a rollback by re-aliasing the old fingerprint first:
`incus image alias create dev-golden-<tag> <fingerprint>`.

Patch a live image without a rebuild (e.g. to refresh kiro-cli or add `gh`):

```bash
incus launch dev-golden tmp-golden -p dev
incus exec tmp-golden -- su -l colin -c 'kiro-cli update -y'
incus exec tmp-golden -- su -l colin -c \
  'rm -rf ~/.local/share/kiro-cli/{data.sqlite3,run,run-receipts,knowledge_bases}'
incus stop tmp-golden
OLD=$(incus image info dev-golden | awk '/^Fingerprint/{print $2}')
incus image alias create dev-golden-prev "$OLD"
incus image alias delete dev-golden
incus publish tmp-golden --alias dev-golden --compression zstd
incus delete tmp-golden
```

Existing containers keep their own rootfs; only new `cb create`s see the change.

## Per-codebase lifecycle (scripts/cb)

```bash
# create: clone golden, PARITY-mount repo dir (same path in-VM), start
mkdir -p /mnt/wsl/code/<name>            # shared VHD — must be mounted (else ask operator)
incus launch dev-golden <name> -p dev     # or `incus create` for --no-start
incus config device add <name> workspace disk \
  source=/mnt/wsl/code/<name> path=/mnt/wsl/code/<name>
# then cb runs three injectors, all via `incus file push` (work on a STOPPED
# instance; no agent/exec needed). Each warns+skips if its host input is absent:
#   inject_docker_host  ~/.config/docker-host/{id_ed25519,known_hosts}
#                       -> ~/.ssh/docker-host_*, ~/.ssh/config, /etc/profile.d/docker-host.sh
#   inject_github_pat   ~/.config/github/pat.d/<name> (or ~/.config/github/pat)
#                       -> ~/.config/github/pat, ~/.config/gh/hosts.yml, /etc/gitconfig,
#                          /usr/local/bin/git-credential-github-pat, /etc/git-agent-guard.sh
#   inject_kiro_auth    ~/.local/share/kiro-cli/data.sqlite3 (sqlite backup API snapshot)
#                       -> ~/.local/share/kiro-cli/data.sqlite3
# re-run any one later:  cb docker-setup | github-setup | kiro-setup <name>

# enter as colin (interactive)
incus exec <name> -- su -l colin
# lifecycle
incus stop <name>;  incus start <name>;  incus restart <name>
incus delete <name> --force
incus list;  incus info <name>
```

Instance names are sanitized by `instance_name()`: lowercased, `[a-z0-9-]`
only, runs of `-` collapsed. `cb create My_Repo` makes `my-repo`.

Push a file into a stopped instance with explicit ownership (what the
injectors do):

```bash
incus file create -p --type=directory --uid 1000 --gid 1000 --mode 0700 <name>/home/colin/.ssh
incus file push ./key <name>/home/colin/.ssh/key --uid 1000 --gid 1000 --mode 0600
printf 'export FOO=bar\n' | incus file push - <name>/etc/profile.d/foo.sh --uid 0 --gid 0 --mode 0644
```

## VM mode (`--vm`) — wired up, but RAM-capped

VM mode works. The `docker-vm` profile boots real KVM VMs:

```bash
incus profile create docker-vm
incus profile device add docker-vm root disk pool=default path=/ size=60GiB
incus profile device add docker-vm eth0 nic network=incusbr0 name=eth0
incus profile set docker-vm limits.cpu=4 limits.memory=2GiB   # see ceiling below
incus launch images:ubuntu/24.04 myvm --vm -p docker-vm       # boots, agent in ~12s
```

Key differences from container mode:
- VMs need a profile **without** `raw.idmap` (idmap is container-only and
  aborts VM start → `ERROR`). That's why `docker-vm` omits it; the `dev`
  profile keeps it for containers.
- `dev-golden` is a container image; to clone a VM with `cb create --vm` you'd
  publish a VM-type golden (`incus launch images:ubuntu/24.04 b --vm`, provision,
  `incus publish b --alias dev-golden-vm`).

**HARD CEILING — nested-virt memory (~2.5 GiB).** VMs with ≥3 GiB RAM crash in
firmware: `KVM: entry failed, hardware error 0xffffffff` (`SMM=1`). Verified:
1/2/2.5 GiB boot, 3/4/6/8 GiB crash. Cause: guest RAM crossing the ~3 GiB PCI
hole / 4 GiB boundary, unmappable under WSL2 nested AMD-SVM. `secureboot=false`
doesn't help; `raw.qemu.conf smm=off` is a false positive (RUNNING but no boot).
**So Incus VMs can't host a 6–8 GiB Docker build host** — that's why Docker
lives in the sibling `docker-host` WSL2 distro instead.

## Docker host (sibling `docker-host` distro)

Docker Engine runs in a separate WSL2 distro, reached over SSH from dev
containers via the stable incusbr0 gateway (all WSL2 distros share one netns).
Full provisioning steps (keygen, staging, `setup.sh`, `known_hosts`) are in
`.kiro/steering/vm-workflow.md` → "Docker" → "Provisioning".

```bash
# one-time, inside docker-host (sshd:2222 + authorized_keys + firewall hook):
#   wsl -d docker-host
#   bash /mnt/wsl/docker-host-setup/setup.sh   (scripts/docker-host-setup.sh, staged)
# keypair + known_hosts live in ~/.config/docker-host/ (NEVER committed/baked).

# per container (auto-done by scripts/cb create; re-apply with cb docker-setup):
#   pushes key+known_hosts to ~/.ssh, writes ~/.ssh/config, sets
#   DOCKER_HOST=ssh://colin@10.126.115.1:2222
incus exec <name> -- su -l colin -c 'docker version'        # client+server 29.x
incus exec <name> -- su -l colin -c 'docker build -t x .'   # runs on docker-host
# reach a published service port from the container at the stable gateway:
incus exec <name> -- su -l colin -c 'curl http://10.126.115.1:8080'

# from dev-host itself (debugging):
ssh -i ~/.config/docker-host/id_ed25519 -o UserKnownHostsFile=~/.config/docker-host/known_hosts \
    -p 2222 colin@10.126.115.1 'docker ps; sudo iptables -S DOCKER-USER'
```

- **No local daemon** in containers — `docker-ce-cli`/buildx/compose only.
- **`docker-host` idle-stops.** Hold it open on Windows with
  `wsl -d docker-host -u colin --exec sleep infinity`. If `docker` calls refuse
  or hang, it's stopped.
- **Firewall hook.** dockerd sets the shared-netns `FORWARD` policy to `drop`,
  which kills Incus container outbound on dev-host. `docker-host-setup.sh`
  installs `docker-incus-forwarding.service` → `ensure-incus-forwarding.sh`
  (`iptables -I DOCKER-USER 1 -{i,o} incusbr0 -j ACCEPT`). Expected output of
  `sudo iptables -S DOCKER-USER` on docker-host:
  ```
  -N DOCKER-USER
  -A DOCKER-USER -o incusbr0 -j ACCEPT
  -A DOCKER-USER -i incusbr0 -j ACCEPT
  ```

## Networking (outbound-only)

- `incusbr0` is NAT: containers reach out, nothing reaches in. This is the
  desired state. **Never** add `proxy` devices or `incus network forward`.
- Verify: `incus exec <name> -- curl -sI https://example.com` works;
  no listening host ports are added for the instance.

## Troubleshooting

- **`cb` prints "waiting: incus daemon has not answered yet" then times out**:
  the daemon stalls transiently (5m17s once; every retry 0.02s). Retry first.
  Then `systemctl status incus incus.socket`, `sudo systemctl restart incus`.
  On a genuinely slow host: `INCUS_TIMEOUT=60 cb ...`.
- **Permission denied talking to incus**: not in `incus-admin` yet — `exec bash -l`.
- **Shared-code files owned by nobody/65534**: idmap not applied. Confirm
  `incus profile get dev raw.idmap` is `both 1000 1000`, then restart the
  instance. As a fallback set it per-instance: `incus config set <name> raw.idmap "both 1000 1000"`.
- **Container start fails `newuidmap: uid range ... not allowed`**: missing
  `root:1000:1` in `/etc/subuid` + `/etc/subgid`. `host-bootstrap.sh` adds it;
  `sudo systemctl restart incus` after adding by hand.
- **`/mnt/wsl/code` empty, `cb` says "not attached"**: the shared VHD isn't
  attached to the WSL VM. Ask the Windows operator to run `mount-shared-code.ps1`
  (`wsl --mount --vhd <path>.vhdx --name code`). Never mount from inside.
- **`cb` says "ATTACHED but NOT MOUNTED"**: happens after a distro restart;
  `/dev/disk/by-label/shared-code` exists but nothing is at `/mnt/wsl/code`, and
  `wsl --mount` reports "already attached". On Windows: `wsl --unmount <path>.vhdx`
  then `wsl --mount --vhd <path>.vhdx --name code`. Mounting from inside the
  distro would hide it from docker-host, so don't.
- **Container outbound dead (DNS works, `curl`/`kiro-cli` time out, "dispatch
  failure")** while `docker` still works: `docker-host`'s `FORWARD` policy is
  `drop` and the `DOCKER-USER` accept rules for `incusbr0` are gone. On
  docker-host: `sudo iptables -S DOCKER-USER`; if empty, `sudo systemctl start
  docker-incus-forwarding` or re-run `setup.sh`. Confirm from a container with
  `curl -sI https://example.com`.
- **`docker` inside a container hangs or "connection refused"**: `docker-host`
  idle-stopped. Windows: `wsl -d docker-host -u colin --exec sleep infinity`.
  Also check `ssh -p 2222 colin@10.126.115.1` works from dev-host with the key
  in `~/.config/docker-host/`.
- **`git push` from an agent hangs silently**: git opened `/dev/tty` for a
  credential prompt and the agent's TUI ate it. The container should have
  `BASH_ENV=/etc/git-agent-guard.sh` (sets `GIT_TERMINAL_PROMPT=0` for
  non-interactive bash); re-run `cb github-setup <name>`. If the PAT is present
  and you still get `403`, the token lacks **Contents: Read and write** or org
  approval.
- **`gh: command not found` in a container**: the current `dev-golden` was
  built before `gh` was added to `build-golden.sh`. Rebuild, or patch the
  image (see "Golden image"), or `sudo apt-get install gh` in that container.
- **Instance won't start, cgroup errors**: ensure host has systemd + cgroup v2
  (`stat -fc %T /sys/fs/cgroup` → `cgroup2fs`).
- **`Too many open files` / inotify**: raise host limits —
  `sudo sysctl -w fs.inotify.max_user_instances=1024 fs.inotify.max_user_watches=1048576`.
- **btrfs pool create fails in WSL**: re-run init with the `dir` fallback.
- **VM goes to ERROR on start**: the `dev` profile's `raw.idmap` is
  container-only and aborts VM start. Use a profile without `raw.idmap` for
  VMs. KVM itself is fine if `/dev/kvm` is rw for the launching user.
- **VM with ≥3 GiB RAM crashes `KVM: entry failed, hardware error 0xffffffff`**:
  WSL2 nested-virt ceiling, not fixable. Keep VMs ≤2.5 GiB.
- **`Asked for a VM but image is of type container`**: `dev-golden` is a
  container image; build a VM-type image (see "VM mode" above).
