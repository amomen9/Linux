#!/usr/bin/env bash
#
# install_system_maintenance.sh
#
# Cross-platform installer for the scheduled system-maintenance systemd units.
# Supports the Debian family (Debian, Ubuntu, ...) and the RHEL family
# (RHEL, CentOS Stream, Rocky, AlmaLinux, Fedora, ...).
#
# It detects the running distribution, then installs the matching unit files
# shipped in this repository (Debian/ or RHEL/) into /etc/systemd/system and
# enables the requested timer(s).
#
# Flags:
#   --update    Install & enable the automatic system-update service + timer.
#   --restart   Install & enable the scheduled reboot service + timer.
#   -h, --help  Show usage and exit.
#
# At least one of --update / --restart is required; they may be combined.
#
# Must be run as root, e.g.:
#   sudo ./install_system_maintenance.sh --update --restart

set -euo pipefail

# --- locate this script's directory so we can find the unit files ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SYSTEMD_DIR="/etc/systemd/system"

DO_UPDATE=0
DO_RESTART=0

usage() {
    cat <<'EOF'
Usage: install_system_maintenance.sh [--update] [--restart]

  --update    Install & enable the automatic system-update service and timer.
  --restart   Install & enable the scheduled reboot service and timer.
  -h, --help  Show this help and exit.

At least one of --update or --restart must be supplied; they can be combined.
EOF
}

# --- parse arguments -------------------------------------------------------
if [ "$#" -eq 0 ]; then
    usage
    exit 1
fi

while [ "$#" -gt 0 ]; do
    case "$1" in
        --update)  DO_UPDATE=1 ;;
        --restart) DO_RESTART=1 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
    esac
    shift
done

if [ "$DO_UPDATE" -eq 0 ] && [ "$DO_RESTART" -eq 0 ]; then
    echo "Nothing to do: pass --update and/or --restart." >&2
    usage
    exit 1
fi

# --- must run as root ------------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root (try: sudo $0 ...)." >&2
    exit 1
fi

# --- detect distribution family --------------------------------------------
detect_family() {
    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        case " ${ID:-} ${ID_LIKE:-} " in
            *" debian "*|*" ubuntu "*)              echo "Debian"; return 0 ;;
            *" rhel "*|*" fedora "*|*" centos "*)    echo "RHEL";   return 0 ;;
        esac
    fi
    # Fall back to whichever package manager is present.
    if command -v apt-get >/dev/null 2>&1 || command -v dpkg >/dev/null 2>&1; then
        echo "Debian"; return 0
    fi
    if command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
        echo "RHEL"; return 0
    fi
    return 1
}

FAMILY="$(detect_family)" || {
    echo "Unsupported or undetected distribution (need a Debian- or RHEL-family system)." >&2
    exit 1
}
echo "Detected distribution family: ${FAMILY}"

SRC_DIR="${SCRIPT_DIR}/${FAMILY}/service files"
if [ ! -d "$SRC_DIR" ]; then
    echo "Cannot find unit files at: ${SRC_DIR}" >&2
    echo "Run this script from within the cloned repository." >&2
    exit 1
fi

# --- RHEL prerequisite: dnf-utils provides needs-restarting &              --
# --- yum-complete-transaction, both used by the unit files -----------------
ensure_rhel_utils() {
    if command -v needs-restarting >/dev/null 2>&1 \
        && command -v yum-complete-transaction >/dev/null 2>&1; then
        return 0
    fi
    echo "Installing dnf-utils (provides needs-restarting / yum-complete-transaction)..."
    if command -v dnf >/dev/null 2>&1; then
        dnf install -y dnf-utils
    else
        yum install -y yum-utils
    fi
}

# --- install a single unit file --------------------------------------------
install_unit() {
    local unit="$1"
    local src="${SRC_DIR}/${unit}"
    if [ ! -f "$src" ]; then
        echo "Missing unit file: ${src}" >&2
        exit 1
    fi
    install -m 0644 "$src" "${SYSTEMD_DIR}/${unit}"
    echo "  installed ${SYSTEMD_DIR}/${unit}"
}

if [ "$FAMILY" = "RHEL" ]; then
    ensure_rhel_utils
fi

INSTALLED_TIMERS=""

if [ "$DO_UPDATE" -eq 1 ]; then
    echo "Installing update units..."
    install_unit "system_update.service"
    install_unit "system_update.timer"
    INSTALLED_TIMERS="${INSTALLED_TIMERS} system_update.timer"
fi

if [ "$DO_RESTART" -eq 1 ]; then
    echo "Installing restart units..."
    install_unit "system_restart.service"
    install_unit "system_restart.timer"
    INSTALLED_TIMERS="${INSTALLED_TIMERS} system_restart.timer"
fi

# --- reload systemd, then enable & start the timer(s) ----------------------
systemctl daemon-reload

for timer in $INSTALLED_TIMERS; do
    systemctl enable --now "$timer"
    echo "  enabled & started ${timer}"
done

echo ""
echo "Done. Scheduled maintenance timers:"
# shellcheck disable=SC2086
systemctl list-timers --all $INSTALLED_TIMERS 2>/dev/null || true
