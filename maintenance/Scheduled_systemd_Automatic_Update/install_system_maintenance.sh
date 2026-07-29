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
# Design notes:
#   * The .service units are always installed *disabled* so they never fire on
#     boot; only the .timer units are enabled. The timers can still trigger the
#     services on schedule (a timer starts its service regardless of whether the
#     service is "enabled").
#   * The script is idempotent: re-running it re-copies the units, re-applies any
#     schedule overrides, and re-asserts the enabled/disabled state without error.
#
# Flags (see --help for the authoritative list):
#   --update  [true|false]        Install & enable the update service + timer.
#   --restart [true|false]        Install & enable the reboot service + timer.
#   --update-sched  "<OnCalendar>"   Override the update timer schedule.
#   --restart-sched "<OnCalendar>"   Override the restart timer schedule.
#   --update-enabled  [true|false]   Whether the update timer is enabled.
#   --restart-enabled [true|false]   Whether the restart timer is enabled.
#   -h, --help                    Show usage and exit.
#
# At least one of --update / --restart must be effectively true.
#
# Must be run as root, e.g.:
#   sudo ./install_system_maintenance.sh --update --restart

set -euo pipefail

# --- locate this script's directory so we can find the unit files ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SYSTEMD_DIR="/etc/systemd/system"

# --- defaults --------------------------------------------------------------
DO_UPDATE=0             # install update units?   (set by --update)
DO_RESTART=0            # install restart units?  (set by --restart)
UPDATE_ENABLED=1        # enable the update timer?   (--update-enabled,  default true)
RESTART_ENABLED=1       # enable the restart timer?  (--restart-enabled, default true)
UPDATE_SCHED=""         # OnCalendar override for the update timer  (empty = keep file default)
RESTART_SCHED=""        # OnCalendar override for the restart timer (empty = keep file default)

usage() {
    cat <<'EOF'
Usage: install_system_maintenance.sh [options]

  --update  [true|false|1|0]   Install the automatic system-update service and
                               timer. A bare --update means true. Default when the
                               flag is omitted: not installed.
  --restart [true|false|1|0]   Install the scheduled reboot service and timer.
                               A bare --restart means true. Default when the flag
                               is omitted: not installed.

  --update-sched  "<OnCalendar>"   Override the update timer's OnCalendar=
                                   schedule (systemd OnCalendar syntax; quote it).
                                   Default: '*-*-* 02:30:00'.
  --restart-sched "<OnCalendar>"   Override the restart timer's OnCalendar=
                                   schedule (systemd OnCalendar syntax; quote it).
                                   Default: 'Fri 04:30:00'.

  --update-enabled  [true|false|1|0]   Enable (start & schedule) the update
                                       timer. Default: true.
  --restart-enabled [true|false|1|0]   Enable (start & schedule) the restart
                                       timer. Default: true.

  -h, --help                   Show this help and exit.

Notes:
  * At least one of --update / --restart must be effectively true.
  * The .service units are always installed disabled, so they never run on boot;
    only the .timer units are enabled. The timers still trigger the services on
    schedule.
  * The script is idempotent — safe to run repeatedly.

Examples:
  sudo ./install_system_maintenance.sh --update
  sudo ./install_system_maintenance.sh --update --restart
  sudo ./install_system_maintenance.sh --update --restart false
  sudo ./install_system_maintenance.sh --update --update-sched "*-*-* 04:00:00"
  sudo ./install_system_maintenance.sh --restart --restart-enabled false
EOF
}

# --- boolean helpers -------------------------------------------------------
# Does the token look like a boolean value? (used to decide whether a bare
# --update / --restart consumed the following argument as its value)
is_bool_token() {
    case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
        1|0|true|false|yes|no|on|off) return 0 ;;
        *) return 1 ;;
    esac
}

# Normalise a boolean value to 1 / 0, or fail with a message.
parse_bool() {
    case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
        1|true|yes|on)   printf '1' ;;
        0|false|no|off)  printf '0' ;;
        *) echo "Invalid boolean value: '${1:-}' (expected true/false or 1/0)." >&2
           return 1 ;;
    esac
}

# --- parse arguments -------------------------------------------------------
if [ "$#" -eq 0 ]; then
    usage
    exit 1
fi

while [ "$#" -gt 0 ]; do
    raw="$1"
    # Support --flag=value as well as --flag value.
    case "$raw" in
        --*=*) opt="${raw%%=*}"; val="${raw#*=}"; has_val=1 ;;
        *)     opt="$raw";        val="";          has_val=0 ;;
    esac

    case "$opt" in
        --update|--restart)
            if [ "$has_val" -eq 1 ]; then
                b="$(parse_bool "$val")" || exit 1
            elif [ "$#" -ge 2 ] && is_bool_token "$2"; then
                b="$(parse_bool "$2")" || exit 1
                shift
            else
                b=1   # a bare --update / --restart means "true"
            fi
            if [ "$opt" = "--update" ]; then DO_UPDATE="$b"; else DO_RESTART="$b"; fi
            ;;
        --update-enabled|--restart-enabled)
            if [ "$has_val" -eq 0 ]; then
                [ "$#" -ge 2 ] || { echo "$opt requires a true/false value." >&2; exit 1; }
                val="$2"; shift
            fi
            b="$(parse_bool "$val")" || exit 1
            if [ "$opt" = "--update-enabled" ]; then UPDATE_ENABLED="$b"; else RESTART_ENABLED="$b"; fi
            ;;
        --update-sched|--restart-sched)
            if [ "$has_val" -eq 0 ]; then
                [ "$#" -ge 2 ] || { echo "$opt requires an OnCalendar value." >&2; exit 1; }
                val="$2"; shift
            fi
            if [ "$opt" = "--update-sched" ]; then UPDATE_SCHED="$val"; else RESTART_SCHED="$val"; fi
            ;;
        -h|--help)
            usage; exit 0 ;;
        *)
            echo "Unknown option: $raw" >&2; usage; exit 1 ;;
    esac
    shift
done

if [ "$DO_UPDATE" -eq 0 ] && [ "$DO_RESTART" -eq 0 ]; then
    echo "Nothing to do: pass --update and/or --restart (they default to true)." >&2
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

# --- install a single unit file (overwrites -> idempotent) -----------------
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

# --- rewrite a timer's OnCalendar= line in place ---------------------------
# awk receives the value as a variable, so it is inserted literally (no regex /
# sed-delimiter pitfalls with '*', '/', ':' etc. in OnCalendar expressions).
set_oncalendar() {
    local file="$1" value="$2" tmp
    tmp="$(mktemp)"
    awk -v val="$value" '
        /^OnCalendar=/ { print "OnCalendar=" val; next }
        { print }
    ' "$file" > "$tmp"
    install -m 0644 "$tmp" "$file"
    rm -f "$tmp"
    echo "  set OnCalendar=${value} in ${file}"
}

# --- print the effective schedule of an installed timer --------------------
current_oncalendar() {
    grep -E '^OnCalendar=' "${SYSTEMD_DIR}/$1" 2>/dev/null | head -n1 | cut -d= -f2- || true
}

# --- assert the desired state for one service/timer pair -------------------
# * the service is always disabled (never runs on boot)
# * the timer is enabled+started, or disabled+stopped, per $enabled
apply_component() {
    local service="$1" timer="$2" enabled="$3"

    # Requirement: the service must never auto-start on boot.
    systemctl disable "$service" >/dev/null 2>&1 || true

    if [ "$enabled" -eq 1 ]; then
        systemctl enable "$timer" >/dev/null 2>&1 || true
        # restart (not just start) so a changed OnCalendar takes effect and a
        # repeat run is idempotent even when the timer was already active.
        systemctl restart "$timer"
        echo "  enabled & (re)started ${timer}  [schedule: $(current_oncalendar "$timer")]"
    else
        systemctl disable "$timer" >/dev/null 2>&1 || true
        systemctl stop "$timer"    >/dev/null 2>&1 || true
        echo "  installed ${timer} but left it DISABLED (per --*-enabled)"
    fi
}

if [ "$FAMILY" = "RHEL" ]; then
    ensure_rhel_utils
fi

# --- install the selected unit files ---------------------------------------
INSTALLED_TIMERS=""

if [ "$DO_UPDATE" -eq 1 ]; then
    echo "Installing update units..."
    install_unit "system_update.service"
    install_unit "system_update.timer"
    [ -n "$UPDATE_SCHED" ] && set_oncalendar "${SYSTEMD_DIR}/system_update.timer" "$UPDATE_SCHED"
    INSTALLED_TIMERS="${INSTALLED_TIMERS} system_update.timer"
fi

if [ "$DO_RESTART" -eq 1 ]; then
    echo "Installing restart units..."
    install_unit "system_restart.service"
    install_unit "system_restart.timer"
    [ -n "$RESTART_SCHED" ] && set_oncalendar "${SYSTEMD_DIR}/system_restart.timer" "$RESTART_SCHED"
    INSTALLED_TIMERS="${INSTALLED_TIMERS} system_restart.timer"
fi

# --- reload systemd, then assert the desired enable/disable state ----------
systemctl daemon-reload

if [ "$DO_UPDATE" -eq 1 ]; then
    apply_component "system_update.service" "system_update.timer" "$UPDATE_ENABLED"
fi
if [ "$DO_RESTART" -eq 1 ]; then
    apply_component "system_restart.service" "system_restart.timer" "$RESTART_ENABLED"
fi

echo ""
echo "Done. Scheduled maintenance timers:"
# shellcheck disable=SC2086
systemctl list-timers --all $INSTALLED_TIMERS 2>/dev/null || true
