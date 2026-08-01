#!/usr/bin/env bash
#
# install_docker_engine.sh
# =============================================================================
# Cross-platform installer for Docker Engine, across every distribution family
# in ../../Migrate_to_Linux/Supported Distributions.txt:
#
#   Debian/Ubuntu (apt) . RHEL/Fedora (dnf/yum) . Arch (pacman) .
#   openSUSE/SUSE (zypper) . Alpine (apk)* . Gentoo (emerge)* . Slackware (static)*
#   (* = best-effort; see the on-screen notes)
#
# Debian/Ubuntu and RHEL/Fedora use Docker's official apt/yum repository.
# Arch, openSUSE, Alpine and Gentoo use the distribution's own packaged
# `docker`. Slackware has no official package, so the script installs
# Docker's upstream static binaries and a minimal SysV init script instead.
#
# The script auto-detects the family from /etc/os-release (with a package
# manager fallback), removes old/conflicting Docker packages, installs Docker
# Engine + Compose, enables/starts the daemon (systemd, OpenRC or sysvinit),
# and adds the invoking user to the `docker` group.
#
# Usage:
#   sudo ./install_docker_engine.sh                # install + enable + start
#   sudo ./install_docker_engine.sh --no-group      # skip adding user to docker group
#   ./install_docker_engine.sh --dry-run            # preview only
#
# See --help for the full flag list.
# =============================================================================

set -euo pipefail

# --------------------------------- defaults ----------------------------------
NO_GROUP=0      # --no-group: don't add the invoking user to the docker group
DRY_RUN=0       # print commands without running them?
ASSUME_YES=0    # skip the confirmation prompt? (-y / --yes)

FAMILY=""       # debian | rhel | arch | suse | alpine | gentoo | slackware
DISTRO_ID=""    # /etc/os-release ID
DISTRO_LIKE=""  # /etc/os-release ID_LIKE
ARCH=""         # x86_64 | aarch64 | armhf | other
PM=""           # resolved dnf/yum on rhel

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

# Write $2 (a single string, may contain newlines) to file $1, dry-run aware.
write_file() {
    local path="$1" content="$2"
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '\033[1;34m[run]\033[0m write %s\n' "$path"
        return 0
    fi
    printf '%s\n' "$content" > "$path"
}

# --------------------------------- usage -------------------------------------
usage() {
    cat <<'EOF'
Usage: install_docker_engine.sh [options]

Installs Docker Engine + Compose on the detected distribution family, enables
and starts the daemon, and adds the invoking user to the `docker` group.

Options:
  --no-group     Do not add the invoking (sudo) user to the docker group.
  --dry-run      Print every command without executing anything (does not
                  require root).
  -y, --yes      Do not prompt for confirmation; just proceed.
  -h, --help     Show this help and exit.

Notes:
  * Must be run as root (unless --dry-run), e.g. via sudo.
  * Debian/Ubuntu and RHEL/Fedora use Docker's official repository.
    Arch, openSUSE, Alpine and Gentoo use the distro's own `docker` package.
    Slackware has no official package: Docker's static binaries and a minimal
    init script are installed instead -- best-effort, read the on-screen notes.

Examples:
  sudo ./install_docker_engine.sh
  sudo ./install_docker_engine.sh --no-group -y
  ./install_docker_engine.sh --dry-run
EOF
}

# ------------------------------ parse arguments ------------------------------
while [ "$#" -gt 0 ]; do
    case "$1" in
        --no-group) NO_GROUP=1 ;;
        --dry-run)  DRY_RUN=1 ;;
        -y|--yes)   ASSUME_YES=1 ;;
        -h|--help)  usage; exit 0 ;;
        *)          echo "Unknown option: $1" >&2; usage; exit 1 ;;
    esac
    shift
done

# --------------------------- detect distro + arch -----------------------------
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

detect_arch() {
    local m; m="$(uname -m)"
    case "$m" in
        x86_64|amd64)        ARCH="x86_64" ;;
        aarch64|arm64)       ARCH="aarch64" ;;
        armv7l|armhf|armv6l) ARCH="armhf" ;;
        *)                   ARCH="$m" ;;
    esac
}

detect_family || die "Could not detect a supported distribution family."
detect_arch

# ------------------------------- family installers ---------------------------
install_debian() {
    export DEBIAN_FRONTEND=noninteractive
    local pkg
    for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
        run apt-get remove -y "$pkg" || true
    done

    run apt-get update
    run apt-get install -y ca-certificates curl gnupg lsb-release

    # Ubuntu (and its derivatives) vs plain Debian use different repo paths.
    local repo="ubuntu" codename=""
    if [ "$DISTRO_ID" = debian ]; then repo="debian"; fi
    codename="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
    [ -n "$codename" ] || codename="$(lsb_release -cs)"

    run install -m 0755 -d /etc/apt/keyrings
    run curl -fsSL "https://download.docker.com/linux/${repo}/gpg" -o /etc/apt/keyrings/docker.asc
    run chmod a+r /etc/apt/keyrings/docker.asc

    write_file /etc/apt/sources.list.d/docker.list \
        "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${repo} ${codename} stable"

    run apt-get update
    run apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

install_rhel() {
    PM=dnf; command -v dnf >/dev/null 2>&1 || PM=yum

    local pkg
    for pkg in docker docker-client docker-client-latest docker-common \
               docker-latest docker-latest-logrotate docker-logrotate \
               docker-engine podman-docker runc; do
        run "$PM" remove -y "$pkg" || true
    done

    # Fedora has its own repo file; RHEL/Rocky/Alma/CentOS/Oracle share the
    # "centos" one (they're all rpm-compatible with it).
    local repo_distro=centos
    [ "$DISTRO_ID" = fedora ] && repo_distro=fedora

    run "$PM" install -y dnf-plugins-core || true
    run curl -fsSL "https://download.docker.com/linux/${repo_distro}/docker-ce.repo" -o /etc/yum.repos.d/docker-ce.repo
    run "$PM" install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

install_arch() {
    # -Syu (not -Sy) avoids an unsupported partial upgrade on rolling Arch.
    run pacman -Syu --needed --noconfirm docker docker-compose docker-buildx
}

install_suse() {
    run zypper --non-interactive install docker docker-compose
}

ensure_alpine_community() {
    local repos=/etc/apk/repositories main_line community_line
    [ -f "$repos" ] || return 0
    grep -qE '^[^#].*/community[[:space:]]*$' "$repos" 2>/dev/null && return 0
    main_line="$(grep -E '^[^#].*/main[[:space:]]*$' "$repos" | head -n1 || true)"
    [ -n "$main_line" ] || return 0
    community_line="${main_line%/main}/community"
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '\033[1;34m[run]\033[0m enable Alpine community repo: %s\n' "$community_line"
    else
        printf '%s\n' "$community_line" >> "$repos"
    fi
}

install_alpine() {
    warn "Alpine is best-effort (OpenRC + musl)."
    ensure_alpine_community
    run apk update
    run apk add docker docker-cli-compose
}

install_gentoo() {
    warn "Gentoo builds from source; this can take a long time."
    run emerge --ask=n --noreplace app-containers/docker app-containers/docker-cli app-containers/docker-compose
}

install_slackware() {
    warn "Slackware has no official Docker package; installing upstream static"
    warn "binaries instead (best-effort). Docker Compose is not included --"
    warn "install it separately (e.g. via SlackBuilds.org) if you need it."

    local sarch
    case "$ARCH" in
        x86_64|aarch64|armhf) sarch="$ARCH" ;;
        *) die "Docker static builds do not support architecture '$ARCH'." ;;
    esac

    local listing ver tarball tmpdir
    listing="$(curl -fsSL "https://download.docker.com/linux/static/stable/${sarch}/")" \
        || die "Could not reach download.docker.com to list Docker static builds."
    ver="$(printf '%s\n' "$listing" | grep -oE "docker-[0-9]+\.[0-9]+\.[0-9]+\.tgz" \
        | sed -e 's/^docker-//' -e 's/\.tgz$//' | sort -V | tail -n1)"
    [ -n "$ver" ] || die "Could not determine the latest Docker static build version."
    tarball="docker-${ver}.tgz"

    log "Installing Docker ${ver} static build for ${sarch}."

    if [ "$DRY_RUN" -eq 1 ]; then
        printf '\033[1;34m[run]\033[0m download+extract %s and copy binaries into /usr/bin\n' \
            "https://download.docker.com/linux/static/stable/${sarch}/${tarball}"
    else
        tmpdir="$(mktemp -d)"
        trap 'rm -rf "$tmpdir"' RETURN
        curl -fsSL "https://download.docker.com/linux/static/stable/${sarch}/${tarball}" -o "${tmpdir}/${tarball}"
        tar -xzf "${tmpdir}/${tarball}" -C "$tmpdir"
        cp "${tmpdir}"/docker/* /usr/bin/
        rm -rf "$tmpdir"
    fi

    run groupadd -f docker

    write_file /etc/rc.d/rc.docker '#!/bin/sh
# Minimal SysV init script for the Docker daemon (static-binary install).
DOCKERD=/usr/bin/dockerd
PIDFILE=/var/run/docker.pid
LOGFILE=/var/log/dockerd.log

case "$1" in
  start)
    if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
      echo "dockerd is already running."
    else
      echo "Starting dockerd..."
      nohup "$DOCKERD" >>"$LOGFILE" 2>&1 &
      echo $! > "$PIDFILE"
    fi
    ;;
  stop)
    if [ -f "$PIDFILE" ]; then
      echo "Stopping dockerd..."
      kill "$(cat "$PIDFILE")" 2>/dev/null
      rm -f "$PIDFILE"
    fi
    ;;
  restart)
    "$0" stop
    sleep 1
    "$0" start
    ;;
  *)
    echo "Usage: $0 {start|stop|restart}"
    exit 1
    ;;
esac'
    run chmod 755 /etc/rc.d/rc.docker

    local hook='[ -x /etc/rc.d/rc.docker ] && /etc/rc.d/rc.docker start'
    if [ -f /etc/rc.d/rc.local ] && ! grep -qF "$hook" /etc/rc.d/rc.local 2>/dev/null; then
        if [ "$DRY_RUN" -eq 1 ]; then
            printf '\033[1;34m[run]\033[0m append to /etc/rc.d/rc.local: %s\n' "$hook"
        else
            printf '\n%s\n' "$hook" >> /etc/rc.d/rc.local
        fi
    fi

    run /etc/rc.d/rc.docker start
}

# ------------------------- enable/start the daemon ---------------------------
enable_service() {
    if [ "$FAMILY" = slackware ]; then
        return 0    # already started by install_slackware
    elif [ -d /run/systemd/system ]; then
        run systemctl enable --now docker
    elif command -v rc-update >/dev/null 2>&1; then
        run rc-update add docker default || warn "Could not add docker to the default runlevel."
        run rc-service docker start || run service docker start
    else
        warn "Unrecognised init system; enable/start the docker daemon manually."
    fi
}

# --------------------------- docker group membership --------------------------
add_user_to_docker_group() {
    [ "$NO_GROUP" -eq 1 ] && return 0
    local target_user="${SUDO_USER:-}"
    if [ -z "$target_user" ] || [ "$target_user" = root ]; then
        warn "No non-root invoking user detected (run via sudo to auto-add one); skipping docker group setup."
        return 0
    fi
    if [ "$FAMILY" = alpine ]; then
        run addgroup "$target_user" docker
    else
        run usermod -aG docker "$target_user"
    fi
    log "Added '$target_user' to the docker group. Log out and back in (or run 'newgrp docker') for this to take effect."
}

# --------------------------------- run plan ----------------------------------
log "Detected distribution family : $FAMILY${DISTRO_ID:+ (ID=$DISTRO_ID)}"
log "Detected architecture        : $ARCH"
log "Add invoking user to docker group : $([ "$NO_GROUP" -eq 1 ] && echo no || echo yes)"
[ "$DRY_RUN" -eq 1 ] && warn "DRY-RUN: no changes will be made."

# Root is required for real runs (package install + system config).
if [ "$DRY_RUN" -eq 0 ] && [ "$(id -u)" -ne 0 ]; then
    die "This script must be run as root (try: sudo $0 ...). Use --dry-run to preview."
fi

# Confirmation prompt (skipped by -y/--yes and by --dry-run).
if [ "$DRY_RUN" -eq 0 ] && [ "$ASSUME_YES" -eq 0 ]; then
    printf 'Proceed with installing Docker Engine above? [y/N] '
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

enable_service
add_user_to_docker_group

# --------------------------------- summary -----------------------------------
echo ""
if [ "$DRY_RUN" -eq 0 ]; then
    run docker --version || warn "docker --version failed; check the daemon/service status."
    run docker context ls || true
fi
log "Done. Docker Engine has been installed for family '$FAMILY'."
