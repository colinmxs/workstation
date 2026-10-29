# VM workflow

Always-loaded. How per-codebase environments work. Commands live in
`.kiro/skills/incus/SKILL.md`; lifecycle is wrapped by `scripts/cb`.

## One-time per host

Full ordered walkthrough with prerequisites is in `README.md` ("Setting this up
on a new machine"). Short form:

1. `scripts/host-bootstrap.sh` — installs Incus + btrfs-progs + zstd, inits
   pool + `incusbr0` + `dev` profile, adds `root:1000:1` to `/etc/sub{u,g}id`,
   adds `colin` to `kvm` + `incus-admin`, symlinks `cb` to `~/.local/bin/cb`.
   Needs sudo; asks before acting.
2. `exec bash -l` — pick up new group membership (no Windows action needed).
3. Pin the bridge address if it differs from `DH_ADDR` in `lib.sh`:
   `incus network get incusbr0 ipv4.address` should be `10.126.115.1/24`.
   If not: `incus network set incusbr0 ipv4.address=10.126.115.1/24`.
4. `scripts/build-golden.sh` — builds the `dev-golden` image with the toolchain
   (10–15 min, network-bound). Seeds kiro-cli from `~/.local/bin/kiro-cli*` if
   present, then self-updates it inside the image.
5. Provision `docker-host` (sibling distro, optional but needed for `docker`
   inside containers) — see "Docker" below.

## Per codebase

- Create: `scripts/cb create <name>` — clones `dev-golden`, parity-mounts
  `/mnt/wsl/code/<name>` (same path in-VM), injects docker-host SSH access, the
  per-instance GitHub PAT, and the kiro-cli auth db, then starts it. Each
  injector warns and skips if its host-side input is missing (see the three
  sections below). `--no-start` leaves it stopped (all injectors go through
  `incus file`, so they work on a stopped instance).
- Enter: `scripts/cb login <name>` — shell as `colin` via `incus exec`.
  Clone repos into `/mnt/wsl/code/<name>` (shared VHD; docker-host sees it too).
- Stop/start: `scripts/cb stop|start <name>`.
- Destroy: `scripts/cb destroy <name>` — deletes the container. Code on
  `/mnt/wsl/code` stays.
- List/status: `scripts/cb list` / `scripts/cb status <name>`.
- Manage interactively: `scripts/cb tui` — full-screen TUI with single-key
  start/stop/restart/login/info/create/destroy and a docker-host indicator.
  **Mouse works**: click a row to select, double-click to log in, wheel to
  scroll the pane (the selection stays put; the footer shows `↑/↓ selection`
  when it is off-screen and any arrow key brings it back), click a footer hint (`[s]tart`, `[?]help`, …) to run it, click the
  docker-host badge to re-probe. `/` is a live filter (narrows as you type;
  Enter keeps, Esc clears), `o` toggles running-first order, `d` asks y/N on
  the status line. Enter on a stopped instance starts it, waits for exec to
  work, then drops you in. Start/stop/restart/delete run as background jobs
  (row shows a spinner; the UI stays responsive; `q` leaves them running).
  Scales to hundreds of instances: scrolling viewport sized to the terminal
  (`j/k`, PgUp/PgDn, `g/G`), `incus list` refreshes asynchronously on a timer,
  and the selection follows the instance name across refreshes and re-sorts.
  Test it with `tests/cb-tui-smoke.py` (read-only) or `--live` (also creates,
  starts, stops and deletes a throwaway `cb-tui-selftest` container).
- **Every `cb` command waits at most `INCUS_TIMEOUT` (15s) for the daemon.**
  `need_incus` nags on stderr after `INCUS_SLOW_AFTER` (2s) and then fails with a
  real message. Before this, a stalled daemon left `cb tui` sitting on a blinking
  cursor with no output — the guard runs before the first paint. Raise it with
  `INCUS_TIMEOUT=60 scripts/cb tui` if a host is genuinely slow. In the TUI, a
  mid-session `incus list` stall keeps the last known list and says so in the
  status line rather than blanking to a false "no instances".

## kiro-cli auth (no per-container login)

The whole session lives in one sqlite db (`~/.local/share/kiro-cli/data.sqlite3`).
`cb create` snapshots it (sqlite backup API, safe on a live db) and pushes it in,
so a new container is already logged in. Re-seed after a token rotation with
`scripts/cb kiro-setup <name>`. **Never bake it into the golden image** — it's a
live, expiring credential. Caveat: many containers refreshing one SSO token
independently can invalidate each other; `kiro-setup` is the fix.

### Refreshing the kiro-cli binary in the image

`build-golden.sh` seeds the host binaries from `~/.local/bin`, then runs
`kiro-cli update -y` **inside** the builder so the image lands on the current
release regardless of the host's version (`KIRO_SELF_UPDATE=0` skips it). The
update also leaves a fresh empty state db behind; the build drops it, because
auth is injected per container and must never be baked.

To refresh an existing image without a full rebuild: launch a throwaway from
`dev-golden`, `kiro-cli update -y`, delete
`~/.local/share/kiro-cli/{data.sqlite3,run,run-receipts,knowledge_bases}`, stop
it, then `incus publish <tmp> --alias dev-golden --compression zstd` (alias the
old fingerprint to `dev-golden-kiro-<oldver>` first so you can roll back).
Existing containers keep their own copy — they are not upgraded by this.

## GitHub auth (git push + gh, per container)

PATs are **per instance**, 0600, host only, **never** committed or baked:

- `~/.config/github/pat.d/<instance>` — that container's token
- `~/.config/github/pat` — optional fallback for instances without their own

`cb create` injects the matching token; re-inject after rotation with
`scripts/cb github-setup <name>`. Inside the container it always lands at
`~/.config/github/pat`, read by the `git-credential-github-pat` helper
(`/etc/gitconfig` selects it). The helper **ignores `$GITHUB_PAT`** on purpose —
a token exported by a shell rc file would otherwise silently override the
container's own and produce confusing 403s.

- **Interactive `git push` still prompts.** `GIT_TERMINAL_PROMPT=0` is set only
  for **non-interactive** bash, via `BASH_ENV=/etc/git-agent-guard.sh`, which
  interactive shells don't read. Never set it globally — it breaks the normal
  human workflow.
- **Why the guard exists:** with no credential, git opens `/dev/tty` *directly*
  to prompt — bypassing stdout/stderr, so a piped command shows nothing. The
  agent TUI holds that terminal in raw mode and eats the keystrokes, so git
  blocks on `read()` forever. It looks exactly like resource contention; it
  isn't. Failing fast makes it a visible error.
- Token needs **Contents: Read and write** (plus **Pull requests: Read and
  write** for `gh pr`) on its repos, and **org approval** for org-owned repos.
  Without it: `403 Permission to <repo> denied`, even though the API reports
  `push: true` (that field is the *user's* role, not the token's grant).

## Bulk import from Azure DevOps

`scripts/azdo-import.sh` creates one **stopped** container per repo in an AzDO
project, cloning each host-side into `/mnt/wsl/code/<instance>`.

- PAT comes from `$AZDO_PAT` or `~/.config/azdo/pat` (0600, never in this repo).
  Needs only **Code: Read**. It reaches git via a credential helper, so it stays
  off argv and out of `.git/config` remotes.
- Serial by design, `nice`/`ionice`'d clones, free-space floor (`MIN_FREE_MB`),
  and resumable — state in `~/.local/state/azdo-import/`. Re-running skips
  completed repos and retries failures.
- `--dry-run` prints the plan. `--only NAME` targets single repos. `AZDO_SKIP`
  and `AZDO_NAME_MAP` (`Original=instance`) handle exclusions and name reuse.
- Repo enumeration alone: `scripts/azdo-list-repos.py` (TSV).

## Review + kiro-init imported repos

`scripts/kiro-init-repos.sh` runs kiro-cli **inside each repo's own container**
to code-review it and write `.kiro/steering/{product,tech,structure}.md` +
`.kiro/CODE_REVIEW.md`, then stops the container again.

- Skips any repo that already has `.kiro/` (`--force` overrides).
- `--jobs N` bounds concurrency (default 3; 4 measured at ~0.5 load, ~3 GiB).
  Each container is started only for its own run.
- Agent is limited to `--trust-tools=fs_read,fs_write`: it cannot run commands,
  so no builds/restores are triggered and nothing is committed. Output lands as
  untracked `.kiro/` for human review; `rm -rf .kiro` reverses it.
- Resumable, per-repo logs in `~/.local/state/kiro-init/`. Success is judged by
  the four artifacts existing, not by the agent's exit code.
- The prompt forbids copying secret **values** into docs — committed secrets get
  reported by file path only.

## Docker (sibling `docker-host` distro)

Docker Engine runs in a separate WSL2 distro (`docker-host`), not in Incus —
the nested-virt memory ceiling makes Incus VMs unusable for a build host. Dev
containers drive it remotely over SSH.

### Provisioning (once per machine)

The only pieces not scripted are on the Windows/docker-host side (installing
the distro and Docker). Everything else is `scripts/docker-host-setup.sh`.

1. **Windows:** install a second Ubuntu 24.04 distro named `docker-host`
   (e.g. `wsl --install Ubuntu-24.04 --name docker-host`, or import a tarball).
   Create user `colin` (uid 1000). Set `/etc/wsl.conf` like dev-host's but with
   `[network] hostname=docker-host` (see environment.md), then
   `wsl --terminate docker-host` to apply.
2. **Inside docker-host:** install Docker Engine from the official apt repo
   (docs.docker.com/engine/install/ubuntu) and `sudo usermod -aG docker colin`.
   Confirm `docker version` shows a server.
3. **On dev-host**, make the keypair and stage the setup bundle on the
   `/mnt/wsl` tmpfs, which every distro shares:
   ```bash
   mkdir -p ~/.config/docker-host && chmod 700 ~/.config/docker-host
   ssh-keygen -t ed25519 -N '' -C docker-host -f ~/.config/docker-host/id_ed25519
   S=/mnt/wsl/docker-host-setup; mkdir -p "$S"
   cp ~/.config/docker-host/id_ed25519.pub            "$S/authorized_keys"
   cp scripts/docker-host-setup.sh                    "$S/setup.sh"
   cp scripts/assets/ensure-incus-forwarding.sh       "$S/"
   cp scripts/assets/docker-incus-forwarding.service  "$S/"
   ```
4. **Inside docker-host:** `bash /mnt/wsl/docker-host-setup/setup.sh`. It
   installs sshd on `:2222` (pubkey only, `AllowUsers colin`), installs the
   `authorized_keys`, installs + enables `docker-incus-forwarding.service`, and
   writes its host key back to `$S/ssh_host_ed25519_key.pub`.
5. **On dev-host**, build `known_hosts` from that host key for the stable
   gateway address, then verify:
   ```bash
   printf '[10.126.115.1]:2222 %s\n' "$(cut -d' ' -f1,2 /mnt/wsl/docker-host-setup/ssh_host_ed25519_key.pub)" \
     > ~/.config/docker-host/known_hosts
   chmod 600 ~/.config/docker-host/known_hosts
   ssh -i ~/.config/docker-host/id_ed25519 -o UserKnownHostsFile=~/.config/docker-host/known_hosts \
       -p 2222 colin@10.126.115.1 docker version
   rm -rf /mnt/wsl/docker-host-setup   # tmpfs; gone on reboot anyway
   ```
   `cb create` now finds `id_ed25519` + `known_hosts` and wires every new
   container. Existing containers: `scripts/cb docker-setup <name>`.

### Using it

- `scripts/cb create` auto-injects the SSH key and sets
  `DOCKER_HOST=ssh://colin@10.126.115.1:2222`. The `docker` CLI/buildx/compose
  are baked into `dev-golden` (client only — **no local daemon**).
- So inside any container, `docker build` / `docker run` / `compose` just work,
  executing on `docker-host`. Reach published service ports from the container
  at the stable gateway, e.g. `curl http://10.126.115.1:8080`.
- Bind mounts work because repo paths are identical on both sides:
  `docker run -v "$PWD":/src` from `/mnt/wsl/code/<name>` resolves on docker-host.
- Re-inject access into an existing container: `scripts/cb docker-setup <name>`.
- **`docker-host` must be running.** It idle-stops; if `docker` calls hang or
  refuse, start/hold it open on the Windows side with
  `wsl -d docker-host -u colin --exec sleep infinity`.
- **If `docker` works but Incus container *outbound* dies after a reboot**
  (DNS ok, but `curl`/`kiro-cli login` time out → "dispatch failure"): it's
  `docker-host`'s shared-netns `FORWARD` policy `drop`. The fix is the
  `docker-incus-forwarding.service` hook that `docker-host-setup.sh` installs
  (`iptables -I DOCKER-USER 1 -{i,o} incusbr0 -j ACCEPT`). Check it with
  `sudo iptables -S DOCKER-USER` on docker-host; re-run `setup.sh` if the rules
  are missing. Not an ordering or recreate-the-VM issue.

## Rules baked into the workflow

- **System container by default.** VM mode (`--vm`) **is** wired up (the
  `docker-vm` profile boots real KVM VMs), but VMs are capped at ~2.5 GiB RAM
  by a WSL2 nested-virt ceiling — only use `--vm` for small workloads needing
  kernel isolation, never for heavy/high-memory ones.
- **Outbound-only.** No proxy/forward devices, ever.
- **Secrets at login.** Export tokens in the shell session; never persist to repo or image.
- **Code on the shared VHD, toolchain in container.** Repos live on the
  cross-distro shared disk at `/mnt/wsl/code/<name>`, parity-mounted (same path
  in-VM) so docker `-v` paths resolve identically on docker-host. Keep heavy
  build dirs container-local if I/O matters.

## Known caveat

`/mnt/wsl/code` is the host-mounted shared VHD, parity-mounted into each VM and
mapped via `raw.idmap`. If it's **empty, the disk isn't mounted** — ask the
Windows operator to run `mount-shared-code.ps1`; never mount from inside. `cb`
guards this (`need_shared_code`). If file ownership looks wrong, see the skill's
troubleshooting section.
