# Disposable per-codebase dev environments

Ubuntu WSL2 is the control plane. Each codebase gets its own disposable
**Incus system container** cloned from a golden image. Code lives on a
cross-distro shared VHD (`/mnt/wsl/code`); tooling and build artifacts live
inside the container. Docker runs in a second WSL2 distro (`docker-host`) that
containers drive over SSH.

```
Windows (WSL2)
├── Ubuntu-26.04  "dev-host"   <- this repo, Incus daemon, `cb`
│   └── incusbr0 10.126.115.1/24 (NAT, outbound only)
│       ├── <repo-a>  container from dev-golden   /mnt/wsl/code/repo-a
│       ├── <repo-b>  container from dev-golden   /mnt/wsl/code/repo-b
│       └── ...
├── Ubuntu-24.04  "docker-host" <- Docker Engine + sshd :2222
└── shared-code.vhdx  -> /mnt/wsl/code in every distro (same path everywhere)
```

## Layout

- `AGENTS.md` — operating rules for the agent (hard constraints).
- `.kiro/steering/environment.md` — verified machine facts; which values are
  machine-specific.
- `.kiro/steering/vm-workflow.md` — how the workflow works day to day, incl.
  the docker-host provisioning flow and the three per-container injectors
  (docker-host SSH, GitHub PAT, kiro-cli auth).
- `.kiro/skills/incus/SKILL.md` — raw Incus recipes and troubleshooting.
- `scripts/` — reproducible setup + lifecycle:
  - `host-bootstrap.sh` — one-time Incus install/init on dev-host (sudo).
  - `build-golden.sh` — builds the `dev-golden` image.
  - `docker-host-setup.sh` — run **inside** `docker-host`: sshd + firewall hook.
  - `cb` / `cb-tui` — per-codebase lifecycle (CLI and full-screen TUI).
  - `lib.sh` — shared config (all paths/addresses live here) and the injectors.
  - `azdo-import.sh`, `azdo-list-repos.py`, `kiro-init-repos.sh` — bulk import
    an Azure DevOps project and kiro-init each repo. Optional.
  - `assets/` — files pushed verbatim into instances or docker-host.
- `tests/cb-tui-smoke.py` — drives the TUI in a pty; `--live` also creates and
  deletes a throwaway container.

## Quick start (host already set up)

```bash
cb create my-repo     # clone dev-golden, mount /mnt/wsl/code/my-repo, inject creds, start
cb login  my-repo     # shell as colin; git clone into /mnt/wsl/code/my-repo
cb tui                # manage everything from one screen (keyboard + mouse)
cb destroy my-repo    # delete the container; code on /mnt/wsl/code stays
```

`cb help` lists the rest (`start|stop|restart|status|list`, and
`docker-setup|github-setup|kiro-setup <name>` to re-inject credentials).

## Setting this up on a new machine

Read this whole section once before starting. Steps are ordered; each one
assumes the previous ones are done.

### Assumptions baked into the scripts

- **Linux user is `colin`, uid/gid 1000** in both distros and in the golden
  image. The uid is what makes shared-disk file ownership line up across host,
  container and docker-host (`raw.idmap both 1000 1000`). If your user is
  different, either create `colin` as the default WSL user, or grep `scripts/`
  for `colin` (about 50 hits, mostly `lib.sh`, `build-golden.sh`,
  `docker-host-setup.sh`) and change it everywhere before running anything.
- **This repo lives at `/home/colin/ubuntu-host-vm`** on dev-host. Only
  `POOL_DIR` in `lib.sh` and the `cb` symlink depend on the path, but the docs
  assume it.
- **The Incus bridge is `10.126.115.1/24`.** `lib.sh` (`DH_ADDR`) and
  `build-golden.sh` (`DOCKER_HOST`) hard-code it. Step 3 pins it.
- **Everything runs inside WSL.** The scripts never call Windows binaries. The
  Windows-side steps below are done by you, by hand, once.

### 0. Windows prerequisites (by hand)

1. WSL2 with systemd support (`wsl --version` ≥ 2.x). Nested virtualization is
   on by default on recent builds; it is only needed for Incus VM mode, which
   you can ignore.
2. Install the control-plane distro: Ubuntu 26.04 (24.04 also works), named
   whatever you like but the docs call it `dev-host`. Default user `colin`.
3. Install a **second** Ubuntu 24.04 distro named `docker-host`
   (`wsl --install Ubuntu-24.04 --name docker-host`), default user `colin`.
4. In **both** distros write `/etc/wsl.conf` (hostname differs):
   ```ini
   [boot]
   systemd=true

   [user]
   default=colin

   [automount]
   enabled=false
   mountFsTab=true

   [interop]
   enabled=true
   appendWindowsPath=false

   [network]
   hostname=dev-host        # docker-host in the other distro
   ```
   then `wsl --shutdown`. `automount=false` means no `/mnt/c`; this is
   deliberate (nothing here touches Windows paths).
5. Create the shared code disk and attach it to WSL (PowerShell, as admin):
   ```powershell
   # once: create + format (~100 GB, ext4, label shared-code)
   New-VHD -Path E:\wsl\shared-code.vhdx -SizeBytes 100GB -Dynamic
   wsl --mount --vhd E:\wsl\shared-code.vhdx --bare
   wsl -d dev-host -u root -- bash -c 'mkfs.ext4 -L shared-code /dev/sdX && mkdir -p /mnt/wsl/code'   # sdX = new disk, check lsblk
   wsl --unmount E:\wsl\shared-code.vhdx
   # every boot (put this in a logon task; this is what the docs call mount-shared-code.ps1):
   wsl --mount --vhd E:\wsl\shared-code.vhdx --name code
   ```
   `--name code` is what makes it appear at `/mnt/wsl/code` in **every**
   distro. Verify in dev-host: `mountpoint /mnt/wsl/code` and
   `sudo chown colin:colin /mnt/wsl/code` on first use.
6. Keep `docker-host` alive. It idle-stops when nothing is running in it; a
   logon task running `wsl -d docker-host -u colin --exec sleep infinity`
   is the simplest fix.

### 1. Clone this repo (dev-host)

```bash
git clone https://github.com/colinmxs/workstation.git ~/ubuntu-host-vm && cd ~/ubuntu-host-vm
```

### 2. Incus (dev-host)

```bash
scripts/host-bootstrap.sh   # apt install incus btrfs-progs zstd; pool, bridge, profile, subuid, groups, cb symlink
exec bash -l                # pick up incus-admin + kvm groups
incus list                  # should answer (empty table)
```

### 3. Pin the bridge address (dev-host)

```bash
incus network get incusbr0 ipv4.address        # want 10.126.115.1/24
incus network set incusbr0 ipv4.address=10.126.115.1/24
```

### 4. kiro-cli on the host (dev-host, optional but expected)

Install kiro-cli into `~/.local/bin` and log in once (`kiro-cli login`). The
golden build seeds the binary from there, and `cb create` copies your session db
into each container so you never log in per container.

### 5. Golden image (dev-host)

```bash
scripts/build-golden.sh     # 10–15 min; network-bound
incus image list            # dev-golden, CONTAINER, ~650–700 MiB
```

### 6. docker-host

Follow "Docker → Provisioning" in `.kiro/steering/vm-workflow.md`. In short:
install Docker Engine inside `docker-host` and add `colin` to the `docker`
group; on dev-host generate `~/.config/docker-host/id_ed25519` and stage the
setup bundle on `/mnt/wsl/docker-host-setup/`; inside docker-host run
`bash /mnt/wsl/docker-host-setup/setup.sh`; back on dev-host write
`~/.config/docker-host/known_hosts` from the host key it leaves behind. Verify:

```bash
ssh -i ~/.config/docker-host/id_ed25519 -o UserKnownHostsFile=~/.config/docker-host/known_hosts \
    -p 2222 colin@10.126.115.1 docker version
```

### 7. First container

```bash
cb create smoke && cb login smoke
# inside: docker version && kiro-cli --version && curl -sI https://example.com | head -1
exit; cb destroy smoke
```

## Secrets you need to prepare (host only, never in this repo)

| What | Where (0600) | Used by |
|---|---|---|
| docker-host SSH keypair + known_hosts | `~/.config/docker-host/{id_ed25519,id_ed25519.pub,known_hosts}` | `cb create`, `cb docker-setup` |
| GitHub fine-grained PAT, one per instance | `~/.config/github/pat.d/<instance>` (fallback `~/.config/github/pat`) | `cb create`, `cb github-setup` |
| kiro-cli session | `~/.local/share/kiro-cli/data.sqlite3` (created by `kiro-cli login`) | `cb create`, `cb kiro-setup` |
| Azure DevOps PAT (Code: Read) | `~/.config/azdo/pat` or `$AZDO_PAT` | `azdo-import.sh` only |

Every injector warns and skips when its file is missing, so you can set these up
in any order and re-run `cb <x>-setup <name>` later.

## Bulk import (optional)

One stopped container per repo in an Azure DevOps project; serial, resumable:

```bash
scripts/azdo-import.sh --dry-run   # show the plan
scripts/azdo-import.sh             # safe to interrupt and re-run
scripts/kiro-init-repos.sh --dry-run   # then write .kiro/ steering per repo
```

Set `AZDO_ORG` and `AZDO_PROJECT` (from `https://dev.azure.com/<org>/<project>`);
`azdo-list-repos.py` refuses to run without them. `AZDO_SKIP` and
`AZDO_NAME_MAP` (`Original=instance`) are optional exclusions and renames.

## Model

- One container per codebase, cloned from `dev-golden`.
- Repos live on a shared VHD at `/mnt/wsl/code/<name>`, parity-mounted (same
  path in-VM; also visible to the `docker-host` distro), so `docker -v "$PWD"`
  from inside a container resolves on docker-host.
- New containers arrive already logged in to `kiro-cli` and GitHub (credentials
  are injected at create time, never baked into the image).
- Containers are **outbound-only** (NAT, no inbound ports).
- Re-establish anywhere by running the `scripts/` in the order above.
