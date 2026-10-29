# Agent instructions

Operating rules for this repo. Read `.kiro/steering/` for machine facts and
the VM workflow; read `.kiro/skills/incus/` when running Incus commands.
`README.md` is the handoff document for setting up a new machine.

## Hard rules

- **Ubuntu-only.** All work runs inside the `Ubuntu-26.04` WSL distro
  (hostname `dev-host`). Never script or instruct actions on the Windows host
  beyond the manual prerequisites listed in `README.md`. The `C:` drive is not
  mounted.
- **This repo** lives at `/home/colin/ubuntu-host-vm` (native WSL ext4).
- **Stack is Incus.** One system container per codebase, cloned from the
  `dev-golden` image. Full VM (`--vm`) only if a codebase needs kernel
  isolation, and never above 2.5 GiB RAM (nested-virt ceiling).
- **Docker lives in the sibling `docker-host` WSL2 distro**, reached over SSH
  at `10.126.115.1:2222`. Never install a Docker daemon in a container or on
  dev-host.
- **Containers are outbound-only.** Never add inbound proxy/port-forward devices.
- **Code on the shared VHD, tooling in container.** Repos live on the
  cross-distro shared disk at `/mnt/wsl/code/<name>`, parity-mounted (same path
  in-VM; also visible to `docker-host`). Build artifacts and toolchains stay
  container-local. Never mount the VHD from inside a distro.
- **No secrets in this repo or in the golden image.** Credentials (docker-host
  SSH key, GitHub PATs, kiro-cli session db) live under `~/.config/` and
  `~/.local/share/` on the host, 0600, and are injected per container by
  `scripts/cb` at create time. The Azure DevOps PAT is read from
  `~/.config/azdo/pat` or `$AZDO_PAT` only.
- **Ask before installing packages or changing groups/services** on the host or
  on `docker-host`.
- **Prefer the `scripts/`.** Keep setup reproducible; update scripts, don't
  hand-run snowflake commands. Files that must land verbatim in an instance or
  on docker-host go in `scripts/assets/`.
- **`colin` / uid 1000 is load-bearing.** Don't rename the user or change
  `HOST_UID` without updating `raw.idmap`, the golden image, and docker-host.

## Maintenance

- Update `.kiro/steering/environment.md` when machine state changes.
- Update `.kiro/steering/vm-workflow.md` when the workflow changes.
- Update `.kiro/skills/incus/SKILL.md` with new command recipes.
- Update `README.md` when the new-machine setup order or prerequisites change.
