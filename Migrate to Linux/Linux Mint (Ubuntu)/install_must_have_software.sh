#!/usr/bin/env bash
#
# install_must_have_software.sh
# -----------------------------------------------------------------------------
# Unattended installer for Linux Mint (Ubuntu base) that installs every program
# flagged "Must be included on Linux = yes" in
#   ../installed_windows_software.csv
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
#   * Missing build dependencies (e.g. kernel headers + dkms/gcc for VMware modules)
#     are installed up front.
#   * The latest PostgreSQL is installed from the official postgresql.org PGDG repo.
#   * Anything that needs a manual/login-gated download (VMware, SpotPlayer, Gurobi,
#     and RStudio if its auto-URL fails) is handled LAST via an interactive prompt
#     that waits until you drop the file in place (or you type 'skip').
#
# The script is idempotent and continues past individual failures, printing a
# summary (installed / updated / failed / skipped / manual) at the end.
# -----------------------------------------------------------------------------
#
# CSV "yes" row  ->  what this script installs
#   Google Chrome ......... google-chrome-stable (Google APT repo)
#   Microsoft Edge ........ microsoft-edge-stable (Microsoft APT repo)
#   Firefox ............... firefox (APT, pre-installed on Mint)
#   Discord ............... discord .deb (vendor)
#   Zoom .................. zoom .deb (vendor)
#   MS Teams .............. teams-for-linux (Flatpak)
#   WhatsApp .............. ZapZap (Flatpak)
#   Dropbox ............... nautilus-dropbox (APT, pulls vendor daemon)
#   Google Drive .......... rclone (official script)
#   OneDrive .............. onedrive (abraunegg, APT)
#   Quick/Nearby Share .... LocalSend (Flatpak)
#   VS Code ............... code (Microsoft APT repo)
#   VS Build Tools / VS ... dotnet-sdk (Microsoft prod repo) + build-essential
#   GitHub Desktop ........ GitKraken .deb (vendor, free tier)
#   Git ................... git (APT)
#   Docker Desktop ........ docker-ce + plugins (Docker APT repo)
#   DBeaver ............... dbeaver-ce (DBeaver APT repo)
#   pgAdmin ............... pgadmin4-desktop (pgAdmin APT repo)
#   pgNow / SSMS .......... covered by dbeaver-ce + postgresql-client
#   PostgreSQL ............ postgresql + client (postgresql.org PGDG repo)
#   CMake / ninja ......... cmake, ninja-build (APT)
#   Node.js ............... nodejs (NodeSource LTS repo)
#   Anaconda .............. Miniconda (latest, repo.anaconda.com) -> /opt/miniconda3
#   Python ................ python3 + pip + venv (APT)
#   R / RStudio ........... r-base (APT); RStudio .deb (auto, else manual)
#   PowerShell ............ powershell (Microsoft prod repo)
#   OpenSSH/OpenSSL/PuTTY . openssh-*, openssl, putty (APT)
#   Perl .................. perl + cpanminus (APT)
#   MiKTeX ................ texlive-full (APT, TeX Live = Linux standard)
#   Pandoc / wkhtmltox .... pandoc, wkhtmltopdf (APT)
#   Gurobi ................ MANUAL (licensed); free solvers glpk/cbc via APT
#   Java .................. default-jdk (OpenJDK, APT)
#   .NET SDK .............. dotnet-sdk (Microsoft prod repo)
#   MobaXterm ............. remmina + plugins, openssh (APT)
#   Bitvise ............... openssh-client (APT)
#   Proxifier ............. proxychains4 (APT)
#   RealVNC ............... RealVNC Viewer (Flatpak)
#   AnyDesk ............... anydesk (AnyDesk APT repo)
#   Parsec ................ parsec .deb (vendor)
#   VMware Workstation .... MANUAL (.bundle from Broadcom) + kernel headers/dkms
#   calibre / ADE ......... calibre (APT)
#   Anki .................. anki (APT)
#   KMPlayer / Zune ....... vlc, mpv, rhythmbox (APT)
#   oCam / Camtasia ....... obs-studio, kdenlive, simplescreenrecorder (APT)
#   Lightshot ............. flameshot (APT)
#   WinRAR ................ p7zip-full, p7zip-rar, unrar, file-roller (APT)
#   uTorrent .............. qbittorrent (APT)
#   IDM ................... uget (APT)
#   Notepad++ ............. notepadqq/geany (APT)
#   MS Office / Office Hub  libreoffice (APT)
#   Grammarly ............. LanguageTool (languagetool.org stable zip) -> /opt
#   Reverso/Babylon/Longman goldendict (APT)
#   Microsoft To Do ....... Planify (Flatpak)
#   Outlook ............... thunderbird (APT)
#   Paint ................. gimp, krita, pinta (APT)
#   Photos ................ shotwell, gthumb (APT)
#   Sticky Notes .......... sticky (APT, Mint app)
#   Alarms ................ gnome-clocks (APT)
#   Sound Recorder ........ gnome-sound-recorder (APT)
#   Camera ................ cheese (APT)
#   Weather ............... gnome-weather (APT)
#   Calculator ............ gnome-calculator (APT)
#   Windows Terminal ...... gnome-terminal / tilix (APT)
#   Windows Notepad ....... gedit (APT)
#   PowerToys ............. ulauncher (best-effort, APT) + DE built-ins
#   Hotspot Shield/Psiphon  Proton VPN (ProtonVPN APT repo, free tier)
#   SpotPlayer ............ MANUAL (.deb from spotplayer.ir)
#   Rufus ................. gnome-disk-utility, usb-creator-gtk (APT)
#   OpenVPN ............... openvpn + NM plugin (APT)
# -----------------------------------------------------------------------------

set -uo pipefail

# ----------------------------- bookkeeping -----------------------------------
OK=();  FAIL=();  SKIPPED=();  MANUAL_DONE=()
DOWNLOAD_DIR="/opt/migrate-downloads"
DOTNET_SDK="dotnet-sdk-9.0"
NODE_MAJOR="22"

log()  { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[fail]\033[0m %s\n' "$*"; }
mark_ok()   { OK+=("$1"); }
mark_fail() { FAIL+=("$1"); err "$1 failed"; }

# Run a step, recording success/failure but never aborting the whole script.
step() {  # step "Label" command...
  local label="$1"; shift
  log "$label"
  if "$@"; then mark_ok "$label"; else mark_fail "$label"; fi
}

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    err "This script must run as root. Use: sudo $0"
    exit 1
  fi
}

# ----------------------------- environment -----------------------------------
require_root
export DEBIAN_FRONTEND=noninteractive
mkdir -p "$DOWNLOAD_DIR" /etc/apt/keyrings

# Detect the Ubuntu base codename/version even on Linux Mint.
# shellcheck disable=SC1091
. /etc/os-release
CODENAME="${UBUNTU_CODENAME:-${VERSION_CODENAME:-jammy}}"
case "$CODENAME" in
  focal)  UBU_VER="20.04" ;;
  jammy)  UBU_VER="22.04" ;;
  noble)  UBU_VER="24.04" ;;
  *)      UBU_VER="22.04"; warn "Unknown codename '$CODENAME', assuming 22.04 for vendor repos." ;;
esac
ARCH="$(dpkg --print-architecture)"   # amd64
info "Ubuntu base: $CODENAME ($UBU_VER), arch $ARCH"

# ----------------------------- helpers ---------------------------------------
have_cmd() { command -v "$1" >/dev/null 2>&1; }
deb_installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"; }

# Install OR upgrade a single APT package (continues on failure).
apt_pkg() {
  local p="$1"
  if deb_installed "$p"; then
    apt-get install -y --only-upgrade "$p" >/dev/null 2>&1 || true
    info "updated: $p"
  else
    if apt-get install -y "$p" >/dev/null 2>&1; then info "installed: $p"; else warn "APT could not install '$p' (skipping)"; return 1; fi
  fi
}

# Install a list of APT packages, each independently.
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
  if curl -fSL --retry 3 -o "$f" "$url"; then
    apt-get install -y "$f" >/dev/null 2>&1 || { dpkg -i "$f" >/dev/null 2>&1; apt-get -f install -y >/dev/null 2>&1; }
    info "installed/updated from vendor .deb: $label"
  else
    warn "download failed: $label ($url)"; return 1
  fi
}

flatpak_app() {  # flatpak_app APPID
  local id="$1"
  if flatpak info "$id" >/dev/null 2>&1; then
    flatpak update -y "$id" >/dev/null 2>&1 || true; info "updated flatpak: $id"
  else
    flatpak install -y --noninteractive flathub "$id" >/dev/null 2>&1 || { warn "flatpak install failed: $id"; return 1; }
    info "installed flatpak: $id"
  fi
}

# Interactive wait for a manually-downloaded file (reads from the terminal).
prompt_for_file() {  # prompt_for_file "App" /path/to/expected/file "instructions"
  local app="$1" dest="$2" info_txt="$3"
  echo; echo "================ MANUAL DOWNLOAD: $app ================"
  echo "$info_txt"
  echo "Save the file as exactly: $dest"
  echo "Then type 'yes'. Type 'skip' to skip $app."
  while true; do
    printf '[%s] yes/skip: ' "$app"
    local ans; read -r ans </dev/tty || { SKIPPED+=("$app (no tty)"); return 1; }
    case "${ans,,}" in
      yes)  if [ -f "$dest" ]; then return 0; else echo "  Not found at $dest — try again."; fi ;;
      skip) SKIPPED+=("$app"); return 1 ;;
      *)    echo "  Please type 'yes' or 'skip'." ;;
    esac
  done
}

# =============================================================================
# 1. BASE SYSTEM + BUILD DEPENDENCIES (incl. VMware kernel-module deps)
# =============================================================================
step "apt update" apt-get update -y
step "Core tools + build deps" apt_pkgs \
  apt-transport-https ca-certificates curl wget gnupg lsb-release unzip \
  software-properties-common gdebi-core flatpak \
  build-essential gcc make dkms "linux-headers-$(uname -r)" default-jdk

# Flathub remote for the Flatpak fallbacks.
step "Enable Flathub" flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo

# =============================================================================
# 2. THIRD-PARTY APT REPOSITORIES
# =============================================================================
log "Configuring vendor APT repositories"

add_repo google-chrome   https://dl.google.com/linux/linux_signing_key.pub \
  "deb [arch=$ARCH signed-by=/etc/apt/keyrings/google-chrome.gpg] https://dl.google.com/linux/chrome/deb/ stable main" || true

add_repo microsoft-edge  https://packages.microsoft.com/keys/microsoft.asc \
  "deb [arch=$ARCH signed-by=/etc/apt/keyrings/microsoft-edge.gpg] https://packages.microsoft.com/repos/edge stable main" || true

add_repo vscode          https://packages.microsoft.com/keys/microsoft.asc \
  "deb [arch=$ARCH signed-by=/etc/apt/keyrings/vscode.gpg] https://packages.microsoft.com/repos/code stable main" || true

add_repo docker          https://download.docker.com/linux/ubuntu/gpg \
  "deb [arch=$ARCH signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $CODENAME stable" || true

add_repo pgdg            https://www.postgresql.org/media/keys/ACCC4CF8.asc \
  "deb [signed-by=/etc/apt/keyrings/pgdg.gpg] https://apt.postgresql.org/pub/repos/apt ${CODENAME}-pgdg main" || true

add_repo pgadmin         https://www.pgadmin.org/static/packages_pgadmin_org.pub \
  "deb [signed-by=/etc/apt/keyrings/pgadmin.gpg] https://ftp.postgresql.org/pub/pgadmin/pgadmin4/apt/${CODENAME} pgadmin4 main" || true

add_repo dbeaver         https://dbeaver.io/debs/dbeaver.gpg.key \
  "deb [signed-by=/etc/apt/keyrings/dbeaver.gpg] https://dbeaver.io/debs/dbeaver-ce /" || true

add_repo anydesk         https://keys.anydesk.com/repos/DEB-GPG-KEY \
  "deb [signed-by=/etc/apt/keyrings/anydesk.gpg] http://deb.anydesk.com/ all main" || true

add_repo protonvpn       https://repo.protonvpn.com/debian/public_key.asc \
  "deb [signed-by=/etc/apt/keyrings/protonvpn.gpg] https://repo.protonvpn.com/debian stable main" || true

add_repo nodesource      https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
  "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" || true

# Microsoft "prod" feed (PowerShell + .NET) via their config package.
if ! deb_installed packages-microsoft-prod; then
  if curl -fsSL -o "$DOWNLOAD_DIR/ms-prod.deb" "https://packages.microsoft.com/config/ubuntu/${UBU_VER}/packages-microsoft-prod.deb"; then
    dpkg -i "$DOWNLOAD_DIR/ms-prod.deb" >/dev/null 2>&1 || true
  else
    warn "Could not fetch Microsoft prod repo config"
  fi
fi

step "apt update (after adding repos)" apt-get update -y

# =============================================================================
# 3. NATIVE / REPO PACKAGES
# =============================================================================
step "Browsers & comms (repo)"   apt_pkgs google-chrome-stable microsoft-edge-stable firefox
step "Editors / IDEs (repo)"     apt_pkgs code
step "PowerShell + .NET SDK"     apt_pkgs powershell "$DOTNET_SDK"
step "Docker Engine"             apt_pkgs docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
step "PostgreSQL (PGDG latest)"  apt_pkgs postgresql postgresql-client
step "DB tools"                  apt_pkgs dbeaver-ce pgadmin4-desktop
step "AnyDesk"                   apt_pkgs anydesk
step "Proton VPN (Hotspot/Psiphon alt)" apt_pkgs proton-vpn-gnome-desktop
step "Node.js (LTS)"             apt_pkgs nodejs

step "Developer CLI tools"       apt_pkgs git cmake ninja-build openssh-client openssh-server \
                                          openssl putty perl cpanminus pandoc wkhtmltopdf \
                                          python3 python3-pip python3-venv r-base r-base-dev \
                                          proxychains4 remmina remmina-plugin-rdp remmina-plugin-vnc

step "Free optimisation solvers (Gurobi alt)" apt_pkgs glpk-utils coinor-cbc

step "Media & utilities"         apt_pkgs vlc mpv rhythmbox qbittorrent flameshot obs-studio \
                                          kdenlive simplescreenrecorder p7zip-full p7zip-rar unrar \
                                          file-roller gimp krita pinta shotwell gthumb goldendict \
                                          thunderbird calibre anki uget notepadqq geany libreoffice

step "Desktop apps (small)"      apt_pkgs gnome-clocks gnome-sound-recorder cheese gnome-weather \
                                          gnome-calculator gnome-terminal tilix gedit sticky \
                                          gnome-disk-utility usb-creator-gtk nautilus-dropbox \
                                          smartmontools nvme-cli openvpn network-manager-openvpn-gnome

step "OneDrive (abraunegg)"      apt_pkgs onedrive
step "PowerToys-ish (launcher)"  apt_pkgs ulauncher

# TeX Live (MiKTeX equivalent) — large download; kept as its own step.
log "TeX Live (texlive-full — large, this can take a while)"
if apt-get install -y texlive-full >/dev/null 2>&1; then mark_ok "TeX Live"; else mark_fail "TeX Live"; fi

# =============================================================================
# 4. VENDOR .deb DOWNLOADS
# =============================================================================
step "Discord"  install_deb_url "Discord" "https://discord.com/api/download?platform=linux&format=deb"
step "Zoom"     install_deb_url "Zoom"    "https://zoom.us/client/latest/zoom_amd64.deb"
step "Parsec"   install_deb_url "Parsec"  "https://builds.parsec.app/package/parsec-linux.deb"
step "GitKraken (GitHub Desktop alt)" install_deb_url "GitKraken" "https://release.gitkraken.com/linux/gitkraken-amd64.deb"

# =============================================================================
# 5. FLATPAK FALLBACKS
# =============================================================================
step "RealVNC Viewer"  flatpak_app com.realvnc.vncviewer
step "Microsoft Teams" flatpak_app com.github.IsmaelMartinez.teams_for_linux
step "WhatsApp (ZapZap)" flatpak_app com.rtosta.zapzap
step "LocalSend (Quick/Nearby Share)" flatpak_app org.localsend.localsend_app
step "Planify (Microsoft To Do alt)" flatpak_app io.github.alainm23.planify

# =============================================================================
# 6. SCRIPT / BINARY INSTALLERS
# =============================================================================
# rclone (Google Drive) — official installer is self-updating.
step "rclone (Google Drive)" bash -c 'curl -fsSL https://rclone.org/install.sh | bash || rclone selfupdate'

# Miniconda (Anaconda) — latest maintained build; unattended.
log "Miniconda (Anaconda ecosystem)"
if [ -d /opt/miniconda3 ]; then
  /opt/miniconda3/bin/conda update -n base -y conda >/dev/null 2>&1 && mark_ok "Miniconda (updated)" || mark_fail "Miniconda update"
else
  if curl -fsSL -o "$DOWNLOAD_DIR/miniconda.sh" "https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh" \
     && bash "$DOWNLOAD_DIR/miniconda.sh" -b -p /opt/miniconda3 >/dev/null 2>&1; then
    ln -sf /opt/miniconda3/bin/conda /usr/local/bin/conda
    mark_ok "Miniconda"
  else
    mark_fail "Miniconda"
  fi
fi

# LanguageTool (Grammarly alt) — stable zip, needs the JRE installed above.
log "LanguageTool (Grammarly alt)"
if curl -fsSL -o "$DOWNLOAD_DIR/LanguageTool.zip" "https://languagetool.org/download/LanguageTool-stable.zip"; then
  rm -rf /opt/languagetool && mkdir -p /opt/languagetool
  if unzip -q -o "$DOWNLOAD_DIR/LanguageTool.zip" -d /opt/languagetool; then
    cat >/usr/local/bin/languagetool <<'EOF'
#!/usr/bin/env bash
dir="$(find /opt/languagetool -maxdepth 1 -type d -name 'LanguageTool-*' | head -n1)"
exec java -jar "$dir/languagetool.jar" "$@"
EOF
    chmod +x /usr/local/bin/languagetool
    mark_ok "LanguageTool"
  else mark_fail "LanguageTool (unzip)"; fi
else mark_fail "LanguageTool (download)"; fi

# =============================================================================
# 7. POST-INSTALL CONFIG
# =============================================================================
log "Post-install configuration"
systemctl enable --now ssh        >/dev/null 2>&1 || true
systemctl enable --now postgresql >/dev/null 2>&1 || true
if getent group docker >/dev/null 2>&1; then
  systemctl enable --now docker   >/dev/null 2>&1 || true
  if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    usermod -aG docker "$SUDO_USER" || true
    info "Added '$SUDO_USER' to the 'docker' group (re-login to take effect)."
  fi
fi

# =============================================================================
# 8. MANUAL / LOGIN-GATED DOWNLOADS  (always LAST)
# =============================================================================
log "Manual downloads (handled last)"

# --- RStudio: try the vendor URL automatically, fall back to a manual prompt ---
log "RStudio"
RSTUDIO_DEB="$DOWNLOAD_DIR/rstudio.deb"
if curl -fSL --retry 2 -o "$RSTUDIO_DEB" "https://rstudio.org/download/latest/stable/desktop/${CODENAME}/rstudio-latest-amd64.deb" 2>/dev/null \
   && [ -s "$RSTUDIO_DEB" ]; then
  apt-get install -y "$RSTUDIO_DEB" >/dev/null 2>&1 && mark_ok "RStudio" || mark_fail "RStudio"
else
  if prompt_for_file "RStudio" "$RSTUDIO_DEB" \
       "Download RStudio Desktop (.deb) from https://posit.co/download/rstudio-desktop/"; then
    apt-get install -y "$RSTUDIO_DEB" >/dev/null 2>&1 && MANUAL_DONE+=("RStudio") || mark_fail "RStudio (manual)"
  fi
fi

# --- SpotPlayer: vendor .deb, manual download from the site ---
SPOT_DEB="$DOWNLOAD_DIR/spotplayer.deb"
if prompt_for_file "SpotPlayer" "$SPOT_DEB" \
     "Download the Linux/Ubuntu .deb of SpotPlayer from https://spotplayer.ir"; then
  apt-get install -y "$SPOT_DEB" >/dev/null 2>&1 && MANUAL_DONE+=("SpotPlayer") || mark_fail "SpotPlayer (manual)"
fi

# --- VMware Workstation: Broadcom login-gated .bundle ---
VMWARE_BUNDLE="$DOWNLOAD_DIR/VMware-Workstation.bundle"
if prompt_for_file "VMware Workstation" "$VMWARE_BUNDLE" \
     "Download VMware Workstation Pro for Linux (.bundle, now free) from the Broadcom
   support portal: https://support.broadcom.com  (free account required).
   Build deps (kernel headers, dkms, gcc) were already installed above."; then
  chmod +x "$VMWARE_BUNDLE"
  if bash "$VMWARE_BUNDLE" --console --required --eulas-agreed >/dev/null 2>&1; then
    vmware-modconfig --console --install-all >/dev/null 2>&1 || true
    MANUAL_DONE+=("VMware Workstation")
  else
    mark_fail "VMware Workstation (bundle install)"
  fi
fi

# --- Gurobi: commercial, license-gated. Free solvers (glpk/cbc) installed above. ---
GUROBI_TGZ="$DOWNLOAD_DIR/gurobi.tar.gz"
echo
info "Gurobi is commercial and license-gated; the free solvers GLPK & CBC were installed."
if prompt_for_file "Gurobi" "$GUROBI_TGZ" \
     "OPTIONAL: download the Gurobi Optimizer Linux tarball from https://www.gurobi.com/downloads/
   (account + license required). Skip if you will use the free solvers instead."; then
  tar -xzf "$GUROBI_TGZ" -C /opt && MANUAL_DONE+=("Gurobi (extracted to /opt — set GUROBI_HOME + license)") || mark_fail "Gurobi (extract)"
fi

# =============================================================================
# 9. SUMMARY
# =============================================================================
echo
echo "============================ SUMMARY ============================"
printf 'Installed/updated OK : %s\n' "${#OK[@]}"
printf 'Manual completed     : %s\n' "${#MANUAL_DONE[@]}"
printf 'Skipped              : %s\n' "${#SKIPPED[@]}"
printf 'Failed               : %s\n' "${#FAIL[@]}"
[ "${#MANUAL_DONE[@]}" -gt 0 ] && { echo; echo "Manual done:";  printf '  - %s\n' "${MANUAL_DONE[@]}"; }
[ "${#SKIPPED[@]}"     -gt 0 ] && { echo; echo "Skipped:";      printf '  - %s\n' "${SKIPPED[@]}"; }
[ "${#FAIL[@]}"        -gt 0 ] && { echo; echo "Failed (review):"; printf '  - %s\n' "${FAIL[@]}"; }
echo
echo "Done. A reboot is recommended (kernel modules, docker group, services)."
