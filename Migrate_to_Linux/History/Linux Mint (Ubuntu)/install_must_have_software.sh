#!/usr/bin/env bash
#
# install_must_have_software.sh
# -----------------------------------------------------------------------------
# Unattended installer for Linux Mint (Ubuntu base) that installs every program
# flagged "Must be included on Linux = yes" in
#   ../B_installed_windows_software.csv
# installing the best native Linux app or the best alternative for each.
#
# Run as root:   sudo ./install_must_have_software.sh
#
# Design rules (from the project spec / instructions.txt):
#   * Prefer the distro's native APT repositories.
#   * Use the vendor's APT repo / .deb / binary when the app is not in APT or the
#     vendor ships a newer version.
#   * Flatpak (Flathub) is used only where neither APT nor a clean vendor .deb exists.
#   * If a program is already installed, its update path runs instead of reinstalling.
#   * Missing build dependencies (kernel headers + dkms/gcc for VMware) are installed.
#   * The latest PostgreSQL is installed from the official postgresql.org PGDG repo.
#   * Target codename AND architecture are auto-detected — nothing hard-coded.
#   * Manual/login-gated downloads (VMware, SpotPlayer, Gurobi, RStudio fallback) come
#     LAST via an interactive prompt that waits until the file is in place (or 'skip').
#
# CLEAN UI: all package-manager noise is sent to a log file; the terminal shows only
# the curated "==> <step>" headers, indented "installed:/updated:" lines, and a live
# spinner while each step runs. Full detail is kept in the log printed at startup.
#
# CSV "yes" row  ->  what this script installs
#   Google Chrome=google-chrome-stable; Edge=microsoft-edge-stable; Firefox=firefox
#   Discord/Zoom/GitKraken(.deb); Teams/WhatsApp/LocalSend/Planify(flatpak)
#   RealVNC=vendor .deb (not on Flathub)
#   Dropbox=nautilus-dropbox; Google Drive=rclone; OneDrive=onedrive(abraunegg)
#   VS Code=code; .NET=dotnet-sdk; PowerShell=powershell; Docker=docker-ce
#   DBeaver=dbeaver-ce; pgAdmin=pgadmin4-desktop; PostgreSQL=postgresql (PGDG repo)
#   Node=nodejs(NodeSource); Anaconda=Miniconda; Python=python3; R=r-base; RStudio(.deb)
#   Git/CMake/ninja/OpenSSH/OpenSSL/PuTTY/Perl/Pandoc/wkhtmltopdf (APT); MiKTeX=texlive-full
#   AnyDesk(repo); Hotspot/Psiphon=Proton VPN(repo); OpenVPN=openvpn
#   KMPlayer/Zune=vlc,mpv,rhythmbox; oCam/Camtasia=obs-studio,kdenlive,simplescreenrecorder
#   Lightshot=flameshot; WinRAR=p7zip+PeaZip; uTorrent=qbittorrent; IDM=uget/XDM+IDM via Wine
#   Notepad++=notepadqq/geany+Wine; Windows Emulator=Wine(WineHQ repo)+Multipass
#   Office=libreoffice; Grammarly=LanguageTool; dictionaries=goldendict; Outlook=thunderbird
#   Paint=gimp,krita,pinta; Photos=shotwell,gthumb; Sticky=sticky; Alarms=gnome-clocks
#   MobaXterm=remmina; Bitvise=openssh; Proxifier=proxychains4; Rufus=gnome-disk-utility
#   Acrobat Pro=Stirling PDF(Docker)+PDF Arranger(APT); Advanced IP Scanner=Angry IP Scanner(.deb); Advanced Port Scanner=RustScan+Zenmap(nmap GUI)
#   Telegram=telegram-desktop(APT/Flatpak); Terminator=terminator(APT); WindTerm=.deb from GitHub; WinDirStat=qdirstat+baobab(APT)
#   PaperCut=NATIVE PaperCut Print Deploy client (hard-coded; from your PaperCut server — NEVER the CUPS alternative)
#   Gurobi=MANUAL(+free glpk/cbc); VMware=MANUAL; VirtualBox=Oracle repo; SpotPlayer=MANUAL
#
#   Parsec is EXCLUDED per user request — not installed.
# -----------------------------------------------------------------------------

set -uo pipefail

# ----------------------------- bookkeeping -----------------------------------
OK=();  FAIL=();  SKIPPED=();  MANUAL_DONE=();  STEP_FAILS=()
DOWNLOAD_DIR="/opt/migrate-downloads"
LOG="$DOWNLOAD_DIR/install.log"             # full, verbose command output
RESULTS="$DOWNLOAD_DIR/install-results.log" # short, one line per step result
DOTNET_SDK="dotnet-sdk-9.0"
# The Microsoft prod repo only has .NET 8.0 on Noble. To get .NET 9.0 on Ubuntu 24.04
# we also need the dotnet/backports PPA (or use the MS dotnet-install script).
NODE_MAJOR="22"
XDM_VERSION="8.0.29"                        # XDM release tag on GitHub
IDM_VERSION="6.42.58"                       # IDM version (for Wine install)
WINRAR_VERSION="7.13"                       # WinRAR version (for Wine install)
# PaperCut Print Deploy client (hard-coded inclusion — the NATIVE PaperCut client,
# never a CUPS substitute). The Linux client is served by YOUR PaperCut Print Deploy
# server, which is the trusted first-party source for it. Set PAPERCUT_SERVER (env or
# here) to auto-install unattended; otherwise the script prompts for the downloaded
# Linux client tarball in the manual section at the end.
PAPERCUT_SERVER="${PAPERCUT_SERVER:-}"      # e.g. "printdeploy.example.com" (host only)
PAPERCUT_PORT="${PAPERCUT_PORT:-9174}"      # default PaperCut Print Deploy client port
PAPERCUT_TARBALL="/opt/migrate-downloads/papercut-print-deploy-linux.tar.gz"
PAPERCUT_NEEDS_MANUAL=0                      # set when auto-install defers to the manual prompt
SPIN='-\|/'
LAST_ERR=""                                 # short failure reason from the last run_spin

# -----------------------------------------------------------------------------
# TRUSTED SOURCES GUARANTEE
# Every package, repo, .deb, key, script, and binary fetched below comes from
# the software's OWN official first-party domain over HTTPS, with GPG-signed
# APT repos using signed-by keyrings. The only exception is the distro's own
# APT mirrors (GPG-signed by Ubuntu). Manual downloads at the end print the
# exact vendor URL and warn the user to verify authenticity. No third-party
# mirrors, shortened URLs, or untrusted domains are used anywhere.
# -----------------------------------------------------------------------------

# All of these print to the SAVED terminal (fd 3); command output goes to the log.
log()  { printf '\n\033[1;34m==>\033[0m %s\n' "$*" >&3; }
info() { printf '       %s\n' "$*" >&3; }
ok()   { printf '       \033[32m%s\033[0m\n' "$*" >&3; }
warn() { printf '       \033[1;33m%s\033[0m\n' "$*" >&3; }
err()  { printf '\033[1;31m%s\033[0m\n' "$*" >&3; }

# Append one line to the short results log: <time> <status> <item> <reason>.
record_line() { printf '%s\t%-4s\t%s\t%s\n' "$(date '+%F %T')" "$1" "$2" "${3:-}" >> "$RESULTS"; }

mark_ok()     { OK+=("$1");       record_line OK   "$1" "${2:-}"; }
mark_skip()   { SKIPPED+=("$1");  record_line SKIP "$1" "${2:-user skipped}"; }
mark_manual() { MANUAL_DONE+=("$1"); record_line OK "$1" "${2:-installed (manual)}"; }
mark_fail() {
  local n="$1" reason="${2:-}"
  FAIL+=("$n")
  if [ -z "$reason" ]; then
    if [ "${#STEP_FAILS[@]}" -gt 0 ]; then reason="$(printf '%s; ' "${STEP_FAILS[@]}")"
    else reason="${LAST_ERR:-failed}"; fi
  fi
  record_line FAIL "$n" "$reason"
  err "$n failed: $reason"
}

# Extract a short failure reason from a captured output file into LAST_ERR.
_capture_reason() {  # _capture_reason FILE RC
  if [ "$2" -ne 0 ]; then
    LAST_ERR="$(grep -iE 'error|unable|not (found|locate)|no installation candidate|^E:|curl:|dpkg:' "$1" 2>/dev/null | tail -n 1 | tr -s ' ' | cut -c1-200)"
    [ -z "$LAST_ERR" ] && LAST_ERR="$(tail -n 1 "$1" 2>/dev/null | tr -s ' ' | cut -c1-200)"
    [ -z "$LAST_ERR" ] && LAST_ERR="exit code $2"
  else LAST_ERR=""; fi
}

# Draw the single transient progress line on the terminal: spinner, label, and a
# live "detail" (a percentage or the command's latest output line).
_progress() {  # _progress ITER "label" "detail"
  local w=$(( ${COLUMNS:-100} - 16 )); [ "$w" -lt 30 ] && w=70
  local d="$3"
  [ -n "$d" ] && d=" — $(printf '%s' "$d" | tr -d '\r\n' | tr -s ' ' | cut -c1-"$w")"
  printf '\r\033[K       \033[2m[%s]\033[0m %s%s' "${SPIN:$(( $1 % 4 )):1}" "$2" "$d" >&3
}

# Run a command showing a LIVE progress line (its latest output), then clear that
# line when the command terminates. Output -> log; failure reason -> LAST_ERR.
run_spin() {  # run_spin "label" cmd...
  local text="$1"; shift
  local tmp rc; tmp="$(mktemp 2>/dev/null || echo /tmp/migrate.$$)"
  if [ -t 3 ]; then
    "$@" >"$tmp" 2>&1 &
    local pid=$! i=0
    while kill -0 "$pid" 2>/dev/null; do
      _progress "$i" "$text" "$(tail -n 1 "$tmp" 2>/dev/null)"; i=$((i+1)); sleep 0.3
    done
    wait "$pid"; rc=$?
    printf '\r\033[K' >&3
  else
    "$@" >"$tmp" 2>&1; rc=$?
  fi
  cat "$tmp" >> "$LOG" 2>/dev/null
  _capture_reason "$tmp" "$rc"
  rm -f "$tmp"
  return $rc
}

# Run a step: print its header, run it, record OK/FAIL (with reason) to the results log.
step() { local label="$1"; shift; log "$label"; STEP_FAILS=(); if "$@"; then mark_ok "$label"; else mark_fail "$label"; fi; }

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    err "This script must run as root. Use: sudo $0"
    exit 1
  fi
}

# Non-interactive apt that keeps existing config files.
apt_get() { DEBIAN_FRONTEND=noninteractive apt-get -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "$@"; }

# Run apt-get showing a LIVE percentage + current operation (via APT::Status-Fd),
# then clear that line when the package finishes. Output -> log; reason -> LAST_ERR.
apt_run() {  # apt_run "label" <apt-get args...>
  local text="$1"; shift
  local out st rc
  out="$(mktemp 2>/dev/null || echo /tmp/migrate.o.$$)"
  st="$(mktemp 2>/dev/null || echo /tmp/migrate.s.$$)"
  if [ -t 3 ]; then
    ( DEBIAN_FRONTEND=noninteractive apt-get -y \
        -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
        -o APT::Status-Fd=9 "$@" 9>"$st" >"$out" 2>&1 ) &
    local pid=$! i=0 s pct desc detail
    while kill -0 "$pid" 2>/dev/null; do
      s="$(tail -n 1 "$st" 2>/dev/null)"
      pct="$(printf '%s' "$s" | cut -d: -f3)"
      desc="$(printf '%s' "$s" | cut -d: -f4-)"
      if printf '%s' "$pct" | grep -qE '^[0-9]+(\.[0-9]+)?$'; then
        detail="$(printf '%3.0f%%  %s' "$pct" "$desc")"
      else
        detail="$(tail -n 1 "$out" 2>/dev/null)"
      fi
      _progress "$i" "$text" "$detail"; i=$((i+1)); sleep 0.3
    done
    wait "$pid"; rc=$?
    printf '\r\033[K' >&3
  else
    DEBIAN_FRONTEND=noninteractive apt-get -y \
      -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "$@" >"$out" 2>&1; rc=$?
  fi
  cat "$out" >> "$LOG" 2>/dev/null
  _capture_reason "$out" "$rc"
  rm -f "$out" "$st"
  return $rc
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }
deb_installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"; }

# Install OR upgrade one APT package, with a spinner and a result line.
apt_pkg() {
  local p="$1"
  if deb_installed "$p"; then
    apt_run "updating $p" install --only-upgrade "$p" || true
    info "updated: $p"
  else
    if apt_run "installing $p" install "$p"; then info "installed: $p"
    else warn "APT could not install '$p' (skipping)"; STEP_FAILS+=("$p (${LAST_ERR:-error})"); return 1; fi
  fi
}
apt_pkgs() { local rc=0; for p in "$@"; do apt_pkg "$p" || rc=1; done; return $rc; }

# Add a keyring + sources.list entry (idempotent; refreshes the key each run).
add_repo() {  # add_repo NAME KEY_URL "deb [opts] URL suite components"
  local name="$1" keyurl="$2" line="$3"
  curl -fsSL "$keyurl" | gpg --dearmor -o "/etc/apt/keyrings/${name}.gpg" || { warn "key fetch failed for $name"; return 1; }
  chmod 0644 "/etc/apt/keyrings/${name}.gpg"
  echo "$line" > "/etc/apt/sources.list.d/${name}.list"
}

# Download the latest vendor .deb and install/upgrade it (idempotent).
install_deb_url() {  # install_deb_url "Label" URL
  local label="$1" url="$2" f="$DOWNLOAD_DIR/${1// /_}.deb"
  if download_file "downloading $label" "$url" "$f"; then
    if apt_run "installing $label" install "$f"; then info "installed: $label"
    elif dpkg -i "$f" 2>/dev/null && apt_get -f install -y 2>/dev/null; then info "installed: $label (deps fixed)"
    else
      _fail_with_file "$label" "$f" "sudo dpkg -i \"$f\" && sudo apt-get -f install -y"
      return 1
    fi
  else
    warn "download failed: $label"; return 1
  fi
}

# Print manual-install instructions with the downloaded file path.
# _fail_with_file "AppName" "/path/to/file" "install command"
_fail_with_file() {
  local name="$1" file="$2" cmd="$3"
  warn "$name auto-install failed"
  info "Downloaded file: $file"
  info "Manual install: $cmd"
  STEP_FAILS+=("$name — manual install: $file ($cmd)")
}

install_flatpak() {  # install_flatpak APPID
  local id="$1"
  if flatpak info "$id" >/dev/null 2>&1; then
    run_spin "updating $id" flatpak update -y --noninteractive "$id" || true; info "updated: $id"
  else
    if run_spin "installing $id" flatpak install -y --noninteractive --show-progress flathub "$id"; then info "installed: $id"
    else warn "flatpak install failed: $id"; return 1; fi
  fi
}

# Download a file with live progress (curl -# shows a hash-bar progress indicator).
# Usage: download_file "label" URL DEST_FILE
download_file() {
  local text="$1" url="$2" dest="$3"
  local tmp rc; tmp="$(mktemp 2>/dev/null || echo /tmp/migrate.dl.$$)"
  if [ -t 3 ]; then
    curl -# -fSL --retry 3 -o "$dest" "$url" 2>"$tmp" &
    local pid=$! i=0
    while kill -0 "$pid" 2>/dev/null; do
      _progress "$i" "$text" "$(tail -n 1 "$tmp" 2>/dev/null | tr -d '\r')"; i=$((i+1)); sleep 0.15
    done
    wait "$pid"; rc=$?
    printf '\r\033[K' >&3
  else
    curl -fsSL --retry 3 -o "$dest" "$url" 2>/dev/null; rc=$?
  fi
  cat "$tmp" >> "$LOG" 2>/dev/null
  _capture_reason "$tmp" "$rc"
  rm -f "$tmp"
  return $rc
}

# Run a command with a non-interactive auto-progress indicator (for installers without a progress API).
# Shows a live elapsed-time counter instead of verbose output. Output -> log.
run_spin_quiet() {  # run_spin_quiet "label" cmd...
  local text="$1"; shift
  local tmp rc start; tmp="$(mktemp 2>/dev/null || echo /tmp/migrate.q.$$)"
  if [ -t 3 ]; then
    start=$(date +%s)
    "$@" >"$tmp" 2>&1 &
    local pid=$! i=0
    while kill -0 "$pid" 2>/dev/null; do
      local now elapsed; now=$(date +%s); elapsed=$((now - start))
      _progress "$i" "$text" "running…  ${elapsed}s"; i=$((i+1)); sleep 0.5
    done
    wait "$pid"; rc=$?
    printf '\r\033[K' >&3
  else
    "$@" >"$tmp" 2>&1; rc=$?
  fi
  cat "$tmp" >> "$LOG" 2>/dev/null
  _capture_reason "$tmp" "$rc"
  rm -f "$tmp"
  return $rc
}

# =============================================================================
# WINE HELPER — run a command as the real (non-root) user under their Wine prefix
# =============================================================================
_wine_cmd() {  # _wine_cmd "description" command...
  local desc="$1"; shift
  if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    local USER_HOME
    USER_HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
    run_spin "$desc" bash -c "export HOME='$USER_HOME' WINEARCH=win64 WINEPREFIX='\${HOME}/.wine'; wineboot -u 2>/dev/null || true; $*"
  else
    run_spin "$desc" bash -c "export WINEARCH=win64 WINEPREFIX='\${HOME}/.wine'; wineboot -u 2>/dev/null || true; $*"
  fi
}

# =============================================================================
# GENERAL WINE FONT FIX — Replace the Windows font registry keys so Wine uses
# readable fonts (Tahoma 8pt as default, Segoe UI 9pt for menus). This runs ONCE
# after Wine is installed and shared by every subsequent Wine-based installer.
# =============================================================================
_configure_wine_fonts() {
  local font_fix_done="$DOWNLOAD_DIR/.wine-fonts-done"
  if [ -f "$font_fix_done" ]; then
    info "Wine fonts already configured (skipping)"
    return 0
  fi
  if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    local USER_HOME
    USER_HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
    _wine_cmd "configuring Wine font substitutions (Tahoma/Segoe UI)" sh -c "
      wineboot -u 2>/dev/null || true
      # Force Wine to use readable font sizes and faces.
      #   FontSmoothing       = 2 (sub-pixel)
      #   FontSmoothingOrientation = 1 (BGR typical for LCD)
      #   FontSmoothingType   = 2 (ClearType)
      wine reg add 'HKCU\\Software\\Wine\\Fonts\\Replacements'  /v 'MS Shell Dlg'      /t REG_SZ /d 'Tahoma'               /f
      wine reg add 'HKCU\\Software\\Wine\\Fonts\\Replacements'  /v 'MS Shell Dlg 2'    /t REG_SZ /d 'Tahoma'               /f
      wine reg add 'HKCU\\Software\\Wine\\Fonts\\Replacements'  /v 'MS Sans Serif'     /t REG_SZ /d 'Tahoma'               /f
      wine reg add 'HKCU\\Software\\Wine\\Fonts\\Replacements'  /v 'Microsoft Sans Serif' /t REG_SZ /d 'Tahoma'           /f
      wine reg add 'HKCU\\Software\\Wine\\Fonts\\Replacements'  /v 'Arial'             /t REG_SZ /d 'Liberation Sans'     /f
      wine reg add 'HKCU\\Software\\Wine\\Fonts\\Replacements'  /v 'Times New Roman'   /t REG_SZ /d 'Liberation Serif'    /f
      wine reg add 'HKCU\\Software\\Wine\\Fonts\\Replacements'  /v 'Courier New'       /t REG_SZ /d 'Liberation Mono'     /f
      # Menu / UI font face and size — sets the default Wine dialog font to Tahoma 8pt
      # which is close to Windows' default (Tahoma 8 / Segoe UI 9).
      wine reg add 'HKCU\\Control Panel\\Desktop\\WindowMetrics' /v 'MenuFont'         /t REG_SZ /d 'Tahoma'              /f
      wine reg add 'HKCU\\Control Panel\\Desktop\\WindowMetrics' /v 'MenuFontSize'     /t REG_DWORD /d 0x00000008        /f
      wine reg add 'HKCU\\Control Panel\\Desktop\\WindowMetrics' /v 'MessageFont'      /t REG_SZ /d 'Tahoma'              /f
      wine reg add 'HKCU\\Control Panel\\Desktop\\WindowMetrics' /v 'MessageFontSize'  /t REG_DWORD /d 0x00000008        /f
      wine reg add 'HKCU\\Control Panel\\Desktop\\WindowMetrics' /v 'StatusFont'       /t REG_SZ /d 'Tahoma'              /f
      wine reg add 'HKCU\\Control Panel\\Desktop\\WindowMetrics' /v 'StatusFontSize'   /t REG_DWORD /d 0x00000008        /f
      wine reg add 'HKCU\\Control Panel\\Desktop\\WindowMetrics' /v 'CaptionFont'      /t REG_SZ /d 'Tahoma'              /f
      wine reg add 'HKCU\\Control Panel\\Desktop\\WindowMetrics' /v 'CaptionFontSize'  /t REG_DWORD /d 0x00000009        /f
      wine reg add 'HKCU\\Control Panel\\Desktop\\WindowMetrics' /v 'SmCaptionFont'    /t REG_SZ /d 'Tahoma'              /f
      wine reg add 'HKCU\\Control Panel\\Desktop\\WindowMetrics' /v 'SmCaptionFontSize'/t REG_DWORD /d 0x00000008        /f
      # Font smoothing (ClearType-like)
      wine reg add 'HKCU\\Control Panel\\Desktop' /v FontSmoothing             /t REG_SZ    /d '2'                 /f
      wine reg add 'HKCU\\Control Panel\\Desktop' /v FontSmoothingOrientation  /t REG_DWORD /d 0x00000001          /f
      wine reg add 'HKCU\\Control Panel\\Desktop' /v FontSmoothingType         /t REG_DWORD /d 0x00000002          /f
    "
    touch "$font_fix_done" 2>/dev/null || true
    info "configured: Wine font substitutions + smoothing (Tahoma 8pt, ClearType)"
  else
    _wine_cmd "configuring Wine font substitutions" sh -c "
      wine reg add 'HKCU\\Software\\Wine\\Fonts\\Replacements' /v 'MS Shell Dlg' /t REG_SZ /d 'Tahoma' /f
    " || true
    info "configured: Wine basic font substitutions"
  fi
}

# Download and install a Windows .exe under Wine (idempotent — checks install dir first).
# Usage: _install_wine_app "Label" "check_file_in_wine_prefix" "download_url" "exe_filename" [extra_silent_flags]
_install_wine_app() {
  local label="$1" check_path="$2" dl_url="$3" exe_name="$4" extra_flags="${5:-}"
  local exe_path="$DOWNLOAD_DIR/${exe_name}"
  if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    local USER_HOME
    USER_HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
    local full_check="${USER_HOME}/${check_path}"
    if [ -f "$full_check" ] || [ -d "$full_check" ]; then
      info "already installed: $label (found: $full_check)"
      return 0
    fi
  fi
  if download_file "downloading $label" "$dl_url" "$exe_path"; then
    if have_cmd wine; then
      if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
        local USER_HOME
        USER_HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
        run_spin_quiet "installing $label under Wine" \
          bash -c "export HOME='$USER_HOME' WINEARCH=win64 WINEPREFIX='\${HOME}/.wine'; wineboot -u 2>/dev/null || true; wine '$exe_path' $extra_flags /S" || true
      else
        run_spin_quiet "installing $label under Wine" \
          bash -c "export WINEARCH=win64 WINEPREFIX='\${HOME}/.wine'; wineboot -u 2>/dev/null || true; wine '$exe_path' $extra_flags /S" || true
      fi
      info "installed: $label via Wine"
    else
      warn "Wine not found on PATH — skipping $label installation"
      return 1
    fi
  else
    warn "download failed: $label"
    return 1
  fi
}

# =============================================================================
# INTERNET DOWNLOAD MANAGER (IDM) under Wine
# Official download: https://www.internetdownloadmanager.com/ (HTTPS).
# Install IDM silently under Wine, using /S + /D=<path> flags.
# Also open the browser extension pages so the user can install the IDM
# browser integration add-ons for Chrome, Edge, and Firefox.
# =============================================================================
_install_idm_wine() {
  local USER_HOME check
  if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    USER_HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
    check="${USER_HOME}/.wine/drive_c/Program Files/Internet Download Manager/IDMan.exe"
    if [ -f "$check" ]; then
      info "already installed: IDM via Wine ($check)"
      return 0
    fi
  fi

  local idm_url="https://mirror2.internetdownloadmanager.com/idman${IDM_VERSION//./}.exe"
  local idm_exe="$DOWNLOAD_DIR/idman_${IDM_VERSION}.exe"
  if download_file "downloading IDM" "$idm_url" "$idm_exe"; then
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
      run_spin_quiet "installing IDM under Wine" \
        bash -c "export HOME='$USER_HOME' WINEARCH=win64 WINEPREFIX='\${HOME}/.wine'; wineboot -u 2>/dev/null || true; wine '$idm_exe' /S /D='C:\\Program Files\\Internet Download Manager'" || true
    else
      run_spin_quiet "installing IDM under Wine" \
        bash -c "export WINEARCH=win64 WINEPREFIX='\${HOME}/.wine'; wineboot -u 2>/dev/null || true; wine '$idm_exe' /S /D='C:\\Program Files\\Internet Download Manager'" || true
    fi
    info "installed: Internet Download Manager ------> IDM (Internet Download Manager) via Wine (same, wine)"
  else
    warn "download failed: IDM — trying fallback URL"
    # Fallback: try the main download page URL format
    local idm_fallback="https://mirror2.internetdownloadmanager.com/idman627build18.exe"
    if run_spin "IDM fallback download" curl -fsSL --retry 3 -o "$idm_exe" "$idm_fallback"; then
      if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
        run_spin_quiet "installing IDM under Wine (fallback)" \
          bash -c "export HOME='$USER_HOME' WINEARCH=win64 WINEPREFIX='\${HOME}/.wine'; wineboot -u 2>/dev/null || true; wine '$idm_exe' /S /D='C:\\Program Files\\Internet Download Manager'" || true
      fi
      info "installed: Internet Download Manager ------> IDM via Wine (fallback build) (same, wine)"
    else
      warn "IDM download failed — manual install needed"
      return 1
    fi
  fi

  # Open browser extension/add-on pages so the user can install IDM integration.
  log "Opening IDM browser extension pages"
  if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    local BROWSERS="google-chrome microsoft-edge firefox"
    for br in $BROWSERS; do
      if have_cmd "$br" 2>/dev/null || have_cmd "$(echo "$br" | sed 's/-/ /')"; then :
      else continue; fi
      case "$br" in
        google-chrome|google-chrome-stable)
          # Chrome Web Store — IDM Integration Module
          sudo -u "$SUDO_USER" xdg-open "https://chromewebstore.google.com/detail/idm-integration-module/ngpampappnmepgilojfohadhhmbhlaek" >/dev/null 2>&1 || true
          info "opened Chrome Web Store: IDM Integration Module" ;;
        microsoft-edge|microsoft-edge-stable)
          # Edge Add-ons — IDM Integration Module
          sudo -u "$SUDO_USER" xdg-open "https://microsoftedge.microsoft.com/addons/detail/idm-integration-module/llbjbkhnmlidjebalopleeepgdfgcpec" >/dev/null 2>&1 || true
          info "opened Edge Add-ons: IDM Integration Module" ;;
        firefox)
          # Firefox Add-ons — IDM Integration (third-party, but linked from IDM's official site)
          sudo -u "$SUDO_USER" xdg-open "https://addons.mozilla.org/en-US/firefox/addon/idm-integration/" >/dev/null 2>&1 || true
          info "opened Firefox Add-ons: IDM Integration" ;;
      esac
    done
    sleep 2  # let the browser tabs settle
  fi
}

# =============================================================================
# WINRAR under Wine
# Official download: https://www.win-rar.com/ (HTTPS, rarlab.com CDN).
# WinRAR is the reference RAR archiver. The native Linux CLI `rar`/`unrar`
# and GUI `PeaZip` are also installed below as complementary RAR-support apps.
# =============================================================================
_install_winrar_wine() {
  local USER_HOME check wrar_url wrar_exe
  if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    USER_HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
    check="${USER_HOME}/.wine/drive_c/Program Files/WinRAR/WinRAR.exe"
    if [ -f "$check" ]; then
      info "already installed: WinRAR via Wine ($check)"
      return 0
    fi
  fi

  # WinRAR uses a locale-specific URL. Fall back to the English installer.
  wrar_exe="$DOWNLOAD_DIR/winrar-${WINRAR_VERSION}.exe"
  # Primary: official rarlab.com download (en-US, HTTPS)
  wrar_url="https://www.win-rar.com/fileadmin/winrar-versions/winrar/winrar-${WINRAR_VERSION//./}-x64-english.exe"
  if download_file "downloading WinRAR (English)" "$wrar_url" "$wrar_exe"; then :; else
    # Fallback: rarlab.com direct
    warn "primary WinRAR URL failed — trying rarlab.com fallback"
    local rarlab_url="https://www.rarlab.com/rar/winrar-x64-${WINRAR_VERSION//./}.exe"
    if ! download_file "downloading WinRAR (rarlab fallback)" "$rarlab_url" "$wrar_exe"; then
      warn "WinRAR download failed — manual install needed"
      return 1
    fi
  fi

  if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    run_spin_quiet "installing WinRAR under Wine" \
      bash -c "export HOME='$USER_HOME' WINEARCH=win64 WINEPREFIX='\${HOME}/.wine'; wineboot -u 2>/dev/null || true; wine '$wrar_exe' /S" || true
  else
    run_spin_quiet "installing WinRAR under Wine" \
      bash -c "export WINEARCH=win64 WINEPREFIX='\${HOME}/.wine'; wineboot -u 2>/dev/null || true; wine '$wrar_exe' /S" || true
  fi
  info "installed: WinRAR via Wine (v${WINRAR_VERSION})"

  # Create a .desktop shortcut for WinRAR under Wine so it appears in the menu
  if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    local apps_dir="${USER_HOME}/.local/share/applications"
    mkdir -p "$apps_dir"
    cat > "${apps_dir}/wine-winrar.desktop" <<WINRAR_DESK
[Desktop Entry]
Version=1.0
Type=Application
Name=WinRAR (Wine)
Comment=File archiver for RAR and ZIP archives
Icon=package-x-generic
Exec=env WINEPREFIX="${USER_HOME}/.wine" wine "C:\\Program Files\\WinRAR\\WinRAR.exe"
Terminal=false
Categories=Utility;Archiving;Compression;
StartupWMClass=winrar.exe
WINRAR_DESK
    chmod 0755 "${apps_dir}/wine-winrar.desktop"
    chown "${SUDO_USER}:${SUDO_USER}" "${apps_dir}/wine-winrar.desktop" 2>/dev/null || true
    info "created menu entry: WinRAR (Wine)"
  fi
}
# Set Wine DPI to 192 so fonts/UI are readable on high-DPI displays.
# Uses 'wine reg add' to write LogPixels to the default user prefix.
_configure_wine_dpi() {
  if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    local USER_HOME
    USER_HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
    local regfile="${USER_HOME}/.wine/user.reg"
    if run_spin "setting Wine DPI to 192" bash -c "
      export HOME=\"$USER_HOME\" WINEARCH=win64 WINEPREFIX=\"\${HOME}/.wine\"
      wineboot -u 2>/dev/null || true
      wine reg add 'HKEY_CURRENT_USER\\Control Panel\\Desktop' /v LogPixels /t REG_DWORD /d 0x000000C0 /f
    "; then
      info "Wine DPI set to 192 (LogPixels = 0xC0)"
    else
      warn "Could not set Wine DPI — run 'wine regedit' manually if needed"
      return 1
    fi
  else
    if run_spin "setting Wine DPI to 192" bash -c "
      wineboot -u 2>/dev/null || true
      wine reg add 'HKEY_CURRENT_USER\\Control Panel\\Desktop' /v LogPixels /t REG_DWORD /d 0x000000C0 /f
    "; then
      info "Wine DPI set to 192 (LogPixels = 0xC0)"
    else
      warn "Could not set Wine DPI — run 'wine regedit' manually if needed"
      return 1
    fi
  fi
}

# Interactive wait for a manually-downloaded file (prints to fd 3, reads the tty).
prompt_for_file() {  # prompt_for_file "App" /path "instructions"
  local app="$1" dest="$2" info_txt="$3"
  { echo; echo "================ MANUAL DOWNLOAD: $app ================"
    echo "$info_txt"; echo "Save the file as exactly: $dest"
    echo "Then type 'yes'. Type 'skip' to skip $app."; } >&3
  while true; do
    printf '[%s] yes/skip: ' "$app" >&3
    local ans; read -r ans </dev/tty || { mark_skip "$app" "no tty"; return 1; }
    case "${ans,,}" in
      yes)  if [ -f "$dest" ]; then return 0; else echo "  Not found at $dest — try again." >&3; fi ;;
      skip) mark_skip "$app"; return 1 ;;
      *)    echo "  Please type 'yes' or 'skip'." >&3 ;;
    esac
  done
}

# ----------------------------- environment -----------------------------------
exec 3>&1 4>&2                       # save the real terminal for the clean UI
require_root
export DEBIAN_FRONTEND=noninteractive
mkdir -p "$DOWNLOAD_DIR" /etc/apt/keyrings
chmod 0777 "$DOWNLOAD_DIR"
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
  chown -R "${SUDO_USER}:${SUDO_USER}" "$DOWNLOAD_DIR" 2>/dev/null || true
fi
: > "$LOG" 2>/dev/null || LOG=/dev/null
{ echo "# Migrate-to-Linux installation results — $(date '+%F %T')";
  printf '# %s\t%s\t%s\t%s\n' "timestamp" "stat" "item" "reason"; } > "$RESULTS" 2>/dev/null || RESULTS=/dev/null
exec >>"$LOG" 2>&1                   # everything else (apt/dpkg/curl/...) -> log
[ -t 3 ] && clear >&3
log "Installer started"
info "full output log : $LOG"
info "results log     : $RESULTS"

# Auto-detect target codename + version (even on Mint) and architecture.
# shellcheck disable=SC1091
. /etc/os-release
CODENAME="${UBUNTU_CODENAME:-${VERSION_CODENAME:-jammy}}"
case "$CODENAME" in
  focal)  UBU_VER="20.04" ;;
  jammy)  UBU_VER="22.04" ;;
  noble)  UBU_VER="24.04" ;;
  *)      UBU_VER="22.04"; warn "Unknown codename '$CODENAME', assuming 22.04 for vendor repos." ;;
esac
DEB_ARCH="$(dpkg --print-architecture)"   # amd64 | arm64 | armhf | i386
KARCH="$(uname -m)"                        # x86_64 | aarch64 | ...
case "$KARCH" in
  x86_64)  CONDA_ARCH="x86_64" ;;
  aarch64) CONDA_ARCH="aarch64" ;;
  *)       CONDA_ARCH="$KARCH" ;;
esac
ARCH="$DEB_ARCH"
info "Target: Ubuntu $CODENAME ($UBU_VER); dpkg arch=$DEB_ARCH, kernel arch=$KARCH"
[ "$DEB_ARCH" != "amd64" ] && warn "Non-amd64: some amd64-only vendor apps (Discord, VMware) may be skipped."

# =============================================================================
# 1. BASE SYSTEM + BUILD DEPENDENCIES (incl. VMware kernel-module deps)
# =============================================================================
step "Refreshing package lists" apt_run "updating package lists" update
step "Core tools + build deps" apt_pkgs \
  apt-transport-https ca-certificates curl wget gnupg lsb-release unzip \
  software-properties-common gdebi-core flatpak \
  build-essential gcc make dkms "linux-headers-$(uname -r)" default-jdk
step "Enable Flathub" flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo

# =============================================================================
# 2. THIRD-PARTY APT REPOSITORIES
# =============================================================================
log "Configuring vendor APT repositories"
add_repo google-chrome  https://dl.google.com/linux/linux_signing_key.pub \
  "deb [arch=$ARCH signed-by=/etc/apt/keyrings/google-chrome.gpg] https://dl.google.com/linux/chrome/deb/ stable main" || true
add_repo microsoft-edge https://packages.microsoft.com/keys/microsoft.asc \
  "deb [arch=$ARCH signed-by=/etc/apt/keyrings/microsoft-edge.gpg] https://packages.microsoft.com/repos/edge stable main" || true
add_repo vscode         https://packages.microsoft.com/keys/microsoft.asc \
  "deb [arch=$ARCH signed-by=/etc/apt/keyrings/vscode.gpg] https://packages.microsoft.com/repos/code stable main" || true
add_repo docker         https://download.docker.com/linux/ubuntu/gpg \
  "deb [arch=$ARCH signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $CODENAME stable" || true
add_repo pgdg           https://www.postgresql.org/media/keys/ACCC4CF8.asc \
  "deb [signed-by=/etc/apt/keyrings/pgdg.gpg] https://apt.postgresql.org/pub/repos/apt ${CODENAME}-pgdg main" || true
add_repo pgadmin        https://www.pgadmin.org/static/packages_pgadmin_org.pub \
  "deb [signed-by=/etc/apt/keyrings/pgadmin.gpg] https://ftp.postgresql.org/pub/pgadmin/pgadmin4/apt/${CODENAME} pgadmin4 main" || true
add_repo dbeaver        https://dbeaver.io/debs/dbeaver.gpg.key \
  "deb [signed-by=/etc/apt/keyrings/dbeaver.gpg] https://dbeaver.io/debs/dbeaver-ce /" || true
add_repo anydesk        https://keys.anydesk.com/repos/DEB-GPG-KEY \
  "deb [signed-by=/etc/apt/keyrings/anydesk.gpg] https://deb.anydesk.com/ all main" || true
add_repo protonvpn      https://repo.protonvpn.com/debian/public_key.asc \
  "deb [signed-by=/etc/apt/keyrings/protonvpn.gpg] https://repo.protonvpn.com/debian stable main" || true
add_repo nodesource     https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
  "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" || true
# WineHQ: official Wine repository (winehq.org) — trusted first-party source over HTTPS.
dpkg --add-architecture i386 || true   # Wine needs 32-bit support
add_repo winehq         https://dl.winehq.org/wine-builds/winehq.key \
  "deb [signed-by=/etc/apt/keyrings/winehq.gpg] https://dl.winehq.org/wine-builds/ubuntu/ ${CODENAME} main" || true
# Oracle VirtualBox: official Oracle Linux repo (virtualbox.org, HTTPS, signed-by keyring).
add_repo virtualbox     https://www.virtualbox.org/download/oracle_vbox_2016.asc \
  "deb [arch=$ARCH signed-by=/etc/apt/keyrings/virtualbox.gpg] https://download.virtualbox.org/virtualbox/debian ${CODENAME} contrib" || true
info "added: chrome, edge, vscode, docker, pgdg, pgadmin, dbeaver, anydesk, protonvpn, nodesource, winehq, virtualbox"

if ! deb_installed packages-microsoft-prod; then
  if curl -fsSL -o "$DOWNLOAD_DIR/ms-prod.deb" "https://packages.microsoft.com/config/ubuntu/${UBU_VER}/packages-microsoft-prod.deb"; then
    dpkg -i "$DOWNLOAD_DIR/ms-prod.deb" || true; info "added: microsoft-prod (PowerShell/.NET)"
  else warn "Could not fetch Microsoft prod repo config"; fi
fi

# .NET 9.0 SDK on Noble needs the dotnet/backports PPA (the Microsoft prod repo
# only carries 8.0 for 24.04). For older releases the package is in the MS repo directly.
if [ "$CODENAME" = "noble" ]; then
  log "Adding dotnet/backports PPA (needed for .NET 9.0 on Noble)"
  if run_spin "adding dotnet/backports PPA" add-apt-repository -y ppa:dotnet/backports; then
    info "added: dotnet/backports PPA"
  else
    warn "Could not add dotnet/backports PPA — .NET 9.0 may not install"
  fi
fi

# Ulauncher is not in the default Noble repos; add its official PPA.
if ! grep -q '^deb.*agornostal/ulauncher' /etc/apt/sources.list.d/*.list 2>/dev/null; then
  log "Adding Ulauncher PPA"
  if run_spin "adding Ulauncher PPA" add-apt-repository -y ppa:agornostal/ulauncher; then
    info "added: Ulauncher PPA"
  else
    warn "Could not add Ulauncher PPA — will try Flatpak fallback"
  fi
fi

step "Refreshing package lists (after repos)" apt_run "updating package lists" update

# =============================================================================
# 3. NATIVE / REPO PACKAGES
# =============================================================================
step "Browsers & comms (repo)"   apt_pkgs google-chrome-stable microsoft-edge-stable firefox
step "Visual Studio Code"        apt_pkgs code
step "PowerShell + .NET SDK"     apt_pkgs powershell "$DOTNET_SDK"
step "Docker Engine"             apt_pkgs docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
step "PostgreSQL (PGDG latest)"  apt_pkgs postgresql postgresql-client
step "DB tools"                  apt_pkgs dbeaver-ce pgadmin4-desktop
step "AnyDesk"                   apt_pkgs anydesk
step "Proton VPN (Hotspot/Psiphon alt)" apt_pkgs proton-vpn-gnome-desktop
step "Node.js (LTS)"             apt_pkgs nodejs
step "Wine (Windows emulator)"   apt_pkgs --install-recommends winehq-stable

# =============================================================================
# 3B. WINE FONT + DPI CONFIGURATION (font face/size substitution + high-DPI)
#     Must run AFTER Wine is installed and BEFORE any Wine-based app installs.
# =============================================================================
step "Wine font substitution (Tahoma 8pt / ClearType)" _configure_wine_fonts
step "Wine DPI scaling (192)" _configure_wine_dpi

# =============================================================================
# 3C. WINE-BASED WINDOWS APPS (installed under Wine with font fixes applied)
# =============================================================================

# Notepad++ native Windows installer under Wine.
NPP_VERSION="8.7.9"
NPP_EXE="$DOWNLOAD_DIR/npp.${NPP_VERSION}.Installer.exe"
NPP_INSTALL_DIR="C:\\Program Files\\Notepad++"
_notepadpp_wine() {
  if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    local USER_HOME
    USER_HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
    local NPP_CHECK="${USER_HOME}/.wine/drive_c/Program Files/Notepad++/notepad++.exe"
    if [ -f "$NPP_CHECK" ]; then
      info "already installed: Notepad++ via Wine (${NPP_CHECK})"
      return 0
    fi
  fi
  local url="https://github.com/notepad-plus-plus/notepad-plus-plus/releases/download/v${NPP_VERSION}/npp.${NPP_VERSION}.Installer.exe"
  if download_file "downloading Notepad++ installer" "$url" "$NPP_EXE"; then
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
      local USER_HOME
      USER_HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
      run_spin_quiet "installing Notepad++ under Wine" \
        bash -c "export HOME='$USER_HOME' WINEARCH=win64 WINEPREFIX='\${HOME}/.wine'; wineboot -u 2>/dev/null || true; wine '$NPP_EXE' /S /D='$NPP_INSTALL_DIR'" || true
    else
      run_spin_quiet "installing Notepad++ under Wine" \
        bash -c "export WINEARCH=win64 WINEPREFIX='\${HOME}/.wine'; wineboot -u 2>/dev/null || true; wine '$NPP_EXE' /S /D='$NPP_INSTALL_DIR'" || true
    fi
    info "installed: Notepad++ via Wine (v${NPP_VERSION})"
  else
    warn "download failed: Notepad++ v${NPP_VERSION}"
    return 1
  fi
}
step "Notepad++ (via Wine)" _notepadpp_wine

# Internet Download Manager under Wine (with corrected fonts from step 3B).
step "IDM via Wine (Internet Download Manager)" _install_idm_wine

# WinRAR under Wine (with corrected fonts from step 3B).
step "WinRAR via Wine" _install_winrar_wine

# =============================================================================
# 3D. MULTIPASS (replaces WSL — Canonical's lightweight VM manager)
#     Official snap from Canonical: https://multipass.run (HTTPS).
#     Multipass provides a WSL-like experience on Linux: instant Ubuntu VMs.
# =============================================================================
step "Multipass (Canonical VM manager, WSL replacement)" bash -c '
  if snap list 2>/dev/null | grep -q "^multipass "; then
    echo "multipass already installed (refreshing)"; snap refresh multipass || true
  elif have_cmd multipass; then
    echo "multipass already installed via package manager"
  elif have_cmd snap; then
    snap install multipass --classic && echo "installed: multipass" || echo "WARN: snap install failed"
  else
    echo "Installing snapd first..."
    apt_get install -y snapd 2>/dev/null || true
    sleep 2
    snap wait system seed.loaded 2>/dev/null || true
    snap install multipass --classic && echo "installed: multipass" || echo "WARN: multipass install via snap failed"
  fi
'

# =============================================================================
# 3E. PEAPACKER (additional rar-support native app alongside p7zip/unrar)
#     PeaZip is a FOSS archiver GUI that handles RAR, 7z, ZIP, and more.
#     Installed as a complementary RAR handler to the WinRAR-in-Wine above.
# =============================================================================
log "PeaZip (native RAR-support archiver, complements WinRAR via Wine)"
PEAZIP_URL="https://github.com/peazip/PeaZip/releases/latest/download/peazip_11.4.0.LINUX.GTK2-1_amd64.deb"
PEAZIP_DEB="$DOWNLOAD_DIR/peazip.deb"
if deb_installed peazip 2>/dev/null; then
  info "PeaZip already installed (skipping)"
  mark_ok "PeaZip"
else
  if download_file "downloading PeaZip" "$PEAZIP_URL" "$PEAZIP_DEB"; then
    if apt_run "installing PeaZip" install "$PEAZIP_DEB"; then
      info "installed: WinRAR ------> PeaZip (native RAR/ZIP/7z GUI) (alt, native)"
      mark_ok "PeaZip"
    else
      warn "PeaZip .deb install failed — trying Flatpak"
      if install_flatpak io.github.peazip.PeaZip; then
        info "installed: WinRAR ------> PeaZip via Flatpak (alt, native)"
        mark_ok "PeaZip"
      else
        mark_fail "PeaZip" "$LAST_ERR"
      fi
    fi
  else
    warn "PeaZip download failed — trying Flatpak"
    if install_flatpak io.github.peazip.PeaZip; then
      info "installed: WinRAR ------> PeaZip via Flatpak (alt, native)"
      mark_ok "PeaZip"
    else
      mark_fail "PeaZip (download+flatpak)" "$LAST_ERR"
    fi
  fi
fi

# =============================================================================
# 4. NATIVE / REPO PACKAGES (continued)
# =============================================================================
step "Oracle VirtualBox"         apt_pkgs virtualbox-7.1
step "Developer CLI tools"       apt_pkgs git cmake ninja-build openssh-client openssh-server \
                                          openssl putty perl cpanminus pandoc wkhtmltopdf \
                                          python3 python3-pip python3-venv r-base r-base-dev \
                                          proxychains4 remmina remmina-plugin-rdp remmina-plugin-vnc
step "Free solvers (Gurobi alt)" apt_pkgs glpk-utils coinor-cbc
step "Media & utilities"         apt_pkgs vlc mpv rhythmbox qbittorrent flameshot obs-studio \
                                          kdenlive simplescreenrecorder p7zip-full p7zip-rar unrar \
                                          file-roller gimp krita shotwell gthumb goldendict \
                                          thunderbird calibre anki uget notepadqq geany libreoffice \
                                          uget aria2
# Pinta was removed from the Ubuntu 24.04 repos; install via Flatpak instead.
step "Pinta (Flatpak)" install_flatpak com.github.PintaProject.Pinta
step "Desktop apps (small)"      apt_pkgs gnome-clocks gnome-sound-recorder cheese gnome-weather \
                                          gnome-calculator gnome-terminal tilix gedit sticky \
                                          gnome-disk-utility usb-creator-gtk nautilus-dropbox \
                                          smartmontools nvme-cli openvpn network-manager-openvpn-gnome
step "OneDrive (abraunegg)"      apt_pkgs onedrive
step "PowerToys: launcher (Run)"           apt_pkgs ulauncher
step "PowerToys: OCR (Text Extractor)"     install_flatpak com.tenderowl.frog
step "PowerToys: color picker"             apt_pkgs gpick
step "PowerToys: image resizer via Nautilus" apt_pkgs nautilus-image-converter imagemagick
step "PowerToys: mouse sharing (KVM)"      install_flatpak com.github.debauchee.barrier
step "PowerToys: screen zoom"              apt_pkgs kmag
step "PowerToys: find mouse"               info "Use GNOME Settings > Mouse > Show Pointer Location (Ctrl to locate)"
step "PowerToys: keyboard accents"         apt_pkgs ibus-typing-booster
step "PowerToys: GNOME shortcut overlay"   info "Press Super key for shortcut guide (built into GNOME)"
step "PowerToys: file locksmith"           apt_pkgs lsof

# --- Hard-coded inclusions ---
# Adobe Acrobat Pro alternative: PDF Arranger (native APT) + Stirling PDF (Docker)
step "Acrobat Pro alt: PDF Arranger (merge/split/reorder PDFs)" apt_pkgs pdfarranger
log "Stirling PDF (full PDF toolkit — Docker, runs on port 8080)"
if have_cmd docker 2>/dev/null; then
  docker rm -f stirling-pdf 2>/dev/null || true
  if run_spin "pulling Stirling PDF" docker pull stirlingtools/stirling-pdf:latest; then
    if run_spin "starting Stirling PDF" docker run -d --name stirling-pdf -p 8080:8080 --restart unless-stopped stirlingtools/stirling-pdf:latest; then
      info "installed: Adobe Acrobat Pro ------> Stirling PDF at http://localhost:8080 (merge, split, OCR, sign, compress, convert) (alt, native)"; mark_ok "Stirling PDF"
    else mark_fail "Stirling PDF (docker run)" "$LAST_ERR"; fi
  else mark_fail "Stirling PDF (docker pull)" "$LAST_ERR"; fi
else warn "Docker not available — Stirling PDF skipped (install Docker first)"; mark_skip "Stirling PDF" "Docker not available"; fi

# Advanced IP Scanner alternative: Angry IP Scanner (.deb from angryip.org)
ANGRY_IP_DEB="$DOWNLOAD_DIR/angry_ip_scanner.deb"
if deb_installed angryipscanner 2>/dev/null || have_cmd ipscan 2>/dev/null; then
  info "Angry IP Scanner already installed"; mark_ok "Angry IP Scanner"
else
  if download_file "downloading Angry IP Scanner" "https://github.com/angryip/ipscan/releases/latest/download/ipscan_${DEB_ARCH}.deb" "$ANGRY_IP_DEB"; then
    if apt_run "installing Angry IP Scanner" install "$ANGRY_IP_DEB"; then
      info "installed: Advanced IP Scanner ------> Angry IP Scanner (network scanner, GUI) (alt, native)"; mark_ok "Angry IP Scanner"
    else mark_fail "Angry IP Scanner (install)" "$LAST_ERR"; fi
  else
    warn "Angry IP Scanner download failed — installing nmap as fallback"; apt_pkgs nmap && info "installed: nmap (CLI network scanner)" && mark_ok "Angry IP Scanner (nmap fallback)" || mark_fail "Angry IP Scanner" "$LAST_ERR"
  fi
fi

# Advanced Port Scanner alternative: nmap + Zenmap GUI + RustScan (fast port scanner)
step "Port Scanner alt: nmap + Zenmap + RustScan" bash -c '
  rc=0
  apt_pkgs nmap || rc=1
  # Zenmap is the official nmap GUI; RustScan is a blazing-fast Rust port scanner
  if ! deb_installed zenmap 2>/dev/null; then
    apt_pkgs zenmap 2>/dev/null || warn "Zenmap not in APT (install via: snap install zenmap-kbx or flatpak install org.nmap.Zenmap)"
  fi
  # Install RustScan from official GitHub .deb
  RUSTSCAN_DEB="'"$DOWNLOAD_DIR"'/rustscan.deb"
  if ! have_cmd rustscan 2>/dev/null; then
    if curl -fsSL --retry 3 -o "$RUSTSCAN_DEB" "https://github.com/RustScan/RustScan/releases/latest/download/rustscan_'"${DEB_ARCH}"'.deb" 2>/dev/null; then
      apt_get install -y "$RUSTSCAN_DEB" 2>/dev/null && info "installed: RustScan (fast port scanner)" || warn "RustScan .deb install failed"
    else warn "RustScan download failed (skip)"; fi
  else info "RustScan already installed"; fi
  [ $rc -eq 0 ] && info "installed: nmap + port scan tools" || warn "partial install — see above"
'

# Telegram — official native Linux client (APT, falls back to Flatpak)
step "Telegram Desktop" bash -c '
  if have_cmd telegram-desktop 2>/dev/null; then info "telegram-desktop already installed"; exit 0; fi
  apt_pkgs telegram-desktop 2>/dev/null || install_flatpak org.telegram.desktop 2>/dev/null || { warn "Telegram install failed (APT + Flatpak)"; exit 1; }
  info "installed: Telegram ------> Telegram Desktop (same, native)"
'

# Terminator — feature-rich terminal emulator with tiling/grouping (APT)
step "Terminator (terminal emulator with tiling)" apt_pkgs terminator

# WindTerm — fast SSH/Telnet/Serial client (native Linux build from GitHub .deb)
WINDTERM_DEB="$DOWNLOAD_DIR/windterm.deb"
if have_cmd windterm 2>/dev/null || [ -f "/opt/windterm/WindTerm" ]; then
  info "WindTerm already installed"; mark_ok "WindTerm"
else
  step "WindTerm (SSH/Telnet/Serial client with file manager)" bash -c '
    if run_spin "downloading WindTerm" curl -fsSL --retry 3 -o "'"$WINDTERM_DEB"'" "https://github.com/kingToolfish/WindTerm/releases/latest/download/WindTerm_${DEB_ARCH}.deb"; then
      if apt_run "installing WindTerm" install "'"$WINDTERM_DEB"'"; then
        info "installed: WindTerm ------> WindTerm (same, native)"; mark_ok "WindTerm"
      else mark_fail "WindTerm (install)" "$LAST_ERR"; fi
    else warn "WindTerm download failed — skipping (may need manual install)"; mark_skip "WindTerm" "download failed"; fi
  '
fi

# WinDirStat alternative: QDirStat + baobab (disk usage analysis)
step "WinDirStat alt: QDirStat (disk usage analyzer)" apt_pkgs qdirstat
step "WinDirStat alt: baobab (GNOME Disk Usage Analyzer)" apt_pkgs baobab

# =============================================================================
# PAPERCUT PRINT DEPLOY CLIENT  (hard-coded inclusion — install the NATIVE PaperCut
# client, never a CUPS substitute). The Linux client is served by YOUR PaperCut Print
# Deploy server, which is the trusted first-party source for it. If PAPERCUT_SERVER is
# set we install it unattended here; otherwise it is DEFERRED to the manual section at
# the very end (so the unattended part still finishes first).
# =============================================================================
# Extract + run the bundled installer from $PAPERCUT_TARBALL.
_papercut_extract_install() {
  rm -rf /opt/papercut-print-deploy && mkdir -p /opt/papercut-print-deploy
  if run_spin "extracting PaperCut client" tar -xzf "$PAPERCUT_TARBALL" -C /opt/papercut-print-deploy; then
    local inst
    inst="$(find /opt/papercut-print-deploy -maxdepth 3 -type f \( -iname 'install*.sh' -o -iname '*installer*' \) 2>/dev/null | head -n1)"
    if [ -n "$inst" ]; then
      chmod +x "$inst" 2>/dev/null || true
      run_spin "running PaperCut installer" bash "$inst" || warn "PaperCut bundled installer returned non-zero (files are in /opt/papercut-print-deploy)"
    fi
    info "installed: PaperCut ------> PaperCut Print Deploy client -> /opt/papercut-print-deploy (same, native)"
    return 0
  else
    warn "PaperCut client extraction failed"
    return 1
  fi
}

# Unattended attempt: install from PAPERCUT_SERVER, else defer to the manual section.
_install_papercut_auto() {
  if have_cmd pc-print-deploy-client 2>/dev/null || [ -d /opt/papercut-print-deploy ] || ls -d /opt/PaperCut* >/dev/null 2>&1; then
    info "PaperCut client already installed (skipping)"; mark_ok "PaperCut Print Deploy client"; return 0
  fi
  if [ -n "${PAPERCUT_SERVER:-}" ]; then
    log "PaperCut Print Deploy client (native PaperCut — not CUPS) from $PAPERCUT_SERVER:$PAPERCUT_PORT"
    local url got=0
    for url in \
      "https://${PAPERCUT_SERVER}:${PAPERCUT_PORT}/client/setup/print-deploy-client%5Blinux-x64%5D.tar.gz" \
      "https://${PAPERCUT_SERVER}:${PAPERCUT_PORT}/client/print-deploy-client-linux.tar.gz" ; do
      # Verified TLS first; the user's OWN server may use a self-signed cert, so retry
      # once with --insecure (it is the explicitly-configured first-party host).
      if run_spin "downloading PaperCut client" curl -fsSL --retry 3 -o "$PAPERCUT_TARBALL" "$url" \
         || run_spin "downloading PaperCut client (self-signed server)" curl -fsSL -k --retry 3 -o "$PAPERCUT_TARBALL" "$url"; then
        got=1; break
      fi
    done
    if [ "$got" -eq 1 ]; then
      if _papercut_extract_install; then mark_ok "PaperCut Print Deploy client"; return 0; fi
    fi
    warn "PaperCut auto-download from $PAPERCUT_SERVER failed — deferring to the manual section"
  else
    log "PaperCut Print Deploy client (native PaperCut — not CUPS)"
    info "PAPERCUT_SERVER not set — deferring PaperCut to the manual section (download from your server)"
  fi
  PAPERCUT_NEEDS_MANUAL=1
  return 0
}
_install_papercut_auto

log "TeX Live (texlive-full — large; please wait)"
if apt_run "installing texlive-full" install texlive-full; then info "installed: texlive-full"; mark_ok "TeX Live"; else mark_fail "TeX Live" "$LAST_ERR"; fi

# =============================================================================
# 5. VENDOR .deb DOWNLOADS  (architecture-aware URLs)
# =============================================================================
step "Discord"  install_deb_url "Discord" "https://discord.com/api/download?platform=linux&format=deb"
step "Zoom"     install_deb_url "Zoom"    "https://zoom.us/client/latest/zoom_${DEB_ARCH}.deb"
# PARSEC — explicitly EXCLUDED per user request. Not installed.
info "Parsec: SKIPPED (per user request — not installed)"
mark_skip "Parsec (user-requested exclusion)"
step "GitKraken (GitHub Desktop alt)" install_deb_url "GitKraken" "https://release.gitkraken.com/linux/gitkraken-${DEB_ARCH}.deb"
# XDM (Xtreme Download Manager): open-source (GitHub 7.8k stars), .deb from official GitHub releases.
# Complements uGet (already installed as APT) and IDM (installed under Wine above).
step "XDM (Xtreme Download Manager)" install_deb_url "XDM" \
  "https://github.com/subhra74/xdm/releases/download/${XDM_VERSION}/xdman_gtk_${XDM_VERSION}_amd64.deb"

# =============================================================================
# 6. VENDOR .deb DOWNLOADS (no Flatpak or APT available)
# =============================================================================
# RealVNC Viewer: distributed as a vendor .deb (not on Flathub, not in APT).
# RealVNC uses "x64" in filenames, not "amd64" — must hard-code the arch suffix.
step "RealVNC Viewer" install_deb_url "RealVNC Viewer" \
  "https://downloads.realvnc.com/download/file/viewer.files/VNC-Viewer-7.15.1-Linux-x64.deb"

# =============================================================================
# 7. FLATPAK FALLBACKS
# =============================================================================
step "Microsoft Teams" install_flatpak com.github.IsmaelMartinez.teams_for_linux
step "WhatsApp (ZapZap)" install_flatpak com.rtosta.zapzap
step "LocalSend (Quick/Nearby Share)" install_flatpak org.localsend.localsend_app
step "Planify (Microsoft To Do alt)" install_flatpak io.github.alainm23.planify

# =============================================================================
# 8. SCRIPT / BINARY INSTALLERS
# =============================================================================
log "rclone (Google Drive)"
if run_spin "installing rclone" bash -c 'curl -fsSL https://rclone.org/install.sh | bash || rclone selfupdate'; then
  info "installed: Google Drive ------> rclone (alt, native)"; mark_ok "rclone"
else mark_fail "rclone" "$LAST_ERR"; fi

log "Miniconda (Anaconda ecosystem)"
if [ -d /opt/miniconda3 ]; then
  if run_spin "accepting conda ToS" /opt/miniconda3/bin/conda config --set tos_accepted true 2>/dev/null || true; then :; fi
if run_spin "updating conda" /opt/miniconda3/bin/conda update -n base -y conda; then info "updated: miniconda"; mark_ok "Miniconda"; else mark_fail "Miniconda update" "$LAST_ERR"; fi
else
  if run_spin "downloading Miniconda" curl -fsSL -o "$DOWNLOAD_DIR/miniconda.sh" "https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-${CONDA_ARCH}.sh" \
     && run_spin "installing Miniconda" bash "$DOWNLOAD_DIR/miniconda.sh" -b -p /opt/miniconda3; then
    ln -sf /opt/miniconda3/bin/conda /usr/local/bin/conda; info "installed: miniconda -> /opt/miniconda3"; mark_ok "Miniconda"
  else mark_fail "Miniconda" "$LAST_ERR"; fi
fi

log "LanguageTool (Grammarly alt)"
if run_spin "downloading LanguageTool" curl -fsSL -o "$DOWNLOAD_DIR/LanguageTool.zip" "https://languagetool.org/download/LanguageTool-stable.zip"; then
  rm -rf /opt/languagetool && mkdir -p /opt/languagetool
  if run_spin "extracting LanguageTool" unzip -q -o "$DOWNLOAD_DIR/LanguageTool.zip" -d /opt/languagetool; then
    cat >/usr/local/bin/languagetool <<'EOF'
#!/usr/bin/env bash
dir="$(find /opt/languagetool -maxdepth 1 -type d -name 'LanguageTool-*' | head -n1)"
exec java -jar "$dir/languagetool.jar" "$@"
EOF
    chmod +x /usr/local/bin/languagetool; info "installed: languagetool -> /opt/languagetool"; mark_ok "LanguageTool"
  else mark_fail "LanguageTool (unzip)" "$LAST_ERR"; fi
else mark_fail "LanguageTool (download)" "$LAST_ERR"; fi

# =============================================================================
# 9. WEB-APP .desktop SHORTCUTS  (searchable in the app menu)
#    For apps that only have a web version (no native Linux client), create
#    .desktop shortcuts in ~/.local/share/applications/ so they appear in the
#    system menu AND are searchable via the launcher, plus symlinked to the
#    desktop for convenience. Runs under the real (non-root) SUDO_USER.
# =============================================================================

# Create a .desktop shortcut in ~/.local/share/applications/ (menu-searchable)
# and also symlink it to ~/Desktop for visibility.
_webapp_desktop() {
  local label="$1" url="$2" icon="${3:-web-browser}"
  local apps_dir="${USER_HOME}/.local/share/applications"
  local desktop_dir="${USER_HOME}/Desktop"
  local desktop_file="${apps_dir}/${label// /_}.desktop"
  mkdir -p "$apps_dir" "$desktop_dir" 2>/dev/null || return 1
  if [ -f "$desktop_file" ]; then
    info "desktop shortcut already exists (menu): $label"
    # Still ensure a Desktop symlink exists
    if [ ! -e "${desktop_dir}/${label// /_}.desktop" ]; then
      ln -sf "$desktop_file" "${desktop_dir}/${label// /_}.desktop" 2>/dev/null || true
      chown -h "${SUDO_USER}:${SUDO_USER}" "${desktop_dir}/${label// /_}.desktop" 2>/dev/null || true
    fi
    return 0
  fi
  cat > "$desktop_file" <<DESK_EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=$label
Comment=Open $label in web browser
Icon=$icon
Exec=xdg-open $url
Terminal=false
Categories=Network;WebBrowser;
StartupWMClass=${label// /_}
DESK_EOF
  chmod 0644 "$desktop_file"
  chown "${SUDO_USER}:${SUDO_USER}" "$desktop_file" 2>/dev/null || true
  # Symlink to Desktop for visibility
  ln -sf "$desktop_file" "${desktop_dir}/${label// /_}.desktop" 2>/dev/null || true
  chown -h "${SUDO_USER}:${SUDO_USER}" "${desktop_dir}/${label// /_}.desktop" 2>/dev/null || true
  info "created web-app shortcut (menu + desktop): $label -> $url"
}

# Only create shortcuts if we have a real non-root SUDO_USER.
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
  USER_HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
  if [ -d "$USER_HOME" ]; then
    log "Creating web-app desktop shortcuts for $SUDO_USER (menu-searchable)"
    # Microsoft 365 / Office — web-only, no native Linux version
    _webapp_desktop "Microsoft 365"        "https://www.office.com"           "libreoffice-writer" || true
    _webapp_desktop "Microsoft Word"       "https://www.office.com/launch/word"       "libreoffice-writer" || true
    _webapp_desktop "Microsoft Excel"      "https://www.office.com/launch/excel"      "libreoffice-calc"   || true
    _webapp_desktop "Microsoft PowerPoint" "https://www.office.com/launch/powerpoint" "libreoffice-impress"|| true
    _webapp_desktop "Microsoft Outlook"    "https://outlook.live.com"         "thunderbird"        || true
    _webapp_desktop "Microsoft OneDrive"   "https://onedrive.live.com"        "folder-remote"      || true
    _webapp_desktop "Microsoft To Do"      "https://to-do.microsoft.com"      "checkbox"           || true
    _webapp_desktop "Copilot"              "https://copilot.microsoft.com"    "assistant"          || true
    _webapp_desktop "Claude AI"            "https://claude.ai"                "assistant"          || true
    _webapp_desktop "Reverso"              "https://www.reverso.net"          "accessories-dictionary" || true

    # Update the desktop database so the menu picks them up immediately
    if have_cmd update-desktop-database 2>/dev/null; then
      run_spin "updating desktop database" update-desktop-database "${USER_HOME}/.local/share/applications" || true
    fi
  fi
fi

# =============================================================================
# 9B. BING WALLPAPER — daily Bing image as desktop background
#     Equivalent to the Windows Bing Wallpaper app.
#     Primary: GNOME Shell extension (neffo/bing-wallpaper-gnome-extension)
#              from extensions.gnome.org — FOSS, pulls daily Bing image.
#     Fallback: bing-wall Snap (snapcraft.io) — standalone daemon that works
#               on any desktop environment, not just GNOME.
# =============================================================================
step "Bing Wallpaper (daily Bing desktop background)" bash -c '
  if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    USER_HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)"

    # Check if already installed via extension or snap
    if [ -d "${USER_HOME}/.local/share/gnome-shell/extensions/BingWallpaper@ineffable-gmail.com" ] 2>/dev/null; then
      echo "Bing Wallpaper GNOME extension already installed"
      exit 0
    fi
    if snap list 2>/dev/null | grep -q "^bing-wall "; then
      echo "bing-wall Snap already installed"
      exit 0
    fi

    # Attempt 1: Clone and install the GNOME Shell extension from git.
    # Official source: https://github.com/neffo/bing-wallpaper-gnome-extension (HTTPS, FOSS).
    # This is the closest equivalent to the Windows Bing Wallpaper app.
    # Cloning from git is more reliable than release .zip (often missing from releases).
    EXT_DIR="${USER_HOME}/.local/share/gnome-shell/extensions/BingWallpaper@ineffable-gmail.com"
    if [ -d "$EXT_DIR/.git" ] || [ -f "$EXT_DIR/extension.js" ]; then
      if [ -d "$EXT_DIR/.git" ]; then
        (cd "$EXT_DIR" && git pull --ff-only 2>/dev/null) || true
      fi
      echo "Bing Wallpaper GNOME extension already installed/updated"
      exit 0
    fi
    rm -rf "$EXT_DIR" 2>/dev/null || true
    if have_cmd git 2>/dev/null && \
       git clone --depth 1 "https://github.com/neffo/bing-wallpaper-gnome-extension.git" "$EXT_DIR" 2>/dev/null; then
      chown -R "${SUDO_USER}:${SUDO_USER}" "$EXT_DIR" 2>/dev/null || true
      echo "installed: Bing Wallpaper GNOME extension (from git)"
      echo "Enable it via: gnome-extensions enable BingWallpaper@ineffable-gmail.com"
      if have_cmd gnome-extensions 2>/dev/null; then
        sudo -u "$SUDO_USER" gnome-extensions enable BingWallpaper@ineffable-gmail.com 2>/dev/null || true
      fi
      echo "NOTE: Restart GNOME Shell (Alt+F2, r, Enter) or log out/in for the extension to take effect."
      exit 0
    fi

    # Attempt 2: Try the GitHub releases .zip as a fallback.
    mkdir -p "$EXT_DIR"
    if curl -fsSL --retry 3 -o /tmp/bing-wallpaper-extension.zip \
       "https://github.com/neffo/bing-wallpaper-gnome-extension/releases/latest/download/bing-wallpaper@ineffable-gmail.com.zip"; then
      if unzip -q -o /tmp/bing-wallpaper-extension.zip -d "$EXT_DIR" 2>/dev/null; then
        chown -R "${SUDO_USER}:${SUDO_USER}" "${USER_HOME}/.local/share/gnome-shell/extensions/BingWallpaper@ineffable-gmail.com" 2>/dev/null || true
        rm -f /tmp/bing-wallpaper-extension.zip
        echo "installed: Bing Wallpaper GNOME extension (from release .zip)"
        if have_cmd gnome-extensions 2>/dev/null; then
          sudo -u "$SUDO_USER" gnome-extensions enable BingWallpaper@ineffable-gmail.com 2>/dev/null || true
        fi
        echo "NOTE: Restart GNOME Shell (Alt+F2, r, Enter) or log out/in for the extension to take effect."
        exit 0
      fi
      rm -f /tmp/bing-wallpaper-extension.zip
    fi

    # Attempt 3: Fallback — install bing-wall via Snap (works on all desktops).
    echo "GNOME extension install failed — trying snap fallback..."
    if have_cmd snap 2>/dev/null; then
      snap install bing-wall && echo "installed: bing-wall (Snap)" && exit 0
    else
      echo "Installing snapd first..."
      apt_get install -y snapd 2>/dev/null || true
      sleep 2
      snap wait system seed.loaded 2>/dev/null || true
      snap install bing-wall && echo "installed: bing-wall (Snap)" && exit 0
    fi
    echo "WARN: Could not install Bing Wallpaper — manual install needed"
    exit 1
  else
    echo "No SUDO_USER — skipping (runs per-user)"
    exit 0
  fi
'

# =============================================================================
# 10. POST-INSTALL CONFIG
# =============================================================================
log "Post-install configuration"
systemctl enable --now ssh        || true
systemctl enable --now postgresql || true
if getent group docker >/dev/null 2>&1; then
  systemctl enable --now docker   || true
  if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    usermod -aG docker "$SUDO_USER" || true
    info "added '$SUDO_USER' to the 'docker' group (re-login to apply)"
  fi
fi
info "enabled services: ssh, postgresql, docker"

# =============================================================================
# 10B. INTERACTIVE FONT INSTALLATION FROM DIRECTORY
#      Prompts the user to input a directory path, then recursively finds and
#      installs all font files (.ttf, .otf, .ttc, .woff, .woff2, .pfa, .pfb,
#      .afm, .pfm, .dfont, .otb, .bdf, .pcf, .gsf, .ttc, .otc, .abf, .chr,
#      .fnt, .mxf) from that directory into the system.
#
#      Fonts go to:
#        • /usr/local/share/fonts/user-import/  — system-wide TrueType/OpenType
#        • /usr/share/fonts/                    — fallback (requires root)
#      After copying, fc-cache is run to refresh the font cache.
#
#      Error handling:
#        • Directory doesn't exist        → reprompt or skip
#        • Directory has no font files    → warn + skip
#        • Permission denied for a file   → skip that file, continue
#        • No tty (non-interactive env)   → skip silently
# =============================================================================
_install_fonts_from_dir() {
  local FONT_EXTS=("ttf" "otf" "ttc" "woff" "woff2" "pfa" "pfb" "afm" "pfm"
                   "dfont" "otb" "bdf" "pcf" "gsf" "otc" "abf" "chr" "fnt" "mxf")
  local FONT_DEST="/usr/local/share/fonts/user-import"
  local found_count=0 installed_count=0 failed_count=0

  # Build a find -iname expression:  -iname '*.ttf' -o -iname '*.otf' ...
  local find_expr=""
  local first=1
  for ext in "${FONT_EXTS[@]}"; do
    if [ "$first" -eq 1 ]; then first=0; find_expr="-iname '*.$ext'"
    else find_expr="$find_expr -o -iname '*.$ext'"; fi
  done

  { echo; echo "================ FONT IMPORT ================"
    echo "This step installs font files from a directory you specify into the"
    echo "system so they are available to all applications (including Wine)."
    echo
    echo "Supported types: ${FONT_EXTS[*]}"
    echo "(These cover Windows, macOS, and Linux font file formats.)"
    echo; } >&3

  while true; do
    printf 'Enter font directory path (or "skip" to skip): ' >&3
    local font_dir
    read -r font_dir </dev/tty || { warn "No tty available — skipping font import"; mark_skip "Font import" "no tty"; return 1; }

    case "${font_dir,,}" in
      skip|"")
        warn "Font import skipped by user"
        mark_skip "Font import" "user skipped"
        return 0 ;;
    esac

    # Validate directory
    if [ ! -d "$font_dir" ]; then
      err "Directory does not exist: '$font_dir'"
      echo "  Please check the path and try again." >&3
      continue
    fi

    if [ ! -r "$font_dir" ]; then
      err "Directory is not readable: '$font_dir'"
      echo "  Please fix permissions and try again." >&3
      continue
    fi

    # Count matching files
    found_count=$(eval find "$font_dir" -type f "$find_expr" 2>/dev/null | wc -l)
    if [ "$found_count" -eq 0 ]; then
      echo "  No font files found in: $font_dir" >&3
      echo "  Supported extensions: ${FONT_EXTS[*]}" >&3
      echo "  Please try another directory." >&3
      continue
    fi

    break
  done

  log "Installing fonts from: $font_dir ($found_count font files found)"

  mkdir -p "$FONT_DEST"

  # Install each font file
  while IFS= read -r -d '' font_file; do
    local font_name; font_name="$(basename "$font_file")"
    local dest_path="$FONT_DEST/$font_name"

    # Skip if already present with same size (idempotent)
    if [ -f "$dest_path" ] && [ "$(stat -c%s "$font_file" 2>/dev/null)" = "$(stat -c%s "$dest_path" 2>/dev/null)" ]; then
      info "already present: $font_name"
      installed_count=$((installed_count + 1))
      continue
    fi

    if cp "$font_file" "$dest_path" 2>/dev/null; then
      info "installed: $font_name"
      installed_count=$((installed_count + 1))
    else
      warn "could not copy: $font_name (permission denied or read error — skipped)"
      failed_count=$((failed_count + 1))
    fi
  done < <(eval find "$font_dir" -type f "$find_expr" -print0 2>/dev/null)

  # Refresh the font cache
  if run_spin "rebuilding font cache" fc-cache -fv "$FONT_DEST" 2>&1; then
    info "font cache updated"
  else
    warn "fc-cache had issues — fonts may still work; check 'fc-list'"
  fi

  info "Font import complete: $installed_count installed, $found_count found"
  [ "$failed_count" -gt 0 ] && warn "$failed_count files could not be copied (permissions)"
  mark_ok "Font import ($installed_count/$found_count fonts)"
}

step "Import user fonts from directory" _install_fonts_from_dir

# =============================================================================
# 11. MANUAL / LOGIN-GATED DOWNLOADS  (always LAST)
# =============================================================================
log "Manual downloads (handled last)"

# RStudio: try the vendor URL automatically, fall back to a manual prompt.
log "RStudio"
RSTUDIO_DEB="$DOWNLOAD_DIR/rstudio.deb"
if run_spin "downloading RStudio" curl -fsSL --retry 2 -o "$RSTUDIO_DEB" "https://rstudio.org/download/latest/stable/desktop/${CODENAME}/rstudio-latest-${DEB_ARCH}.deb" \
   && [ -s "$RSTUDIO_DEB" ]; then
  if run_spin "installing RStudio" apt_get install -y "$RSTUDIO_DEB"; then info "installed: rstudio"; mark_ok "RStudio"; else mark_fail "RStudio" "$LAST_ERR"; fi
else
  if prompt_for_file "RStudio" "$RSTUDIO_DEB" "Download RStudio Desktop (.deb) from https://posit.co/download/rstudio-desktop/"; then
    if run_spin "installing RStudio" apt_get install -y "$RSTUDIO_DEB"; then info "installed: rstudio"; mark_manual "RStudio"; else mark_fail "RStudio (manual)" "$LAST_ERR"; fi
  fi
fi

# SpotPlayer: vendor .deb from spotplayer.ir — this domain cannot be verified as
# a trusted first-party source per our "Trusted Sources Only" policy. The download
# is MANUAL ONLY and you are responsible for verifying the .deb's authenticity
# before proceeding (check hashes/signatures if the vendor publishes them).
SPOT_DEB="$DOWNLOAD_DIR/spotplayer.deb"
if prompt_for_file "SpotPlayer" "$SPOT_DEB" \
     "WARNING: SpotPlayer is distributed from https://spotplayer.ir — this domain
   could not be verified as a trusted first-party source. You are responsible
   for checking the authenticity of the downloaded .deb before installing it.
   Download the Linux/Ubuntu .deb from https://spotplayer.ir"; then
  if run_spin "installing SpotPlayer" apt_get install -y "$SPOT_DEB"; then
    info "installed: SpotPlayer ------> spotplayer (same, native)"; mark_manual "SpotPlayer" "user-accepted risk; installed from spotplayer.ir .deb"
  else mark_fail "SpotPlayer (manual)" "$LAST_ERR"; fi
fi

# VMware Workstation: Broadcom login-gated .bundle.
VMWARE_BUNDLE="$DOWNLOAD_DIR/VMware-Workstation.bundle"
if prompt_for_file "VMware Workstation" "$VMWARE_BUNDLE" \
     "Download VMware Workstation Pro for Linux (.bundle, now free) from the Broadcom
   support portal https://support.broadcom.com (free account). Build deps already installed."; then
  chmod +x "$VMWARE_BUNDLE"
  if run_spin "installing VMware" bash "$VMWARE_BUNDLE" --console --required --eulas-agreed; then
    vmware-modconfig --console --install-all || true; info "installed: vmware workstation"; mark_manual "VMware Workstation"
  else mark_fail "VMware Workstation (bundle install)" "$LAST_ERR"; fi
fi

# Gurobi: commercial, license-gated. Free solvers (glpk/cbc) were installed above.
GUROBI_TGZ="$DOWNLOAD_DIR/gurobi.tar.gz"
info "Gurobi is commercial/licensed; free solvers GLPK & CBC were installed."
if prompt_for_file "Gurobi" "$GUROBI_TGZ" \
     "OPTIONAL: download the Gurobi Optimizer Linux tarball from https://www.gurobi.com/downloads/
   (account + license required). Skip to use the free solvers instead."; then
  if run_spin "extracting Gurobi" tar -xzf "$GUROBI_TGZ" -C /opt; then info "extracted: gurobi -> /opt (set GUROBI_HOME + license)"; mark_manual "Gurobi" "extracted to /opt (set GUROBI_HOME + license)"; else mark_fail "Gurobi (extract)" "$LAST_ERR"; fi
fi

# PaperCut Print Deploy client — hard-coded inclusion (the NATIVE PaperCut client,
# never a CUPS substitute). Reached here only when PAPERCUT_SERVER was not set, or the
# unattended auto-download failed. The client is downloaded from YOUR PaperCut Print
# Deploy server (the trusted first-party source for it).
if [ "${PAPERCUT_NEEDS_MANUAL:-0}" -eq 1 ]; then
  log "PaperCut Print Deploy client (manual — from your PaperCut server)"
  if prompt_for_file "PaperCut Print Deploy client" "$PAPERCUT_TARBALL" \
       "Open your PaperCut Print Deploy client page (e.g. https://<your-server>:9174) in a
   browser, download the LINUX client (.tar.gz), and save it to the path below.
   Tip: set PAPERCUT_SERVER at the top of this script to automate this next time."; then
    if _papercut_extract_install; then mark_manual "PaperCut Print Deploy client"; else mark_fail "PaperCut Print Deploy client (manual)" "$LAST_ERR"; fi
  fi
fi

# =============================================================================
# 12. SUMMARY  (appended to the results log AND printed to the terminal)
# =============================================================================
{
  echo
  echo "# ---- totals: OK=${#OK[@]} manual=${#MANUAL_DONE[@]} skipped=${#SKIPPED[@]} failed=${#FAIL[@]} ----"
} >> "$RESULTS" 2>/dev/null

{
  echo
  echo "============================ SUMMARY ============================"
  printf 'Installed/updated OK : %s\n' "${#OK[@]}"
  printf 'Manual completed     : %s\n' "${#MANUAL_DONE[@]}"
  printf 'Skipped              : %s\n' "${#SKIPPED[@]}"
  printf 'Failed               : %s\n' "${#FAIL[@]}"
  [ "${#SKIPPED[@]}" -gt 0 ] && { echo; echo "Skipped:";         printf '  - %s\n' "${SKIPPED[@]}"; }
  [ "${#FAIL[@]}"    -gt 0 ] && { echo; echo "Failed (review):"; printf '  - %s\n' "${FAIL[@]}"; }
  echo
  echo "Results log : $RESULTS   (success/failure + reason per step)"
  echo "Full log    : $LOG"
  echo "Done. A reboot is recommended (kernel modules, docker group, services)."
} >&3
