#!/usr/bin/env bash
#
# initiate_os_script.sh
# =============================================================================
# One-shot provisioning driver for a fresh Linux box. Detects the running
# distribution family (see
#   ../../Migrate_to_Linux/Supported Distributions.txt
# ), updates/upgrades the system with that family's own package manager, then
# runs the following scripts from this repository IN ORDER:
#
#   1. install_packages/Install_Server_with_Minimum_UI/install_server_with_minimum_ui.sh
#   2. install_packages/Install_and_Setup_TigerVNC_Server/setup-vnc-combined.sh
#   3. install_packages/Install_Docker_Engine/install_docker_engine.sh
#   4. maintenance/Scheduled_systemd_Automatic_Update/install_system_maintenance.sh
#   5. useful_scripts/bandwidth_test/bandwidth_test.sh
#
# Supported families: Debian/Ubuntu (apt) . RHEL/Fedora (dnf/yum) .
# Arch (pacman) . openSUSE/SUSE (zypper) . Alpine (apk)* . Gentoo (emerge)* .
# Slackware (slackpkg)* (* = best-effort; see the on-screen notes).
#
# Step 4 (install_system_maintenance.sh) only supports the Debian and RHEL
# families itself; on every other family it is skipped with a warning.
#
# Usage:
#   sudo ./initiate_os_script.sh                 # run every step, no prompts
#   sudo ./initiate_os_script.sh --prompt         # ask for confirmation first
#   ./initiate_os_script.sh --dry-run             # preview only, no root needed
#   sudo ./initiate_os_script.sh --skip-vnc --skip-docker
#
# See --help for the full flag list.
# =============================================================================

set -euo pipefail

# --- locate this script's directory / the repository root ------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

DESKTOP_SCRIPT="${REPO_ROOT}/install_packages/Install_Server_with_Minimum_UI/install_server_with_minimum_ui.sh"
VNC_SCRIPT="${REPO_ROOT}/install_packages/Install_and_Setup_TigerVNC_Server/setup-vnc-combined.sh"
DOCKER_SCRIPT="${REPO_ROOT}/install_packages/Install_Docker_Engine/install_docker_engine.sh"
MAINTENANCE_SCRIPT="${REPO_ROOT}/maintenance/Scheduled_systemd_Automatic_Update/install_system_maintenance.sh"
BANDWIDTH_SCRIPT="${REPO_ROOT}/useful_scripts/bandwidth_test/bandwidth_test.sh"

# --- default arguments passed to each sub-script (edit to taste) -----------
DESKTOP_ARGS=(--minimal --desktop xfce)
VNC_ARGS=()
DOCKER_ARGS=()
MAINTENANCE_ARGS=(--update --restart)
BANDWIDTH_ARGS=(--mbps)

# --------------------------------- defaults ----------------------------------
DRY_RUN=0        # print commands without running them?
PROMPT=0         # ask for confirmation before proceeding? (--prompt) -- default: auto-approved.
                 # When off (default), -y is also forwarded to the sub-scripts that support it.
DO_UPDATE=1      # run the system update/upgrade step?
DO_DESKTOP=1     # step 1: install_server_with_minimum_ui.sh
DO_VNC=1         # step 2: setup-vnc-combined.sh
DO_DOCKER=1      # step 3: install_docker_engine.sh
DO_MAINTENANCE=1 # step 4: install_system_maintenance.sh
DO_BANDWIDTH=1   # step 5: bandwidth_test.sh

FAMILY=""        # debian | rhel | arch | suse | alpine | gentoo | slackware
DISTRO_ID=""     # /etc/os-release ID
DISTRO_LIKE=""   # /etc/os-release ID_LIKE
PM=""            # resolved dnf/yum on rhel

# ------------------------------- pretty output -------------------------------
log()  { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

# Print a command (nicely quoted) and run it -- unless --dry-run, in which case
# it is only printed, so --dry-run is a faithful preview of a real run.
run() {
    printf '\033[1;34m[run]\033[0m'
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
Usage: initiate_os_script.sh [options]

Updates the system, then runs (in order): the minimum-UI desktop installer,
the TigerVNC setup, the Docker Engine installer, the scheduled-maintenance
installer, and the bandwidth test -- all from this repository.

By default, nothing prompts for confirmation: this script proceeds
automatically, and -y is forwarded to the sub-scripts that support it
(desktop, docker) so their own confirmation prompts are skipped too.

Options:
  --skip-update         Do not update/upgrade system packages first.
  --skip-desktop        Skip step 1 (install_server_with_minimum_ui.sh).
  --skip-vnc            Skip step 2 (setup-vnc-combined.sh).
  --skip-docker         Skip step 3 (install_docker_engine.sh).
  --skip-maintenance    Skip step 4 (install_system_maintenance.sh).
  --skip-bandwidth      Skip step 5 (bandwidth_test.sh).
  --dry-run             Print every command without executing anything
                          (does not require root).
  --prompt              Ask for confirmation before proceeding, instead of
                          auto-approving; sub-scripts are also left to show
                          their own confirmation prompts.
  -h, --help             Show this help and exit.

Notes:
  * Must be run as root (unless --dry-run), e.g. via sudo.
  * The TigerVNC step grants access to the invoking login user (via `logname`)
    and prompts for a VNC password unless $VNC_PASSWORD is already set; this
    is independent of --prompt.
  * install_system_maintenance.sh only supports the Debian and RHEL families;
    on every other family, step 4 is skipped automatically with a warning.

Examples:
  sudo ./initiate_os_script.sh
  sudo ./initiate_os_script.sh --prompt
  sudo ./initiate_os_script.sh --skip-vnc --skip-docker
  ./initiate_os_script.sh --dry-run
EOF
}

# ------------------------------ parse arguments ------------------------------
while [ "$#" -gt 0 ]; do
    case "$1" in
        --skip-update)      DO_UPDATE=0 ;;
        --skip-desktop)     DO_DESKTOP=0 ;;
        --skip-vnc)         DO_VNC=0 ;;
        --skip-docker)      DO_DOCKER=0 ;;
        --skip-maintenance) DO_MAINTENANCE=0 ;;
        --skip-bandwidth)   DO_BANDWIDTH=0 ;;
        --dry-run)          DRY_RUN=1 ;;
        --prompt)           PROMPT=1 ;;
        -h|--help)          usage; exit 0 ;;
        *)                  echo "Unknown option: $1" >&2; usage; exit 1 ;;
    esac
    shift
done

[ "$PROMPT" -eq 0 ] && { DESKTOP_ARGS+=(-y); DOCKER_ARGS+=(-y); }

# --------------------------- detect the distro family ------------------------
detect_family() {
    local id="" like=""
    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        id="${ID:-}"; like="${ID_LIKE:-}"
    fi
    DISTRO_ID="$id"; DISTRO_LIKE="$like"
    case " $id $like " in
        *" debian "*|*" ubuntu "*|*" linuxmint "*|*" pop "*|*" zorin "*|*" elementary "*) FAMILY=debian; return 0 ;;
        *" rhel "*|*" fedora "*|*" centos "*|*" rocky "*|*" almalinux "*|*" ol "*)         FAMILY=rhel;   return 0 ;;
        *" arch "*|*" archlinux "*|*" manjaro "*|*" endeavouros "*)                        FAMILY=arch;   return 0 ;;
        *" suse "*|*" opensuse "*|*" sles "*|*" sled "*)                                   FAMILY=suse;   return 0 ;;
        *" alpine "*|*" postmarketos "*)                                                   FAMILY=alpine; return 0 ;;
        *" gentoo "*|*" funtoo "*)                                                         FAMILY=gentoo; return 0 ;;
        *" slackware "*)                                                                   FAMILY=slackware; return 0 ;;
    esac
    # Fall back to whichever package manager is present.
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

detect_family || die "Could not detect a supported distribution family."

# ------------------------- system update/upgrade -----------------------------
update_system() {
    case "$FAMILY" in
        debian)
            export DEBIAN_FRONTEND=noninteractive
            run apt-get update
            run apt-get -y upgrade
            ;;
        rhel)
            PM=dnf; command -v dnf >/dev/null 2>&1 || PM=yum
            if [ "$PM" = dnf ]; then run dnf -y upgrade --refresh; else run yum -y update; fi
            ;;
        arch)
            # -Syu (not -Sy) avoids an unsupported partial upgrade on rolling Arch.
            run pacman -Syu --noconfirm
            ;;
        suse)
            run zypper --non-interactive refresh
            run zypper --non-interactive update
            ;;
        alpine)
            warn "Alpine is best-effort (OpenRC + musl)."
            run apk update
            run apk upgrade
            ;;
        gentoo)
            warn "Gentoo builds from source; syncing Portage and upgrading @world can take a long time."
            run emerge --sync
            run emerge -uDN @world
            ;;
        slackware)
            warn "Slackware is best-effort; upgrading with slackpkg's batch mode."
            run slackpkg update
            run slackpkg -batch=on -default-answer=y upgrade-all
            ;;
        *)
            die "Unsupported family: $FAMILY" ;;
    esac
}

# ----------------------------- helpers ----------------------------------------
require_script() {
    local path="$1"
    [ -f "$path" ] || die "Required script not found: $path"
}

run_step() {
    local n="$1" total="$2" desc="$3" script="$4"; shift 4
    printf '\n--------------------------------------------------------------------------------\n'
    log "Step ${n}/${total}: ${desc}"
    run "$script" "$@"
}

# --------------------------------- run plan ----------------------------------
log "Detected distribution family : $FAMILY${DISTRO_ID:+ (ID=$DISTRO_ID)}"
log "System update/upgrade        : $([ "$DO_UPDATE" -eq 1 ] && echo yes || echo no)"
log "Step 1 desktop (minimum UI)  : $([ "$DO_DESKTOP" -eq 1 ] && echo yes || echo "skip")"
log "Step 2 VNC server            : $([ "$DO_VNC" -eq 1 ] && echo yes || echo "skip")"
log "Step 3 Docker Engine         : $([ "$DO_DOCKER" -eq 1 ] && echo yes || echo "skip")"
log "Step 4 scheduled maintenance : $([ "$DO_MAINTENANCE" -eq 1 ] && echo yes || echo "skip")"
log "Step 5 bandwidth test        : $([ "$DO_BANDWIDTH" -eq 1 ] && echo yes || echo "skip")"
[ "$DRY_RUN" -eq 1 ] && warn "DRY-RUN: no changes will be made."

# Root is required for real runs (package installs + system config).
if [ "$DRY_RUN" -eq 0 ] && [ "$(id -u)" -ne 0 ]; then
    die "This script must be run as root (try: sudo $0 ...). Use --dry-run to preview."
fi

# Confirmation prompt (shown only with --prompt; skipped by default and by --dry-run).
if [ "$DRY_RUN" -eq 0 ] && [ "$PROMPT" -eq 1 ]; then
    printf 'Proceed with the plan above? [y/N] '
    read -r ans || ans=""
    case "$ans" in
        y|Y|yes|YES|Yes) ;;
        *) echo "Aborted."; exit 0 ;;
    esac
fi

# Make sure every script we intend to run actually exists before touching anything.
[ "$DO_DESKTOP" -eq 1 ]     && require_script "$DESKTOP_SCRIPT"
[ "$DO_VNC" -eq 1 ]         && require_script "$VNC_SCRIPT"
[ "$DO_DOCKER" -eq 1 ]      && require_script "$DOCKER_SCRIPT"
[ "$DO_MAINTENANCE" -eq 1 ] && require_script "$MAINTENANCE_SCRIPT"
[ "$DO_BANDWIDTH" -eq 1 ]   && require_script "$BANDWIDTH_SCRIPT"

# --------------------------------- execute -----------------------------------
if [ "$DO_UPDATE" -eq 1 ]; then
    printf '\n--------------------------------------------------------------------------------\n'
    log "Updating and upgrading system packages ($FAMILY)..."
    update_system
fi

[ "$DO_DESKTOP" -eq 1 ] && { run chmod +x "$DESKTOP_SCRIPT"; run_step 1 5 "Minimum-UI desktop (install_server_with_minimum_ui.sh)" "$DESKTOP_SCRIPT" "${DESKTOP_ARGS[@]}"; }
[ "$DO_VNC" -eq 1 ]     && { run chmod +x "$VNC_SCRIPT";     run_step 2 5 "TigerVNC server (setup-vnc-combined.sh)"              "$VNC_SCRIPT"     "${VNC_ARGS[@]}"; }
[ "$DO_DOCKER" -eq 1 ]  && { run chmod +x "$DOCKER_SCRIPT";  run_step 3 5 "Docker Engine (install_docker_engine.sh)"            "$DOCKER_SCRIPT"  "${DOCKER_ARGS[@]}"; }

if [ "$DO_MAINTENANCE" -eq 1 ]; then
    run chmod +x "$MAINTENANCE_SCRIPT"
    case "$FAMILY" in
        debian|rhel) run_step 4 5 "Scheduled maintenance (install_system_maintenance.sh)" "$MAINTENANCE_SCRIPT" "${MAINTENANCE_ARGS[@]}" ;;
        *) printf '\n--------------------------------------------------------------------------------\n'
           warn "Step 4/5: install_system_maintenance.sh only supports Debian/RHEL; skipping on '$FAMILY'." ;;
    esac
fi

[ "$DO_BANDWIDTH" -eq 1 ] && { run chmod +x "$BANDWIDTH_SCRIPT"; run_step 5 5 "Bandwidth test (bandwidth_test.sh)" "$BANDWIDTH_SCRIPT" "${BANDWIDTH_ARGS[@]}"; }

printf '\n--------------------------------------------------------------------------------\n'
log "Done."
