#!/usr/bin/env bash
#
# os_config.sh
# =============================================================================
# Fixes ownership of the invoking (non-root) user's home directory --
# useful after earlier setup steps ran as root (see
# ../initiate_os_script/initiate_os_script.sh) and left root-owned files
# under the real user's $HOME -- and grants that same user passwordless sudo
# (via a validated /etc/sudoers.d drop-in), unless they are already root.
#
# Supported families (see
#   ../../Migrate_to_Linux/Supported Distributions.txt ):
# Debian/Ubuntu (apt) . RHEL/Fedora (dnf/yum) . Arch (pacman) .
# openSUSE/SUSE (zypper) . Alpine (apk)* . Gentoo (emerge)* .
# Slackware (slackpkg)* (* = best-effort; the ownership fix and sudoers
# steps themselves need no package manager and work identically everywhere
# -- the family is only consulted by the optional recommendations at the
# bottom of this file).
#
# Usage:
#   sudo ./os_config.sh                  # fix home ownership + passwordless sudo
#   sudo ./os_config.sh --user alice     # do it for a specific user instead
#   sudo ./os_config.sh --no-passwordless-sudo   # ownership fix only
#   ./os_config.sh --dry-run             # preview only, no root needed
#
# See --help for the full flag list.
#
# Beyond the ownership fix, this script also ships a library of OPTIONAL
# config recommendations (NTP sync, swappiness, inotify limits, fstrim,
# journald size cap, a baseline firewall, open-file limits...). They are
# plain comments and never execute on their own -- read them, then uncomment
# whichever you want. Each block is distro-aware via $FAMILY.
# =============================================================================

set -euo pipefail

# --------------------------------- defaults ----------------------------------
DRY_RUN=0          # --dry-run: print what would happen, change nothing
TARGET_USER=""     # --user NAME: whose home directory to fix (default: see below)
ENABLE_SUDO=1      # --no-passwordless-sudo clears this

# ------------------------------- pretty output -------------------------------
if [ -t 1 ]; then
    GRN=$'\033[1;32m'; YEL=$'\033[1;33m'; RED=$'\033[1;31m'; DIM=$'\033[2m'; RST=$'\033[0m'
else
    GRN=''; YEL=''; RED=''; DIM=''; RST=''
fi
log()  { printf '%s[+]%s %s\n' "$GRN" "$RST" "$*"; }
warn() { printf '%s[!]%s %s\n' "$YEL" "$RST" "$*"; }
die()  { printf '%s[x]%s %s\n' "$RED" "$RST" "$*" >&2; exit 1; }

# Print a command (nicely quoted) and run it -- unless --dry-run, in which case
# it is only printed, so --dry-run is a faithful preview of a real run.
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
Usage: os_config.sh [options]

Fixes ownership of a user's home directory (recursively), so files created
by earlier root-run setup steps end up owned by the real user instead of
root. Also grants that user passwordless sudo (via a validated
/etc/sudoers.d drop-in), unless they are already root. Also carries a
library of optional, distro-aware config recommendations -- see the
comments near the bottom of the script for how to enable those.

Options:
  --user NAME              Act on NAME instead of the default. Default is
                             $SUDO_USER (when run via sudo), otherwise the
                             current user.
  --no-passwordless-sudo   Skip granting passwordless sudo; only fix home
                             directory ownership.
  --dry-run                Print what would be done without changing
                             anything. Does not require root.
  -h, --help               Show this help and exit.

Examples:
  sudo ./os_config.sh
  sudo ./os_config.sh --user alice
  sudo ./os_config.sh --no-passwordless-sudo
  ./os_config.sh --dry-run
EOF
}

# ------------------------------ parse arguments ------------------------------
while [ "$#" -gt 0 ]; do
    case "$1" in
        --user)
            [ "$#" -ge 2 ] || die "--user needs a value."
            TARGET_USER="$2"; shift ;;
        --user=*)  TARGET_USER="${1#*=}" ;;
        --no-passwordless-sudo) ENABLE_SUDO=0 ;;
        --dry-run) DRY_RUN=1 ;;
        -h|--help) usage; exit 0 ;;
        *)         echo "Unknown option: $1" >&2; usage; exit 1 ;;
    esac
    shift
done

if [ "$DRY_RUN" -eq 0 ] && [ "$(id -u)" -ne 0 ]; then
    die "This script must be run as root (try: sudo $0). Use --dry-run to preview without root."
fi

# Whose home directory are we fixing? Root's own $HOME is the wrong answer if
# this was invoked via sudo -- the real user is $SUDO_USER. The previous
# version of this script used `chown -R $(logname):$(logname) ~$(logname)`,
# which had two bugs: `logname` fails with "no login name" whenever there is
# no controlling terminal (e.g. run from cron, CI, or a calling script like
# initiate_os_script.sh's `run()` helper), and when it fails, `~$(logname)`
# silently collapses to `~` -- root's own home -- so the wrong directory
# would get chown'd instead of the invoking user's.
if [ -z "$TARGET_USER" ]; then
    TARGET_USER="${SUDO_USER:-$(id -un)}"
fi

# The `|| true` on each lookup matters under `set -e`: a bare assignment
# (`VAR=$(cmd)`) propagates a failing command substitution's exit status to
# the whole statement, which would otherwise kill the script here with a
# bare, unexplained exit code (e.g. getent's "user not found") instead of
# reaching the friendly `die` message just below.
if command -v getent >/dev/null 2>&1; then
    TARGET_HOME=$(getent passwd "$TARGET_USER" 2>/dev/null | cut -d: -f6) || true
else
    TARGET_HOME=$(awk -F: -v u="$TARGET_USER" '$1==u{print $6}' /etc/passwd 2>/dev/null) || true
fi
[ -n "$TARGET_HOME" ] || die "Could not resolve a home directory for user '$TARGET_USER'."
[ -d "$TARGET_HOME" ] || die "Resolved home directory '$TARGET_HOME' for '$TARGET_USER' does not exist."
# Refuse to ever recursively chown "/" (or an empty path) -- a defensive
# guard in case a future resolver bug ever turns this into a whole-
# filesystem ownership change.
case "$TARGET_HOME" in
    /|'') die "Refusing to chown a suspicious home directory: '$TARGET_HOME'." ;;
esac

# --------------------------- detect the distro family -------------------------
# Only consulted by the optional recommendations below; the ownership fix
# itself needs nothing distro-specific and works the same everywhere.
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
detect_family || warn "Could not detect the distro family (only affects the optional recommendations below)."

# ------------------------------ ownership fix ---------------------------------
log "Fixing ownership of '$TARGET_HOME' -> $TARGET_USER:$TARGET_USER"
[ "$DRY_RUN" -eq 1 ] && warn "DRY-RUN: no changes will be made."
run chown -R "$TARGET_USER:$TARGET_USER" "$TARGET_HOME"
log "Done."

# ------------------------- passwordless sudo for the user --------------------
if [ "$TARGET_USER" = "root" ]; then
    log "Target user is root; no sudoers entry needed."
elif [ "$ENABLE_SUDO" -eq 0 ]; then
    log "Skipping passwordless-sudo setup (--no-passwordless-sudo)."
elif ! command -v sudo >/dev/null 2>&1; then
    warn "'sudo' is not installed; skipping passwordless-sudo setup for '$TARGET_USER'."
else
    SUDOERS_FILE="/etc/sudoers.d/99-${TARGET_USER}-nopasswd"
    log "Granting passwordless sudo to '$TARGET_USER' ($SUDOERS_FILE)"
    if [ "$DRY_RUN" -eq 1 ]; then
        warn "DRY-RUN: no changes will be made."
        printf '%s[dry-run]%s would write to %s:\n    %s ALL=(ALL) NOPASSWD:ALL\n' \
            "$DIM" "$RST" "$SUDOERS_FILE" "$TARGET_USER"
    else
        # Write to a temp file and validate with `visudo -c` before installing it
        # -- a malformed /etc/sudoers.d file can break sudo for everyone, so this
        # is checked (and discarded on failure) before it ever lands in place.
        TMP_SUDOERS=$(mktemp)
        printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$TARGET_USER" > "$TMP_SUDOERS"
        chmod 0440 "$TMP_SUDOERS"
        if command -v visudo >/dev/null 2>&1 && ! visudo -c -f "$TMP_SUDOERS" >/dev/null 2>&1; then
            rm -f "$TMP_SUDOERS"
            die "Generated sudoers entry failed validation (visudo -c); aborting without touching $SUDOERS_FILE."
        fi
        mv "$TMP_SUDOERS" "$SUDOERS_FILE"
        chown root:root "$SUDOERS_FILE"
        chmod 0440 "$SUDOERS_FILE"
        log "Done -- '$TARGET_USER' can now run sudo without a password."
    fi
fi

# ==============================================================================
# OPTIONAL RECOMMENDATIONS (disabled by default -- read, then uncomment what
# you want). Every block below is plain shell comments, self-contained,
# idempotent, and distro-aware via $FAMILY (set above). Nothing here runs
# unless you edit this file.
# ==============================================================================

# --- 1. NTP time sync -------------------------------------------------------
# Keeps the clock accurate, which matters for TLS, Kerberos, build
# reproducibility, and anything timestamp-sensitive.
# case "$FAMILY" in
#     debian|rhel|arch|suse) timedatectl set-ntp true ;;
#     alpine)    rc-update add chronyd default && rc-service chronyd start ;;
#     gentoo)    rc-update add chronyd default && /etc/init.d/chronyd start ;;
#     slackware) warn "Slackware: enable ntpd manually (not in the base install)." ;;
# esac

# --- 2. Lower swappiness for desktop/SSD responsiveness ---------------------
# The default (60) swaps out fairly eagerly; 10 keeps more in RAM before
# swapping, which feels snappier on desktops with plenty of RAM.
# cat > /etc/sysctl.d/99-swappiness.conf <<'CONF'
# vm.swappiness=10
# CONF
# sysctl --system

# --- 3. Raise inotify watch limits for dev tools -----------------------------
# VS Code, IntelliJ, webpack/vite watch-mode, etc. hit the default
# fs.inotify.max_user_watches (often 8192-65536) on any non-trivial repo.
# cat > /etc/sysctl.d/99-inotify.conf <<'CONF'
# fs.inotify.max_user_watches=524288
# CONF
# sysctl --system

# --- 4. Periodic SSD TRIM ----------------------------------------------------
# Keeps SSD write performance from degrading over time. Prefer the weekly
# systemd timer over a continuous "discard" mount option (less write
# amplification).
# case "$FAMILY" in
#     debian|rhel|arch|suse) systemctl enable --now fstrim.timer ;;
#     *) warn "$FAMILY: no fstrim.timer; add a weekly 'fstrim -av' cron job instead." ;;
# esac

# --- 5. Cap systemd-journald's on-disk log size ------------------------------
# Unbounded journals can quietly fill /var/log/journal. 200M keeps recent
# history without risking disk pressure on small servers/VMs.
# mkdir -p /etc/systemd/journald.conf.d
# cat > /etc/systemd/journald.conf.d/99-size-cap.conf <<'CONF'
# [Journal]
# SystemMaxUse=200M
# CONF
# systemctl restart systemd-journald

# --- 6. Baseline firewall: default-deny inbound, allow SSH -------------------
# A sane starting point for a freshly provisioned box. Review before
# enabling on a box with other exposed services -- add rules for those
# first, or you can lock yourself out.
# case "$FAMILY" in
#     debian)    ufw allow OpenSSH && ufw --force enable ;;
#     rhel|suse) firewall-cmd --permanent --add-service=ssh && firewall-cmd --reload ;;
#     arch)      warn "Arch: no firewall installed by default; e.g. 'pacman -S ufw && ufw allow OpenSSH && ufw enable'." ;;
#     *)         warn "$FAMILY: configure a firewall manually (e.g. nftables/iptables)." ;;
# esac

# --- 7. Raise open-file-descriptor limits ------------------------------------
# The default (1024 soft) is too low for dev servers, Docker, databases, etc.
# cat > /etc/security/limits.d/99-nofile.conf <<'CONF'
# *    soft nofile 65536
# *    hard nofile 65536
# CONF
