# Scheduled systemd Automatic Update

systemd `service` + `timer` units that keep a Linux server patched on a schedule
and, optionally, reboot it when an update requires it.

The units come in two flavours:

| Distribution family | Folder | Package tooling |
| ------------------- | ------ | --------------- |
| Debian / Ubuntu     | [`Debian/`](Debian/README.md) | `apt` / `dpkg` |
| RHEL / CentOS Stream / Rocky / AlmaLinux / Fedora | [`RHEL/`](RHEL/README.md) | `dnf` / `needs-restarting` |

Each folder's `README.md` documents the unit files in detail and how to install
them by hand. For a one-shot install, use the cross-platform script below.

## Quick install — `install_system_maintenance.sh`

[`install_system_maintenance.sh`](install_system_maintenance.sh) auto-detects the
distribution family, copies the matching unit files from `Debian/` or `RHEL/`
into `/etc/systemd/system`, and enables the requested timer(s).

```bash
# Automatic updates only
sudo ./install_system_maintenance.sh --update

# Scheduled reboot-when-required only
sudo ./install_system_maintenance.sh --restart

# Both
sudo ./install_system_maintenance.sh --update --restart
```

If the executable bit is not set (e.g. after checking out on Windows), invoke it
through bash instead:

```bash
sudo bash install_system_maintenance.sh --update --restart
```

### Flags

| Flag        | Effect |
| ----------- | ------ |
| `--update`  | Installs and enables `system_update.service` + `system_update.timer` (daily package upgrade). |
| `--restart` | Installs and enables `system_restart.service` + `system_restart.timer` (weekly reboot, only if a reboot is pending). |
| `-h`, `--help` | Prints usage. |

At least one of `--update` / `--restart` is required; the two can be combined.

### What the script does

1. Requires root (`sudo`).
2. Detects the distribution family from `/etc/os-release` (falling back to the
   available package manager).
3. On RHEL-family systems, installs `dnf-utils` if needed — it provides the
   `needs-restarting` and `yum-complete-transaction` helpers used by the units.
4. Copies the selected unit files into `/etc/systemd/system` (mode `0644`).
5. Runs `systemctl daemon-reload` and `systemctl enable --now` on the installed
   timer(s), then prints the resulting schedule with `systemctl list-timers`.

> **Note:** The script reads the unit files from the `Debian/` and `RHEL/`
> subdirectories, so run it from within the cloned repository (it locates those
> folders relative to its own path).

### Uninstalling

```bash
sudo systemctl disable --now system_update.timer system_restart.timer
sudo rm -f /etc/systemd/system/system_update.{service,timer} \
           /etc/systemd/system/system_restart.{service,timer}
sudo systemctl daemon-reload
```
