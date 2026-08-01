# Docker Engine Installer (`install_docker_engine.sh`)

A small Bash script that installs **Docker Engine** on Debian/Ubuntu-family systems
using Docker's official `apt` repository — the same steps as
[Docker's own install guide](https://docs.docker.com/engine/install/ubuntu/), automated.

---

## What it does

1. Removes old/conflicting packages (`docker.io`, `docker-doc`, `docker-compose`,
   `docker-compose-v2`, `podman-docker`, `containerd`, `runc`) if present.
2. Installs prerequisites: `ca-certificates`, `curl`, `gnupg`, `lsb-release`.
3. Downloads Docker's GPG signing key into `/etc/apt/keyrings/docker.asc`.
4. Adds the Docker `apt` repository, pinned to that key via `signed-by`.
5. Installs `docker-ce`, `docker-ce-cli`, `containerd.io`, `docker-buildx-plugin`,
   and `docker-compose-plugin`.
6. Enables and starts the `docker` systemd service.
7. Adds the user who invoked `sudo` to the `docker` group, so Docker can be used
   without `sudo`.
8. Prints the installed version and `docker context ls` to confirm it's working.

---

## Requirements

- A **Debian/Ubuntu-family** distribution with `apt` and `systemd`.
- **Root privileges** (run with `sudo`).

---

## Usage

```bash
sudo ./install_docker_engine.sh
```

After it finishes, log out and back in (or run `newgrp docker`) so your shell picks
up the new `docker` group membership, then verify with:

```bash
docker run hello-world
```

---

## Fixes from the original version

The script previously used Docker's **legacy install method**, which has since broken:

- Replaced the deprecated `apt-key add` (removed in current Ubuntu/Debian releases)
  with the current `/etc/apt/keyrings` + `signed-by` approach.
- Added the missing `gnupg` and `lsb-release` prerequisites that `apt-key` and
  `lsb_release -cs` depend on.
- Added `set -euo pipefail` and a root check so failures stop the script instead of
  silently continuing.
- Quoted variable expansions and replaced backticks with `$(...)`.
- Added `systemctl enable --now docker` so the daemon actually starts after install.
- Added the invoking user to the `docker` group so Docker can be used without `sudo`.
- Dropped `software-properties-common`, which was only needed for the old
  `add-apt-repository`-based method.
