# Install Server with (Minimum) UI

A single cross-platform script that adds a graphical desktop to a server across
every distribution family in
[`Supported Distributions.txt`](../../Migrate_to_Linux/Supported%20Distributions.txt),
using each family's own group/pattern install.

It ships **two profiles**:

* **Default — full "server with GUI".** The distribution's canonical grouping,
  e.g.

  ```bash
  sudo dnf group install "Server with GUI" -y      # RHEL / Rocky / Alma / ...
  sudo apt install ubuntu-desktop-minimal          # Ubuntu
  ```

* **`--minimal` — a stripped-down graphical layer.** The X.Org base via the
  family's group/pattern (dnf `base-x`, the `xorg` metapackage, zypper
  `-t pattern x11`, …) plus a lightweight window manager/desktop and LightDM.

## Quick start — `install_server_with_minimum_ui.sh`

```bash
# Full server GUI (default)
sudo ./install_server_with_minimum_ui.sh

# Minimal: Openbox + LightDM
sudo ./install_server_with_minimum_ui.sh --minimal

# Minimal, but a lightweight XFCE desktop (group install)
sudo ./install_server_with_minimum_ui.sh --minimal --desktop xfce

# Minimal, X.Org only, no window manager, no display manager (use `startx`)
sudo ./install_server_with_minimum_ui.sh --minimal --desktop none --no-dm

# Preview every command without changing anything (no root needed)
./install_server_with_minimum_ui.sh --dry-run --minimal
```

If the executable bit is not set (e.g. after checking out on Windows), run it
through bash:

```bash
sudo bash install_server_with_minimum_ui.sh --minimal --desktop xfce -y
```

## What each family installs

The script auto-detects the family from `/etc/os-release` (with a
package-manager fallback). Native **group/pattern** installs are shown in bold.

| Family | Default (full server GUI) | `--minimal` (X base + light UI) | Display mgr |
| ------ | ------------------------- | ------------------------------- | ----------- |
| Debian / Ubuntu (`apt`) | `ubuntu-desktop-minimal` (Ubuntu) / `gnome-core` (Debian) | `xorg` metapackage + `openbox` \| `xfce4` | gdm3 / **lightdm** |
| RHEL / Fedora (`dnf`/`yum`) | **`group install "Server with GUI"`** (RHEL) / **`workstation-product-environment`** (Fedora) | **`group install base-x`** + `openbox` \| **`group install xfce-desktop`** | gdm / **lightdm** |
| Arch (`pacman`) | **`gnome` group** + gdm | **`xorg` group** + `openbox` \| **`xfce4` group** | gdm / **lightdm** |
| openSUSE / SUSE (`zypper`) | **`-t pattern gnome`** | **`-t pattern x11`** + `openbox` \| **`-t pattern xfce`** | gdm / lightdm¹ |
| Alpine² (`apk`) | `gnome` | `setup-xorg-base` + `openbox` \| `xfce4` | gdm / lightdm |
| Gentoo² (`emerge`) | `xfce4-meta`³ | `xorg-server` + `openbox` \| `xfce4-meta` | lightdm |
| Slackware² (`slackpkg`) | **`install x xap kde`** (Plasma) | **`install x xap`** | runlevel 4 |

1. On openSUSE the display manager is chosen via `DISPLAYMANAGER=` in
   `/etc/sysconfig/displaymanager` and enabled through `display-manager.service`;
   the script handles this automatically.
2. **Best-effort.** Alpine (musl/OpenRC), Gentoo (source builds) and Slackware
   (no packaged Openbox/LightDM; graphical login via runlevel 4) print extra
   guidance on screen. Flatpak is the recommended app-delivery method on these,
   per `Supported Distributions.txt`.
3. A full GNOME build from source on Gentoo is impractical, so the "full"
   profile there installs XFCE.

## Flags

| Flag | Effect | Default |
| ---- | ------ | ------- |
| `--minimal` | Install the minimal graphical layer (X base + light UI + LightDM) instead of the full server GUI. | full server GUI |
| `--desktop <openbox\|xfce\|none>` | With `--minimal`, which light UI to install: `openbox` (tiny WM), `xfce` (lightweight desktop), or `none` (X.Org only). Ignored without `--minimal`. | `openbox` |
| `--dm <name>` | Force a specific display manager package/service (e.g. `sddm`). | family default |
| `--no-dm` | Do not install or enable a display manager (text login + `startx`). | display manager enabled |
| `--no-graphical` | Do not switch the default boot target to graphical (keep booting to text). | boots to graphical |
| `--dry-run` | Print every command without executing anything. Does **not** require root. | off |
| `-y`, `--yes` | Skip the confirmation prompt and proceed. | prompt |
| `-h`, `--help` | Show usage and exit. | — |

## What the script does

1. Prints the plan (family, profile, display manager, boot target).
2. Requires root for a real run (`--dry-run` is exempt) and asks for
   confirmation unless `-y`/`--yes` is given.
3. Detects the distribution family and installs, via that family's package
   tooling, either the full "server with GUI" grouping (default) or — with
   `--minimal` — the X.Org base (using the native group/pattern) plus the chosen
   lightweight desktop and, unless `--no-dm`, a display manager.
4. Enables graphical login:
   * **systemd** — `systemctl set-default graphical.target` (unless
     `--no-graphical`) and `systemctl enable <dm>.service` (via
     `display-manager.service` on openSUSE);
   * **OpenRC** — adds the display manager to the `default` runlevel;
   * **Slackware** — sets the default runlevel to 4.
5. In `--minimal` mode on RHEL rebuilds (not Fedora) it enables **EPEL** first,
   since `openbox` and `lightdm` live there.

Every command is routed through a `run` helper, so `--dry-run` is a faithful
preview of exactly what a real run would execute. Package installs use each
tool's idempotent, non-interactive mode, so re-running the script is safe.

Reboot afterwards to boot into the new desktop:

```bash
sudo reboot
```
