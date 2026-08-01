# OS Config (`os_config.sh`)

Fixes ownership of a user's home directory — recursively `chown`s it back to
the real user — and ships a library of optional, distro-aware OS config
recommendations that you can opt into.

It's step 7 (the last step) of
[`initiate_os_script.sh`](../initiate_os_script/initiate_os_script.sh), where
it cleans up anything earlier steps (VNC, Docker, etc.) wrote under the
invoking user's `$HOME` while running as root. It also works standalone.

It is cross-platform across every distribution family in
[`Supported Distributions.txt`](../../Migrate_to_Linux/Supported%20Distributions.txt):
Debian/Ubuntu (`apt`), RHEL/Fedora (`dnf`/`yum`), Arch (`pacman`),
openSUSE/SUSE (`zypper`), Alpine (`apk`), Gentoo (`emerge`) and Slackware
(`slackpkg`). The ownership fix itself needs no package manager and works
identically on all of them; the distro family is only consulted by the
optional recommendations below.

## Quick start

```bash
chmod +x useful_scripts/OS_Config/os_config.sh

# Fix ownership of the invoking user's own home directory
sudo useful_scripts/OS_Config/os_config.sh

# Fix a specific user's home directory instead
sudo useful_scripts/OS_Config/os_config.sh --user alice

# Preview only, no root needed
useful_scripts/OS_Config/os_config.sh --dry-run
```

## Flags

| Flag | Effect | Default |
| ---- | ------ | ------- |
| `--user NAME` | Fix `NAME`'s home directory instead of the default. | `$SUDO_USER` when run via `sudo`, otherwise the current user |
| `--dry-run` | Print what would be done without changing anything. Does **not** require root. | off |
| `-h`, `--help` | Show usage and exit. | — |

## What the script does

1. Works out which user's home directory to fix — `--user`, else
   `$SUDO_USER` (set by `sudo`), else the current user.
2. Resolves that user's home directory from the passwd database (`getent`,
   falling back to `awk` over `/etc/passwd` if `getent` isn't installed) and
   refuses to continue if it can't find one, if the directory doesn't exist,
   or if it resolves to `/` (a defensive guard against ever recursively
   `chown`ing the whole filesystem).
3. Recursively `chown`s that directory to `user:user`.
4. Detects the distro family (same detection logic as the other scripts in
   this repo), for use by the optional recommendations below.

Every command is routed through a `run` helper, so `--dry-run` is a faithful
preview of exactly what a real run would execute.

## Fixed from the previous version

The earlier version of this script was a single line:

```bash
chown -R $(logname):$(logname) ~$(logname)
```

This had two bugs:

- **`logname` fails without a controlling terminal.** It reads the
  controlling terminal's audit info, which doesn't exist when the script is
  run from cron, CI, or a calling script's `run()`-style helper (exactly how
  `initiate_os_script.sh` invokes it). When `logname` fails, `$(logname)`
  expands to an empty string.
- **That empty string silently redirected the `chown` to the wrong
  directory.** `~$(logname)` becoming `~` (with nothing after it) tilde-
  expands to the *current* user's home — root's `/root`, since the script is
  meant to be run via `sudo` — instead of erroring out. So instead of fixing
  the invoking user's home directory, a failed `logname` would silently
  `chown -R` **root's own home directory** to `root:root` (a no-op, but the
  intended fix never happened) or, if `logname` printed something that
  happened to match no real user, `chown` would just fail on a literal `~name`
  path in the current directory.

The rewritten script resolves the invoking user via `$SUDO_USER` (falling
back to the current user, matching the pattern already used by
[`Prepare_X11/prepare_x11.sh`](../Prepare_X11/prepare_x11.sh)), looks up
their home directory explicitly via the passwd database instead of relying
on shell tilde-expansion, and refuses to proceed if that resolution is empty,
missing, or `/` — so a lookup failure now produces a clear error message
instead of silently operating on the wrong directory.

## Optional recommendations (disabled by default)

Beyond the ownership fix, `os_config.sh` ends with a block of **optional**
general config recommendations. These are plain shell comments — inert by
default, never executed — that you can read and selectively uncomment
directly in the script:

| # | Recommendation | Why |
| - | --------------- | --- |
| 1 | Enable NTP time sync | Accurate clocks matter for TLS, Kerberos, build reproducibility, and anything timestamp-sensitive. |
| 2 | Lower `vm.swappiness` to 10 | Keeps more in RAM before swapping out — snappier on desktops with plenty of RAM (default is 60). |
| 3 | Raise `fs.inotify.max_user_watches` | The default limit is too low for VS Code / IntelliJ / webpack-vite watch-mode on any non-trivial repo. |
| 4 | Enable `fstrim.timer` | Weekly SSD TRIM keeps write performance from degrading over time. |
| 5 | Cap `systemd-journald`'s on-disk log size | Prevents an unbounded journal from quietly filling `/var/log/journal`. |
| 6 | Baseline firewall (default-deny inbound, allow SSH) | A sane starting point for a freshly provisioned box — review before enabling if other services are exposed. |
| 7 | Raise open-file-descriptor limits | The default (1024 soft) is too low for dev servers, Docker, databases, etc. |

Each block is distro-aware via the `$FAMILY` variable the script already
computes (`debian`, `rhel`, `arch`, `suse`, `alpine`, `gentoo`, `slackware`),
so once uncommented it picks the right tool for the running distro (e.g.
`timedatectl` vs. `chronyd`, `ufw` vs. `firewall-cmd`). None of them are
enabled by default — open the script and uncomment only what you want.
