# Environment facts

Always-loaded. Terse machine state, verified 2026-10-29. Update when it changes.
Values marked **(this machine)** will differ on another host; everything else is
what the `scripts/` expect and create.

## Host distro (control plane)

- Distro: `Ubuntu-26.04` (resolute) on WSL2, kernel `6.18.33.1-microsoft-standard-WSL2`.
  WSL hostname `dev-host` (set in `/etc/wsl.conf`).
- `/etc/wsl.conf`: `[boot] systemd=true`, `[user] default=colin`,
  `[automount] enabled=false mountFsTab=true`, `[interop] appendWindowsPath=false`,
  `[network] hostname=dev-host`. Same layout on `docker-host` with its own hostname.
- Init: `systemd` (PID 1). cgroup v2. User: `colin` (uid/gid 1000). The uid is
  load-bearing: `raw.idmap`, `HOST_UID`, the golden image's `colin`, and the
  docker-host login all assume 1000.
- CPU **(this machine)**: AMD Ryzen 7 5800X, 12 vCPU visible to WSL. RAM 21 GiB,
  swap 8 GiB (`/dev/sdc`).
- Root **(this machine)**: ext4 `/dev/sde`, 1 TiB, ~907 GiB free. This repo and
  Incus storage (`/var/lib/incus`) live here.
- This repo: `/home/colin/ubuntu-host-vm`. `cb` is symlinked to
  `~/.local/bin/cb` by `host-bootstrap.sh`.
- Codebases live on a **cross-distro shared VHD**: ext4, label `shared-code`,
  100 GiB **(this machine)**, attached by Windows via `wsl --mount --vhd ... --name code`,
  which lands it at `/mnt/wsl/code` in **every** distro. Repos are at
  `/mnt/wsl/code/<name>`; dev-host, each container, and `docker-host` all see
  the same path. Empty `/mnt/wsl/code` = not mounted; `cb` refuses to run
  (`need_shared_code`) and tells you whether the disk is attached-but-unmounted
  or not attached at all.
- No Windows drive mounts are used (`automount` is off; `/mnt/c` absent). WSL
  interop is on, but the scripts never call Windows binaries.

## Virtualization

- `/dev/kvm` present (root:kvm). `kvm`/`kvm_amd` loaded — VM mode works, with a
  memory ceiling (below).
- `colin` must be in `kvm` + `incus-admin` (added by `host-bootstrap.sh`).
- Storage backends: `btrfs` module present (used); `zfs` NOT available.
- Net modules present: `nf_tables`, `bridge`, `overlay`.

## Incus state

- Version: Incus `6.0.5` (Ubuntu archive package). `zstd` required on host for
  `incus publish`.
- Pool: `default`, **btrfs** via an Incus-managed loop image (created with
  `size=60GiB`, not `source=`). Lives under `/var/lib/incus` on the ext4 root.
  `POOL_DIR` (`/home/colin/incus`) is only used by the `dir` fallback.
- Network: `incusbr0`, NAT, `10.126.115.1/24`, IPv6 off. Outbound-only
  (only host listener on the subnet is the bridge's dnsmasq on `:53`).
  `10.126.115.1` is also how containers reach `docker-host`, so `DH_ADDR` in
  `lib.sh` and the hard-coded `DOCKER_HOST` in `build-golden.sh` must match the
  bridge address a new host gets (`ipv4.address=auto` picks a random
  `10.x.y.1/24`; pin it with `incus network set incusbr0 ipv4.address=10.126.115.1/24`
  or change both scripts).
- Profile `dev` = root disk (pool `default`) + `eth0` (incusbr0) +
  `limits.cpu=4`, `limits.memory=4GiB` + `raw.idmap both 1000 1000`.
  `raw.idmap` is **container-only** — it breaks VM start (see below).
- Profile `docker-vm` = root disk (60GiB) + eth0 + `limits.cpu=4 limits.memory=2GiB`,
  **no idmap**. Hand-made for VM experiments; not created by any script.
- idmap: requires `root:1000:1` in `/etc/subuid` + `/etc/subgid` (added by
  `host-bootstrap.sh`); without it container start fails with
  `newuidmap: uid range ... not allowed`. With it, host `colin` (1000) ↔
  container `colin` (1000) and files on the shared disk round-trip correctly.
- Instances **(this machine)**: 109 on the `dev` profile (mostly stopped
  imports from `azdo-import.sh`).
- Golden image alias `dev-golden` (Ubuntu 24.04 base, **container type**,
  669 MiB). Verified contents: `colin` at uid 1000 (default `ubuntu` user
  removed), passwordless sudo, git 2.43, python3 3.12, node 24.16 / npm 11.13,
  aws-cdk 2.1127, aws-cli 2.35.6, uv 0.11.21, docker CLI 29.5.3 + buildx +
  compose 5.1.4 (client only), kiro-cli 2.23.1, `/etc/profile.d/docker-host.sh`
  setting `DOCKER_HOST`. **Not** in the image, by design: kiro-cli auth db,
  SSH keys, GitHub PAT, `/etc/gitconfig` (all injected per container by `cb`).
  - **`gh` is missing from this image** (it predates the `gh` step in
    `build-golden.sh`). A rebuild fixes it; until then `gh pr` fails in
    containers cloned from `dev-golden`. A fresh host building from the current
    script gets `gh`.
  - Previous image kept as `dev-golden-kiro-2.7.1` (994 MiB) for rollback.
- **Daemon can stall transiently.** `incus info` measured **5m17s** once
  (2026-09-10), then 0.02s on every retry; `incus list`/`version`/`query /1.0`
  stayed at 0.02–0.04s throughout. Nothing was wrong with the host. `cb` caps
  the wait at `INCUS_TIMEOUT` (15s) with a nag after `INCUS_SLOW_AFTER` (2s).

## VM mode

- KVM works and is **wired up**: the `docker-vm` profile boots a real KVM VM
  (`systemd-detect-virt` = `kvm`, incus-agent up in ~12s, gets an IP).
- **HARD CEILING — nested-virt memory (~2.5 GiB):** KVM VMs on this host
  **cannot use ≥3 GiB RAM.** 1/2/2.5 GiB boot fine; 3/4/6/8 GiB crash in
  firmware with `KVM: entry failed, hardware error 0xffffffff` (`SMM=1`).
  Root cause: guest RAM crossing the ~3 GiB PCI hole / 4 GiB boundary, which
  the L2 guest can't map under WSL2's nested AMD-SVM (Hyper-V). Not RAM
  pressure. `security.secureboot=false` does **not** help; `raw.qemu.conf`
  `smm=off` is a **false positive** (qemu stays RUNNING but the guest never
  boots). Not fixable from the Linux side.
- Consequence: **do not use Incus VMs for 6–8 GiB workloads** (e.g. a Docker
  build host). Docker runs in a sibling WSL2 distro instead — see below.

## Docker host (sibling WSL2 distro)

- Docker Engine lives in a **separate WSL2 distro** named `docker-host`
  (Ubuntu 24.04.4, hostname `docker-host`, systemd on, 251 GiB root VHD
  **(this machine)**), NOT in an Incus VM/container — chosen to dodge the
  nested-virt memory ceiling and give Docker the full host kernel + RAM.
- Docker Engine 29.5.3 from the official `download.docker.com` apt repo
  (`/etc/apt/sources.list.d/docker.sources`). `colin` is in the `docker` group.
  Installing Docker itself is a manual prerequisite; `docker-host-setup.sh`
  refuses to run without it.
- **Networking:** all WSL2 distros share **one** network stack. `docker-host`
  runs `sshd` on `0.0.0.0:2222` (`/etc/ssh/sshd_config.d/10-docker-host.conf`:
  pubkey only, `AllowUsers colin`). Dev containers reach it, and any published
  service port, via the **stable incusbr0 gateway `10.126.115.1`** — this
  survives WSL restarts; the `172.x` eth0 IP does not.
- **Access:** `DOCKER_HOST=ssh://colin@10.126.115.1:2222`. Authenticated by a
  dedicated keypair in `~/.config/docker-host/` (`id_ed25519`, `id_ed25519.pub`,
  `known_hosts`; host `colin` only; **never** baked into the golden image or
  committed). `scripts/cb` injects key + known_hosts + `~/.ssh/config` into each
  container at create time. Provision the distro side with
  `scripts/docker-host-setup.sh` (run inside `docker-host`; flow in vm-workflow.md).
- **Firewall hook (installed by `docker-host-setup.sh`):** `dockerd` sets the
  VM-wide `FORWARD` policy to `drop`, which also blocks dev-host Incus container
  outbound (DNS still works; new flows die → `kiro-cli` "dispatch failure").
  `docker-incus-forwarding.service` (oneshot, `After=docker.service`) runs
  `/usr/local/sbin/ensure-incus-forwarding.sh`, which adds
  `iptables -I DOCKER-USER 1 -{i,o} incusbr0 -j ACCEPT` idempotently. Verify
  with `sudo iptables -S DOCKER-USER` on docker-host. Don't use
  `--ip-forward-no-drop` (drops the policy VM-wide; less targeted).
- **Caveat:** `docker-host` idle-stops when it has no running process. Keep it
  alive from Windows with `wsl -d docker-host -u colin --exec sleep infinity`
  (or auto-start it on Windows logon). If `DOCKER_HOST` calls fail, it's almost
  always stopped.

## Versions seen at setup

- Incus `6.0.5`, Ubuntu base `24.04 LTS`, Docker `29.5.3`, kiro-cli host binary
  `2.7.1` (the golden image self-updates to the current release during
  `build-golden.sh`; a 2.7.1 auth db is read fine by 2.23.1 — verified).
