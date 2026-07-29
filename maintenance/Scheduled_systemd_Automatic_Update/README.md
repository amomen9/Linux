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

# Both, but with a custom update schedule (systemd OnCalendar syntax, quoted)
sudo ./install_system_maintenance.sh --update --restart --update-sched "*-*-* 04:00:00"

# Install the restart units but leave the timer disabled for now
sudo ./install_system_maintenance.sh --restart --restart-enabled false
```

If the executable bit is not set (e.g. after checking out on Windows), invoke it
through bash instead:

```bash
sudo bash install_system_maintenance.sh --update --restart
```

### Flags

| Flag | Effect | Default |
| ---- | ------ | ------- |
| `--update [true\|false]` | Install `system_update.service` + `system_update.timer` (daily package upgrade). A bare `--update` means `true`; pass `false`/`0` to skip the update units. | not installed unless the flag is given (bare `--update` = `true`) |
| `--restart [true\|false]` | Install `system_restart.service` + `system_restart.timer` (weekly reboot, only if a reboot is pending). A bare `--restart` means `true`; pass `false`/`0` to skip the restart units. | not installed unless the flag is given (bare `--restart` = `true`) |
| `--update-sched "<OnCalendar>"` | Override the update timer's `OnCalendar=` schedule. Use systemd `OnCalendar` syntax and quote it with `"` or `'`. | `*-*-* 02:30:00` |
| `--restart-sched "<OnCalendar>"` | Override the restart timer's `OnCalendar=` schedule. Use systemd `OnCalendar` syntax and quote it with `"` or `'`. | `Fri 04:30:00` |
| `--update-enabled [true\|false]` | Whether the update **timer** is enabled (started at boot and scheduled). When `false`, the timer is installed but left stopped and disabled. | `true` |
| `--restart-enabled [true\|false]` | Whether the restart **timer** is enabled. When `false`, the timer is installed but left stopped and disabled. | `true` |
| `-h`, `--help` | Print usage and exit. | — |

At least one of `--update` / `--restart` must be effectively true; the two can be
combined. Boolean flags accept `true`/`false` or `1`/`0`, written either as
`--flag value` or `--flag=value`.

> **Services are installed disabled.** The `.service` units are never enabled, so
> they do **not** run on boot — only the `.timer` units are enabled. The timers
> still trigger the services on schedule. This is deliberate: it stops a pending
> reboot from firing on every startup. The script is also idempotent, so it is
> safe to re-run to change a schedule or toggle a timer on/off.

### What the script does

1. Requires root (`sudo`).
2. Detects the distribution family from `/etc/os-release` (falling back to the
   available package manager).
3. On RHEL-family systems, installs `dnf-utils` if needed — it provides the
   `needs-restarting` and `yum-complete-transaction` helpers used by the units.
4. Copies the selected unit files into `/etc/systemd/system` (mode `0644`),
   applying any `--update-sched` / `--restart-sched` `OnCalendar` override to the
   installed timer.
5. Runs `systemctl daemon-reload`, then:
   * **disables** each `.service` so it never runs on boot; and
   * **enables and (re)starts** each `.timer` (unless `--update-enabled` /
     `--restart-enabled` is `false`, in which case the timer is left stopped and
     disabled). Restarting the timer makes a changed schedule take effect.
6. Prints the resulting schedule with `systemctl list-timers`.

Because every step overwrites the units and re-asserts the enabled/disabled
state, the script is **idempotent** — re-running it (e.g. to change a schedule)
converges to the same result without error.

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
