#!/usr/bin/env bash
#
# setup-vnc-combined.sh
# =============================================================================
# One combined, DISTRO-AGNOSTIC script that:
#
#   PART 1 - installs and configures a TigerVNC server that:
#       * grants remote desktop access to a username you supply (must exist)
#       * listens on TCP port 63512
#       * encrypts the ENTIRE session (not just the handshake) with TLS via the
#         X509Vnc security type (GnuTLS) - no SSH tunnelling
#       * authenticates with a VNC password over that encrypted channel
#       * verifies server identity with a self-signed X.509 certificate
#     ...and works across apt / dnf / yum / zypper / pacman based distributions.
#
#   PART 2 - detects the DISTRIBUTION'S OWN DEFAULT desktop session (GNOME on
#       Ubuntu/Fedora, Cinnamon on Mint, Plasma on Kubuntu, MATE on a MATE spin,
#       etc.) and points the VNC session at it. Nothing is hardcoded.
#       EXCEPTION: GNOME Shell and KDE Plasma are OpenGL compositors that
#       black-screen under Xvnc (no GPU). When one of those is the default, the
#       script installs XFCE - a lightweight, VNC-friendly desktop - and runs
#       that instead. Control this with --session auto|xfce|native (see --help).
#
# Usage:   sudo ./setup-vnc-combined.sh
#          VNC_USER=bob VNC_PASSWORD='secret' sudo -E ./setup-vnc-combined.sh   (non-interactive)
#          sudo ./setup-vnc-combined.sh --vnc-user bob --vnc-port 63512 \
#              --vnc-display :1 --geometry 1920x1080 --depth 24                  (command-line)
#
# Settings can be supplied on the command line (see --help). If --vnc-user is
# omitted, the script uses the invoking login user (via `logname`); $VNC_USER
# still overrides. That account MUST already exist on the system; if it does not,
# the script errors out and does nothing else.
#
# A graphical desktop must already be installed. If none is found, the script
# tells you and stops before touching the service, so nothing is left broken.
# =============================================================================

set -euo pipefail

# ------------------------------- configuration -------------------------------
VNC_PORT=63512
VNC_DISPLAY=":1"
GEOMETRY="1920x1080"
DEPTH=24
SESSION_CHOICE="auto"   # auto | xfce | native  (see --session in --help)
XSESS_DIR="/usr/share/xsessions"
# VNC_USER and SERVICE_NAME are resolved after prompting (see below).
# -----------------------------------------------------------------------------

log()  { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

# --------------------------- command-line arguments --------------------------
# Every setting above can be overridden here. Long options mirror the variable
# names, lowercased with underscores turned into hyphens:
#   --vnc-user, --vnc-port, --vnc-display, --geometry, --depth
# VNC_USER may also come from the environment; if it is set by neither, the
# script prompts for it during execution (as before). The VNC password is never
# accepted on the command line (so it can't leak into shell history) - it still
# comes from $VNC_PASSWORD or an interactive prompt.
usage() {
    cat <<EOF
Usage: $0 [options]

Options:
  --vnc-user USER        Existing account to grant VNC access to
                           (default: the invoking login user, via logname)
  --vnc-port PORT        TCP port to listen on            (default: ${VNC_PORT})
  --vnc-display DISPLAY  X display number, e.g. :1        (default: ${VNC_DISPLAY})
  --geometry WxH         Screen resolution                (default: ${GEOMETRY})
  --depth BITS           Colour depth                     (default: ${DEPTH})
  --session MODE         Which desktop to run under VNC   (default: ${SESSION_CHOICE})
                           auto   - use the distro default, but swap GNOME/KDE
                                    (which black-screen over VNC) for XFCE
                           xfce   - always install and use XFCE
                           native - always use the detected default desktop
  -h, --help             Show this help and exit
EOF
}

need_val() { [[ $# -ge 2 && "${2:0:2}" != "--" ]] || die "Option '$1' requires a value."; }

VNC_USER="${VNC_USER:-}"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --vnc-user)      need_val "$@"; VNC_USER="$2";           shift 2 ;;
        --vnc-user=*)    VNC_USER="${1#*=}";                     shift ;;
        --vnc-port)      need_val "$@"; VNC_PORT="$2";           shift 2 ;;
        --vnc-port=*)    VNC_PORT="${1#*=}";                     shift ;;
        --vnc-display)   need_val "$@"; VNC_DISPLAY="$2";        shift 2 ;;
        --vnc-display=*) VNC_DISPLAY="${1#*=}";                  shift ;;
        --geometry)      need_val "$@"; GEOMETRY="$2";           shift 2 ;;
        --geometry=*)    GEOMETRY="${1#*=}";                     shift ;;
        --depth)         need_val "$@"; DEPTH="$2";              shift 2 ;;
        --depth=*)       DEPTH="${1#*=}";                        shift ;;
        --session)       need_val "$@"; SESSION_CHOICE="$2";     shift 2 ;;
        --session=*)     SESSION_CHOICE="${1#*=}";               shift ;;
        -h|--help)       usage; exit 0 ;;
        *)               die "Unknown argument: '$1' (try --help)." ;;
    esac
done
case "$SESSION_CHOICE" in
    auto|xfce|native) ;;
    *) die "Invalid --session '${SESSION_CHOICE}' (use auto, xfce, or native)." ;;
esac

[[ $EUID -eq 0 ]] || die "This script must be run as root (use sudo)."

# --- resolve the target username ---------------------------------------------
# Priority: --vnc-user / $VNC_USER, else the invoking login user (logname).
# The account must already exist; this script never creates users.
if [[ -n "${VNC_USER:-}" ]]; then
    log "VNC user: '${VNC_USER}'  (from --vnc-user / \$VNC_USER)."
else
    VNC_USER="$(logname 2>/dev/null || true)"
    [[ -n "$VNC_USER" ]] || die "No username given and 'logname' returned nothing; pass --vnc-user."
    log "VNC user: '${VNC_USER}'  (no --vnc-user given; using the login user via logname)."
fi
if ! id "$VNC_USER" &>/dev/null; then
    die "User '$VNC_USER' does not exist on this system. Create it first, then re-run."
fi
SERVICE_NAME="vncserver-${VNC_USER}.service"
VNC_GROUP="$(id -gn "$VNC_USER")"
VNC_HOME="$(getent passwd "$VNC_USER" | cut -d: -f6)"
[[ -d "$VNC_HOME" ]] || die "Home directory for '$VNC_USER' not found: $VNC_HOME"
VNC_DIR="${VNC_HOME}/.vnc"
log "Target user: ${VNC_USER}  (home: ${VNC_HOME})"

# =============================================================================
# PART 1 - DISTRO-AGNOSTIC INSTALLATION
# =============================================================================

# --- 1a. detect the package manager ------------------------------------------
if   command -v apt-get >/dev/null 2>&1; then PM=apt
elif command -v dnf     >/dev/null 2>&1; then PM=dnf
elif command -v yum     >/dev/null 2>&1; then PM=yum
elif command -v zypper  >/dev/null 2>&1; then PM=zypper
elif command -v pacman  >/dev/null 2>&1; then PM=pacman
else die "No supported package manager found (apt/dnf/yum/zypper/pacman)."; fi
log "Package manager: ${PM}"

pm_refresh() {
    case "$PM" in
        apt)    DEBIAN_FRONTEND=noninteractive apt-get update -y ;;
        zypper) zypper --non-interactive refresh ;;
        *)      : ;;  # dnf/yum/pacman refresh implicitly on install
    esac
}
pm_install() {
    case "$PM" in
        apt)    DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" ;;
        dnf)    dnf install -y "$@" ;;
        yum)    yum install -y "$@" ;;
        zypper) zypper --non-interactive install --no-recommends "$@" ;;
        pacman) pacman -Sy --needed --noconfirm "$@" ;;
    esac
}
# Install a minimal-but-usable XFCE desktop (VNC-friendly). --no-install-recommends
# on apt keeps a display manager from being dragged in and switched as default.
install_xfce() {
    case "$PM" in
        apt)    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
                    xfce4 xfce4-session xfce4-terminal ;;
        dnf)    dnf install -y @xfce-desktop-environment \
                    || dnf group install -y "Xfce Desktop" \
                    || pm_install xfce4-session xfdesktop xfwm4 xfce4-panel xfce4-settings xfce4-terminal ;;
        yum)    yum groupinstall -y "Xfce" \
                    || pm_install xfce4-session xfdesktop xfwm4 xfce4-panel xfce4-settings xfce4-terminal ;;
        zypper) zypper --non-interactive install -t pattern xfce \
                    || pm_install xfce4-session xfdesktop xfwm4 xfce4-panel xfce4-settings xfce4-terminal ;;
        pacman) pm_install xfce4 ;;
    esac
}

# --- 1b. per-distro package names for the TigerVNC server --------------------
case "$PM" in
    apt)    VNC_PKGS=(tigervnc-standalone-server tigervnc-common) ;;
    dnf|yum) VNC_PKGS=(tigervnc-server) ;;
    zypper) VNC_PKGS=(tigervnc xorg-x11-Xvnc) ;;
    pacman) VNC_PKGS=(tigervnc) ;;
esac

# --- 1c. (target user was validated at the top; nothing to create here) ------

# --- 1d. install packages ----------------------------------------------------
log "Refreshing package metadata..."
pm_refresh || warn "Metadata refresh reported an issue; continuing."
log "Installing TigerVNC and dependencies..."
pm_install "${VNC_PKGS[@]}" openssl
# dbus-run-session is needed by PART 2's session launcher; install if missing.
if ! command -v dbus-run-session >/dev/null 2>&1; then
    case "$PM" in
        apt)    pm_install dbus-user-session || pm_install dbus-x11 || true ;;
        dnf|yum) pm_install dbus-tools || pm_install dbus-x11 || true ;;
        zypper) pm_install dbus-1-x11 || true ;;
        pacman) pm_install dbus || true ;;
    esac
fi

# --- 1e. locate the TigerVNC wrapper binary (name varies by distro) ----------
if   command -v tigervncserver >/dev/null 2>&1; then VNCBIN="$(command -v tigervncserver)"
elif command -v vncserver      >/dev/null 2>&1; then VNCBIN="$(command -v vncserver)"
else die "TigerVNC wrapper (tigervncserver/vncserver) not found after install."; fi
log "VNC wrapper: ${VNCBIN}"

# --- 1f. prepare ~/.vnc ------------------------------------------------------
log "Preparing ${VNC_DIR}"
mkdir -p "$VNC_DIR"

# --- 1g. VNC password (idempotent: skip if one already exists) ---------------
if [[ -s "${VNC_DIR}/passwd" && -z "${VNC_PASSWORD:-}" ]]; then
    log "Existing VNC password file found; keeping it."
else
    if [[ -n "${VNC_PASSWORD:-}" ]]; then
        pw="$VNC_PASSWORD"
    else
        read -rsp "Enter VNC password for ${VNC_USER} (only first 8 chars are used): " pw; echo
        read -rsp "Confirm password: " pw2; echo
        [[ "$pw" == "$pw2" ]] || die "Passwords do not match."
    fi
    [[ -n "$pw" ]] || die "Empty password is not allowed."
    printf '%s' "$pw" | vncpasswd -f > "${VNC_DIR}/passwd"
    unset pw pw2 VNC_PASSWORD 2>/dev/null || true
    log "VNC password file written."
fi

# --- 1h. self-signed X.509 certificate for full-session TLS ------------------
HOSTFQDN="$(hostname -f 2>/dev/null || hostname)"
HOSTSHORT="$(hostname -s 2>/dev/null || hostname)"
if [[ -f "${VNC_DIR}/cert.pem" && -f "${VNC_DIR}/key.pem" ]]; then
    log "Existing certificate found; keeping it."
else
    log "Generating self-signed X.509 certificate (valid 10 years)."
    openssl req -x509 -nodes -newkey rsa:2048 \
        -keyout "${VNC_DIR}/key.pem" \
        -out    "${VNC_DIR}/cert.pem" \
        -days 3650 \
        -subj "/CN=${HOSTFQDN}" \
        -addext "subjectAltName=DNS:${HOSTFQDN},DNS:${HOSTSHORT}"
fi

# =============================================================================
# PART 2 - DETECT THE DISTRIBUTION'S DEFAULT SESSION (appended, nothing hardcoded)
# =============================================================================

# Xvnc is an X11 server; it cannot run Wayland-only sessions, so we only ever
# consider X11 session files under /usr/share/xsessions.
shopt -s nullglob
xsessions=("$XSESS_DIR"/*.desktop)
shopt -u nullglob
if (( ${#xsessions[@]} == 0 )); then
    warn "No X11 session files found in $XSESS_DIR."
    warn "A graphical desktop (with an Xorg session) must be installed first."
    warn "Examples: Ubuntu 'ubuntu-desktop', Mint 'cinnamon', Fedora 'gnome-session-xsession'/'GNOME on Xorg'."
    die  "Install your desktop, then re-run this script."
fi

val() { grep -m1 "^$2=" "$1" 2>/dev/null | cut -d= -f2- || true; }   # $1=file $2=key

# Determine the default session NAME the way a display manager would.
name=""
as="/var/lib/AccountsService/users/${VNC_USER}"
if [[ -f "$as" ]]; then
    name="$(val "$as" XSession)"; [[ -z "$name" ]] && name="$(val "$as" Session)"
fi
[[ -z "$name" && -f "${VNC_HOME}/.dmrc" ]] && name="$(val "${VNC_HOME}/.dmrc" Session)"
[[ -z "$name" ]] && name="$(grep -rhm1 '^user-session=' /etc/lightdm/lightdm.conf /etc/lightdm/lightdm.conf.d/ 2>/dev/null | cut -d= -f2- | tail -1 || true)"
name="${name%.desktop}"
[[ -n "$name" && ! -f "${XSESS_DIR}/${name}.desktop" ]] && name=""

# Only one session installed -> that's the default.
[[ -z "$name" && ${#xsessions[@]} -eq 1 ]] && name="$(basename "${xsessions[0]}" .desktop)"

# Last resort: guess from the distro (prefer Xorg variants), else first found.
if [[ -z "$name" ]]; then
    distro_id="$(. /etc/os-release 2>/dev/null && echo "${ID:-}" || true)"
    case "$distro_id" in
        ubuntu)                              pref="ubuntu gnome" ;;
        linuxmint|mint)                      pref="cinnamon mate xfce" ;;
        debian)                              pref="gnome cinnamon mate xfce plasmax11" ;;
        fedora|rhel|centos|rocky|almalinux)  pref="gnome-xorg gnome plasmax11 kde" ;;
        opensuse*|suse|sled|sles)            pref="plasmax11 plasma kde gnome xfce" ;;
        kubuntu)                             pref="plasmax11 plasma kde" ;;
        xubuntu)                             pref="xubuntu xfce" ;;
        pop)                                 pref="pop cosmic gnome" ;;
        arch|manjaro|endeavouros)            pref="plasmax11 plasma gnome-xorg gnome xfce" ;;
        *)                                   pref="" ;;
    esac
    for c in $pref; do
        [[ -f "${XSESS_DIR}/${c}.desktop" ]] && { name="$c"; break; }
    done
    [[ -z "$name" ]] && name="$(basename "${xsessions[0]}" .desktop)"
fi

DESKTOP_FILE="${XSESS_DIR}/${name}.desktop"
EXEC_CMD="$(val "$DESKTOP_FILE" Exec | sed 's/ %[a-zA-Z]//g')"
DESKTOP_NAMES="$(val "$DESKTOP_FILE" DesktopNames)"
[[ -n "$EXEC_CMD" ]] || die "Could not read Exec= from $DESKTOP_FILE"

log "Distro default session : ${name}"
log "Launch command         : ${EXEC_CMD}"
[[ -n "$DESKTOP_NAMES" ]] && log "Desktop names          : ${DESKTOP_NAMES}"

# --- choose which desktop the VNC session runs -------------------------------
# GNOME Shell and KDE Plasma are OpenGL compositors. Under Xvnc there is no GPU,
# so they typically render a BLACK SCREEN even with software GL forced. XFCE is a
# lightweight, XRender-based desktop that runs reliably over VNC. So by default
# (--session auto) we install XFCE and run it whenever the machine's own default
# desktop is one of those GL-heavy compositors.
gl_heavy=0
case " ${DESKTOP_NAMES,,} ${name,,} " in
    *gnome*|*kde*|*plasma*) gl_heavy=1 ;;
esac

use_xfce=0
case "$SESSION_CHOICE" in
    xfce)   use_xfce=1 ;;
    auto)   (( gl_heavy )) && use_xfce=1 ;;
    native) use_xfce=0 ;;
esac

if (( use_xfce )); then
    (( gl_heavy )) && log "Default desktop '${name}' is a GL compositor - black screen under Xvnc."
    log "Installing XFCE for the VNC session (lightweight, VNC-friendly)..."
    install_xfce
    if   command -v startxfce4    >/dev/null 2>&1; then EXEC_CMD="$(command -v startxfce4)"
    elif command -v xfce4-session >/dev/null 2>&1; then EXEC_CMD="$(command -v xfce4-session)"
    else die "XFCE install did not provide startxfce4/xfce4-session; try '--session native'."; fi
    name="xfce"
    DESKTOP_NAMES="XFCE"
    gl_heavy=0     # XFCE renders fine over VNC without software GL
    log "VNC session desktop    : XFCE (${EXEC_CMD})"
fi

# Decide software-GL: only GL-heavy desktops kept as 'native' still need it.
if (( gl_heavy )); then
    log "GL-heavy desktop (${name}) kept as-is -> enabling software GL in xstartup."
    GL_HINT="Software GL is pre-enabled for this desktop (GNOME/KDE need it under Xvnc)."
else
    GL_HINT="Black screen? uncomment the software-GL lines in ${VNC_DIR}/xstartup and restart."
fi

# --- write xstartup that launches the detected session under Xorg ------------
{
    echo '#!/bin/sh'
    echo 'unset SESSION_MANAGER'
    echo 'unset DBUS_SESSION_BUS_ADDRESS'
    echo 'export XDG_SESSION_TYPE=x11'
    [[ -n "$DESKTOP_NAMES" ]] && echo "export XDG_CURRENT_DESKTOP=${DESKTOP_NAMES}"
    if (( gl_heavy )); then
        echo '# GNOME/KDE are GL compositors; under Xvnc (no GPU) they need software GL.'
        echo '# __GLX_VENDOR_LIBRARY_NAME=mesa is set FIRST so this still works when a'
        echo '# proprietary GLVND driver (e.g. NVIDIA) is installed - that GLX would'
        echo '# otherwise ignore LIBGL_ALWAYS_SOFTWARE and keep the screen black.'
        echo 'export __GLX_VENDOR_LIBRARY_NAME=mesa'
        echo 'export LIBGL_ALWAYS_SOFTWARE=1'
    else
        echo '# If you get a black screen, uncomment the next two lines (forces software GL):'
        echo '# export __GLX_VENDOR_LIBRARY_NAME=mesa'
        echo '# export LIBGL_ALWAYS_SOFTWARE=1'
    fi
    echo "exec dbus-run-session -- ${EXEC_CMD}"
} > "${VNC_DIR}/xstartup"
chmod +x "${VNC_DIR}/xstartup"

# =============================================================================
# FINALISE - config, permissions, systemd unit, firewall, start
# =============================================================================

# --- per-user VNC config (session + geometry; security is set on the unit) ---
log "Writing ${VNC_DIR}/config"
cat > "${VNC_DIR}/config" <<EOF
## TigerVNC per-user configuration for ${VNC_USER}
session=${name}
geometry=${GEOMETRY}
depth=${DEPTH}
localhost=no
alwaysshared
EOF

# --- permissions -------------------------------------------------------------
log "Fixing ownership and permissions."
chmod 700 "$VNC_DIR"
chmod 600 "${VNC_DIR}/passwd" "${VNC_DIR}/key.pem"
chmod 644 "${VNC_DIR}/cert.pem"
chmod 755 "${VNC_DIR}/xstartup"
chown -R "${VNC_USER}:${VNC_GROUP}" "$VNC_DIR"

# --- systemd unit (security-critical options live here, on the command line) -
log "Creating systemd unit /etc/systemd/system/${SERVICE_NAME}"
cat > "/etc/systemd/system/${SERVICE_NAME}" <<EOF
[Unit]
Description=TigerVNC server for ${VNC_USER} (X509 TLS, port ${VNC_PORT})
After=network-online.target syslog.target
Wants=network-online.target

[Service]
Type=forking
User=${VNC_USER}
Group=${VNC_GROUP}
WorkingDirectory=${VNC_HOME}
Environment=HOME=${VNC_HOME}
PIDFile=${VNC_DIR}/%H${VNC_DISPLAY}.pid
ExecStartPre=-${VNCBIN} -kill ${VNC_DISPLAY}
ExecStart=${VNCBIN} ${VNC_DISPLAY} \\
    -rfbport ${VNC_PORT} \\
    -localhost no \\
    -SecurityTypes X509Vnc \\
    -X509Cert ${VNC_DIR}/cert.pem \\
    -X509Key ${VNC_DIR}/key.pem \\
    -PasswordFile ${VNC_DIR}/passwd \\
    -xstartup ${VNC_DIR}/xstartup \\
    -geometry ${GEOMETRY} \\
    -depth ${DEPTH}
ExecStop=${VNCBIN} -kill ${VNC_DISPLAY}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# --- firewall (distro-agnostic: ufw OR firewalld) ----------------------------
if command -v ufw >/dev/null 2>&1 && ufw status >/dev/null 2>&1; then
    log "Opening ${VNC_PORT}/tcp in ufw."
    ufw allow "${VNC_PORT}/tcp" || warn "Could not add ufw rule."
elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    log "Opening ${VNC_PORT}/tcp in firewalld."
    firewall-cmd --permanent --add-port="${VNC_PORT}/tcp" || warn "Could not add firewalld rule."
    firewall-cmd --reload || true
else
    warn "No active ufw/firewalld detected. Open ${VNC_PORT}/tcp manually if a firewall is in use."
fi

# --- SELinux heads-up (Fedora/RHEL/openSUSE) ---------------------------------
if command -v getenforce >/dev/null 2>&1 && [[ "$(getenforce 2>/dev/null)" == "Enforcing" ]]; then
    warn "SELinux is Enforcing. If connections are refused on the custom port, label it:"
    warn "    semanage port -a -t vnc_port_t -p tcp ${VNC_PORT}   (needs policycoreutils-python-utils)"
fi

# --- start it ----------------------------------------------------------------
log "Enabling and starting ${SERVICE_NAME}"
systemctl daemon-reload
systemctl enable --now "${SERVICE_NAME}"
sleep 2
systemctl --no-pager --full status "${SERVICE_NAME}" || true

# --- summary -----------------------------------------------------------------
SERVER_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
cat <<EOF

=============================================================================
 VNC server for '${VNC_USER}' is configured.
=============================================================================
  Listening on : ${SERVER_IP:-<server-ip>} : ${VNC_PORT}   (TCP)
  Encryption   : full-session TLS via X509Vnc (GnuTLS) - no SSH tunnel
  Auth         : VNC password (over the encrypted channel)
  Desktop      : ${name}   (${EXEC_CMD})
  Certificate  : ${VNC_DIR}/cert.pem

 CONNECT (TigerVNC Viewer recommended):
   Address:  ${SERVER_IP:-<server-ip>}::${VNC_PORT}     (note the DOUBLE colon)
   First connect prompts about the self-signed cert - accept once, or copy
   ${VNC_DIR}/cert.pem to the client and set it as the viewer's X509 CA.

 USEFUL:
   systemctl status  ${SERVICE_NAME}
   systemctl restart ${SERVICE_NAME}
   journalctl -u ${SERVICE_NAME} -e
   Session log: ${VNC_DIR}/$(hostname):${VNC_DISPLAY#:}.log
   ${GL_HINT}
=============================================================================
EOF
