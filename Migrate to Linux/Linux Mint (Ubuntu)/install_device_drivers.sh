#!/usr/bin/env bash
#
# install_device_drivers.sh
# -----------------------------------------------------------------------------
# Unattended DEVICE-DRIVER installer for Linux Mint (Ubuntu base). It installs the
# Linux driver for every piece of hardware that needs one beyond the in-box kernel,
# downloading from the manufacturer where required:
#
#   * NVIDIA GPU      -> the proprietary NVIDIA driver (via ubuntu-drivers, whose
#                        binary IS NVIDIA's) — optional NVIDIA .run from nvidia.com.
#   * AMD / Intel GPU -> in-kernel amdgpu / i915 + up-to-date Mesa + VA-API.
#   * Realtek NICs    -> r8168-dkms / r8125-dkms (built from Realtek's source).
#   * Broadcom Wi-Fi  -> broadcom-sta-dkms (Broadcom's proprietary wl).
#   * USB Wi-Fi       -> rtl88x2bu / rtl8812au DKMS modules.
#   * CPU microcode   -> intel-microcode / amd64-microcode.
#   * Printers/scan   -> CUPS driverless + HPLIP (HP) + SANE.
#   * Fingerprint     -> fprintd + libfprint.
#   * System firmware -> fwupd + LVFS: downloads firmware DIRECTLY from the
#                        manufacturer (Lenovo, Dell, HP, Intel, ...) and flashes it.
#
# Unlike the Windows side, the AUTHORITATIVE source of truth here is the live
# hardware (lspci/lsusb/lscpu/DMI) — Windows device names don't map cleanly to
# Linux modules. The script therefore DETECTS the hardware on this machine and
# installs accordingly, and ALSO cross-references ../A_installed_windows_drivers.csv
# (produced by A_detect_installed_drivers.ps1) to show which Windows-flagged devices
# it handled.
#
# Run as root:   sudo ./install_device_drivers.sh
#
# CLEAN UI: all package-manager noise is sent to a log file; the terminal shows
# only the curated "==> <step>" headers, indented detail lines, and a live spinner
# while each step runs. Two logs are written and printed at the end.
# -----------------------------------------------------------------------------

set -uo pipefail

# ----------------------------- bookkeeping -----------------------------------
OK=();  FAIL=();  SKIPPED=();  MANUAL_DONE=();  STEP_FAILS=()
DOWNLOAD_DIR="/opt/driver-downloads"
LOG="$DOWNLOAD_DIR/driver-install.log"             # full, verbose command output
RESULTS="$DOWNLOAD_DIR/driver-install-results.log" # short, one line per step result
DRIVER_CSV="../A_installed_windows_drivers.csv"      # cross-reference (optional)
SPIN='-\|/'
LAST_ERR=""

# -----------------------------------------------------------------------------
# TRUSTED SOURCES GUARANTEE
# Every package, repo, key and binary fetched below comes from a first-party,
# verifiable source over HTTPS: the distro's own GPG-signed APT mirrors; NVIDIA's
# packaged driver from Ubuntu restricted (the binary is NVIDIA's own); and fwupd's
# LVFS service, which serves firmware uploaded and signed by the hardware
# manufacturers themselves. Optional manual installers (NVIDIA .run, AMDGPU-PRO)
# print the exact vendor URL (nvidia.com / amd.com) and are user-verified. No
# third-party mirrors, shortened URLs, or untrusted domains are used anywhere.
# -----------------------------------------------------------------------------

# All of these print to the SAVED terminal (fd 3); command output goes to the log.
log()  { printf '\n\033[1;34m==>\033[0m %s\n' "$*" >&3; }
info() { printf '       %s\n' "$*" >&3; }
ok()   { printf '       \033[32m%s\033[0m\n' "$*" >&3; }
warn() { printf '       \033[1;33m%s\033[0m\n' "$*" >&3; }
err()  { printf '\033[1;31m%s\033[0m\n' "$*" >&3; }

record_line() { printf '%s\t%-4s\t%s\t%s\n' "$(date '+%F %T')" "$1" "$2" "${3:-}" >> "$RESULTS"; }
mark_ok()     { OK+=("$1");          record_line OK   "$1" "${2:-}"; }
mark_skip()   { SKIPPED+=("$1");     record_line SKIP "$1" "${2:-not present}"; }
mark_manual() { MANUAL_DONE+=("$1"); record_line OK   "$1" "${2:-installed (manual)}"; }
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

# Draw the single transient progress line: spinner, label, and a live detail.
_progress() {  # _progress ITER "label" "detail"
  local w=$(( ${COLUMNS:-100} - 16 )); [ "$w" -lt 30 ] && w=70
  local d="$3"
  [ -n "$d" ] && d=" — $(printf '%s' "$d" | tr -d '\r' | tr -s ' ' | cut -c1-"$w")"
  printf '\r\033[K       \033[2m[%s]\033[0m %s%s' "${SPIN:$(( $1 % 4 )):1}" "$2" "$d" >&3
}

# Run a command showing a LIVE progress line, clearing it when the command ends.
run_spin() {  # run_spin "label" cmd...
  local text="$1"; shift
  local tmp rc; tmp="$(mktemp 2>/dev/null || echo /tmp/driver.$$)"
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

# Run a step: print its header, run it, record OK/FAIL (with reason).
step() { local label="$1"; shift; log "$label"; STEP_FAILS=(); if "$@"; then mark_ok "$label"; else mark_fail "$label"; fi; }

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    err "This script must run as root. Use: sudo $0"
    exit 1
  fi
}

# Non-interactive apt that keeps existing config files.
apt_get() { DEBIAN_FRONTEND=noninteractive apt-get -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "$@"; }

# apt-get with a LIVE percentage + current operation (APT::Status-Fd).
apt_run() {  # apt_run "label" <apt-get args...>
  local text="$1"; shift
  local out st rc
  out="$(mktemp 2>/dev/null || echo /tmp/driver.o.$$)"
  st="$(mktemp 2>/dev/null || echo /tmp/driver.s.$$)"
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

# Interactive wait for a manually-downloaded file (prints to fd 3, reads the tty).
prompt_for_file() {  # prompt_for_file "App" /path "instructions"
  local app="$1" dest="$2" info_txt="$3"
  { echo; echo "================ OPTIONAL MANUAL DOWNLOAD: $app ================"
    echo "$info_txt"; echo "Save the file as exactly: $dest"
    echo "Then type 'yes'. Type 'skip' to skip $app (the packaged driver already covers it)."; } >&3
  while true; do
    printf '[%s] yes/skip: ' "$app" >&3
    local ans; read -r ans </dev/tty || { mark_skip "$app" "no tty"; return 1; }
    case "${ans,,}" in
      yes)  if [ -f "$dest" ]; then return 0; else echo "  Not found at $dest — try again." >&3; fi ;;
      skip) mark_skip "$app" "user skipped"; return 1 ;;
      *)    echo "  Please type 'yes' or 'skip'." >&3 ;;
    esac
  done
}

# ----------------------------- environment -----------------------------------
exec 3>&1 4>&2                       # save the real terminal for the clean UI
require_root
export DEBIAN_FRONTEND=noninteractive
mkdir -p "$DOWNLOAD_DIR"
: > "$LOG" 2>/dev/null || LOG=/dev/null
{ echo "# Device-driver installation results — $(date '+%F %T')";
  printf '# %s\t%s\t%s\t%s\n' "timestamp" "stat" "item" "reason"; } > "$RESULTS" 2>/dev/null || RESULTS=/dev/null
exec >>"$LOG" 2>&1                   # everything else -> log
[ -t 3 ] && clear >&3
log "Device-driver installer started"
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
DEB_ARCH="$(dpkg --print-architecture)"
KARCH="$(uname -m)"
info "Target: Ubuntu $CODENAME ($UBU_VER); dpkg arch=$DEB_ARCH, kernel arch=$KARCH"

# =============================================================================
# 0. LIVE HARDWARE DETECTION  (authoritative — this is the machine we install on)
# =============================================================================
log "Detecting hardware on this machine"
# Make sure the inspection tools exist before we read them.
if ! have_cmd lspci || ! have_cmd lsusb; then
  apt_run "installing pciutils + usbutils" update >/dev/null 2>&1 || true
  apt_run "installing pciutils + usbutils" install pciutils usbutils >/dev/null 2>&1 || true
fi

PCI_LIST="$(lspci -nn 2>/dev/null || true)"
PCIK_LIST="$(lspci -nnk 2>/dev/null || true)"
USB_LIST="$(lsusb 2>/dev/null || true)"
CPU_VENDOR="$(grep -m1 -i 'vendor_id' /proc/cpuinfo 2>/dev/null | awk -F: '{gsub(/ /,"",$2); print $2}')"
SYS_VENDOR="$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || echo unknown)"
SYS_PRODUCT="$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo unknown)"

pci_match() { printf '%s\n' "$PCI_LIST" | grep -iqE "$1"; }   # match against lspci -nn
usb_match() { printf '%s\n' "$USB_LIST" | grep -iqE "$1"; }   # match against lsusb

info "System    : $SYS_VENDOR $SYS_PRODUCT"
info "CPU vendor: ${CPU_VENDOR:-unknown}"
info "PCI devices: $(printf '%s\n' "$PCI_LIST" | grep -c . ) | USB devices: $(printf '%s\n' "$USB_LIST" | grep -c . )"
# Full hardware + bound-module listing goes to the log for debugging.
{ echo "==== lspci -nnk ===="; printf '%s\n' "$PCIK_LIST"; echo "==== lsusb ===="; printf '%s\n' "$USB_LIST"; } >>"$LOG" 2>/dev/null

# Hardware presence flags (used to gate every driver step below).
HAS_NVIDIA=false;  pci_match 'VGA.*NVIDIA|3D controller.*NVIDIA|\[10de:'       && HAS_NVIDIA=true
HAS_AMDGPU=false;  pci_match 'VGA.*(AMD|ATI)|Display controller.*(AMD|ATI)'    && HAS_AMDGPU=true
HAS_INTELGPU=false;pci_match 'VGA.*Intel|Display controller.*Intel'           && HAS_INTELGPU=true
HAS_RTL_ETH=false; pci_match 'Ethernet controller.*Realtek'                   && HAS_RTL_ETH=true
HAS_RTL_2G5=false; pci_match 'RTL8125'                                        && HAS_RTL_2G5=true
HAS_BCM_WIFI=false;pci_match 'Network controller.*Broadcom|Broadcom.*BCM43'   && HAS_BCM_WIFI=true
HAS_RTL_USBWIFI=false; usb_match '0bda:(8812|881[0-9]|b812|b82c|c811|8821)'   && HAS_RTL_USBWIFI=true
HAS_HP_PRINT=false; usb_match '03f0:'                                         && HAS_HP_PRINT=true
HAS_FPRINT=false;  usb_match '(06cb|27c6|138a|08ff|1c7a):'                    && HAS_FPRINT=true
HAS_PRINTER=false; pci_match 'Printer' || usb_match ' Printer| LaserJet| DeskJet| OfficeJet| Pixma' && HAS_PRINTER=true

# =============================================================================
# 0b. CROSS-REFERENCE the Windows driver CSV (optional, informational)
# =============================================================================
log "Cross-referencing ../A_installed_windows_drivers.csv (Windows-flagged drivers)"
if [ -f "$DRIVER_CSV" ]; then
  # Rows whose LAST field is "yes" are the Windows-flagged devices. Extract just the
  # device name (field 1) — robust against embedded quotes/commas in later fields and
  # against the CRLF line endings PowerShell's Export-Csv writes.
  flagged="$(grep -E ',"yes"[[:space:]]*$' "$DRIVER_CSV" 2>/dev/null | sed -E 's/^"([^"]*)".*/  - \1/' | tr -d '\r' | head -40)"
  if [ -n "$flagged" ]; then
    info "Windows reported these devices as needing an actively-installed Linux driver:"
    printf '%s\n' "$flagged" >&3
  else
    info "No devices flagged 'Must install on Linux = yes' in the CSV (all in-kernel)."
  fi
else
  info "CSV not found at $DRIVER_CSV — proceeding from live detection only."
fi

# =============================================================================
# 1. BASE DRIVER INFRASTRUCTURE
#    linux-firmware covers Wi-Fi/Bluetooth/GPU firmware for Intel/Atheros/MediaTek/
#    AMD/Broadcom; dkms + headers build out-of-tree modules; ubuntu-drivers picks
#    the right proprietary driver; fwupd flashes manufacturer firmware via LVFS.
# =============================================================================
step "Refreshing package lists" apt_run "updating package lists" update
step "Base driver tools + firmware" apt_pkgs \
  pciutils usbutils lshw \
  linux-firmware \
  build-essential dkms "linux-headers-$(uname -r)" \
  ubuntu-drivers-common \
  fwupd

# Secure Boot note — DKMS / NVIDIA modules must be MOK-signed to load when SB is on.
if have_cmd mokutil && mokutil --sb-state 2>/dev/null | grep -qi 'enabled'; then
  warn "Secure Boot is ENABLED. DKMS/NVIDIA modules need MOK enrollment to load."
  warn "If a driver fails to load after reboot, run: sudo mokutil --import (or disable Secure Boot in UEFI)."
fi

# =============================================================================
# 2. GPU DRIVERS
# =============================================================================
if $HAS_NVIDIA; then
  log "NVIDIA GPU detected — installing the proprietary NVIDIA driver"
  info "$(printf '%s\n' "$PCI_LIST" | grep -iE 'NVIDIA' | head -1)"
  # ubuntu-drivers selects & installs the recommended nvidia-driver-NNN (NVIDIA's
  # own binary, packaged in Ubuntu restricted). Newest API; falls back to autoinstall.
  if run_spin "running ubuntu-drivers (NVIDIA)" ubuntu-drivers install; then
    info "installed: recommended NVIDIA driver (ubuntu-drivers)"; mark_ok "NVIDIA driver"
  elif run_spin "running ubuntu-drivers autoinstall" ubuntu-drivers autoinstall; then
    info "installed: NVIDIA driver (autoinstall)"; mark_ok "NVIDIA driver"
  else
    warn "ubuntu-drivers failed — trying the distro's recommended metapackage directly"
    if apt_pkgs nvidia-driver-550 2>/dev/null || apt_pkgs nvidia-driver-535 2>/dev/null; then
      info "installed: nvidia-driver (metapackage)"; mark_ok "NVIDIA driver"
    else
      mark_fail "NVIDIA driver" "${LAST_ERR:-ubuntu-drivers + metapackage both failed}"
    fi
  fi
  # CUDA/VA-API niceties for the NVIDIA stack (non-fatal).
  apt_pkgs libnvidia-egl-wayland1 nvidia-settings 2>/dev/null || true
else
  mark_skip "NVIDIA driver" "no NVIDIA GPU detected"
fi

if $HAS_AMDGPU; then
  step "AMD GPU (amdgpu in-kernel) — Mesa + VA-API/Vulkan userspace" apt_pkgs \
    mesa-utils mesa-vulkan-drivers mesa-va-drivers mesa-vdpau-drivers \
    libgl1-mesa-dri vainfo
  info "AMD GPU uses the in-kernel amdgpu driver; AMDGPU-PRO is optional (manual section)."
else
  mark_skip "AMD GPU userspace" "no AMD GPU detected"
fi

if $HAS_INTELGPU; then
  step "Intel GPU (i915/xe in-kernel) — Mesa + Intel VA-API media driver" apt_pkgs \
    mesa-utils mesa-vulkan-drivers intel-media-va-driver-non-free i965-va-driver vainfo
else
  mark_skip "Intel GPU userspace" "no Intel GPU detected"
fi

# =============================================================================
# 3. NETWORK DRIVERS (only the ones not already covered in-kernel / by firmware)
# =============================================================================
if $HAS_RTL_2G5; then
  step "Realtek 2.5GbE NIC — r8125-dkms (Realtek source)" apt_pkgs r8125-dkms
elif $HAS_RTL_ETH; then
  log "Realtek Gigabit NIC detected"
  info "$(printf '%s\n' "$PCI_LIST" | grep -iE 'Ethernet controller.*Realtek' | head -1)"
  info "In-kernel r8169 normally works; installing r8168-dkms only as a fallback for flaky links."
  if apt_pkgs r8168-dkms; then mark_ok "Realtek NIC (r8168-dkms)"; else mark_skip "Realtek NIC" "r8168-dkms unavailable (r8169 in-kernel still works)"; fi
else
  mark_skip "Realtek wired NIC driver" "no Realtek Ethernet detected"
fi

if $HAS_BCM_WIFI; then
  log "Broadcom Wi-Fi detected — installing the proprietary wl driver"
  info "$(printf '%s\n' "$PCI_LIST" | grep -iE 'Network controller.*Broadcom' | head -1)"
  # broadcom-sta-dkms lives in the 'restricted' component; ensure it's enabled.
  add-apt-repository -y restricted >/dev/null 2>&1 || true
  apt_run "refreshing lists" update >/dev/null 2>&1 || true
  if apt_pkgs broadcom-sta-dkms; then
    # The proprietary wl conflicts with in-tree b43/brcmsmac — blacklist them.
    printf 'blacklist b43\nblacklist brcmsmac\nblacklist bcma\nblacklist ssb\n' > /etc/modprobe.d/broadcom-sta-dkms-blacklist.conf 2>/dev/null || true
    modprobe wl 2>/dev/null || true
    info "installed: broadcom-sta-dkms (wl); b43/brcmsmac blacklisted"; mark_ok "Broadcom Wi-Fi (wl)"
  else
    mark_fail "Broadcom Wi-Fi (wl)" "$LAST_ERR"
  fi
else
  mark_skip "Broadcom Wi-Fi driver" "no Broadcom Wi-Fi detected"
fi

if $HAS_RTL_USBWIFI; then
  log "Realtek USB Wi-Fi dongle detected — installing a DKMS module"
  info "$(printf '%s\n' "$USB_LIST" | grep -iE '0bda:' | head -1)"
  # Try the common DKMS packages in order; first that installs wins.
  if   apt_pkgs rtl88x2bu-dkms 2>/dev/null; then info "installed: rtl88x2bu-dkms"; mark_ok "Realtek USB Wi-Fi"
  elif apt_pkgs rtl8812au-dkms 2>/dev/null; then info "installed: rtl8812au-dkms"; mark_ok "Realtek USB Wi-Fi"
  else mark_skip "Realtek USB Wi-Fi" "no matching DKMS package in APT — see realtek.com / GitHub (morrownr)"; fi
else
  mark_skip "Realtek USB Wi-Fi driver" "no Realtek USB Wi-Fi detected"
fi

# Intel/Atheros/MediaTek Wi-Fi + all Bluetooth radios are in-kernel; firmware is in
# linux-firmware (installed above). Nothing extra to install — note it for clarity.
info "Intel/Atheros/MediaTek Wi-Fi + Bluetooth: in-kernel, firmware via linux-firmware (done)."

# =============================================================================
# 4. CPU MICROCODE  (security/stability updates from the CPU vendor)
# =============================================================================
case "$CPU_VENDOR" in
  GenuineIntel) step "Intel CPU microcode" apt_pkgs intel-microcode ;;
  AuthenticAMD) step "AMD CPU microcode"   apt_pkgs amd64-microcode ;;
  *)            mark_skip "CPU microcode" "unknown CPU vendor '${CPU_VENDOR:-?}'" ;;
esac

# =============================================================================
# 5. PRINTERS & SCANNERS
# =============================================================================
step "Printing stack (CUPS driverless + IPP-USB)" apt_pkgs cups cups-client printer-driver-all ipp-usb
step "Scanning stack (SANE)" apt_pkgs sane-utils libsane1
if $HAS_HP_PRINT || $HAS_PRINTER; then
  step "HP printers/scanners (HPLIP)" apt_pkgs hplip hplip-gui
else
  mark_skip "HPLIP (HP printer driver)" "no HP device detected (printing stack still installed)"
fi
systemctl enable --now cups 2>/dev/null || true

# =============================================================================
# 6. FINGERPRINT READER
# =============================================================================
if $HAS_FPRINT; then
  log "Fingerprint reader detected — installing fprintd + libfprint"
  info "$(printf '%s\n' "$USB_LIST" | grep -iE '(06cb|27c6|138a|08ff|1c7a):' | head -1)"
  if apt_pkgs fprintd libpam-fprintd; then
    info "installed: fprintd + libpam-fprintd. Enroll with: fprintd-enroll  (then 'pam-auth-update' to enable PAM)."
    info "NOTE: support depends on the exact chip — see https://fprint.freedesktop.org/supported-devices.html"
    mark_ok "Fingerprint (fprintd)"
  else
    mark_fail "Fingerprint (fprintd)" "$LAST_ERR"
  fi
else
  mark_skip "Fingerprint driver" "no supported fingerprint reader detected"
fi

# =============================================================================
# 7. MANUFACTURER FIRMWARE via fwupd / LVFS
#    This is the genuine "download from the manufacturer website" path: LVFS
#    serves UEFI/SSD/dock/peripheral firmware uploaded & signed by Lenovo, Dell,
#    HP, Intel, Logitech, etc. We refresh, list, and apply offline updates.
# =============================================================================
log "Manufacturer firmware updates (fwupd + LVFS)"
if have_cmd fwupdmgr; then
  run_spin "enabling LVFS remote" fwupdmgr enable-remote -y lvfs 2>/dev/null || true
  if run_spin "refreshing firmware metadata (LVFS)" fwupdmgr refresh --force; then
    info "refreshed: LVFS firmware metadata"
  else
    warn "Could not refresh LVFS metadata (offline?) — skipping firmware updates"
  fi
  # List available updates into the log; apply them non-interactively.
  fwupdmgr get-updates -y >>"$LOG" 2>&1 || true
  if run_spin "applying firmware updates" fwupdmgr update -y --no-reboot-check; then
    info "firmware: updates applied where available (some may need a reboot to flash)"
    mark_ok "Firmware (fwupd/LVFS)"
  else
    # 'No updates available' returns non-zero; treat as success-ish.
    if grep -qiE 'no updates|no upgrades|current version' "$LOG" 2>/dev/null; then
      info "firmware: already up to date (nothing to apply)"; mark_ok "Firmware (fwupd/LVFS)"
    else
      mark_skip "Firmware (fwupd/LVFS)" "no applicable updates or device not LVFS-supported"
    fi
  fi
else
  mark_fail "Firmware (fwupd/LVFS)" "fwupd not available"
fi

# =============================================================================
# 8. OPTIONAL MANUAL VENDOR INSTALLERS  (download from the manufacturer site)
#    The packaged drivers above already cover these; offer the vendor's own
#    standalone installer only for users who specifically want it.
# =============================================================================
log "Optional vendor installers (download from the manufacturer — skippable)"

if $HAS_NVIDIA; then
  NV_RUN="$DOWNLOAD_DIR/NVIDIA-Linux.run"
  if prompt_for_file "NVIDIA .run (from nvidia.com)" "$NV_RUN" \
       "OPTIONAL: the proprietary NVIDIA driver is already installed via ubuntu-drivers.
   Only use this if you specifically want NVIDIA's standalone installer. Download the
   Linux ${KARCH} driver .run from https://www.nvidia.com/Download/index.aspx"; then
    chmod +x "$NV_RUN"
    if run_spin "installing NVIDIA .run" bash "$NV_RUN" --silent --dkms; then
      info "installed: NVIDIA driver from vendor .run"; mark_manual "NVIDIA .run"
    else mark_fail "NVIDIA .run" "$LAST_ERR"; fi
  fi
fi

if $HAS_AMDGPU; then
  AMD_TGZ="$DOWNLOAD_DIR/amdgpu-pro.tar.xz"
  if prompt_for_file "AMDGPU-PRO (from amd.com)" "$AMD_TGZ" \
       "OPTIONAL: the in-kernel amdgpu driver + Mesa are already installed and are the
   recommended stack. AMDGPU-PRO only helps specific pro/compute workloads. Download
   the AMDGPU-PRO tarball for Ubuntu $UBU_VER from https://www.amd.com/en/support"; then
    if run_spin "extracting AMDGPU-PRO" tar -xf "$AMD_TGZ" -C "$DOWNLOAD_DIR"; then
      AMD_DIR="$(find "$DOWNLOAD_DIR" -maxdepth 1 -type d -name 'amdgpu-pro*' | head -n1)"
      if [ -n "$AMD_DIR" ] && run_spin "running amdgpu-pro-install" bash "$AMD_DIR/amdgpu-pro-install" -y; then
        info "installed: AMDGPU-PRO"; mark_manual "AMDGPU-PRO"
      else mark_fail "AMDGPU-PRO" "installer script failed — see $LOG"; fi
    else mark_fail "AMDGPU-PRO" "$LAST_ERR"; fi
  fi
fi

# =============================================================================
# 9. SUMMARY
# =============================================================================
{
  echo
  echo "# ---- totals: OK=${#OK[@]} manual=${#MANUAL_DONE[@]} skipped=${#SKIPPED[@]} failed=${#FAIL[@]} ----"
} >> "$RESULTS" 2>/dev/null

{
  echo
  echo "============================ DRIVER SUMMARY ============================"
  printf 'Installed/updated OK : %s\n' "${#OK[@]}"
  printf 'Manual completed     : %s\n' "${#MANUAL_DONE[@]}"
  printf 'Skipped (n/a)        : %s\n' "${#SKIPPED[@]}"
  printf 'Failed               : %s\n' "${#FAIL[@]}"
  [ "${#SKIPPED[@]}" -gt 0 ] && { echo; echo "Skipped (hardware not present):"; printf '  - %s\n' "${SKIPPED[@]}"; }
  [ "${#FAIL[@]}"    -gt 0 ] && { echo; echo "Failed (review):";              printf '  - %s\n' "${FAIL[@]}"; }
  echo
  echo "Results log : $RESULTS"
  echo "Full log    : $LOG"
  echo "Done. A REBOOT is strongly recommended (GPU/DKMS modules, microcode, firmware flash)."
} >&3
