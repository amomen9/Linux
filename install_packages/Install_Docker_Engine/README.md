# Install Docker Engine (`install_docker_engine.sh`)

A cross-platform script that installs **Docker Engine + Compose** across every
distribution family in
[`Supported Distributions.txt`](../../Migrate_to_Linux/Supported%20Distributions.txt),
using each family's own package tooling where possible.

Debian/Ubuntu and RHEL/Fedora use Docker's official repository. Arch,
openSUSE, Alpine and Gentoo use the distribution's own packaged `docker`.
Slackware has no official Docker package, so the script installs Docker's
upstream **static binaries** and a minimal SysV init script instead.

## Quick start

```bash
# Install, enable and start Docker; add the invoking (sudo) user to the docker group
sudo ./install_docker_engine.sh

# Skip adding the invoking user to the docker group
sudo ./install_docker_engine.sh --no-group

# Preview every command without changing anything (no root needed)
./install_docker_engine.sh --dry-run
```

If the executable bit is not set (e.g. after checking out on Windows), run it
through bash:

```bash
sudo bash install_docker_engine.sh
```

## What each family does

The script auto-detects the family from `/etc/os-release` (with a
package-manager fallback).

| Family | Source | Service enable |
| ------ | ------ | --------------- |
| Debian / Ubuntu (`apt`) | Docker's official apt repo (`download.docker.com/linux/{debian,ubuntu}`) | `systemctl enable --now docker` |
| RHEL / Fedora (`dnf`/`yum`) | Docker's official yum repo (`docker-ce.repo` for `centos`/`fedora`) | `systemctl enable --now docker` |
| Arch (`pacman`) | `docker`, `docker-compose`, `docker-buildx` (official repos) | `systemctl enable --now docker` |
| openSUSE / SUSE (`zypper`) | `docker`, `docker-compose` (official repos) | `systemctl enable --now docker` |
| Alpine¹ (`apk`) | `docker`, `docker-cli-compose` (community repo, enabled if missing) | OpenRC: `rc-update add docker default` |
| Gentoo¹ (`emerge`) | `app-containers/docker[-cli\|-compose]` (source build) | systemd or OpenRC, whichever is present |
| Slackware¹ (static) | Docker's static binary tarball for the detected architecture, copied to `/usr/bin` | Custom `/etc/rc.d/rc.docker`, hooked into `rc.local` |

1. **Best-effort.** Alpine and Gentoo print extra guidance on screen. Slackware
   has no Compose plugin in the static build — install it separately (e.g. via
   SlackBuilds.org) if you need it.

## Flags

| Flag | Effect | Default |
| ---- | ------ | ------- |
| `--no-group` | Do not add the invoking (`sudo`) user to the `docker` group. | user is added |
| `--dry-run` | Print every command without executing anything. Does **not** require root. | off |
| `-y`, `--yes` | Skip the confirmation prompt and proceed. | prompt |
| `-h`, `--help` | Show usage and exit. | — |

## What the script does

1. Detects the distribution family and CPU architecture.
2. Requires root for a real run (`--dry-run` is exempt) and asks for
   confirmation unless `-y`/`--yes` is given.
3. Removes old/conflicting Docker-related packages for that family.
4. Installs Docker Engine (+ Compose, where packaged) via the family's own
   tooling, as described above.
5. Enables and starts the daemon: `systemd` (`systemctl enable --now docker`),
   `OpenRC` (`rc-update add docker default` + `rc-service docker start`), or
   Slackware's `sysvinit` (a generated `/etc/rc.d/rc.docker`, started
   immediately and hooked into `/etc/rc.d/rc.local` for future boots).
6. Adds the user who invoked `sudo` to the `docker` group (skip with
   `--no-group`), so Docker can be used without `sudo`.
7. Prints `docker --version` and `docker context ls` to confirm it's working.

Every command is routed through a `run` helper, so `--dry-run` is a faithful
preview of exactly what a real run would execute.

After it finishes, log out and back in (or run `newgrp docker`) so your shell
picks up the new `docker` group membership, then verify with:

```bash
docker run hello-world
```

## Notes on the official-repo families (Debian/Ubuntu, RHEL/Fedora)

- Replaces the deprecated `apt-key add` (removed in current Ubuntu/Debian)
  with the current `/etc/apt/keyrings` + `signed-by` approach.
- Ubuntu derivatives (Mint, Pop!_OS, Zorin, elementary, Kubuntu) resolve their
  underlying Ubuntu codename via `UBUNTU_CODENAME`/`VERSION_CODENAME` (falling
  back to `lsb_release -cs`), so the correct apt suite is always used.
- RHEL-family distros (RHEL, Rocky, AlmaLinux, CentOS, Oracle Linux) share
  Docker's `centos` repo file; Fedora uses its own.
