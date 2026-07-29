#!/usr/bin/env bash
#
# install_server_with_minimum_ui.sh
# =============================================================================
# Cross-platform installer that adds a graphical desktop to a server, across
# every distribution family in
#   ../../Migrate_to_Linux/Supported Distributions.txt
#
# Two profiles:
#
#   * DEFAULT ("standard") -- the distribution's canonical *server with GUI*
#     grouping, e.g.
#         RHEL / Fedora ....... dnf group install "Server with GUI"
#         Debian / Ubuntu ..... apt install ubuntu-desktop-minimal
#     A full (if lean) desktop with the distro's own display manager.
#
#   * --minimal -- a stripped-down graphical layer: the X.Org base via each
#     family's group/pattern (dnf `base-x`, the `xorg` metapackage, ...) plus a
#     lightweight window manager or desktop selected with --desktop:
#         openbox : tiny window manager (default)
#         xfce    : lightweight desktop  (dnf group `xfce-desktop`, etc.)
#         none    : X.Org only
#     paired with the LightDM display manager.
#
# The script auto-detects the family from /etc/os-release (with a package
# manager fallback) and dispatches to the right tooling, then enables graphical
# login (systemd graphical.target, OpenRC runlevel, or Slackware runlevel 4).
#
# Supported families:
#   Debian/Ubuntu (apt) . RHEL/Fedora (dnf/yum) . Arch (pacman) .
#   openSUSE/SUSE (zypper) . Alpine (apk)* . Gentoo (emerge)* . Slackware*
#   (* = best-effort; see the on-screen notes)
#
# Usage:
#   sudo ./install_server_with_minimum_ui.sh                    # full server GUI
#   sudo ./install_server_with_minimum_ui.sh --minimal          # openbox + LightDM
#   sudo ./install_server_with_minimum_ui.sh --minimal --desktop xfce
#   sudo ./install_server_with_minimum_ui.sh --minimal --desktop none --no-dm
#   ./install_server_with_minimum_ui.sh --dry-run               # preview only
#
# See --help for the full flag list.
# =============================================================================

set -euo pipefail

# --------------------------------- defaults ----------------------------------
MINIMAL=0             # 0 = standard (full server GUI); 1 = minimal X + light WM/DE
DESKTOP="openbox"     # openbox | xfce | none  (only used when --minimal)
NO_DM=0               # --no-dm: do not install/enable any display manager
DM_OVERRIDE=""        # --dm <name>: force a specific display manager
SET_GRAPHICAL=1       # set the default boot target to graphical?
DRY_RUN=0             # print commands without running them?
ASSUME_YES=0          # skip the confirmation prompt? (-y / --yes)

FAMILY=""             # filled in by detect_family
DISTRO_ID=""          # /etc/os-release ID
DISTRO_LIKE=""        # /etc/os-release ID_LIKE
PM=""                 # RHEL package manager (dnf|yum), resolved in install_rhel

# Resolved per family at install time:
DM_SERVICE=""         # display-manager service/name to enable ("" = none)
DM_PKGS=()            # display-manager packages to install (may be empty)

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
Usage: install_server_with_minimum_ui.sh [options]

Adds a graphical desktop to a server on the detected distribution family.

By DEFAULT it installs the distribution's canonical "server with GUI" grouping
(RHEL: dnf group install "Server with GUI"; Ubuntu: ubuntu-desktop-minimal;
and the analogous full desktop on the other families).

Options:
  --minimal                       Install a MINIMAL graphical layer instead of
                                    the full desktop: the X.Org base (via the
                                    family's group/pattern) plus a lightweight
                                    window manager/desktop and LightDM.
  --desktop <openbox|xfce|none>   With --minimal, which light UI to install:
                                    openbox : tiny window manager (default)
                                    xfce    : lightweight desktop (group install)
                                    none    : X.Org only, no window manager
                                    (ignored without --minimal).
  --dm <name>                     Force a specific display manager package/service.
  --no-dm                         Do not install or enable a display manager.
  --no-graphical                  Do not switch the default boot target to
                                    graphical (leave the system booting to text).
  --dry-run                       Print every command without executing anything
                                    (does not require root).
  -y, --yes                       Do not prompt for confirmation; just proceed.
  -h, --help                      Show this help and exit.

Notes:
  * Must be run as root (unless --dry-run), e.g. via sudo.
  * Debian/Ubuntu, RHEL/Fedora, Arch and openSUSE are the primary targets.
    Alpine, Gentoo and Slackware are best-effort (non-systemd init, source
    builds, or no packaged Openbox/LightDM) -- read the on-screen notes.

Examples:
  sudo ./install_server_with_minimum_ui.sh                  # full server GUI (default)
  sudo ./install_server_with_minimum_ui.sh --minimal        # openbox + LightDM
  sudo ./install_server_with_minimum_ui.sh --minimal --desktop xfce -y
  sudo ./install_server_with_minimum_ui.sh --minimal --desktop none --no-dm
  ./install_server_with_minimum_ui.sh --dry-run --minimal
EOF
}

# ------------------------------ parse arguments ------------------------------
while [ "$#" -gt 0 ]; do
    raw="$1"
    case "$raw" in
        --*=*) opt="${raw%%=*}"; val="${raw#*=}"; has_val=1 ;;
        *)     opt="$raw";        val="";          has_val=0 ;;
    esac

    case "$opt" in
        --minimal)      MINIMAL=1 ;;
        --desktop)
            if [ "$has_val" -eq 0 ]; then
                [ "$#" -ge 2 ] || die "$opt requires a value (openbox|xfce|none)."
                val="$2"; shift
            fi
            case "$val" in
                openbox|xfce|none) DESKTOP="$val" ;;
                *) die "Invalid --desktop '$val' (expected openbox, xfce or none)." ;;
            esac
            ;;
        --dm)
            if [ "$has_val" -eq 0 ]; then
                [ "$#" -ge 2 ] || die "$opt requires a display-manager name."
                val="$2"; shift
            fi
            DM_OVERRIDE="$val"
            ;;
        --no-dm)        NO_DM=1 ;;
        --no-graphical) SET_GRAPHICAL=0 ;;
        --dry-run)      DRY_RUN=1 ;;
        -y|--yes)       ASSUME_YES=1 ;;
        -h|--help)      usage; exit 0 ;;
        *)              echo "Unknown option: $raw" >&2; usage; exit 1 ;;
    esac
    shift
done

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
        *" debian "*|*" ubuntu "*)                       FAMILY=debian;    return 0 ;;
        *" rhel "*|*" fedora "*|*" centos "*)             FAMILY=rhel;      return 0 ;;
        *" arch "*)                                       FAMILY=arch;      return 0 ;;
        *" suse "*|*" opensuse "*|*" sles "*|*" sled "*)  FAMILY=suse;      return 0 ;;
        *" alpine "*)                                     FAMILY=alpine;    return 0 ;;
        *" gentoo "*)                                     FAMILY=gentoo;    return 0 ;;
        *" slackware "*)                                  FAMILY=slackware; return 0 ;;
    esac
    # Fall back to whichever package manager is present.
    if   command -v apt-get >/dev/null 2>&1;                                    then FAMILY=debian
    elif command -v dnf     >/dev/null 2>&1 || command -v yum >/dev/null 2>&1;  then FAMILY=rhel
    elif command -v pacman  >/dev/null 2>&1;                                    then FAMILY=arch
    elif command -v zypper  >/dev/null 2>&1;                                    then FAMILY=suse
    elif command -v apk     >/dev/null 2>&1;                                    then FAMILY=alpine
    elif command -v emerge  >/dev/null 2>&1;                                    then FAMILY=gentoo
    elif command -v slackpkg >/dev/null 2>&1;                                   then FAMILY=slackware
    else return 1
    fi
    return 0
}

detect_family || die "Could not detect a supported distribution family."

# Resolve the display manager for this run given the family defaults.
#   finalize_dm <default-service> [default-packages...]
# Honours --no-dm (none) and --dm <name> (override), else uses the family default.
finalize_dm() {
    local def_service="$1"; shift
    if [ "$NO_DM" -eq 1 ]; then
        DM_SERVICE=""; DM_PKGS=(); return 0
    fi
    if [ -n "$DM_OVERRIDE" ]; then
        DM_SERVICE="$DM_OVERRIDE"; DM_PKGS=("$DM_OVERRIDE"); return 0
    fi
    DM_SERVICE="$def_service"; DM_PKGS=("$@")
}

# ------------------------------- family installers ---------------------------
install_debian() {
    export DEBIAN_FRONTEND=noninteractive
    run apt-get update
    local pkgs=()
    if [ "$MINIMAL" -eq 1 ]; then
        pkgs=(xorg xinit x11-xserver-utils xterm)   # 'xorg' == the X.Org metapackage
        case "$DESKTOP" in
            openbox) pkgs+=(openbox obconf) ;;
            xfce)    pkgs+=(xfce4 xfce4-terminal) ;;
        esac
        finalize_dm lightdm lightdm lightdm-gtk-greeter
        [ ${#DM_PKGS[@]} -gt 0 ] && pkgs+=("${DM_PKGS[@]}")
        run apt-get install -y --no-install-recommends "${pkgs[@]}"
    else
        # Standard: a full (lean) desktop with its own display manager (gdm3).
        case " $DISTRO_ID $DISTRO_LIKE " in
            *" ubuntu "*) pkgs=(ubuntu-desktop-minimal) ;;
            *)            pkgs=(gnome-core) ;;          # plain Debian analogue
        esac
        finalize_dm gdm3                               # pulled in by the desktop
        [ ${#DM_PKGS[@]} -gt 0 ] && pkgs+=("${DM_PKGS[@]}")
        run apt-get install -y "${pkgs[@]}"
    fi
}

# dnf uses `group install <id/name>`; yum uses `groupinstall`.
pm_group_install() {
    if [ "$PM" = dnf ]; then run dnf group install -y "$@"; else run yum -y groupinstall "$@"; fi
}

install_rhel() {
    PM=dnf; command -v dnf >/dev/null 2>&1 || PM=yum

    if [ "$MINIMAL" -eq 1 ]; then
        # RHEL rebuilds (not Fedora) need EPEL for openbox / lightdm.
        case " $DISTRO_ID " in
            *" fedora "*) : ;;
            *) run "$PM" install -y epel-release \
                  || warn "Could not enable EPEL; openbox/lightdm may be unavailable." ;;
        esac
        pm_group_install base-x                        # X Window System (a real group)
        local pkgs=(xorg-x11-xinit xterm)
        case "$DESKTOP" in
            openbox) pkgs+=(openbox) ;;
            xfce)    pm_group_install xfce-desktop \
                        || pkgs+=(xfce4-session xfce4-panel xfwm4 xfdesktop xfce4-terminal) ;;
        esac
        finalize_dm lightdm lightdm lightdm-gtk
        [ ${#DM_PKGS[@]} -gt 0 ] && pkgs+=("${DM_PKGS[@]}")
        run "$PM" install -y "${pkgs[@]}"
    else
        # Standard: the canonical server-with-GUI environment.
        case " $DISTRO_ID " in
            *" fedora "*) pm_group_install workstation-product-environment ;;  # Fedora GUI env
            *)            pm_group_install "Server with GUI" ;;                 # RHEL/Rocky/Alma/...
        esac
        finalize_dm gdm                                # brought in by the environment
        if [ ${#DM_PKGS[@]} -gt 0 ]; then run "$PM" install -y "${DM_PKGS[@]}"; fi
    fi
}

install_arch() {
    local pkgs=()
    if [ "$MINIMAL" -eq 1 ]; then
        pkgs=(xorg xorg-xinit xterm)                   # 'xorg' is a pacman *group*
        case "$DESKTOP" in
            openbox) pkgs+=(openbox) ;;
            xfce)    pkgs+=(xfce4) ;;                   # 'xfce4' is also a group
        esac
        finalize_dm lightdm lightdm lightdm-gtk-greeter
    else
        pkgs=(gnome)                                    # 'gnome' group == full desktop
        finalize_dm gdm gdm
    fi
    [ ${#DM_PKGS[@]} -gt 0 ] && pkgs+=("${DM_PKGS[@]}")
    # -Syu (not -Sy) avoids an unsupported partial upgrade on rolling Arch.
    run pacman -Syu --needed --noconfirm "${pkgs[@]}"
}

install_suse() {
    if [ "$MINIMAL" -eq 1 ]; then
        run zypper --non-interactive install -t pattern x11   # X11 pattern == group
        local pkgs=(xterm)
        case "$DESKTOP" in
            openbox) pkgs+=(openbox) ;;
            xfce)    run zypper --non-interactive install -t pattern xfce ;;
        esac
        finalize_dm lightdm lightdm lightdm-gtk-greeter
        [ ${#DM_PKGS[@]} -gt 0 ] && pkgs+=("${DM_PKGS[@]}")
        run zypper --non-interactive install "${pkgs[@]}"
    else
        run zypper --non-interactive install -t pattern gnome  # full GNOME pattern
        finalize_dm gdm
        if [ ${#DM_PKGS[@]} -gt 0 ]; then run zypper --non-interactive install "${DM_PKGS[@]}"; fi
    fi
}

install_alpine() {
    warn "Alpine is best-effort (OpenRC + musl); Flatpak apps are recommended there."
    run apk update
    if command -v setup-xorg-base >/dev/null 2>&1; then
        run setup-xorg-base
    else
        run apk add xorg-server xf86-input-libinput xinit
    fi
    local pkgs=(dbus elogind)
    if [ "$MINIMAL" -eq 1 ]; then
        pkgs+=(xterm)
        case "$DESKTOP" in
            openbox) pkgs+=(openbox) ;;
            xfce)    pkgs+=(xfce4 xfce4-terminal) ;;
        esac
        finalize_dm lightdm lightdm lightdm-gtk-greeter
    else
        pkgs+=(gnome)                                  # best-effort full desktop
        finalize_dm gdm gdm
    fi
    [ ${#DM_PKGS[@]} -gt 0 ] && pkgs+=("${DM_PKGS[@]}")
    run apk add "${pkgs[@]}"
    run rc-update add dbus default    || warn "Could not add dbus to the default runlevel."
    run rc-update add elogind default || warn "Could not add elogind to the default runlevel."
}

install_gentoo() {
    warn "Gentoo builds from source; this can take a long time."
    local atoms=(x11-base/xorg-server x11-apps/xinit x11-terms/xterm)
    if [ "$MINIMAL" -eq 1 ]; then
        case "$DESKTOP" in
            openbox) atoms+=(x11-wm/openbox) ;;
            xfce)    atoms+=(xfce-base/xfce4-meta) ;;
        esac
    else
        # A full GNOME build via source is impractical; XFCE is the sane "standard".
        atoms+=(xfce-base/xfce4-meta)
    fi
    finalize_dm lightdm x11-misc/lightdm
    [ ${#DM_PKGS[@]} -gt 0 ] && atoms+=("${DM_PKGS[@]}")
    run emerge --ask=n --noreplace "${atoms[@]}"
}

install_slackware() {
    run slackpkg update
    if [ "$MINIMAL" -eq 1 ]; then
        warn "Slackware: installing the X (x) and X-applications (xap) series."
        warn "Openbox/LightDM are not in the base tree -- after install run 'xwmconfig'"
        warn "to choose a window manager (extras come from SlackBuilds.org)."
        run slackpkg install x xap
    else
        warn "Slackware: installing X (x), X-applications (xap) and KDE Plasma (kde)."
        run slackpkg install x xap kde
    fi
}

# ---------------------- enable the graphical login / target ------------------
configure_suse_dm() {   # point openSUSE's display-manager.service at $1
    local dm="$1" f=/etc/sysconfig/displaymanager
    [ -f "$f" ] || { warn "$f not found; set DISPLAYMANAGER=\"$dm\" manually."; return 0; }
    run sed -i "s/^DISPLAYMANAGER=.*/DISPLAYMANAGER=\"$dm\"/" "$f"
}

enable_slackware_runlevel4() {   # Slackware boots to X from runlevel 4
    local f=/etc/inittab
    [ -f "$f" ] || { warn "$f not found; set the default runlevel to 4 manually."; return 0; }
    run sed -i 's/^id:[0-9]:initdefault:/id:4:initdefault:/' "$f"
}

enable_graphical() {
    if [ -d /run/systemd/system ]; then                       # systemd
        [ "$SET_GRAPHICAL" -eq 1 ] && run systemctl set-default graphical.target
        if [ -n "$DM_SERVICE" ]; then
            if [ "$FAMILY" = suse ]; then
                configure_suse_dm "$DM_SERVICE"
                run systemctl enable display-manager.service
            else
                run systemctl enable "${DM_SERVICE}.service"
            fi
        fi
    elif command -v rc-update >/dev/null 2>&1; then           # OpenRC (Alpine/Gentoo)
        if [ -n "$DM_SERVICE" ]; then
            run rc-update add "$DM_SERVICE" default \
                || warn "Could not add $DM_SERVICE to the default runlevel; enable it manually."
        fi
    elif [ "$FAMILY" = slackware ]; then                       # sysvinit
        if [ "$NO_DM" -eq 0 ] && [ "$SET_GRAPHICAL" -eq 1 ]; then enable_slackware_runlevel4; fi
    else
        warn "Unrecognised init system; enable your display manager manually."
    fi
}

# --------------------------------- run plan ----------------------------------
if [ "$MINIMAL" -eq 1 ]; then
    mode_label="minimal (X.Org + light UI)"
else
    mode_label="standard (full server GUI)"
fi
if   [ "$NO_DM" -eq 1 ];            then dm_label="none (text login / startx)"
elif [ -n "$DM_OVERRIDE" ];        then dm_label="$DM_OVERRIDE"
elif [ "$MINIMAL" -eq 1 ];         then dm_label="lightdm"
else                                    dm_label="the desktop's default display manager"
fi

log "Detected distribution family : $FAMILY${DISTRO_ID:+ (ID=$DISTRO_ID)}"
log "Install profile              : $mode_label"
[ "$MINIMAL" -eq 1 ] && log "Minimal desktop (--desktop)  : $DESKTOP"
log "Display manager              : $dm_label"
log "Set default target graphical : $([ "$SET_GRAPHICAL" -eq 1 ] && echo yes || echo no)"
[ "$DRY_RUN" -eq 1 ] && warn "DRY-RUN: no changes will be made."

# Root is required for real runs (package install + system config).
if [ "$DRY_RUN" -eq 0 ] && [ "$(id -u)" -ne 0 ]; then
    die "This script must be run as root (try: sudo $0 ...). Use --dry-run to preview."
fi

# Confirmation prompt (skipped by -y/--yes and by --dry-run).
if [ "$DRY_RUN" -eq 0 ] && [ "$ASSUME_YES" -eq 0 ]; then
    printf 'Proceed with the installation above? [y/N] '
    read -r ans || ans=""
    case "$ans" in
        y|Y|yes|YES|Yes) ;;
        *) echo "Aborted."; exit 0 ;;
    esac
fi

# --------------------------------- execute -----------------------------------
case "$FAMILY" in
    debian)    install_debian ;;
    rhel)      install_rhel ;;
    arch)      install_arch ;;
    suse)      install_suse ;;
    alpine)    install_alpine ;;
    gentoo)    install_gentoo ;;
    slackware) install_slackware ;;
    *)         die "Unsupported family: $FAMILY" ;;
esac

enable_graphical

# --------------------------------- summary -----------------------------------
echo ""
log "Done. A graphical environment ($mode_label) has been installed."
if [ "$NO_DM" -eq 1 ]; then
    warn "No display manager was enabled: log in on a text console and run 'startx'."
fi
if [ "$FAMILY" = slackware ]; then
    warn "On Slackware, run 'xwmconfig' to pick a window manager for your login."
fi
log "Reboot to boot into the new desktop:  sudo reboot"
