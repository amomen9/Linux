# Install Chrome and Edge (X11)

Installs Google Chrome and Microsoft Edge on a Debian/Ubuntu machine, along
with the minimal X11 stack (`xauth`, `xterm`, `xorg`, `x11-apps`, Openbox)
needed to display their windows back to your local machine over an
X11-forwarded SSH session.

## Quick start

```bash
./install_chrome_and_edge_x11.sh
```

If the executable bit isn't set (e.g. after checking out on Windows), run it
through bash:

```bash
bash install_chrome_and_edge_x11.sh
```

The script uses `sudo` internally for package installs, so run it as your
normal user, not as root.

## Requirements

* Debian or Ubuntu (uses `apt`).
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

## What it does

1. Updates package lists and installs `xterm`, `xauth`, `xorg`,
   `openbox`, and `x11-apps`.
2. Ensures `~/.Xauthority` exists for X11 cookie storage.
3. Adds Microsoft's APT repository (with its signing key) and installs
   `microsoft-edge-stable`, unless it's already installed.
4. Downloads and installs the official Google Chrome `.deb` package,
   unless it's already installed.
5. Cleans the local APT package cache.

Re-running the script is safe — both browser installs are skipped if the
respective binary is already on `PATH`, and the APT/xauth steps are
idempotent.

## Notes

* The script does **not** launch either browser after installing it —
  start them yourself once you're ready (`google-chrome-stable` /
  `microsoft-edge-stable`).
* It does not touch `/root` or change any file permissions on `.Xauthority`
  beyond creating it — those cookie files must stay private to the owning
  user.
