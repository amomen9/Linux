# Install Chrome and Edge (X11)

Cross-platform installer for Google Chrome and Microsoft Edge, plus the
minimal local X11 stack (`xauth`, `xterm`, a lightweight window manager)
needed to display their windows back to your local machine over an
X11-forwarded SSH session. Covers every distribution family in
[`Supported Distributions.txt`](../../Migrate_to_Linux/Supported%20Distributions.txt).

## Quick start

```bash
# Install Chrome, Edge and the X11 stack (asks for confirmation)
./install_chrome_and_edge_x11.sh

# Skip the confirmation prompt
./install_chrome_and_edge_x11.sh -y

# Preview every command without changing anything (no root needed)
./install_chrome_and_edge_x11.sh --dry-run
```

If the executable bit isn't set (e.g. after checking out on Windows), run it
through bash:

```bash
bash install_chrome_and_edge_x11.sh -y
```

Run it as your normal user, **not** as root — individual privileged commands
are prefixed with `sudo` internally. (This also matters on Arch: AUR helpers
refuse to run as root.)

## Requirements

* An SSH connection with X11 forwarding enabled if you want the browser
  windows to appear on your local display, e.g.:

  ```bash
  ssh -X user@host
  ```

  Verify forwarding works before running the script:

  ```bash
  echo $DISPLAY        # should print something like localhost:10.0
  xauth list           # should list a cookie for that display
  ```

## Supported families

The script auto-detects the family from `/etc/os-release` (with a
package-manager fallback), same as
[`install_server_with_minimum_ui.sh`](../Install_Server_with_Minimum_UI/install_server_with_minimum_ui.sh).

| Family | Package manager | Chrome | Edge |
| ------ | ---------------- | ------ | ---- |
| Debian / Ubuntu | `apt` | Official `.deb` direct download | Official APT repo |
| RHEL / Fedora | `dnf`/`yum` | Official `.rpm` direct download | Official yum repo |
| Arch | `pacman` | AUR (`google-chrome`) via `yay`/`paru` | AUR (`microsoft-edge-stable-bin`) via `yay`/`paru` |
| openSUSE / SUSE | `zypper` | Fedora `.rpm` installed directly (best-effort — not officially supported by Google) | Official yum repo added via `zypper` (Microsoft documents this) |
| Alpine¹ | `apk` | Not installable (glibc-only binary on musl) — installs Chromium instead | Not installable (glibc-only binary on musl) — installs Chromium instead |
| Gentoo¹ | `emerge` | `www-client/google-chrome` (accepts its license automatically) | No ebuild in the main tree — prints instructions for the GURU overlay |
| Slackware¹ | `slackpkg` | Via `sboinstall` if `sbotools` is present, else guidance only (SlackBuilds.org) | Via `sboinstall` if `sbotools` is present, else guidance only (SlackBuilds.org) |

1. **Best-effort**, per the notes in `Supported Distributions.txt`: neither
   browser is officially packaged for these families. The script does what
   it reasonably can and prints on-screen guidance for the rest.

## What it does

1. Detects the distribution family.
2. Ensures `~/.Xauthority` exists for X11 cookie storage (no permission
   changes beyond creating it — it must stay private to your user).
3. Installs the family's X11 base packages (`xauth`, `xterm`, a minimal
   X.Org base, and Openbox where packaged).
4. Installs Google Chrome and Microsoft Edge using the method appropriate
   for that family (see table above), skipping either browser if it's
   already installed.
5. Cleans the local package cache where the package manager supports it.

Re-running the script is safe: browser installs are skipped when the
respective binary is already on `PATH`, and the package-manager steps are
idempotent.

## Notes

* The script does **not** launch either browser after installing it —
  start them yourself once you're ready (`google-chrome-stable` /
  `microsoft-edge-stable`).
* It does not touch `/root` or change any file permissions on `.Xauthority`
  beyond creating it — those cookie files must stay private to the owning
  user.
* On Arch, if neither `yay` nor `paru` is installed, the script prints
  instructions for installing one rather than building AUR packages itself.
