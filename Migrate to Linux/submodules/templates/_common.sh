#!/usr/bin/env bash
# =============================================================================
#  _common.sh  --  universal runtime engine for the generated installer scripts
# -----------------------------------------------------------------------------
#  This file is INLINED into every generated script in "Execute on Linux!/" by
#  submodules/D_compile_and_generate_shell_script.ps1.  It is distro- and
#  architecture-agnostic: it detects the running distro FAMILY (apt/dnf/zypper/
#  pacman) and CPU ARCH at runtime, then dispatches installs accordingly.
#
#  Design: Flatpak-first.  GUI apps come from Flathub (identical app id on every
#  distro).  The native package manager is used only for the irreducible base
#  (installing Flatpak itself, CLI/dev tools, drivers, system bits).
# =============================================================================

# Be strict but survivable: we handle per-app failures ourselves, so do not let
# a single failing install abort the whole run.
set -o pipefail

# ----------------------------- pretty output ---------------------------------
# All human-facing chatter goes to fd 3 (stdout) so command output can be hidden.
exec 3>&1
log()  { printf '\n\033[1;34m==>\033[0m %s\n' "$*" >&3; }
info() { printf '       %s\n' "$*" >&3; }
ok()   { printf '       \033[32m%s\033[0m\n' "$*" >&3; }
warn() { printf '       \033[1;33m%s\033[0m\n' "$*" >&3; }
err()  { printf '\033[1;31m%s\033[0m\n' "$*" >&3; }

have_cmd() { command -v "$1" >/dev/null 2>&1; }

# Filesystem-safe slug from an app name. execute_all.sh stages user-supplied
# files for "manual" apps under $MIGRATE_MANUAL_DIR/<slug>/ using the SAME slug.
slugify() { printf '%s' "$1" | tr '[:upper:] ' '[:lower:]-' | tr -cd 'a-z0-9-_'; }

# ----------------------------- bookkeeping -----------------------------------
RESULTS="${RESULTS:-/tmp/migrate_to_linux_results.tsv}"
# execute_all sets MIGRATE_KEEP_RESULTS so the per-stage child scripts APPEND to one
# shared log instead of truncating it, which lets execute_all print a combined
# summary of every operation at the very end. Run standalone, a script truncates.
if [ -z "${MIGRATE_KEEP_RESULTS:-}" ]; then
  : > "$RESULTS" 2>/dev/null || RESULTS="$(mktemp)"
fi
# Containers launched by the docker install method are recorded here (one TSV row per
# container: winapp \t image \t container \t how-to) so the end-of-run summary can print
# a "Launched containers" section. Shares the same cross-stage model as RESULTS.
DOCKER_LAUNCHED="${DOCKER_LAUNCHED:-/tmp/migrate_to_linux_launched.tsv}"
if [ -z "${MIGRATE_KEEP_RESULTS:-}" ]; then
  : > "$DOCKER_LAUNCHED" 2>/dev/null || DOCKER_LAUNCHED="$(mktemp)"
fi
declare -a OK_LIST=() SKIP_LIST=() FAIL_LIST=() FAIL_REASON=() MANUAL_LIST=()

# LAST_ERR holds the 1-line reason from the most recent captured command failure.
LAST_ERR=""

# Run a command, show its output, and on failure capture the last output line into
# LAST_ERR (a 1-line error reason). stdin stays attached, so interactive installers
# still work. Returns the command's real exit code.
capture() {
  local rc tmp; tmp="$(mktemp 2>/dev/null || echo /tmp/mtl_cap.$$)"
  "$@" 2>&1 | tee "$tmp" >&3
  rc=${PIPESTATUS[0]}
  LAST_ERR=""
  if [ "$rc" -ne 0 ]; then
    LAST_ERR="$(grep -v '^[[:space:]]*$' "$tmp" 2>/dev/null | tail -n 1)"
    [ -z "$LAST_ERR" ] && LAST_ERR="exit code $rc"
  fi
  rm -f "$tmp" 2>/dev/null || true
  return "$rc"
}

# MODULE tags which big module (Drivers / Config settings / Applications) each result
# belongs to, so execute_all can print a per-module classified summary at the end.
MODULE="${MODULE:-General}"
record_line() { printf '%s\t%s\t%-6s\t%s\t%s\n' "$(date '+%F %T')" "${MODULE:-General}" "$1" "$2" "${3:-}" >> "$RESULTS"; }
mark_ok()     { OK_LIST+=("$1");     record_line OK     "$1" "${2:-}"; ok "installed: $1"; }
mark_skip()   { SKIP_LIST+=("$1");   record_line SKIP   "$1" "${2:-}"; info "skipped: $1 (${2:-already present})"; }
mark_fail()   { FAIL_LIST+=("$1"); FAIL_REASON+=("${2:-unknown error}"); record_line FAIL "$1" "${2:-}"; err "failed: $1 ${2:+- $2}"; }
mark_manual() { MANUAL_LIST+=("$1"); record_line MANUAL "$1" "${2:-}"; warn "manual step required: $1 ${2:+- $2}"; }

print_summary() {
  # When orchestrated by execute_all, it prints ONE combined, classified summary at
  # the very end; suppress the per-stage summary here to avoid mid-run clutter.
  [ -n "${MIGRATE_KEEP_RESULTS:-}" ] && return 0
  log "Summary"
  info "OK:     ${#OK_LIST[@]}"
  info "Skip:   ${#SKIP_LIST[@]}"
  info "Manual: ${#MANUAL_LIST[@]}"
  info "Failed: ${#FAIL_LIST[@]}"
  if [ "${#FAIL_LIST[@]}" -gt 0 ]; then
    warn "Failures (1-line reason each):"
    for i in "${!FAIL_LIST[@]}"; do err "  - ${FAIL_LIST[$i]}: ${FAIL_REASON[$i]}"; done
  fi
  if [ "${#MANUAL_LIST[@]}" -gt 0 ]; then
    warn "Need a manual step:"; for i in "${MANUAL_LIST[@]}"; do info "  - $i"; done
  fi
  print_launched_containers
  info "Full log: $RESULTS"
}

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    err "This script must be run as root.  Try:  sudo $0"
    exit 1
  fi
}

# The non-root user we should install Flatpak apps / write desktop files for,
# even though the script itself runs under sudo.
TARGET_USER="${SUDO_USER:-$(id -un)}"
TARGET_HOME="$(getent passwd "$TARGET_USER" 2>/dev/null | cut -d: -f6)"
[ -z "$TARGET_HOME" ] && TARGET_HOME="$HOME"

# =============================================================================
#  DISTRO + ARCHITECTURE DETECTION
# =============================================================================
FAMILY=""      # debian | rhel | suse | arch
PM=""          # apt | dnf | zypper | pacman
DISTRO_ID=""
DISTRO_NAME=""

detect_distro() {
  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    DISTRO_ID="${ID:-}"
    DISTRO_NAME="${PRETTY_NAME:-${NAME:-$ID}}"
  fi
  local hay=" ${DISTRO_ID} ${ID_LIKE:-} "
  case "$hay" in
    *" debian "*|*" ubuntu "*|*" linuxmint "*|*" pop "*|*" zorin "*|*" elementary "*) FAMILY="debian"; PM="apt" ;;
    *" rhel "*|*" fedora "*|*" centos "*|*" rocky "*|*" almalinux "*|*" ol "*) FAMILY="rhel"; PM="dnf" ;;
    *" suse "*|*" opensuse "*|*" sles "*|*" sled "*) FAMILY="suse"; PM="zypper" ;;
    *" arch "*|*" archlinux "*|*" manjaro "*|*" endeavouros "*) FAMILY="arch"; PM="pacman" ;;
    *)
      # Fall back to whichever package manager actually exists.
      if   have_cmd apt-get; then FAMILY="debian"; PM="apt"
      elif have_cmd dnf;     then FAMILY="rhel";   PM="dnf"
      elif have_cmd zypper;  then FAMILY="suse";   PM="zypper"
      elif have_cmd pacman;  then FAMILY="arch";   PM="pacman"
      else err "Unsupported distribution: could not find apt/dnf/zypper/pacman."; exit 1
      fi ;;
  esac
}

ARCH=""        # x86_64 | aarch64 | armhf | other
detect_arch() {
  local m; m="$(uname -m)"
  case "$m" in
    x86_64|amd64)        ARCH="x86_64" ;;
    aarch64|arm64)       ARCH="aarch64" ;;
    armv7l|armhf|armv6l) ARCH="armhf" ;;
    *)                   ARCH="$m" ;;
  esac
}

# arch_supported "x86_64 aarch64"  ->  true if $ARCH is listed (empty list = all)
arch_supported() {
  local list="$1"
  [ -z "$list" ] && return 0
  case " $list " in *" $ARCH "*) return 0 ;; *) return 1 ;; esac
}

# =============================================================================
#  PACKAGE-MANAGER ABSTRACTION
# =============================================================================
_PM_REFRESHED=0
pm_refresh() {
  [ "$_PM_REFRESHED" = "1" ] && return 0
  case "$PM" in
    apt)    DEBIAN_FRONTEND=noninteractive apt-get update -y ;;
    dnf)    dnf -y makecache ;;
    zypper) zypper --non-interactive refresh ;;
    pacman) pacman -Sy --noconfirm ;;
  esac
  _PM_REFRESHED=1
}

pm_install() {
  [ "$#" -eq 0 ] && return 0
  case "$PM" in
    apt)    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@" ;;
    dnf)    dnf install -y "$@" ;;
    zypper) zypper --non-interactive install -y --no-recommends "$@" ;;
    pacman) pacman -S --noconfirm --needed "$@" ;;
  esac
}

pm_installed() {
  case "$PM" in
    apt)    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed" ;;
    dnf)    rpm -q "$1" >/dev/null 2>&1 ;;
    zypper) rpm -q "$1" >/dev/null 2>&1 ;;
    pacman) pacman -Q "$1" >/dev/null 2>&1 ;;
  esac
}

# =============================================================================
#  FLATPAK (universal app layer)
# =============================================================================
ensure_flatpak() {
  if ! have_cmd flatpak; then
    log "Installing Flatpak (required for the universal app layer)"
    pm_refresh
    pm_install flatpak || { mark_fail "flatpak" "could not install flatpak via $PM"; return 1; }
  fi
  flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo >/dev/null 2>&1 || true
  return 0
}

flatpak_installed() { flatpak info "$1" >/dev/null 2>&1; }

install_flatpak() {  # install_flatpak APPID
  local id="$1"
  if flatpak_installed "$id"; then
    # Already present: update it if the user asked to update existing apps.
    [ "${MIGRATE_UPDATE_EXISTING:-no}" = "yes" ] && flatpak update -y --noninteractive "$id"
    return 0
  fi
  flatpak install -y --noninteractive flathub "$id"
}

# =============================================================================
#  SNAP (optional fallback)
# =============================================================================
ensure_snap() {
  have_cmd snap && return 0
  case "$PM" in
    apt)    pm_install snapd ;;
    dnf)    pm_install snapd && systemctl enable --now snapd.socket 2>/dev/null && ln -sf /var/lib/snapd/snap /snap 2>/dev/null ;;
    zypper) warn "snap on openSUSE needs the snappy repo; skipping snap fallback"; return 1 ;;
    pacman) warn "snap on Arch is via AUR; skipping snap fallback"; return 1 ;;
  esac
  have_cmd snap
}

# =============================================================================
#  DESKTOP / WEB-APP SHORTCUTS
# =============================================================================
detect_browser() {
  local b
  for b in google-chrome google-chrome-stable chromium chromium-browser microsoft-edge brave-browser firefox; do
    have_cmd "$b" && { printf '%s' "$b"; return 0; }
  done
  # Flatpak browsers
  if flatpak_installed com.google.Chrome; then printf 'flatpak run com.google.Chrome'; return 0; fi
  if flatpak_installed org.chromium.Chromium; then printf 'flatpak run org.chromium.Chromium'; return 0; fi
  if flatpak_installed com.microsoft.Edge; then printf 'flatpak run com.microsoft.Edge'; return 0; fi
  return 1
}

webapp_desktop() {  # webapp_desktop "Name" "URL"
  local name="$1" url="$2" browser appdir desktop slug
  browser="$(detect_browser)" || { mark_manual "$name" "no browser found for web-app shortcut ($url)"; return 1; }
  slug="$(printf '%s' "$name" | tr '[:upper:] ' '[:lower:]-' | tr -cd 'a-z0-9-')"
  appdir="$TARGET_HOME/.local/share/applications"
  mkdir -p "$appdir"
  desktop="$appdir/webapp-$slug.desktop"
  {
    printf '[Desktop Entry]\n'
    printf 'Version=1.0\nType=Application\n'
    printf 'Name=%s\n' "$name"
    printf 'Exec=%s --app=%s\n' "$browser" "$url"
    printf 'Terminal=false\nCategories=Network;WebBrowser;\n'
  } > "$desktop"
  chown "$TARGET_USER":"$TARGET_USER" "$desktop" 2>/dev/null || true
  chmod +x "$desktop" 2>/dev/null || true
  mark_ok "$name" "web-app shortcut -> $url"
}

# =============================================================================
#  DIRECT DOWNLOADS (.deb / .rpm / AppImage)
# =============================================================================
DOWNLOAD_DIR="${DOWNLOAD_DIR:-/tmp/migrate_to_linux_downloads}"
mkdir -p "$DOWNLOAD_DIR" 2>/dev/null || true

download_file() {  # download_file URL OUTPATH
  local url="$1" out="$2"
  if have_cmd curl; then curl -fL --retry 3 -o "$out" "$url"
  elif have_cmd wget; then wget -O "$out" "$url"
  else err "neither curl nor wget available"; return 1; fi
}

install_local_package() {  # install_local_package FILE
  local f="$1"
  case "$PM" in
    apt)    DEBIAN_FRONTEND=noninteractive apt-get install -y "$f" || { dpkg -i "$f"; apt-get -f install -y; } ;;
    dnf)    dnf install -y "$f" ;;
    zypper) zypper --non-interactive install -y --allow-unsigned-rpm "$f" ;;
    pacman) pacman -U --noconfirm "$f" ;;
  esac
}

# Best-effort install of a package matching a specific (Windows) version. Tries the
# major-version package name and an exact version pin. Returns 0 on success, 1 if no
# matching version could be installed (caller then falls back to latest). pacman is
# rolling-release, so version pinning is not supported there.
install_native_version() {  # install_native_version PKG WINVER
  local pkg="$1" ver="$2" major
  major="$(printf '%s' "$ver" | grep -oE '[0-9]+' | head -n1)"
  [ -z "$major" ] && return 1
  case "$PM" in
    apt)    capture pm_install "${pkg}-${major}" || capture pm_install "${pkg}=${ver}" ;;
    dnf)    capture pm_install "${pkg}${major}" || capture pm_install "${pkg}-${major}" || capture pm_install "${pkg}-${ver}" ;;
    zypper) capture pm_install "${pkg}${major}" || capture pm_install "${pkg}-${ver}" ;;
    pacman) return 1 ;;
  esac
}

# =============================================================================
#  install_app  --  the multi-strategy, Flatpak-first dispatcher
# -----------------------------------------------------------------------------
#  Usage (emitted by the generator):
#    install_app --name "VLC" --method flatpak --flatpak org.videolan.VLC \
#                --apt vlc --dnf vlc --zypper vlc --pacman vlc \
#                --arch "x86_64 aarch64"
#  Methods: flatpak | native | snap | webapp | docker | wine-bottles |
#           deb-url | github-deb | manual
# =============================================================================
install_app() {
  local name="" alt="" method="" flatpak="" snap_pkg="" arch_list="" winver="" is_security=0 is_paid=0
  local apt="" dnf="" zypper="" pacman=""
  local url_x86="" url_arm="" url_deb="" url_rpm="" webapp_url="" docker_image="" github_repo="" note=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --name)    name="$2"; shift 2 ;;
      --alt)     alt="$2"; shift 2 ;;
      --method)  method="$2"; shift 2 ;;
      --flatpak) flatpak="$2"; shift 2 ;;
      --snap)    snap_pkg="$2"; shift 2 ;;
      --apt)     apt="$2"; shift 2 ;;
      --dnf)     dnf="$2"; shift 2 ;;
      --zypper)  zypper="$2"; shift 2 ;;
      --pacman)  pacman="$2"; shift 2 ;;
      --arch)    arch_list="$2"; shift 2 ;;
      --winver)  winver="$2"; shift 2 ;;
      --url-x86) url_x86="$2"; shift 2 ;;
      --url-arm) url_arm="$2"; shift 2 ;;
      --url-deb) url_deb="$2"; shift 2 ;;
      --url-rpm) url_rpm="$2"; shift 2 ;;
      --webapp)  webapp_url="$2"; shift 2 ;;
      --docker)  docker_image="$2"; shift 2 ;;
      --github)  github_repo="$2"; shift 2 ;;
      --note)     note="$2"; shift 2 ;;
      --security) is_security=1; shift ;;
      --paid)     is_paid=1; shift ;;
      *) shift ;;
    esac
  done
  [ -z "$name" ] && return 0

  # Security-suite equivalents (antivirus/firewall, etc.) are only installed when the
  # user opted in; many skip them because Linux is hardened by default.
  if [ "$is_security" -eq 1 ] && [ "${MIGRATE_INSTALL_SECURITY:-no}" != "yes" ]; then
    mark_skip "$name" "security suite - not installed (opted out)"
    return 0
  fi

  # Free-only mode: this app's only alternative is paid. Ask whether to proceed.
  if [ "${MIGRATE_FREE_ONLY:-no}" = "yes" ] && [ "$is_paid" -eq 1 ]; then
    local _fans=""
    if [ -r /dev/tty ]; then
      printf '\n\n\033[1;33m==> %s%s has no free alternative.\033[0m\n' "$name" "${alt:+ ---> $alt}" >&3
      printf '  No free alternative exists for this application. Do you want to continue with the installation of the paid one? Answering with No means skipping this application (y/n): ' > /dev/tty
      read -r _fans < /dev/tty || _fans="n"
      case "$_fans" in [Yy]*) ;; *) mark_skip "$name" "paid - skipped (free-only mode)"; return 0 ;; esac
    else
      mark_skip "$name" "paid - skipped (free-only mode)"; return 0
    fi
  fi

  if ! arch_supported "$arch_list"; then
    mark_skip "$name" "not available for $ARCH"
    return 0
  fi

  if [ -n "$alt" ]; then
    printf '\n\n\033[1;34m==> Installing: %s   --->   %s\033[0m\n' "$name" "$alt" >&3
  else
    printf '\n\n\033[1;34m==> Installing: %s\033[0m\n' "$name" >&3
  fi
  [ -n "$note" ] && info "$note"

  # native package name for the running family
  local native_pkg=""
  case "$PM" in
    apt) native_pkg="$apt" ;; dnf) native_pkg="$dnf" ;;
    zypper) native_pkg="$zypper" ;; pacman) native_pkg="$pacman" ;;
  esac
  local slug; slug="$(slugify "$name")"

  # ---- single-path methods ----
  case "$method" in
    webapp)
      webapp_desktop "$name" "$webapp_url"; return 0 ;;
    docker)
      docker_launch_app "$name" "$docker_image" "$note"; return 0 ;;
    wine-bottles)
      if ensure_flatpak && capture install_flatpak com.usebottles.bottles; then
        mark_ok "$name" "via Bottles (flatpak) - configure the Windows app inside Bottles"
      else mark_fail "$name" "${LAST_ERR:-could not install Bottles (flatpak)}"; fi
      return 0 ;;
    manual)
      local mdir="${MIGRATE_MANUAL_DIR:-$DOWNLOAD_DIR/manual}/$slug" mf got=0
      if [ -d "$mdir" ] && [ -n "$(ls -A "$mdir" 2>/dev/null)" ]; then
        for mf in "$mdir"/*; do [ -f "$mf" ] && install_by_ext "$mf" && got=1; done
        if [ "$got" -eq 1 ]; then mark_ok "$name" "installed from staged file"
        else mark_fail "$name" "${LAST_ERR:-staged file could not be installed}"; fi
      else
        mark_manual "$name" "${note:-manual install}"
      fi
      return 0 ;;
  esac

  # Universal "already installed" short-circuit. Unless the user asked to update
  # existing apps to the LATEST version, an app that is already present is skipped
  # entirely here -- BEFORE any vendor repo setup or download happens. This applies
  # when "same version" was chosen OR when existing apps are not being updated.
  if [ "${MIGRATE_VERSION_MODE:-latest}" = "same" ] || [ "${MIGRATE_UPDATE_EXISTING:-no}" != "yes" ]; then
    if { [ -n "$native_pkg" ] && pm_installed "${native_pkg%% *}"; } \
       || { [ -n "$flatpak" ] && have_cmd flatpak && flatpak_installed "$flatpak"; } \
       || { [ -n "$snap_pkg" ] && have_cmd snap && snap list "${snap_pkg%% *}" >/dev/null 2>&1; }; then
      mark_skip "$name" "already installed"
      return 0
    fi
  fi

  # ---- multi-backend methods (req: try every available pm until one works) ----
  # The declared method goes first; then EVERY other available backend is tried as a
  # fallback (native / flatpak / snap / direct-download) before the app is failed.
  local order
  case "$method" in
    flatpak)            order="flatpak native snap deburl" ;;
    native)             order="native flatpak snap deburl" ;;
    snap)               order="snap flatpak native deburl" ;;
    deb-url|github-deb) order="deburl native flatpak snap" ;;
    *)                  order="flatpak native snap deburl" ;;
  esac

  local b url f rfn
  LAST_ERR=""   # so an empty value after the loop means "nothing was even attempted"
  for b in $order; do
    case "$b" in
      flatpak)
        [ -n "$flatpak" ] || continue
        ensure_flatpak || continue
        if capture install_flatpak "$flatpak"; then mark_ok "$name" "flatpak $flatpak"; return 0; fi ;;
      native)
        [ -n "$native_pkg" ] || continue
        # vendor's own repo first, for the latest upstream build (if defined).
        rfn="repo_setup_$(printf '%s' "$slug" | tr '-' '_')"
        if declare -F "$rfn" >/dev/null 2>&1; then
          info "configuring vendor repository for $name ..."
          "$rfn" || warn "vendor repo setup failed; falling back to the distro repo"
        fi
        pm_refresh
        # Skip if present, UNLESS the user asked to update existing apps (then
        # pm_install upgrades it to the latest available).
        if pm_installed "${native_pkg%% *}" && [ "${MIGRATE_UPDATE_EXISTING:-no}" != "yes" ]; then
          mark_skip "$name" "already installed"; return 0
        fi
        # match the Windows version when the user chose "same version".
        if [ "${MIGRATE_VERSION_MODE:-latest}" = "same" ] && [ -n "$winver" ]; then
          if install_native_version "$native_pkg" "$winver"; then mark_ok "$name" "native $native_pkg (matched Windows $winver)"; return 0; fi
          warn "could not match Windows version $winver; installing latest"
        fi
        if capture pm_install $native_pkg; then mark_ok "$name" "native $native_pkg"; return 0; fi ;;
      snap)
        [ -n "$snap_pkg" ] || continue
        ensure_snap || continue
        if capture snap install $snap_pkg; then mark_ok "$name" "snap $snap_pkg"; return 0; fi ;;
      deburl)
        [ -n "$url_x86$url_arm$url_deb$url_rpm" ] || continue
        # Prefer the package format matching the distro family (.deb on apt, .rpm on
        # dnf/zypper); fall back to the arch-keyed URLs when no format-specific one fits.
        url=""
        case "$PM" in apt) url="$url_deb" ;; dnf|zypper) url="$url_rpm" ;; esac
        [ -n "$url" ] || { url="$url_x86"; [ "$ARCH" = "aarch64" ] && [ -n "$url_arm" ] && url="$url_arm"; }
        [ -n "$url" ] || continue
        f="$DOWNLOAD_DIR/${name// /_}.pkg"
        if capture download_file "$url" "$f" && capture install_local_package "$f"; then mark_ok "$name" "downloaded package"; return 0; fi ;;
    esac
  done

  # A real install error -> report failure. But if nothing was even attempted (no
  # package-manager route on this distro), show that and fall back to the manual
  # download-by-user scheme (place the file, then done/skip, handled by extension).
  if [ -n "$LAST_ERR" ]; then
    mark_fail "$name" "$LAST_ERR"
  else
    err "no available package manager could install it"
    manual_fallback "$name" "$alt" "$note" "$webapp_url$url_x86$github_repo"
  fi
}

# Resolve a user-typed installer path: strip surrounding single/double quotes and
# outer whitespace; absolute paths and ~/... are used as-is; a bare/relative path is
# taken relative to the logged-in user's Downloads folder. Echoes the resolved path.
resolve_user_path() {  # resolve_user_path RAW
  local p="$1"
  p="${p#"${p%%[![:space:]]*}"}"; p="${p%"${p##*[![:space:]]}"}"   # trim outer whitespace
  case "$p" in
    \'*\') p="${p#\'}"; p="${p%\'}" ;;
    \"*\") p="${p#\"}"; p="${p%\"}" ;;
  esac
  case "$p" in
    '')    : ;;
    /*)    : ;;
    '~')   p="$TARGET_HOME" ;;
    '~/'*) p="$TARGET_HOME/${p#\~/}" ;;
    *)     p="$TARGET_HOME/Downloads/$p" ;;
  esac
  printf '%s' "$p"
}

# Run a wine (Windows emulator) command as the logged-in user in their default 64-bit
# wine prefix (the installer itself usually runs as root under sudo).
run_wine() {  # run_wine CMD [ARGS...]
  if [ "$(id -u)" -eq 0 ] && [ "$TARGET_USER" != "root" ]; then
    sudo -u "$TARGET_USER" env HOME="$TARGET_HOME" WINEARCH=win64 WINEPREFIX="$TARGET_HOME/.wine" WINEDEBUG=-all "$@"
  else
    env HOME="$TARGET_HOME" WINEARCH=win64 WINEPREFIX="$TARGET_HOME/.wine" WINEDEBUG=-all "$@"
  fi
}

# Ensure wine (the Windows emulator) is installed via the native package manager.
ensure_wine() {
  have_cmd wine && return 0
  info "installing wine (Windows emulator) ..."
  case "$PM" in
    apt)    dpkg --add-architecture i386 2>/dev/null || true; pm_refresh; capture pm_install wine64 wine32 || capture pm_install wine ;;
    dnf)    capture pm_install wine ;;
    zypper) capture pm_install wine ;;
    pacman) capture pm_install wine ;;
  esac
  have_cmd wine
}

# Manual download-by-user fallback for an app no package manager could install.
# Asks the user to download the installer and type its path (full, or relative to the
# logged-in user's Downloads folder) in single quotes; installs it by extension; loops
# until a valid path is given or the user skips. Marks the result.
manual_fallback() {  # manual_fallback NAME [ALT] [NOTE] [URL]
  local name="$1" alt="$2" mnote="$3" murl="$4"
  # "skip all" chosen earlier: skip this and every remaining manual app without prompting.
  if [ "${MANUAL_FALLBACK_SKIP_ALL:-0}" = "1" ]; then mark_skip "$name" "user skipped (skip all)"; return 0; fi
  local ans f disp="${alt:-$name}"
  [ -n "$mnote" ] && info "$mnote"
  [ -n "$murl" ] && info "More info / download: $murl"
  info "Download the installer yourself (unzip it first if it is zipped)."
  info "Then type its path in single quotes -- either a full path, or one relative to ${TARGET_HOME}/Downloads."
  info "Any valid installer extension works (.deb/.rpm/.sh/.run/.bin/.bundle/.AppImage/.tar.gz/.zip/...); 'skip' to skip this app, or 'skip all' to skip this and every remaining manual app."
  if [ ! -r /dev/tty ]; then mark_manual "$name" "no package manager route - needs manual download"; return 0; fi
  while :; do
    printf "  %s ('installer path'/skip/skip all): " "$disp" > /dev/tty
    read -r ans < /dev/tty || ans="skip"
    case "$ans" in
      [Aa]|[Aa][Ll][Ll]|[Ss][Kk][Ii][Pp][Aa][Ll][Ll]|'skip all'|'Skip all'|'Skip All'|'SKIP ALL')
        MANUAL_FALLBACK_SKIP_ALL=1; mark_skip "$name" "user skipped (skip all)"; return 0 ;;
      [Ss]|[Ss][Kk][Ii][Pp]) mark_skip "$name" "user skipped"; return 0 ;;
      *)
        f="$(resolve_user_path "$ans")"
        if [ -z "$f" ] || [ ! -f "$f" ] || [ ! -r "$f" ]; then
          printf "\033[1;31m  No readable file at that path -- type the path in single quotes (e.g. '%s/Downloads/app.deb'), or skip.\033[0m\n" "$TARGET_HOME" > /dev/tty; continue
        fi
        LAST_ERR=""
        if install_by_ext "$f"; then mark_ok "$name" "installed from $f"; return 0
        else printf "\033[1;31m  %s -- fix the file and re-enter its path, or skip.\033[0m\n" "${LAST_ERR:-could not handle the file}" > /dev/tty; fi
        ;;
    esac
  done
}

# Install a non-cross-platform Windows app under wine (the Windows emulator), when the
# user opted in (MIGRATE_WINE_NONCROSS=yes). Tries the manifest-provided Windows
# installer URL first; on failure (or none) asks for the installer path in single
# quotes. After installing, scales the wine font/DPI to 2.5x (LogPixels 240) so the
# app is readable. Marks the result.
wine_app() {  # wine_app NAME [WINDOWS_INSTALLER_URL]
  [ "${MIGRATE_WINE_NONCROSS:-no}" = "yes" ] || return 0
  local name="$1" winurl="${2:-}" ans f winpath="" slug dir rc
  if [ "${WINE_SKIP_ALL:-0}" = "1" ]; then mark_skip "$name (wine - Windows emulator)" "user skipped (skip all)"; return 0; fi
  printf '\n\n\033[1;34m==> Install under wine (Windows emulator): %s\033[0m\n' "$name" >&3
  if ! ensure_wine; then mark_fail "$name (wine - Windows emulator)" "${LAST_ERR:-could not install wine}"; return 0; fi
  run_wine wineboot -u >/dev/null 2>&1 || true
  slug="$(slugify "$name")"; dir="${MIGRATE_MANUAL_DIR:-$DOWNLOAD_DIR/manual}/wine-$slug"; mkdir -p "$dir"
  # 1) auto-download the Windows installer if the manifest provided a URL.
  if [ -n "$winurl" ]; then
    f="$dir/${slug}-setup.exe"
    info "Downloading the Windows installer for $name (to run under wine - Windows emulator) ..."
    if capture download_file "$winurl" "$f"; then winpath="$f"
    else warn "automatic download failed -- you can provide the installer yourself."; fi
  fi
  # 2) manual fallback: ask for the installer path in single quotes.
  if [ -z "$winpath" ]; then
    if [ ! -r /dev/tty ]; then mark_manual "$name (wine - Windows emulator)" "provide a Windows installer to run under wine"; return 0; fi
    info "Download the Windows installer for $name (unzip it first if it is zipped)."
    info "Then type its path in single quotes -- either a full path, or one relative to ${TARGET_HOME}/Downloads."
    info "Any valid installer extension works (.exe, .msi, .bat, etc.); 'skip' to skip this app, or 'skip all' to skip every remaining wine (Windows emulator) install."
    while :; do
      printf "  %s ('installer path'/skip/skip all): " "$name" > /dev/tty
      read -r ans < /dev/tty || ans="skip"
      case "$ans" in
        [Aa]|[Aa][Ll][Ll]|[Ss][Kk][Ii][Pp][Aa][Ll][Ll]|'skip all'|'Skip all'|'Skip All'|'SKIP ALL')
          WINE_SKIP_ALL=1; mark_skip "$name (wine - Windows emulator)" "user skipped (skip all)"; return 0 ;;
        [Ss]|[Ss][Kk][Ii][Pp]) mark_skip "$name (wine - Windows emulator)" "user skipped"; return 0 ;;
        *)
          winpath="$(resolve_user_path "$ans")"
          if [ -n "$winpath" ] && [ -f "$winpath" ] && [ -r "$winpath" ]; then break
          else printf "\033[1;31m  No readable file at that path -- type the path in single quotes (e.g. '%s/Downloads/setup.exe'), or skip.\033[0m\n" "$TARGET_HOME" > /dev/tty; winpath=""; fi ;;
      esac
    done
  fi
  # 3) run the installer under wine (best-effort silent), then scale the font/DPI 2.5x.
  info "installing $name under wine (Windows emulator) ..."
  case "$winpath" in
    *.msi|*.MSI)             capture run_wine wine msiexec /i "$winpath" /qn ;;
    *.bat|*.BAT|*.cmd|*.CMD) capture run_wine wine cmd /c "$winpath" ;;
    *)                       capture run_wine wine "$winpath" /S ;;
  esac
  rc=$?
  # font size 2.5x: default wine DPI 96 -> 240 (LogPixels 0xF0), applied right after install.
  run_wine wine reg add 'HKEY_CURRENT_USER\Control Panel\Desktop' /v LogPixels /t REG_DWORD /d 0x000000F0 /f >/dev/null 2>&1 || true
  if [ "$rc" -eq 0 ]; then mark_ok "$name (wine - Windows emulator)" "installed under wine; font/DPI scaled to 2.5x (240)"
  else mark_fail "$name (wine - Windows emulator)" "${LAST_ERR:-wine install failed}"; fi
}

# Install the Nth-best alternative of an app only if the user asked for at least
# N alternatives (MIGRATE_ALT_LIMIT, default 1). Usage:  app_alt RANK install_app ...
app_alt() {
  local rank="$1"; shift
  local limit="${MIGRATE_ALT_LIMIT:-1}"
  case "$limit" in ''|*[!0-9]*) limit=1 ;; esac
  if [ "$rank" -le "$limit" ]; then "$@"; fi
  return 0
}

# Handle a user-downloaded installer FILE according to its extension. Returns 0 on
# success, 1 on failure (LAST_ERR holds a 1-line reason). Used by the manual phase.
install_by_ext() {  # install_by_ext FILE
  local f="$1"
  case "$f" in
    *.deb|*.rpm|*.pkg.tar.zst|*.pkg.tar.xz|*.pkg.tar)
      capture install_local_package "$f" ;;
    *.sh)
      chmod +x "$f" 2>/dev/null; capture bash "$f" ;;
    *.run|*.bin|*.bundle)
      chmod +x "$f" 2>/dev/null; capture "$f" ;;
    *.appimage|*.AppImage)
      chmod +x "$f" 2>/dev/null
      mkdir -p /opt/migrate_appimages
      if cp -f "$f" /opt/migrate_appimages/ 2>/dev/null; then return 0
      else LAST_ERR="could not place AppImage in /opt/migrate_appimages"; return 1; fi ;;
    *.tar.gz|*.tgz|*.tar.bz2|*.tbz2|*.tar.xz|*.txz|*.tar)
      mkdir -p "${f%/*}/extracted"
      capture tar -xf "$f" -C "${f%/*}/extracted" ;;
    *.zip)
      if ! have_cmd unzip; then LAST_ERR="unzip is not installed"; return 1; fi
      mkdir -p "${f%/*}/extracted"
      capture unzip -o "$f" -d "${f%/*}/extracted" ;;
    *)
      LAST_ERR="unsupported file type: .${f##*.}"; return 1 ;;
  esac
}

ensure_docker() {
  have_cmd docker && return 0
  pm_refresh
  case "$PM" in
    apt)    pm_install docker.io ;;
    dnf)    pm_install moby-engine || pm_install docker ;;
    zypper) pm_install docker ;;
    pacman) pm_install docker ;;
  esac
  have_cmd docker && systemctl enable --now docker 2>/dev/null
  have_cmd docker
}

# =============================================================================
#  DOCKER CONTAINER LAUNCHING  (apps whose Linux equivalent IS a container)
# -----------------------------------------------------------------------------
#  For each app with install.method=docker we pull the image, attach it to ONE
#  shared bridge network, and start a container with sensible defaults. Host
#  ports are taken from the image's EXPOSED ports and bumped by 1 on conflict.
#  If a container for the same image already exists, we just (re)start it instead
#  of creating a duplicate. These are NOT the images migrated from Windows Docker
#  (those are handled separately by docker_rebuild.sh).
# =============================================================================
DOCKER_NET="${DOCKER_NET:-migrate-bridge}"

ensure_docker_net() {
  docker network inspect "$DOCKER_NET" >/dev/null 2>&1 && return 0
  capture docker network create --driver bridge "$DOCKER_NET" >/dev/null 2>&1 || \
    docker network create --driver bridge "$DOCKER_NET" >/dev/null 2>&1
}

# Track host ports assigned during this run; combined with live listener checks.
_MIGRATE_PORTS_TAKEN=""
_port_in_use() {  # _port_in_use PORT
  local p="$1"
  case " $_MIGRATE_PORTS_TAKEN " in *" $p "*) return 0 ;; esac
  if have_cmd ss; then
    ss -ltnH 2>/dev/null | awk '{print $4}' | sed 's/.*[:.]//' | grep -qx "$p" && return 0
  elif have_cmd netstat; then
    netstat -ltn 2>/dev/null | awk 'NR>2{print $4}' | sed 's/.*[:.]//' | grep -qx "$p" && return 0
  fi
  return 1
}
_pick_port() {  # _pick_port DESIRED -> free host port (incrementing on conflict)
  local p="$1"
  [ -z "$p" ] && { printf ''; return 0; }
  while _port_in_use "$p"; do p=$((p + 1)); done
  _MIGRATE_PORTS_TAKEN="$_MIGRATE_PORTS_TAKEN $p"
  printf '%s' "$p"
}

# Human-readable "how to use" line derived from the container's published ports.
_docker_howto() {  # _docker_howto CONTAINER NOTE
  local c="$1" note="$2" hp howto
  hp="$(docker port "$c" 2>/dev/null | sed -n 's/.*:\([0-9]\{1,\}\)$/\1/p' | head -n1)"
  if [ -n "$hp" ]; then howto="open http://localhost:${hp} in your browser"
  else howto="attach with: docker exec -it ${c} sh"; fi
  howto="${howto}; start/stop with: docker start ${c} / docker stop ${c}"
  [ -n "$note" ] && howto="${howto} (${note})"
  printf '%s' "$howto"
}

# Record a launched container ONCE (one line per container, deduped by name).
_record_launched() {  # _record_launched WINAPP IMAGE CONTAINER NOTE
  local winapp="$1" image="$2" c="$3" note="$4"
  if [ -f "$DOCKER_LAUNCHED" ] && cut -f3 "$DOCKER_LAUNCHED" 2>/dev/null | grep -qx "$c"; then return 0; fi
  printf '%s\t%s\t%s\t%s\n' "$winapp" "$image" "$c" "$(_docker_howto "$c" "$note")" >> "$DOCKER_LAUNCHED"
}

docker_launch_app() {  # docker_launch_app WINAPP IMAGE NOTE
  local winapp="$1" image="$2" note="$3"
  [ -z "$image" ] && { mark_fail "$winapp" "no docker image specified"; return 0; }
  if ! ensure_docker; then mark_fail "$winapp" "docker is not available"; return 0; fi
  docker info >/dev/null 2>&1 || systemctl start docker 2>/dev/null || true

  # Stable container name derived from the image (so the SAME image always maps to
  # the SAME container -> reuse instead of duplicate).
  local base cname
  base="${image##*/}"; base="${base%%:*}"
  cname="migrate-$(slugify "$base")"

  # Already created (this run or a previous one)? Just start it if stopped; never
  # create a second container for the same image.
  if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$cname"; then
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$cname"; then
      info "container already running: $cname"
    else
      capture docker start "$cname" >/dev/null 2>&1 || docker start "$cname" >/dev/null 2>&1 || true
    fi
    _record_launched "$winapp" "$image" "$cname" "$note"
    mark_ok "$winapp" "using existing container: $cname"
    return 0
  fi

  if ! capture docker pull "$image"; then mark_fail "$winapp" "${LAST_ERR:-could not pull docker image $image}"; return 0; fi
  ensure_docker_net

  # Map each EXPOSED container port to a free host port (incrementing on conflict).
  local pflags="" ep cport hport
  for ep in $(docker image inspect --format '{{range $p,$_ := .Config.ExposedPorts}}{{$p}} {{end}}' "$image" 2>/dev/null); do
    cport="${ep%%/*}"
    [ -z "$cport" ] && continue
    hport="$(_pick_port "$cport")"
    [ -n "$hport" ] && pflags="$pflags -p ${hport}:${cport}"
  done

  # shellcheck disable=SC2086
  if capture docker run -d --name "$cname" --network "$DOCKER_NET" --restart unless-stopped $pflags "$image"; then
    _record_launched "$winapp" "$image" "$cname" "$note"
    mark_ok "$winapp" "container launched: $cname"
  else
    mark_fail "$winapp" "${LAST_ERR:-could not start container for $image}"
  fi
}

# Purple "Launched containers" section (one line per container). Printed at the end
# of a run by execute_all (orchestrated) or print_summary (standalone stage).
print_launched_containers() {
  local f="${DOCKER_LAUNCHED:-/tmp/migrate_to_linux_launched.tsv}"
  [ -s "$f" ] || return 0
  printf '\n' >&3
  printf '        \033[1;35m===== Launched containers =====\033[0m\n' >&3
  local winapp image cname howto
  while IFS="$(printf '\t')" read -r winapp image cname howto; do
    [ -z "$cname" ] && continue
    info "          ${winapp}  --> image:'${image}' | container: '${cname}' | How to use: ${howto}"
  done < "$f"
}
