# X11 Forwarding Fixer (`prepare_x11.sh`)

Diagnoses and fixes the classic SSH X11-forwarding failure seen with MobaXterm
(MoTTY), PuTTY+Xming, or any `ssh -X` client:

```text
MoTTY X11 proxy: No authorisation provided
Failed to connect to Mir: Failed to connect to server socket: No such file or directory
Unable to init server: Could not connect: Connection refused

(midori:263046): Gtk-WARNING **: cannot open display: localhost:10.0
```

`$DISPLAY` looking like `localhost:10.0` is completely normal (that's how SSH
X11 forwarding works). The actual fault is "no authorisation", and it is
almost always one of:

1. **`xauth` is not installed on the server.** sshd can only write the
   MIT-MAGIC-COOKIE into `~/.Xauthority` at login time if `xauth` exists then
   — no `xauth`, no cookie, and every GUI app fails the instant it tries to
   connect. This is the #1 cause.
2. **`X11Forwarding` is disabled** in `/etc/ssh/sshd_config`.
3. **`~/.Xauthority` has the wrong owner/permissions** (often left over from a
   stray `sudo` run).
4. **The GUI app was launched with `sudo`/`su`**, which drops the forwarded
   `DISPLAY`/`XAUTHORITY` — this produces the exact same error even on an
   otherwise healthy setup.
5. **A shell startup file hardcodes `DISPLAY=...`** (in `~/.bashrc`,
   `/etc/environment`, etc.), silently overriding the display sshd actually
   assigned this session. Suspect this when the display number never changes
   between logins (e.g. always `:10.0`) even though everything else checks
   out — the cookie sshd wrote is for the real per-session display, not the
   stale one the shell forces afterwards.

Run this **on the Linux server you SSH into** (not on Windows).

---

## Usage

**Fixing is on by default — no `--fix` flag needed.** Every fix is
idempotent: it checks the current state first and only touches what's
actually wrong, so running the script again and again is always safe, and a
no-op once everything is correct.

```bash
chmod +x prepare_x11.sh
sudo ./prepare_x11.sh           # diagnose AND fix (default), idempotent
./prepare_x11.sh --check        # diagnose only, changes nothing
sudo ./prepare_x11.sh --test    # fix it, then prove it works live
sudo ./prepare_x11.sh --dry-run # preview every fix, no root needed
```

Root is only required for the specific fixes that need it — installing
`xauth`, editing `sshd_config`, restarting sshd. Running without `sudo` still
diagnoses everything and applies any fix that doesn't need root (e.g.
`chmod`-ing your own `~/.Xauthority`); the steps that do need root are simply
skipped with a message telling you to re-run with `sudo`.

| Flag                     | Meaning                                                                                          |
| ------------------------ | ------------------------------------------------------------------------------------------------- |
| *(none)*                | Diagnose AND fix. The default — no flag required.                                                |
| `--check`, `--no-fix`  | Diagnose only; report problems but change nothing.                                                |
| `--dry-run`             | Preview every fix that would be applied, without changing anything. No root needed.               |
| `--no-restart`          | Edit sshd_config but skip restarting sshd.                                                        |
| `--test`                | Try a live round-trip test with`xclock`/`xeyes` after diagnosing/fixing.                        |
| `--user NAME`           | Check`NAME`'s`~/.Xauthority` instead of the default (`$SUDO_USER`, or the current user).      |
| `--fix`                 | Accepted for backwards compatibility; already the default, so it's a no-op.                       |
| `-h`, `--help`        | Show help.                                                                                          |

Works across Debian/Ubuntu, RHEL/Fedora, Arch, openSUSE, Alpine and Gentoo
(package names and service managers are resolved per family; Slackware gets a
best-effort note instead, since it normally ships `xauth` with X itself).

`X11Forwarding` is checked and set via `sshd -T`/a validated `sshd -t` before
any restart, so a bad edit is rolled back automatically instead of locking you
out of SSH.

---

## Important: reconnect after fixing

`sshd` only writes the `~/.Xauthority` cookie **once, at login time**. An
already-open MobaXterm/SSH session cannot pick up a fix applied mid-session —
after running the script, fully close and reopen the session before retrying
the GUI app.

If the server-side check comes back clean and the app still fails, the
remaining suspect is MobaXterm itself: **Session settings → Advanced SSH
settings → "X11-Forwarding"** must be checked, and its X server tab should
show a running X server.
