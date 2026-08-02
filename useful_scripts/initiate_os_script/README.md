# Initiate OS Script (`initiate_os_script.sh`)

A one-shot provisioning driver for a fresh Linux box. It updates the system
with the running distribution's own package manager, then runs the following
scripts from this repository **in order**:

| # | Script | Purpose |
| - | ------ | ------- |
| 1 | [`install_packages/Install_Server_with_Minimum_UI/install_server_with_minimum_ui.sh`](../../install_packages/Install_Server_with_Minimum_UI/install_server_with_minimum_ui.sh) | Adds a minimal XFCE desktop |
| 2 | [`install_packages/Install_and_Setup_TigerVNC_Server/setup-vnc-combined.sh`](../../install_packages/Install_and_Setup_TigerVNC_Server/setup-vnc-combined.sh) | Installs and configures a TLS-encrypted TigerVNC server |
| 3 | [`install_packages/Install_Docker_Engine/install_docker_engine.sh`](../../install_packages/Install_Docker_Engine/install_docker_engine.sh) | Installs Docker Engine + Compose |
| 4 | [`maintenance/Scheduled_systemd_Automatic_Update/install_system_maintenance.sh`](../../maintenance/Scheduled_systemd_Automatic_Update/install_system_maintenance.sh) | Installs scheduled-update / scheduled-reboot systemd timers |
| 5 | [`useful_scripts/bandwidth_test/bandwidth_test.sh`](../bandwidth_test/bandwidth_test.sh) | Runs a multi-region bandwidth test |
| 6 | [`useful_scripts/Prepare_X11/prepare_x11.sh`](../Prepare_X11/prepare_x11.sh) | Prepares X11 |
| 7 | [`useful_scripts/OS_Config/os_config.sh`](../OS_Config/os_config.sh) | Fixes ownership of the invoking user's home directory |

It is cross-platform across every distribution family in
[`Supported Distributions.txt`](../../Migrate_to_Linux/Supported%20Distributions.txt):
Debian/Ubuntu (`apt`), RHEL/Fedora (`dnf`/`yum`), Arch (`pacman`),
openSUSE/SUSE (`zypper`), Alpine (`apk`)\*, Gentoo (`emerge`)\* and Slackware
(`slackpkg`)\* (\* = best-effort). The family is auto-detected from
`/etc/os-release` (falling back to whichever package manager is present), and
the system update/upgrade step uses that family's own tooling.

> **Step 4 is Debian/RHEL only.** `install_system_maintenance.sh` itself only
> supports the Debian and RHEL families. On every other family, step 4 is
> skipped automatically with a warning — the rest of the plan still runs.

> **Step 6 (`prepare_x11.sh`) is currently an empty placeholder.** The script
> file exists but has no content yet; step 6 will run it (and succeed
> trivially) until it's filled in. Use `--skip-x11` to leave it out until then.

## Quick start

Run these from the repository root. `chmod +x` sets the executable bit,
which is commonly lost after checking out the repo on Windows — harmless to
repeat, so every command below sets it first.

```bash
# Run every step, no confirmation prompts (the default)
chmod +x useful_scripts/initiate_os_script/initiate_os_script.sh && sudo useful_scripts/initiate_os_script/initiate_os_script.sh

# Same, but ask for confirmation first (also leaves the desktop and Docker
# installers to show their own confirmation prompts, instead of auto-approving)
chmod +x useful_scripts/initiate_os_script/initiate_os_script.sh && sudo useful_scripts/initiate_os_script/initiate_os_script.sh --prompt

# Preview every command without changing anything (no root needed)
chmod +x useful_scripts/initiate_os_script/initiate_os_script.sh && useful_scripts/initiate_os_script/initiate_os_script.sh --dry-run

# Skip steps you've already done or don't want
chmod +x useful_scripts/initiate_os_script/initiate_os_script.sh && sudo useful_scripts/initiate_os_script/initiate_os_script.sh --skip-vnc --skip-docker
```

## Flags

| Flag | Effect | Default |
| ---- | ------ | ------- |
| `--skip-update` | Do not update/upgrade system packages first. | update runs |
| `--skip-desktop` | Skip step 1 (`install_server_with_minimum_ui.sh`). | runs |
| `--skip-vnc` | Skip step 2 (`setup-vnc-combined.sh`). | runs |
| `--skip-docker` | Skip step 3 (`install_docker_engine.sh`). | runs |
| `--skip-maintenance` | Skip step 4 (`install_system_maintenance.sh`). | runs |
| `--skip-bandwidth` | Skip step 5 (`bandwidth_test.sh`). | runs |
| `--skip-x11` | Skip step 6 (`prepare_x11.sh`). | runs |
| `--skip-os-config` | Skip step 7 (`os_config.sh`). | runs |
| `--dry-run` | Print every command without executing anything. Does **not** require root. | off |
| `--prompt` | Ask for confirmation before proceeding, instead of auto-approving; also leaves the desktop and Docker installers to show their own confirmation prompts (no `-y` forwarded). | auto-approved |
| `-h`, `--help` | Show usage and exit. | — |

## What the script does

1. Detects the distribution family and requires root for a real run
   (`--dry-run` is exempt). By default it proceeds without asking, and
   forwards `-y` to the desktop and Docker installers so their own prompts
   are skipped too; pass `--prompt` to ask for confirmation instead (and
   leave the sub-scripts' own prompts in place).
2. Verifies every sub-script it's about to run actually exists, before
   touching anything.
3. Updates and upgrades system packages with the family's own tooling
   (`apt-get`, `dnf`/`yum`, `pacman`, `zypper`, `apk`, `emerge` or
   `slackpkg`).
4. `chmod +x`'s and runs each sub-script in turn, printing a numbered banner
   before each one. Step 4 is skipped automatically on families other than
   Debian/RHEL (see above).

Every command is routed through a `run` helper, so `--dry-run` is a faithful
preview of exactly what a real run would execute.

### Default arguments passed to each sub-script

These are set near the top of the script and can be edited directly if you
want different defaults:

| Script | Default arguments |
| ------ | ------------------ |
| `install_server_with_minimum_ui.sh` | `--minimal --desktop xfce` |
| `setup-vnc-combined.sh` | *(none — grants access to the invoking login user)* |
| `install_docker_engine.sh` | *(none)* |
| `install_system_maintenance.sh` | `--update --restart` |
| `bandwidth_test.sh` | `--mbps` |
| `prepare_x11.sh` | *(none)* |
| `os_config.sh` | *(none)* |

Each sub-script has its own flags (window manager, VNC port, update
schedule, connection count, ...) — see that script's own `--help` / README
for the full list.

### Notes on the VNC step

`setup-vnc-combined.sh` grants access to the invoking login user (via
`logname`) and requires a graphical desktop to already be installed (which
step 1 provides). It prompts for a VNC password unless `$VNC_PASSWORD` is
already set in the environment, independently of `--prompt` — set
`VNC_PASSWORD` beforehand for a fully non-interactive run:

```bash
chmod +x useful_scripts/initiate_os_script/initiate_os_script.sh && VNC_PASSWORD='secret' sudo -E useful_scripts/initiate_os_script/initiate_os_script.sh
```

### Notes on the OS config step

`os_config.sh` recursively `chown`s the invoking login user's home directory
back to that user (resolved via `$SUDO_USER`, not `logname` — see
[`OS_Config/README.md`](../OS_Config/README.md) for why), and grants that
user passwordless sudo unless `OS_CONFIG_ARGS` includes
`--no-passwordless-sudo`. It runs last so it also cleans up anything earlier
steps wrote there as root (e.g. VNC's `~/.vnc`). It also ships a library of
optional, commented-out config recommendations — see its README for details.

## Fixed from the previous version

The earlier version of this script had several bugs:

- **Docker was never actually installed.** It was announced in the on-screen
  step list but was missing from both the `chmod +x` list and the execution
  block entirely.
- **Only the first sub-script in the execution block ever ran.** The script
  tried to sequence multiple different commands using a single Bash brace
  expansion (`../../../{cmd1,cmd2,...}`). Brace expansion just expands into
  extra *words* on one command line — it does not run each item as a
  separate command. In practice, Bash treated the first expanded word as the
  command and *all the rest* (including the `printf` banners and the other
  scripts) as literal arguments to it, so everything after the first script
  was passed as unrecognized flags instead of being executed.
- **Wrong relative path depth.** The script referenced its sibling
  directories via `../../../`, which resolves to the parent of the
  repository root, not the repository root itself.
- **Not cross-platform.** The system update step was hardcoded to
  `apt update && apt upgrade -y` (Debian/Ubuntu only). It now detects the
  distribution family and updates with that family's own package manager.
- **Path resolution depended on the current working directory.** There was
  no `cd`/`dirname` anchoring, so running the script from anywhere other
  than its own directory would break the relative paths. It now resolves
  its own location and the repository root explicitly.
