# TigerVNC Server Setup (`setup-vnc-combined.sh`)

A single, **distro-agnostic** Bash script that installs a TigerVNC server and wires it
up to your distribution's *own* default desktop — with the **entire session encrypted
by TLS**, no SSH tunnel required.

Point it at an existing user account, answer two prompts, and you get a hardened,
`systemd`-managed remote desktop listening on a non-standard port.

---

## What it does

The script runs in two parts:

**Part 1 — Install & secure the VNC server**
- Grants remote-desktop access to a username **you supply** (the account must already exist).
- Listens on **TCP port `63512`** (a non-default port to cut down on drive-by scans).
- Encrypts the **entire session** — not just the login handshake — using the `X509Vnc`
  security type (TLS via GnuTLS). **No SSH tunnelling needed.**
- Authenticates with a **VNC password**, sent over that already-encrypted channel.
- Verifies server identity with a **self-signed X.509 certificate** (valid 10 years).

**Part 2 — Detect the default desktop**
- Detects the distribution's **own default X11 session** (GNOME on Ubuntu/Fedora, Cinnamon
  on Mint, Plasma on Kubuntu, MATE on a MATE spin, etc.) and points VNC at it.
- **Nothing is hardcoded** — it reads AccountsService / `.dmrc` / LightDM config, falls back
  to the only installed session, and finally to a sensible per-distro guess.
- **GNOME / KDE exception:** GNOME Shell and KDE Plasma are OpenGL compositors that
  **black-screen under `Xvnc`** (there's no GPU). When one of them is the default, the
  script installs **XFCE** — a lightweight, VNC-friendly desktop — and runs that for the VNC
  session instead. Override with `--session native` (force the detected desktop) or
  `--session xfce` (always use XFCE).

Then it writes a `systemd` unit, opens the firewall port, and starts the service.

---

## Supported distributions

Works across the five major package-manager families:

| Package manager | Example distros                         | VNC packages installed              |
| --------------- | --------------------------------------- | ----------------------------------- |
| `apt`           | Debian, Ubuntu, Mint, Pop!\_OS          | `tigervnc-standalone-server`, `tigervnc-common` |
| `dnf` / `yum`   | Fedora, RHEL, CentOS, Rocky, AlmaLinux  | `tigervnc-server`                   |
| `zypper`        | openSUSE, SLE                           | `tigervnc`, `xorg-x11-Xvnc`         |
| `pacman`        | Arch, Manjaro, EndeavourOS              | `tigervnc`                          |

`openssl` and a `dbus-run-session` provider are installed too, if missing.

---

## Requirements

- **Root privileges** (run with `sudo`).
- The **target user account must already exist** — this script never creates users.
- A **graphical desktop with an Xorg (X11) session** must already be installed.
  `Xvnc` is an X11 server and cannot run Wayland-only sessions, so the script only
  considers `.desktop` files under `/usr/share/xsessions`. If none are found, it stops
  cleanly before touching anything.

---

## Usage

Interactive (prompts for username and VNC password):

```bash
sudo ./setup-vnc-combined.sh
```

Non-interactive (pass the account and password via the environment — note `sudo -E`):

```bash
VNC_USER=bob VNC_PASSWORD='secret' sudo -E ./setup-vnc-combined.sh
```

Command-line options (each mirrors a config variable — lowercased, with `_` → `-`):

```bash
sudo ./setup-vnc-combined.sh --vnc-user user --vnc-port 63512 --vnc-display :1 --geometry 1920x1080 --depth 24
```

If `--vnc-user` (or `$VNC_USER`) is omitted, the script prompts for the username as usual.
The VNC **password is never taken on the command line** — it still comes from `$VNC_PASSWORD`
or an interactive prompt, so it can't leak into your shell history. Run with `--help` to see
all options and their defaults.

> **Note:** TigerVNC only uses the **first 8 characters** of the VNC password.

The script is **idempotent** where it matters: an existing `~/.vnc/passwd` or certificate
is kept rather than regenerated (unless you override the password via `VNC_PASSWORD`).

---

## Configuration

Defaults live at the top of the script — edit them there, or override them per-run with the
matching command-line option (variable name lowercased, `_` → `-`):

| Setting       | CLI option       | Default            | Meaning                          |
| ------------- | ---------------- | ------------------ | -------------------------------- |
| `VNC_USER`    | `--vnc-user`     | *(prompted)*       | Existing account to grant access |
| `VNC_PORT`    | `--vnc-port`     | `63512`            | TCP port the server listens on   |
| `VNC_DISPLAY` | `--vnc-display`  | `:1`               | X display number                 |
| `GEOMETRY`    | `--geometry`     | `1920x1080`        | Screen resolution                |
| `DEPTH`       | `--depth`        | `24`               | Colour depth (bits)              |
| `SESSION_CHOICE` | `--session`   | `auto`             | `auto` (swap GNOME/KDE→XFCE), `xfce`, or `native` |
| `XSESS_DIR`   | *(edit script)*  | `/usr/share/xsessions` | Where X11 session files are read from |

**`--session` modes:**

- **`auto`** *(default)* — use the distro's own default desktop, **except** GNOME/KDE/Plasma
  (which black-screen over VNC): those are swapped for a freshly-installed XFCE.
- **`xfce`** — always install and use XFCE, regardless of the machine's default desktop.
- **`native`** — always use the detected default desktop as-is. For GNOME/KDE this enables
  software GL as a best-effort, but a black screen is still likely — see Troubleshooting.

---

## Connecting

Use the **TigerVNC Viewer** (recommended, since it supports the `X509Vnc` security type):

```
Address:  <server-ip>::63512      # note the DOUBLE colon before the port
```

On first connect you'll be prompted about the self-signed certificate. Either **accept it
once**, or copy `~/.vnc/cert.pem` from the server to the client and set it as the viewer's
**X509 CA** for silent verification thereafter.

---

## What gets created

In the target user's home (`~/.vnc/`):

| File          | Purpose                                            | Perms |
| ------------- | -------------------------------------------------- | ----- |
| `passwd`      | VNC password (obfuscated by `vncpasswd`)           | `600` |
| `key.pem`     | Private key for the TLS certificate                | `600` |
| `cert.pem`    | Self-signed X.509 certificate                      | `644` |
| `xstartup`    | Launches the detected desktop under Xorg + D-Bus   | `755` |
| `config`      | Per-user session/geometry/depth settings           | `644` |

System-wide:

- **`/etc/systemd/system/vncserver-<user>.service`** — the `systemd` unit. Security-critical
  options (`-SecurityTypes X509Vnc`, cert/key paths, password file, port) live on the
  `ExecStart` command line here. The service is `enable`d and started immediately.
- A firewall rule opening **`63512/tcp`** via **ufw** or **firewalld** (whichever is active).

---

## Managing the service

```bash
systemctl status  vncserver-<user>.service
systemctl restart vncserver-<user>.service
journalctl -u vncserver-<user>.service -e     # logs
```

The per-session log is at `~/.vnc/<hostname>:1.log`.

---

## Troubleshooting

**Black screen after connecting.**
This is the classic **GNOME Shell / KDE Plasma over VNC** failure: they're OpenGL
compositors and `Xvnc` has no GPU, so they render black. By default (`--session auto`) the
script **avoids this entirely by running XFCE instead** — so a fresh run shouldn't hit it.

If you deliberately used `--session native` to keep GNOME/KDE, the script enables software
GL as a best-effort — you'll find these lines already active near the top of `~/.vnc/xstartup`:

```sh
export __GLX_VENDOR_LIBRARY_NAME=mesa   # force the Mesa GLX vendor...
export LIBGL_ALWAYS_SOFTWARE=1          # ...then its software rasteriser
```

The **`__GLX_VENDOR_LIBRARY_NAME=mesa` line matters**: if a proprietary GLVND driver
(e.g. NVIDIA) is installed, its GLX ignores `LIBGL_ALWAYS_SOFTWARE` and the screen stays
black — forcing the Mesa vendor first fixes that. Even so, GNOME Shell over VNC is genuinely
fragile and may stay black regardless. **The reliable fix is to switch to XFCE:** re-run with
`--session xfce` (or `--session auto`). Check the session log (`~/.vnc/<hostname>:1.log`) for
the underlying error. After any change: `systemctl restart vncserver-<user>.service`.

**Connection refused on Fedora / RHEL / openSUSE (SELinux `Enforcing`).**
The custom port may need labelling for VNC:

```bash
semanage port -a -t vnc_port_t -p tcp 63512     # needs policycoreutils-python-utils
```

**No X11 session found.**
Install a desktop with an Xorg session first, e.g. Ubuntu `ubuntu-desktop`, Mint `cinnamon`,
or Fedora's *GNOME on Xorg* (`gnome-session-xsession`), then re-run the script.

**Firewall didn't open the port.**
If you don't run ufw or firewalld, open `63512/tcp` manually in whatever firewall you use.

---

## Security notes

- The **whole session is TLS-encrypted** (`X509Vnc`), so the VNC password and all screen/input
  traffic travel encrypted — unlike plain VNC, which only obfuscates the initial handshake.
- The certificate is **self-signed**. That secures the channel, but a client can't verify the
  server's identity until it has trusted the cert (accept-on-first-use, or pin `cert.pem` as CA).
- The server listens on **all interfaces** (`localhost=no`) so it's reachable remotely. Restrict
  access with your firewall / network as appropriate for your environment.
