#!/usr/bin/env bash
#
# prepare_x11.sh
# =============================================================================
# Diagnoses and fixes the classic SSH X11-forwarding failure:
#
#   MoTTY X11 proxy: No authorisation provided
#   Failed to connect to Mir: Failed to connect to server socket: ...
#   Unable to init server: Could not connect: Connection refused
#   (app:PID): Gtk-WARNING **: cannot open display: localhost:10.0
#
# This happens with MobaXterm/MoTTY, PuTTY+Xming, and any other ssh -X client.
# $DISPLAY being set to something like localhost:10.0 is completely normal
# (that's X11UseLocalhost forwarding) -- it is not the problem. The problem is
# almost always one of, in order of likelihood:
#
#   1. `xauth` is not installed on THIS (the remote/server) machine. sshd can
#      only write the MIT-MAGIC-COOKIE into ~/.Xauthority at login time if the
#      xauth binary exists then. No xauth -> no cookie -> "No authorisation
#      provided" the instant a GUI app tries to connect.
#   2. X11Forwarding is not enabled in sshd_config on this machine.
#   3. ~/.Xauthority exists but is owned by the wrong user / has bad
#      permissions (e.g. left over from a stray `sudo` run).
#   4. The GUI app itself was launched with `sudo`/`su`, which drops the
#      forwarded DISPLAY/XAUTHORITY environment and cookie.
#   5. A shell startup file (~/.bashrc, /etc/environment, etc.) hardcodes
#      `DISPLAY=...`, silently overriding the display sshd actually assigned
#      this session. This is the usual explanation when the display number
#      never changes between logins (e.g. always ":10.0") and everything else
#      checks out -- the cookie sshd wrote is for the real per-session
#      display, not the stale one the shell forces afterwards.
#   6. The GUI app is sandboxed (a snap, or a flatpak) and $XAUTHORITY is not
#      set. This is THE cause when a plain X11 client (xeyes, xclock) works
#      in the very same session where the sandboxed app fails -- that split
#      is the tell. Inside strict snap confinement $HOME is *redirected* to
#      SNAP_USER_DATA (/home/<user>/snap/<app>/<rev>), not the real home. Over
#      SSH, sshd writes the cookie to ~/.Xauthority and sets DISPLAY but
#      leaves XAUTHORITY unset, so every X client falls back to
#      "$HOME/.Xauthority": for an unconfined binary that resolves to the real
#      /home/<user>/.Xauthority (works), but inside the sandbox it resolves to
#      /home/<user>/snap/<app>/<rev>/.Xauthority, which does not exist -> "No
#      authorisation provided". Note this leaves NO AppArmor denial in dmesg,
#      because a missing file inside an allowed directory is a plain ENOENT,
#      not a confinement violation -- so an empty audit log does not clear
#      this cause. The fix is to export XAUTHORITY with the ABSOLUTE real path
#      (AppArmor's x11/unity7 rule `owner @{HOME}/.Xauthority r` permits it,
#      since @{HOME} there is the real home), which this script installs
#      system-wide via /etc/profile.d so it applies to every login and every
#      sandboxed app, not just one.
#
# This script runs ON THE REMOTE LINUX SERVER (the machine you SSH into),
# not on the Windows/MobaXterm side.
#
# Fixing is ON BY DEFAULT -- no --fix flag needed. Every fix is idempotent
# (checks current state first, only touches what's actually wrong), so running
# this repeatedly is always safe and a no-op once everything is already
# correct. Root is only needed for the fixes that require it (installing
# packages, editing sshd_config, restarting sshd); without root those specific
# steps are skipped with a clear message instead of the whole script failing.
#
# Usage:
#   sudo ./prepare_x11.sh             # diagnose AND fix (default), idempotent
#   ./prepare_x11.sh --check          # diagnose only, change nothing
#   sudo ./prepare_x11.sh --dry-run   # preview every fix, no root needed
#   sudo ./prepare_x11.sh --test      # fix, then try a live round-trip X11 test
#
# See --help for the full flag list.
# =============================================================================

set -uo pipefail

# --------------------------------- defaults ----------------------------------
DO_FIX=1          # fixing on by default; --check/--no-fix turns it off
DRY_RUN=0         # --dry-run: print what would happen without changing anything
DO_TEST=0         # --test: try a live xclock round-trip after diagnosing/fixing
NO_RESTART=0      # --no-restart: edit sshd_config but don't restart sshd
TARGET_USER=""    # --user NAME: whose ~/.Xauthority to check (default: see below)

ISSUES=0          # count of problems found, for the closing summary

# ------------------------------- pretty output -------------------------------
if [ -t 1 ]; then
  GRN=$'\033[1;32m'; YEL=$'\033[1;33m'; RED=$'\033[1;31m'; DIM=$'\033[2m'; RST=$'\033[0m'
else
  GRN=''; YEL=''; RED=''; DIM=''; RST=''
fi
ok()   { printf '%s[ok]%s  %s\n'   "$GRN" "$RST" "$*"; }
info() { printf '%s[i]%s   %s\n'    "$DIM" "$RST" "$*"; }
warn() { printf '%s[!]%s  %s\n'    "$YEL" "$RST" "$*"; ISSUES=$(( ISSUES + 1 )); }
fail() { printf '%s[x]%s  %s\n'    "$RED" "$RST" "$*"; ISSUES=$(( ISSUES + 1 )); }
die()  { printf '%s[x]%s  %s\n' "$RED" "$RST" "$*" >&2; exit 1; }
log()  { printf '\n%s== %s ==%s\n' "$DIM" "$*" "$RST"; }

# Print a command (nicely quoted) and run it -- unless --dry-run, in which case
# it is only printed, so --fix --dry-run is a faithful preview of a real run.
run() {
  printf '%s[run]%s' "$DIM" "$RST"
  local a
  for a in "$@"; do
    case "$a" in
      ''|*[[:space:]]*) printf ' %q' "$a" ;;
      *)                printf ' %s'  "$a" ;;
    esac
  done
  printf '\n'
  [ "$DRY_RUN" -eq 1 ] && return 0
  "$@"
}

# --------------------------------- usage -------------------------------------
usage() {
  cat <<'EOF'
Usage: prepare_x11.sh [options]

Diagnoses AND REPAIRS (by default -- no flag needed) the remote-server side
of the classic SSH X11-forwarding failure:

  MoTTY X11 proxy: No authorisation provided
  Gtk-WARNING **: cannot open display: localhost:10.0

Run this ON THE LINUX SERVER you SSH into (e.g. via MobaXterm), not on
Windows. A $DISPLAY like "localhost:10.0" is normal; the "no authorisation"
part is the actual fault, and it is almost always fixed by installing xauth
and/or enabling X11Forwarding, then reconnecting.

Every fix checks current state first and only touches what's actually wrong,
so running this script repeatedly is always safe (idempotent) -- once
everything is correct, re-running it is a no-op that just reports "ok".

Options:
  --check, --no-fix   Diagnose only; report problems but change nothing.
  --dry-run           Preview every fix that would be applied, without
                       changing anything. Does not require root.
  --no-restart        Edit sshd_config but skip restarting sshd (restarting
                       does not drop your current session, but you can defer
                       it if you'd rather do it yourself).
  --test              After diagnosing/fixing, try a live round-trip test
                       with a small X client (xclock/xeyes).
  --user NAME         Check NAME's ~/.Xauthority instead of the default.
                       Default is $SUDO_USER when run via sudo, otherwise the
                       current user -- this matters when running as root,
                       since root's own ~/.Xauthority is not the one your GUI
                       apps use.
  --fix               Accepted for backwards compatibility; fixing is already
                       the default, so this flag does nothing extra.
  -h, --help          Show this help and exit.

Fixes that need root (installing xauth, editing sshd_config, installing the
XAUTHORITY profile snippet, restarting sshd) are skipped with a clear message
if not run as root -- the rest of the script (diagnosis, and any fix that
doesn't need root) still runs normally.

Sandboxed apps: snaps and flatpaks fail with the same "No authorisation
provided" even when xeyes/xclock work, because their $HOME is redirected
inside the sandbox and sshd leaves XAUTHORITY unset. This script installs
/etc/profile.d/99-x11-xauthority.sh to export XAUTHORITY with the absolute
real path, which fixes every such app from the next login onward. A script
cannot export into the shell that invoked it, so to fix the CURRENT session
run:  export XAUTHORITY="$HOME/.Xauthority"

Examples:
  sudo ./prepare_x11.sh          # diagnose AND fix, idempotent
  ./prepare_x11.sh --check       # just tell me what's wrong
  sudo ./prepare_x11.sh --test   # fix it, then prove it works
  sudo ./prepare_x11.sh --dry-run   # preview every fix, no changes

After fixing xauth or X11Forwarding, you MUST fully close and reopen your
MobaXterm/SSH session -- the auth cookie is set up by sshd once, at login
time, so an already-open session cannot pick up the fix.
EOF
}

# ------------------------------ parse arguments ------------------------------
while [ "$#" -gt 0 ]; do
  case "$1" in
    --fix)                DO_FIX=1 ;;   # already the default; kept for compatibility
    --check|--no-fix)     DO_FIX=0 ;;
    --dry-run)            DRY_RUN=1 ;;
    --no-restart)         NO_RESTART=1 ;;
    --test)               DO_TEST=1 ;;
    --user)
      [ "$#" -ge 2 ] || die "--user needs a value."
      TARGET_USER="$2"; shift ;;
    --user=*)     TARGET_USER="${1#*=}" ;;
    -h|--help)    usage; exit 0 ;;
    *)            echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
  shift
done

# Root is only required for the specific fixes that need it (package installs,
# sshd_config edits, service restarts) -- not to run the script at all. When
# not root, HAVE_ROOT gates just those steps off (each with its own message)
# instead of the whole script refusing to run.
HAVE_ROOT=0; [ "$(id -u)" -eq 0 ] && HAVE_ROOT=1
if [ "$DO_FIX" -eq 1 ] && [ "$HAVE_ROOT" -eq 0 ] && [ "$DRY_RUN" -eq 0 ]; then
  warn "Not running as root: fixes needing root (installing packages, editing sshd_config, restarting sshd) will be skipped below. Re-run with sudo to apply them, or add --dry-run to preview without root."
fi

# Whose ~/.Xauthority are we actually diagnosing? Root's own $HOME is the wrong
# answer here -- if this was invoked via sudo, the real GUI user is $SUDO_USER.
if [ -z "$TARGET_USER" ]; then
  TARGET_USER="${SUDO_USER:-$(id -un)}"
fi
if command -v getent >/dev/null 2>&1; then
  TARGET_HOME=$(getent passwd "$TARGET_USER" 2>/dev/null | cut -d: -f6)
else
  TARGET_HOME=$(awk -F: -v u="$TARGET_USER" '$1==u{print $6}' /etc/passwd 2>/dev/null)
fi
[ -n "$TARGET_HOME" ] || die "Could not resolve a home directory for user '$TARGET_USER'."
XAUTH_FILE="$TARGET_HOME/.Xauthority"

# --------------------------- detect the distro family -------------------------
FAMILY=""
detect_family() {
  local id="" like=""
  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    id="${ID:-}"; like="${ID_LIKE:-}"
  fi
  case " $id $like " in
    *" debian "*|*" ubuntu "*|*" linuxmint "*|*" pop "*|*" zorin "*|*" elementary "*) FAMILY=debian; return 0 ;;
    *" rhel "*|*" fedora "*|*" centos "*|*" rocky "*|*" almalinux "*|*" ol "*)         FAMILY=rhel;   return 0 ;;
    *" arch "*|*" archlinux "*|*" manjaro "*|*" endeavouros "*)                        FAMILY=arch;   return 0 ;;
    *" suse "*|*" opensuse "*|*" sles "*|*" sled "*)                                   FAMILY=suse;   return 0 ;;
    *" alpine "*|*" postmarketos "*)                                                   FAMILY=alpine; return 0 ;;
    *" gentoo "*|*" funtoo "*)                                                         FAMILY=gentoo; return 0 ;;
    *" slackware "*)                                                                   FAMILY=slackware; return 0 ;;
  esac
  if   command -v apt-get  >/dev/null 2>&1; then FAMILY=debian
  elif command -v dnf      >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then FAMILY=rhel
  elif command -v pacman   >/dev/null 2>&1; then FAMILY=arch
  elif command -v zypper   >/dev/null 2>&1; then FAMILY=suse
  elif command -v apk      >/dev/null 2>&1; then FAMILY=alpine
  elif command -v emerge   >/dev/null 2>&1; then FAMILY=gentoo
  elif command -v slackpkg >/dev/null 2>&1; then FAMILY=slackware
  else return 1
  fi
  return 0
}
detect_family || warn "Could not detect the distro family; package installs will be skipped."

install_pkg() {  # $1=package name -> installs it with this distro's package manager
  case "$FAMILY" in
    debian)    run apt-get update -qq; run apt-get install -y "$1" ;;
    rhel)      command -v dnf >/dev/null 2>&1 && run dnf install -y "$1" || run yum install -y "$1" ;;
    arch)      run pacman -Sy --noconfirm "$1" ;;
    suse)      run zypper --non-interactive install "$1" ;;
    alpine)    run apk add --no-cache "$1" ;;
    gentoo)    run emerge -n "$1" ;;
    slackware) warn "Slackware: xauth normally ships with X itself; install manually if truly missing." ;;
    *)         warn "Unknown distro family; install '$1' manually." ;;
  esac
}

xauth_pkg_name() {
  case "$FAMILY" in
    rhel)   echo "xorg-x11-xauth" ;;
    arch)   echo "xorg-xauth" ;;
    gentoo) echo "x11-apps/xauth" ;;
    *)      echo "xauth" ;;
  esac
}

x11apps_pkg_name() {  # a package providing xclock, for --test's live check
  case "$FAMILY" in
    rhel)   echo "xorg-x11-apps" ;;
    arch)   echo "xorg-xclock" ;;
    suse)   echo "xclock" ;;
    gentoo) echo "x11-apps/xclock" ;;
    *)      echo "x11-apps" ;;
  esac
}

# ============================== 1. xauth binary ===============================
log "1/6 -- xauth binary"
if command -v xauth >/dev/null 2>&1; then
  ok "xauth is installed ($(command -v xauth))."
else
  fail "xauth is NOT installed. This is the #1 cause of 'No authorisation provided':"
  fail "sshd can only write the X11 cookie into ~/.Xauthority at login time if xauth exists then."
  if [ "$DO_FIX" -eq 0 ]; then
    info "Fix by re-running without --check: sudo $0"
  elif [ "$HAVE_ROOT" -eq 1 ] || [ "$DRY_RUN" -eq 1 ]; then
    info "Installing xauth..."
    install_pkg "$(xauth_pkg_name)"
  else
    info "Needs root to install -- re-run with sudo to apply automatically."
  fi
fi

# ========================= 2. sshd X11Forwarding setting ======================
log "2/6 -- sshd X11Forwarding"
EFFECTIVE_X11FWD=""
if [ "$(id -u)" -eq 0 ]; then
  # sshd -T dumps the fully-resolved effective config (all Includes/Match
  # blocks applied), which is the only reliable way to check this -- hand-
  # parsing sshd_config text can't account for Include order or first-match-wins.
  EFFECTIVE_X11FWD=$(sshd -T 2>/dev/null | awk '$1=="x11forwarding"{print tolower($2)}')
fi

if [ "$EFFECTIVE_X11FWD" = "yes" ]; then
  ok "X11Forwarding is enabled (confirmed via 'sshd -T')."
elif [ -n "$EFFECTIVE_X11FWD" ]; then
  fail "X11Forwarding is disabled in the effective sshd config."
  if [ "$DO_FIX" -eq 1 ]; then
    MAIN_CFG="/etc/ssh/sshd_config"
    DROPIN_DIR="/etc/ssh/sshd_config.d"
    if [ -d "$DROPIN_DIR" ] && grep -Eq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' "$MAIN_CFG" 2>/dev/null; then
      info "Adding a drop-in: $DROPIN_DIR/99-x11-forwarding.conf"
      if [ "$DRY_RUN" -eq 1 ]; then
        printf '%s[dry-run]%s would write "X11Forwarding yes" to %s\n' "$DIM" "$RST" "$DROPIN_DIR/99-x11-forwarding.conf"
      else
        printf 'X11Forwarding yes\n' > "$DROPIN_DIR/99-x11-forwarding.conf"
      fi
    else
      BACKUP="${MAIN_CFG}.bak-$(date +%Y%m%d%H%M%S)"
      info "Editing $MAIN_CFG directly (backup: $BACKUP)"
      if [ "$DRY_RUN" -eq 1 ]; then
        printf '%s[dry-run]%s would back up %s and set X11Forwarding yes\n' "$DIM" "$RST" "$MAIN_CFG"
      else
        cp "$MAIN_CFG" "$BACKUP"
        if grep -Eq '^[[:space:]]*#?[[:space:]]*X11Forwarding\b' "$MAIN_CFG"; then
          sed -i -E 's/^[[:space:]]*#?[[:space:]]*X11Forwarding\b.*/X11Forwarding yes/' "$MAIN_CFG"
        else
          printf '\nX11Forwarding yes\n' >> "$MAIN_CFG"
        fi
      fi
    fi
    if [ "$DRY_RUN" -eq 0 ]; then
      if ! sshd -t 2>/tmp/prepare_x11_sshd_t.err; then
        fail "sshd -t reports the new config is INVALID; not restarting sshd. Details:"
        sed -e 's/^/      /' /tmp/prepare_x11_sshd_t.err
        [ -n "${BACKUP:-}" ] && [ -f "$BACKUP" ] && { cp "$BACKUP" "$MAIN_CFG"; warn "Restored $MAIN_CFG from backup."; }
      else
        ok "sshd config validated OK (sshd -t)."
        if [ "$NO_RESTART" -eq 1 ]; then
          info "Skipping sshd restart (--no-restart). Restart it yourself to apply: systemctl restart sshd"
        else
          info "Restarting sshd (this does not drop your current SSH session)..."
          if command -v systemctl >/dev/null 2>&1; then
            SVC=""
            for candidate in sshd ssh; do
              systemctl list-unit-files --type=service 2>/dev/null | grep -q "^${candidate}\.service" && { SVC="$candidate"; break; }
            done
            if [ -n "$SVC" ]; then run systemctl restart "$SVC"; ok "Restarted $SVC.service."
            else warn "Could not find an sshd systemd unit; restart it manually."; fi
          elif command -v rc-service >/dev/null 2>&1; then
            run rc-service sshd restart
          elif command -v service >/dev/null 2>&1; then
            run service ssh restart 2>/dev/null || run service sshd restart
          else
            warn "No known service manager found; restart sshd manually."
          fi
        fi
      fi
      rm -f /tmp/prepare_x11_sshd_t.err
    fi
  else
    info "Fix by re-running without --check: sudo $0"
  fi
else
  warn "Could not check the effective X11Forwarding setting without root."
  if grep -Eq '^[[:space:]]*X11Forwarding[[:space:]]+yes' /etc/ssh/sshd_config 2>/dev/null; then
    info "(best-effort, unprivileged) /etc/ssh/sshd_config appears to say 'X11Forwarding yes'."
  else
    info "(best-effort, unprivileged) no 'X11Forwarding yes' line found in /etc/ssh/sshd_config."
  fi
  info "Re-run with sudo for an authoritative check via 'sshd -T' and to auto-fix if needed."
fi

# ============================ 3. ~/.Xauthority state ===========================
log "3/6 -- ~/.Xauthority for user '$TARGET_USER'"
if [ ! -e "$XAUTH_FILE" ]; then
  info "$XAUTH_FILE does not exist yet -- normal if that user hasn't logged in over SSH"
  info "with X11 forwarding since the last fix. It is created automatically at login"
  info "time once xauth is installed and X11Forwarding is enabled."
else
  OWNER_UID=$(stat -c '%u' "$XAUTH_FILE" 2>/dev/null || stat -f '%u' "$XAUTH_FILE" 2>/dev/null)
  WANT_UID=$(id -u "$TARGET_USER")
  PERM=$(stat -c '%a' "$XAUTH_FILE" 2>/dev/null || stat -f '%Lp' "$XAUTH_FILE" 2>/dev/null)
  BAD_OWNER=0; BAD_PERM=0
  if [ "$OWNER_UID" != "$WANT_UID" ]; then
    fail "$XAUTH_FILE is owned by uid $OWNER_UID, not $TARGET_USER (uid $WANT_UID)."
    BAD_OWNER=1
  fi
  if [ "$PERM" != "600" ]; then
    fail "$XAUTH_FILE has permissions $PERM (expected 600)."
    BAD_PERM=1
  fi
  if [ "$BAD_OWNER" -eq 0 ] && [ "$BAD_PERM" -eq 0 ]; then
    ok "$XAUTH_FILE is owned by $TARGET_USER with mode 600."
  elif [ "$DO_FIX" -eq 0 ]; then
    info "Fix by re-running without --check: sudo $0"
  else
    # chown needs root; chmod on a file you already own does not, so a plain
    # user re-running this without sudo can still fix its own permissions.
    if [ "$BAD_OWNER" -eq 1 ]; then
      if [ "$HAVE_ROOT" -eq 1 ] || [ "$DRY_RUN" -eq 1 ]; then
        run chown "$TARGET_USER:$TARGET_USER" "$XAUTH_FILE"
      else
        info "Needs root to fix ownership -- re-run with sudo to apply automatically."
      fi
    fi
    if [ "$BAD_PERM" -eq 1 ]; then
      if [ "$HAVE_ROOT" -eq 1 ] || [ "$DRY_RUN" -eq 1 ] || [ "$(id -un)" = "$TARGET_USER" ]; then
        run chmod 600 "$XAUTH_FILE"
      else
        info "Needs root (or to be run as $TARGET_USER) to fix permissions."
      fi
    fi
  fi
fi

# A very common gotcha: launching the GUI app itself with sudo/su strips the
# forwarded DISPLAY/XAUTHORITY, which looks identical to this same error.
info "Reminder: never launch GUI apps (e.g. midori) with sudo/su -- that drops the"
info "forwarded X11 cookie and produces this exact same error, even with a healthy setup."

# ==================== 4. stale/hardcoded DISPLAY + cookie sanity ================
log "4/6 -- \$DISPLAY sanity (stale overrides, cookie match)"

# A hardcoded `export DISPLAY=...` in a shell startup file silently overrides
# whatever sshd assigns for THIS session, and is the usual explanation when
# every other check passes but the app still fails, or the display number
# never changes between logins. Check the user's own startup files plus the
# system-wide ones PAM/bash source at login.
STARTUP_FILES=(
  "$TARGET_HOME/.bashrc" "$TARGET_HOME/.bash_profile" "$TARGET_HOME/.bash_login"
  "$TARGET_HOME/.profile" "$TARGET_HOME/.zshrc" "$TARGET_HOME/.zprofile"
  "$TARGET_HOME/.xsessionrc" "$TARGET_HOME/.pam_environment"
  /etc/environment /etc/profile /etc/bash.bashrc
)
HITS=""
for f in "${STARTUP_FILES[@]}"; do
  [ -r "$f" ] || continue
  m=$(grep -Hn -E '^[[:space:]]*(export[[:space:]]+)?DISPLAY[[:space:]]*=' "$f" 2>/dev/null)
  [ -n "$m" ] && HITS="${HITS}${HITS:+$'\n'}${m}"
done
if [ -n "$HITS" ]; then
  fail "Found a hardcoded DISPLAY= assignment -- this overrides the per-session value sshd sets and is a common cause of a display number that never changes:"
  printf '%s\n' "$HITS" | sed -e 's/^/      /'
  info "Remove or comment out that line and let sshd set DISPLAY dynamically each login."
else
  ok "No hardcoded DISPLAY= assignment found in shell/PAM startup files."
fi

# If we're actually inside the session being complained about, DISPLAY should
# have a matching cookie in this user's .Xauthority. An empty result here
# means either this DISPLAY has no cookie (fix wasn't picked up -- reconnect)
# or DISPLAY doesn't match what sshd actually assigned (see the check above).
if [ -n "${DISPLAY:-}" ] && command -v xauth >/dev/null 2>&1; then
  COOKIE=$(xauth list "$DISPLAY" 2>/dev/null)
  if [ -n "$COOKIE" ]; then
    ok "xauth has a cookie registered for \$DISPLAY ($DISPLAY)."
  else
    fail "xauth has NO cookie for \$DISPLAY ($DISPLAY) in $XAUTH_FILE."
    info "This means this exact session's DISPLAY doesn't match anything sshd wrote --"
    info "either reconnect (if xauth/X11Forwarding were only just fixed) or check for"
    info "the hardcoded-DISPLAY issue above."
  fi
elif [ -z "${DISPLAY:-}" ]; then
  info "\$DISPLAY is not set in this shell, so the cookie match can't be checked here."
fi

# ============ 5. XAUTHORITY export (sandboxed snap/flatpak apps) ==============
log "5/6 -- XAUTHORITY export for sandboxed apps (snap/flatpak)"

PROFILE_SNIPPET="/etc/profile.d/99-x11-xauthority.sh"

# The snippet is deliberately POSIX sh (profile.d is sourced by dash/ash as well
# as bash) and deliberately conservative: it only acts on an X11-forwarded login
# that has a real cookie file, and it never overrides an XAUTHORITY that is
# already set -- some sshd setups point that at a private temp xauth file, and
# clobbering it would break the very thing we are fixing.
xauthority_snippet() {
  cat <<'SNIPPET'
# Managed by prepare_x11.sh -- safe to remove, but do not hand-edit.
#
# Export XAUTHORITY with an absolute path to the real ~/.Xauthority.
#
# sshd sets DISPLAY for a forwarded session but leaves XAUTHORITY unset, so X
# clients fall back to "$HOME/.Xauthority". That fallback breaks for sandboxed
# apps: inside strict snap confinement $HOME is redirected to SNAP_USER_DATA
# (~/snap/<app>/<rev>), where no cookie exists -- so the app reports "No
# authorisation provided" while unconfined clients (xeyes/xclock) work fine in
# the same session. Setting the variable explicitly makes every client, sandboxed
# or not, look at the one real cookie file.
if [ -n "${DISPLAY:-}" ] && [ -z "${XAUTHORITY:-}" ] && [ -f "$HOME/.Xauthority" ]; then
    XAUTHORITY="$HOME/.Xauthority"
    export XAUTHORITY
fi
SNIPPET
}

if [ -f "$PROFILE_SNIPPET" ] && xauthority_snippet | cmp -s - "$PROFILE_SNIPPET"; then
  ok "$PROFILE_SNIPPET is already installed and up to date."
else
  if [ -f "$PROFILE_SNIPPET" ]; then
    warn "$PROFILE_SNIPPET exists but differs from the current version; it will be refreshed."
  else
    fail "$PROFILE_SNIPPET is missing: sandboxed (snap/flatpak) apps will fail with 'No authorisation provided' even though plain X11 clients work."
  fi
  if [ "$DO_FIX" -eq 0 ]; then
    info "Fix by re-running without --check: sudo $0"
  elif [ "$DRY_RUN" -eq 1 ]; then
    printf '%s[dry-run]%s would write the XAUTHORITY export snippet to %s (mode 644):\n' "$DIM" "$RST" "$PROFILE_SNIPPET"
    xauthority_snippet | sed -e 's/^/      /'
  elif [ "$HAVE_ROOT" -eq 1 ]; then
    if xauthority_snippet > "$PROFILE_SNIPPET" && chmod 644 "$PROFILE_SNIPPET"; then
      ok "Installed $PROFILE_SNIPPET (applies to every user, every login)."
    else
      fail "Could not write $PROFILE_SNIPPET."
    fi
  else
    info "Needs root to install -- re-run with sudo to apply automatically."
  fi
fi

# Report on this shell too. A child process can never export into its parent, so
# the snippet only takes effect on the NEXT login -- say so explicitly rather
# than letting the user think the current session was just fixed.
if [ -n "${DISPLAY:-}" ]; then
  if [ -z "${XAUTHORITY:-}" ]; then
    info "This shell has XAUTHORITY unset (it applies from your next login onward)."
    info "To fix the session you are in right now, run:"
    printf '        export XAUTHORITY="%s"\n' "$XAUTH_FILE"
  elif [ ! -f "$XAUTHORITY" ]; then
    fail "XAUTHORITY is set to '$XAUTHORITY', but that file does not exist -- X clients will find no cookie."
    info "Clear the stale value and use the real cookie instead:"
    printf '        unset XAUTHORITY; export XAUTHORITY="%s"\n' "$XAUTH_FILE"
  elif [ "$XAUTHORITY" != "$XAUTH_FILE" ]; then
    info "XAUTHORITY is set to '$XAUTHORITY' (not $XAUTH_FILE). That is fine if deliberate,"
    info "but note sandboxed apps can only read paths their confinement allows -- the real"
    info "home path is the one permitted by the snap x11/unity7 rules."
  else
    ok "This shell already exports XAUTHORITY=$XAUTHORITY."
  fi
fi

# Sandboxed apps are only worth calling out when some are actually installed.
if command -v snap >/dev/null 2>&1 || command -v flatpak >/dev/null 2>&1; then
  info "Sandboxed package managers detected (snap/flatpak). Note that a passing"
  info "xeyes/xclock test does NOT prove those work: unconfined clients read the"
  info "cookie via \$HOME, which the sandbox redirects. Test one of those apps too."
fi

# ================================ 6. live test ==================================
if [ "$DO_TEST" -eq 1 ]; then
  log "6/6 -- live round-trip test"
  if [ -z "${DISPLAY:-}" ]; then
    warn "\$DISPLAY is not set in this shell -- run --test from inside the actual SSH/X11 session you're troubleshooting."
  elif ! command -v xauth >/dev/null 2>&1; then
    warn "xauth still missing; skipping the live test. Re-run with sudo first."
  else
    TESTBIN=""
    for c in xclock xeyes; do command -v "$c" >/dev/null 2>&1 && { TESTBIN="$c"; break; }; done
    if [ -z "$TESTBIN" ] && [ "$DO_FIX" -eq 1 ] && { [ "$HAVE_ROOT" -eq 1 ] || [ "$DRY_RUN" -eq 1 ]; }; then
      install_pkg "$(x11apps_pkg_name)"
      for c in xclock xeyes; do command -v "$c" >/dev/null 2>&1 && { TESTBIN="$c"; break; }; done
    fi
    if [ -z "$TESTBIN" ]; then
      warn "No xclock/xeyes available for a live test. Install one (part of x11-apps) or re-run with sudo."
    elif [ "$DRY_RUN" -eq 1 ]; then
      info "[dry-run] would launch '$TESTBIN -display $DISPLAY' briefly to test the round trip."
    else
      ERRF=$(mktemp)
      "$TESTBIN" -display "$DISPLAY" >/dev/null 2>"$ERRF" &
      TPID=$!
      sleep 1.5
      if kill -0 "$TPID" 2>/dev/null; then
        ok "$TESTBIN connected to $DISPLAY and is running -- X11 forwarding works."
        kill "$TPID" 2>/dev/null; wait "$TPID" 2>/dev/null
      else
        fail "$TESTBIN exited immediately. Error output:"
        sed -e 's/^/      /' "$ERRF"
      fi
      rm -f "$ERRF"
    fi
  fi
fi

# --------------------------------- summary ------------------------------------
log "Summary"
if [ "$ISSUES" -eq 0 ]; then
  ok "No issues found on this (server-side) end."
  info "If the app still fails to connect, the remaining suspects are the MobaXterm"
  info "session's own settings: Session -> Advanced SSH settings -> 'X11-Forwarding'"
  info "must be checked, and the DISPLAY number/X server must actually be running"
  info "(MobaXterm starts one automatically, shown in its X server tab)."
else
  if [ "$DO_FIX" -eq 0 ]; then
    warn "$ISSUES issue(s) found (diagnose-only run). Fix them with: sudo $0"
  elif [ "$DRY_RUN" -eq 1 ]; then
    warn "$ISSUES issue(s) found. This was a --dry-run preview; re-run without it to apply."
  elif [ "$HAVE_ROOT" -eq 0 ]; then
    warn "$ISSUES issue(s) found; some fixes needed root and were skipped. Re-run with: sudo $0"
  else
    ok "Fixes applied where possible (re-run any time -- it's idempotent)."
  fi
  printf '\n%sImportant:%s after installing xauth and/or changing X11Forwarding, fully close\n' "$YEL" "$RST"
  echo "and reopen your MobaXterm/SSH session -- sshd writes the auth cookie once, at"
  echo "login time, so a session that is already open cannot pick up the fix."
  echo
  echo "The same applies to the XAUTHORITY snippet: /etc/profile.d is sourced at login,"
  echo "so it takes effect on your next session. For the session you are in right now:"
  printf '    export XAUTHORITY="%s"\n' "$XAUTH_FILE"
fi
