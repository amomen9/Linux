#!/usr/bin/env bash
#
# install_chrome_and_edge_x11.sh
# =============================================================================
# Cross-platform installer for Google Chrome and Microsoft Edge, plus the
# minimal local X11 stack (xauth, xterm, a lightweight window manager) needed
# to display their windows back over an X11-forwarded SSH session, across
# every distribution family in
#   ../../Migrate_to_Linux/Supported Distributions.txt
#
# Supported families:
#   Debian/Ubuntu (apt) . RHEL/Fedora (dnf/yum) . Arch (pacman, via AUR) .
#   openSUSE/SUSE (zypper) . Alpine (apk)* . Gentoo (emerge)* . Slackware*
#   (* = best-effort; see the on-screen notes -- neither browser is
#        officially packaged for these families)
#
# Usage:
#   ./install_chrome_and_edge_x11.sh              # install everything
#   ./install_chrome_and_edge_x11.sh --dry-run     # preview only, no changes
#   ./install_chrome_and_edge_x11.sh -y            # skip confirmation prompt
#
# The script itself is run as a normal user; individual privileged commands
# are prefixed with sudo (Arch's AUR helper must NOT run as root, so the
# whole script cannot simply require root).
# =============================================================================

set -euo pipefail

DRY_RUN=0
ASSUME_YES=0
FAMILY=""
DISTRO_ID=""
DISTRO_LIKE=""
PM=""   # RHEL package manager (dnf|yum), resolved in install functions

# ------------------------------- pretty output -------------------------------
log()  { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

# Print a command (nicely quoted) and run it -- unless --dry-run, in which
# case it is only printed, so --dry-run is a faithful preview of a real run.
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

usage() {
    cat <<'EOF'
Usage: install_chrome_and_edge_x11.sh [options]

Installs Google Chrome, Microsoft Edge, and the minimal X11 stack needed to
display their windows over an X11-forwarded SSH session, on the detected
distribution family.

Options:
  --dry-run    Print every command without executing anything (no root needed).
  -y, --yes    Do not prompt for confirmation; just proceed.
  -h, --help   Show this help and exit.

Notes:
  * Debian/Ubuntu, RHEL/Fedora and openSUSE install both browsers from their
    official (or, for openSUSE Chrome, well-established de-facto) package
    repositories.
  * Arch installs both via an AUR helper (yay or paru) if one is present.
  * Alpine, Gentoo and Slackware are best-effort: neither browser is
    officially packaged there. The script does what it reasonably can and
    prints guidance for the rest -- read the on-screen notes.
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        -y|--yes)  ASSUME_YES=1 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
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
    if   command -v apt-get  >/dev/null 2>&1;                                   then FAMILY=debian
    elif command -v dnf      >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then FAMILY=rhel
    elif command -v pacman   >/dev/null 2>&1;                                   then FAMILY=arch
    elif command -v zypper   >/dev/null 2>&1;                                   then FAMILY=suse
    elif command -v apk      >/dev/null 2>&1;                                   then FAMILY=alpine
    elif command -v emerge   >/dev/null 2>&1;                                   then FAMILY=gentoo
    elif command -v slackpkg >/dev/null 2>&1;                                   then FAMILY=slackware
    else return 1
    fi
    return 0
}

detect_family || die "Could not detect a supported distribution family."

# Ensure the current user's X authority file exists so xauth/SSH X11
# forwarding has something to write cookies into. Default permissions from
# touch (no world read/write) are sufficient; it must stay private.
setup_xauthority() {
    run touch ~/.Xauthority
}

# ------------------------------- family installers ---------------------------

install_debian() {
    run sudo apt update
    run sudo apt install -y xterm xauth xorg openbox x11-apps

    if command -v microsoft-edge-stable >/dev/null 2>&1; then
        log "Microsoft Edge is already installed, skipping."
    elif [ "$DRY_RUN" -eq 1 ]; then
        log "[dry-run] would add the Microsoft Edge apt repo and install microsoft-edge-stable"
    else
        sudo sh -c '
            set -euo pipefail
            wget -qO- https://packages.microsoft.com/keys/microsoft.asc \
              | gpg --dearmor > /usr/share/keyrings/microsoft-edge.gpg
            echo "deb [arch=amd64 signed-by=/usr/share/keyrings/microsoft-edge.gpg] https://packages.microsoft.com/repos/edge stable main" \
              > /etc/apt/sources.list.d/microsoft-edge.list
            apt update
            apt install -y microsoft-edge-stable
        '
    fi

    if command -v google-chrome-stable >/dev/null 2>&1; then
        log "Google Chrome is already installed, skipping."
    elif [ "$DRY_RUN" -eq 1 ]; then
        log "[dry-run] would download and install the Google Chrome .deb"
    else
        local tmp_deb; tmp_deb="$(mktemp --suffix=.deb)"
        curl -fL -o "$tmp_deb" https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
        sudo apt install -y --fix-broken "$tmp_deb"
        rm -f "$tmp_deb"
    fi

    run sudo apt-get clean
}

install_rhel() {
    PM=dnf; command -v dnf >/dev/null 2>&1 || PM=yum

    # RHEL rebuilds (not Fedora) need EPEL for openbox.
    case " $DISTRO_ID " in
        *" fedora "*) : ;;
        *) run sudo "$PM" install -y epel-release \
              || warn "Could not enable EPEL; openbox may be unavailable." ;;
    esac
    if [ "$PM" = dnf ]; then run sudo dnf group install -y base-x; else run sudo yum -y groupinstall base-x; fi
    run sudo "$PM" install -y xorg-x11-xauth xterm openbox

    if command -v microsoft-edge-stable >/dev/null 2>&1; then
        log "Microsoft Edge is already installed, skipping."
    elif [ "$DRY_RUN" -eq 1 ]; then
        log "[dry-run] would add the Microsoft Edge yum repo and install microsoft-edge-stable"
    else
        sudo rpm --import https://packages.microsoft.com/keys/microsoft.asc
        sudo sh -c 'cat > /etc/yum.repos.d/microsoft-edge.repo' <<'EOF'
[microsoft-edge]
name=microsoft-edge
baseurl=https://packages.microsoft.com/yumrepos/edge
enabled=1
gpgcheck=1
gpgkey=https://packages.microsoft.com/keys/microsoft.asc
EOF
        run sudo "$PM" install -y microsoft-edge-stable
    fi

    if command -v google-chrome-stable >/dev/null 2>&1; then
        log "Google Chrome is already installed, skipping."
    elif [ "$DRY_RUN" -eq 1 ]; then
        log "[dry-run] would import Google's signing key and install the Google Chrome rpm"
    else
        sudo rpm --import https://dl.google.com/linux/linux_signing_key.pub
        run sudo "$PM" install -y https://dl.google.com/linux/direct/google-chrome-stable_current_x86_64.rpm
    fi

    run sudo "$PM" clean all
}

install_arch() {
    run sudo pacman -Syu --needed --noconfirm xorg-xauth xterm xorg openbox

    local aur=""
    if   command -v yay  >/dev/null 2>&1; then aur=yay
    elif command -v paru >/dev/null 2>&1; then aur=paru
    fi

    if [ -z "$aur" ]; then
        warn "Neither yay nor paru is installed; Chrome and Edge are AUR-only on Arch."
        warn "Install an AUR helper first, e.g.:"
        warn "  git clone https://aur.archlinux.org/yay.git && cd yay && makepkg -si"
        warn "then re-run this script, or manually: yay -S google-chrome microsoft-edge-stable-bin"
        return 0
    fi

    # AUR helpers must not run as root -- no sudo here, they escalate internally.
    if command -v google-chrome-stable >/dev/null 2>&1; then
        log "Google Chrome is already installed, skipping."
    else
        run "$aur" -S --needed --noconfirm google-chrome
    fi

    if command -v microsoft-edge-stable >/dev/null 2>&1; then
        log "Microsoft Edge is already installed, skipping."
    else
        run "$aur" -S --needed --noconfirm microsoft-edge-stable-bin
    fi
}

install_suse() {
    run sudo zypper --non-interactive install -t pattern x11
    run sudo zypper --non-interactive install xterm openbox

    if command -v microsoft-edge-stable >/dev/null 2>&1; then
        log "Microsoft Edge is already installed, skipping."
    elif [ "$DRY_RUN" -eq 1 ]; then
        log "[dry-run] would add the Microsoft Edge zypper repo and install microsoft-edge-stable"
    else
        sudo rpm --import https://packages.microsoft.com/keys/microsoft.asc
        run sudo zypper --non-interactive addrepo https://packages.microsoft.com/yumrepos/edge microsoft-edge
        run sudo zypper --non-interactive --gpg-auto-import-keys refresh
        run sudo zypper --non-interactive install microsoft-edge-stable
    fi

    if command -v google-chrome-stable >/dev/null 2>&1; then
        log "Google Chrome is already installed, skipping."
    elif [ "$DRY_RUN" -eq 1 ]; then
        log "[dry-run] would download and install the Google Chrome rpm (best-effort on openSUSE)"
    else
        warn "Google doesn't officially support openSUSE; installing the Fedora rpm directly (best-effort)."
        local tmp_rpm; tmp_rpm="$(mktemp --suffix=.rpm)"
        curl -fL -o "$tmp_rpm" https://dl.google.com/linux/direct/google-chrome-stable_current_x86_64.rpm
        sudo rpm --import https://dl.google.com/linux/linux_signing_key.pub
        sudo zypper --non-interactive install "$tmp_rpm"
        rm -f "$tmp_rpm"
    fi

    run sudo zypper clean
}

install_alpine() {
    warn "Alpine is musl-based; Chrome and Edge are glibc-only proprietary binaries"
    warn "and are not reliably installable here (see Supported Distributions.txt)."
    run sudo apk update
    run sudo apk add xauth xterm openbox
    if command -v setup-xorg-base >/dev/null 2>&1; then
        run sudo setup-xorg-base
    else
        run sudo apk add xorg-server xf86-input-libinput xinit
    fi
    warn "Installing Chromium instead, as the closest working substitute."
    run sudo apk add chromium
}

install_gentoo() {
    warn "Gentoo builds from source and Chrome/Edge fetch prebuilt binaries instead;"
    warn "this is best-effort and may need manual adjustment."
    run sudo emerge --ask=n --noreplace x11-apps/xauth x11-terms/xterm x11-wm/openbox

    if command -v google-chrome-stable >/dev/null 2>&1; then
        log "Google Chrome is already installed, skipping."
    elif [ "$DRY_RUN" -eq 1 ]; then
        log "[dry-run] would accept the Chrome license and emerge www-client/google-chrome"
    else
        echo "www-client/google-chrome google-chrome" | sudo tee -a /etc/portage/package.license >/dev/null
        run sudo emerge --ask=n --noreplace www-client/google-chrome
    fi

    warn "Microsoft Edge has no ebuild in the main Gentoo tree."
    warn "It may be available as www-client/microsoft-edge-stable-bin in the GURU overlay:"
    warn "  sudo eselect repository enable guru && sudo emerge --sync guru"
    warn "  sudo emerge --ask=n www-client/microsoft-edge-stable-bin"
}

install_slackware() {
    run sudo slackpkg update
    run sudo slackpkg install x xap
    warn "Openbox is not in the Slackware base tree; after install run 'xwmconfig'"
    warn "to choose a window manager (get one from SlackBuilds.org)."

    if command -v sboinstall >/dev/null 2>&1; then
        run sudo sboinstall -r google-chrome microsoft-edge
    else
        warn "Chrome and Edge are not packaged for Slackware; sbotools (sboinstall) isn't"
        warn "installed either, so this is guidance-only. See:"
        warn "  https://slackbuilds.org/repository/current/network/google-chrome/"
        warn "  https://slackbuilds.org/repository/current/network/microsoft-edge/"
    fi
}

# --------------------------------- run plan ----------------------------------
log "Detected distribution family : $FAMILY${DISTRO_ID:+ (ID=$DISTRO_ID)}"
[ "$DRY_RUN" -eq 1 ] && warn "DRY-RUN: no changes will be made."

if [ "$DRY_RUN" -eq 0 ] && [ "$ASSUME_YES" -eq 0 ]; then
    printf 'Install Google Chrome, Microsoft Edge and the X11 stack for %s? [y/N] ' "$FAMILY"
    read -r ans || ans=""
    case "$ans" in
        y|Y|yes|YES|Yes) ;;
        *) echo "Aborted."; exit 0 ;;
    esac
fi

setup_xauthority

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

log "Done."
