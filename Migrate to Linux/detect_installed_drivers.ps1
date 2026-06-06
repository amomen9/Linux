<#
.SYNOPSIS
    Inventories EVERY device driver on this Windows PC and rates how each device is
    handled on Linux: whether the driver is in-kernel, needs a DKMS/proprietary
    module, needs firmware, or needs a vendor download — plus the Linux module/
    package name, the manufacturer's Linux download page (when a vendor driver is
    needed), and whether you must actively install something on Linux.

.DESCRIPTION
    The script produces installed_windows_drivers.csv with 12 columns:

      MACHINE-DERIVED (read live from this PC via Win32_PnPSignedDriver, never
      hand-authored):
        Device Name        the PnP device's friendly name
        Device Class       PnP class (Display, Net, Bluetooth, Printer, ...)
        Manufacturer       device manufacturer
        Driver Version     installed driver version
        Driver Date        driver date (yyyy-MM-dd)
        Driver Provider    who signed/provides the driver (NVIDIA, Microsoft, ...)
        Hardware ID        the bus ID (PCI\VEN_10DE&DEV_... or USB\VID_...&PID_...)
                           — the only reliable key to the real silicon

      KNOWLEDGE-DERIVED (classified in code from the class + the PCI/USB vendor ID
      in the Hardware ID — the single place to tweak is the $DriverKB table below):
        Linux Driver Status   one or more flags, normalised to a fixed order:
                                In-Kernel ; Generic Driver ; Firmware Required ;
                                Kernel Module (DKMS) ; Proprietary Driver ;
                                Vendor Driver ; Not Applicable ; Needs Review
        Linux Driver / Module the kernel module or package that drives the device
                              on Linux (amdgpu, iwlwifi, nvidia-driver-NNN,
                              r8168-dkms, hplip, ...)
        Vendor Download       the manufacturer's official Linux driver page, filled
                              only when a vendor download is actually needed
        Notes                 short human note about the Linux situation
        Must install on Linux yes/no — DERIVED: "yes" when the device needs an
                              actively-installed driver (proprietary, DKMS, or a
                              vendor download); "no" when the in-box kernel + the
                              base linux-firmware package already cover it.

    How the data is sourced: the machine columns are read fresh from
    Win32_PnPSignedDriver and are never edited. The four curated columns are derived
    by Classify-Driver from the device class and the PCI/USB vendor ID embedded in
    the Hardware ID, using the $DriverKB rule table (researched June 2026).

    Noise removed before rating: by default only real hardware buses are listed
    (PCI, USB, ACPI, HID, SCSI, NVMe, etc.). Root-enumerated / software / SWD
    virtual devices are dropped unless -IncludeVirtualDevices is given.

.PARAMETER OutputPath
    CSV path. Default: installed_windows_drivers.csv beside this script.
.PARAMETER IncludeVirtualDevices
    Keep ROOT\, SW\ and SWD\ software/virtual devices (off by default).
.PARAMETER IncludeMicrosoftInbox
    Keep generic Microsoft in-box drivers for standard devices that need no action
    on Linux (off by default — they only add noise to the report).

.EXAMPLE
    .\detect_installed_drivers.ps1
    .\detect_installed_drivers.ps1 -IncludeVirtualDevices
#>

[CmdletBinding()]
param(
    # Resolved in the body so an empty $PSScriptRoot (Code Runner / selection) can't
    # break parameter binding.
    [string] $OutputPath,
    [switch] $IncludeVirtualDevices,
    [switch] $IncludeMicrosoftInbox
)

$ErrorActionPreference = 'Stop'

# Resolve the output path robustly: prefer the script's own folder, then the folder
# of the running command, then the current directory.
if (-not $OutputPath) {
    $scriptDir = $PSScriptRoot
    if (-not $scriptDir -and $PSCommandPath)               { $scriptDir = Split-Path -Parent $PSCommandPath }
    if (-not $scriptDir -and $MyInvocation.MyCommand.Path) { $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
    if (-not $scriptDir)                                   { $scriptDir = (Get-Location).Path }
    $OutputPath = Join-Path $scriptDir 'installed_windows_drivers.csv'
}

# ---------------------------------------------------------------------------
# 0. HELPERS  (defined before use)
# ---------------------------------------------------------------------------

# Safely access a property that may not exist (some CIM instances lack fields).
function Safe-Property {
    param($Obj, [string] $Name, $Default = $null)
    try { $Obj.$Name } catch { $Default }
}

# Pull the 4-hex PCI/USB vendor ID out of a Hardware ID string.
#   "PCI\VEN_10DE&DEV_1F95&..."  -> "10DE"
#   "USB\VID_0BDA&PID_8153&..."  -> "0BDA"
function Get-VendorId {
    param([string] $HardwareId)
    if (-not $HardwareId) { return '' }
    if ($HardwareId -match 'VEN_([0-9A-Fa-f]{4})') { return $Matches[1].ToUpperInvariant() }
    if ($HardwareId -match 'VID_([0-9A-Fa-f]{4})') { return $Matches[1].ToUpperInvariant() }
    return ''
}

# The bus prefix (PCI / USB / ACPI / HID / ROOT / SWD ...) of a Hardware ID.
function Get-BusPrefix {
    param([string] $HardwareId)
    if (-not $HardwareId) { return '' }
    if ($HardwareId -match '^([A-Za-z0-9]+)\\') { return $Matches[1].ToUpperInvariant() }
    return ''
}

# Map a PCI/USB vendor ID to a readable manufacturer name (display only).
$VendorIdName = @{
    '10DE'='NVIDIA'; '1002'='AMD/ATI'; '1022'='AMD'; '8086'='Intel'; '10EC'='Realtek'
    '14E4'='Broadcom'; '168C'='Qualcomm Atheros'; '17CB'='Qualcomm'; '14C3'='MediaTek'
    '1814'='Ralink/MediaTek'; '0E8D'='MediaTek'; '1969'='Qualcomm Atheros'; '11AB'='Marvell'
    '144D'='Samsung'; '1C5C'='SK hynix'; '1E0F'='KIOXIA'; '1987'='Phison'; '15B7'='Western Digital'
    '8087'='Intel'; '0BDA'='Realtek'; '0CF3'='Qualcomm Atheros'; '13D3'='IMC Networks'
    '04CA'='Lite-On'; '0489'='Foxconn'; '0B05'='ASUS'; '06CB'='Synaptics'; '27C6'='Goodix'
    '138A'='Validity/Synaptics'; '08FF'='AuthenTec'; '1C7A'='LighTuning'; '04F2'='Chicony'
    '5986'='Acer/Bison'; '0C45'='Sonix'; '1D6B'='Linux Foundation'; '03F0'='HP'; '04A9'='Canon'
    '04B8'='Epson'; '04E8'='Samsung'; '0924'='Xerox'; '413C'='Dell'; '17EF'='Lenovo'
}

# ---------------------------------------------------------------------------
# 1. KNOWLEDGE BASE  -- one ordered rule list. First matching rule wins, so put
#    specific rules (a vendor in a class) before generic class fallbacks.
#
#    Each rule:
#       Cls  = regex matched against Device Class (case-insensitive), or '' for any
#       Ven  = regex matched against the PCI/USB vendor ID,           or '' for any
#       Name = regex matched against the Device Name,                 or '' for any
#       Bus  = regex matched against the bus prefix (PCI/USB/BTHENUM), or '' for any
#       S    = Linux Driver Status flags (';'-separated)
#       D    = Linux driver / module / package
#       U    = vendor Linux download page (only when a vendor download is needed)
#       N    = short note
# ---------------------------------------------------------------------------
$DriverKB = @(
    # ---- Paired Bluetooth peripherals (host BT radio handles the link) ----
    @{ Cls=''; Ven=''; Name=''; Bus='^BTH'; S='Not Applicable';
       D='BlueZ (bluez) — pairs via the in-kernel Bluetooth radio';
       U=''; N='Paired Bluetooth peripheral (headset/phone/etc.) — no driver to install; BlueZ handles pairing.' }

    # ---- USB4 / Thunderbolt ----
    @{ Cls=''; Ven=''; Name='USB4|Thunderbolt'; Bus=''; S='In-Kernel';
       D='thunderbolt (in-kernel) + boltd'; U=''; N='USB4/Thunderbolt — in-kernel; "boltctl" authorises devices.' }

    # ---- Neural / AI accelerators (NPU) ----
    @{ Cls='ComputeAccelerator'; Ven='8086'; Name='AI Boost|NPU|Neural|VPU';
       S='In-Kernel; Firmware Required'; D='intel_vpu (Linux 6.8+) + linux-firmware (intel/vpu)';
       U='https://github.com/intel/linux-npu-driver';
       N='Intel AI Boost NPU: intel_vpu lands in recent kernels; user-space stack from intel/linux-npu-driver.' }
    @{ Cls='ComputeAccelerator'; Ven=''; Name=''; S='In-Kernel; Needs Review';
       D='vendor accelerator driver (check on Linux)'; U=''; N='Compute accelerator — verify Linux support for the exact part.' }

    # ---- Audio post-processing software (no Linux driver) ----
    @{ Cls='AudioProcessingObject'; Ven=''; Name=''; S='Not Applicable';
       D='EasyEffects (PipeWire DSP) provides comparable EQ/effects';
       U=''; N='Vendor audio enhancement (Nahimic/Dolby/DTS APO) — no Linux driver; EasyEffects is the closest equivalent.' }

    # ---- GPU / Display ----
    @{ Cls='Display'; Ven='10DE'; Name=''; S='Proprietary Driver; Kernel Module (DKMS)';
       D='nvidia-driver-NNN (proprietary) — or in-kernel "nouveau" as a fallback';
       U='https://www.nvidia.com/Download/index.aspx';
       N='NVIDIA GPU: install the proprietary driver (ubuntu-drivers / nvidia-driver-NNN). nouveau works but is slower.' }
    @{ Cls='Display'; Ven='1002'; Name=''; S='In-Kernel; Firmware Required';
       D='amdgpu (in-kernel) + Mesa (mesa-vulkan-drivers, mesa-va-drivers)';
       U=''; N='AMD GPU: amdgpu is in the kernel; just install up-to-date Mesa. AMDGPU-PRO is optional/manual.' }
    @{ Cls='Display'; Ven='8086'; Name=''; S='In-Kernel; Firmware Required';
       D='i915 / xe (in-kernel) + Mesa + intel-media-va-driver';
       U=''; N='Intel iGPU: driver is in the kernel; install Mesa + the Intel VA-API media driver.' }
    @{ Cls='Display'; Ven=''; Name=''; S='In-Kernel; Generic Driver';
       D='Mesa / generic KMS'; U=''; N='Generic display — covered by the in-kernel driver + Mesa.' }

    # ---- Networking: Wi-Fi vs Ethernet split by name where it matters ----
    @{ Cls='Net'; Ven='10DE'; Name=''; S='In-Kernel'; D='forcedeth (in-kernel)'; U=''; N='NVIDIA nForce Ethernet — in-kernel.' }
    @{ Cls='Net'; Ven='8086'; Name='Wireless|Wi-?Fi|WLAN|802\.11|AX\d|AC \d|Wireless-AC';
       S='In-Kernel; Firmware Required'; D='iwlwifi (in-kernel) + linux-firmware';
       U=''; N='Intel Wi-Fi: iwlwifi is in the kernel; firmware ships in linux-firmware.' }
    @{ Cls='Net'; Ven='8086'; Name='';
       S='In-Kernel'; D='e1000e / igb / igc / e1000 (in-kernel)'; U=''; N='Intel Ethernet — in-kernel.' }
    @{ Cls='Net'; Ven='10EC'; Name='Wireless|Wi-?Fi|WLAN|802\.11|8821|8822|8811|8812|88x2|8852|8723';
       S='Kernel Module (DKMS)'; D='rtw88 / rtw89 (newer kernels) or rtl88x2bu-dkms / rtl8821ce-dkms';
       U='https://www.realtek.com/Download/List?cate_id=584';
       N='Realtek Wi-Fi: many chips need a DKMS out-of-tree module (rtl88x2bu/rtl8821ce); newer kernels have rtw88/rtw89.' }
    @{ Cls='Net'; Ven='10EC'; Name='2\.5|2500|RTL8125|Killer E3000';
       S='In-Kernel; Kernel Module (DKMS)'; D='r8169 (in-kernel) or r8125-dkms for full 2.5GbE support';
       U='https://www.realtek.com/Download/List?cate_id=584';
       N='Realtek 2.5GbE: in-kernel r8169 works; r8125-dkms (Realtek source) fixes link/throughput quirks.' }
    @{ Cls='Net'; Ven='10EC'; Name='';
       S='In-Kernel; Kernel Module (DKMS)'; D='r8169 (in-kernel) — r8168-dkms if the NIC drops/links flaky';
       U='https://www.realtek.com/Download/List?cate_id=584';
       N='Realtek GbE: in-kernel r8169 normally works; r8168-dkms (Realtek source) fixes some flaky links.' }
    @{ Cls='Net'; Ven='14E4'; Name='Wireless|Wi-?Fi|WLAN|802\.11|BCM43';
       S='Proprietary Driver; Kernel Module (DKMS)'; D='broadcom-sta-dkms (wl) — or in-kernel b43/brcmfmac for some chips';
       U='https://www.broadcom.com/support/download-search';
       N='Broadcom Wi-Fi: most need the proprietary wl (broadcom-sta-dkms); some work with in-kernel brcmfmac + firmware.' }
    @{ Cls='Net'; Ven='14E4'; Name=''; S='In-Kernel; Firmware Required'; D='tg3 / bnx2 (in-kernel) + linux-firmware';
       U=''; N='Broadcom Ethernet — in-kernel (tg3), firmware in linux-firmware.' }
    @{ Cls='Net'; Ven='168C|17CB|0CF3'; Name=''; S='In-Kernel; Firmware Required';
       D='ath9k / ath10k / ath11k (in-kernel) + linux-firmware'; U=''; N='Qualcomm Atheros Wi-Fi — in-kernel + firmware.' }
    @{ Cls='Net'; Ven='1969'; Name=''; S='In-Kernel'; D='alx / atl1c (in-kernel)'; U=''; N='Qualcomm Atheros/Killer Ethernet — in-kernel.' }
    @{ Cls='Net'; Ven='14C3|0E8D|1814'; Name=''; S='In-Kernel; Firmware Required';
       D='mt76 / mt7601u (in-kernel) + linux-firmware'; U=''; N='MediaTek/Ralink Wi-Fi — in-kernel + firmware.' }
    @{ Cls='Net'; Ven='0BDA'; Name='';
       S='Kernel Module (DKMS)'; D='rtl8812au-dkms / rtl88x2bu-dkms (USB Wi-Fi) — r8152 for USB Ethernet';
       U='https://www.realtek.com/Download/List?cate_id=584';
       N='Realtek USB Wi-Fi dongles usually need a DKMS module; USB Ethernet (r8152) is in-kernel.' }
    @{ Cls='Net'; Ven='11AB'; Name=''; S='In-Kernel'; D='sky2 / mvneta (in-kernel)'; U=''; N='Marvell Ethernet — in-kernel.' }
    @{ Cls='Net'; Ven=''; Name=''; S='In-Kernel; Needs Review'; D='generic net driver (check lspci -k on Linux)';
       U=''; N='Network device — most NICs are in-kernel; confirm the module with "lspci -k" on Linux.' }

    # ---- Bluetooth ----
    @{ Cls='Bluetooth'; Ven=''; Name=''; S='In-Kernel; Firmware Required'; D='btusb / btintel / btrtl (in-kernel) + linux-firmware';
       U=''; N='Bluetooth radios are driven by btusb in-kernel; firmware ships in linux-firmware.' }

    # ---- Audio ----
    @{ Cls='MEDIA|AudioEndpoint|Audio|SoftwareDevice'; Ven=''; Name='Audio|Realtek Audio|High Definition Audio|Sound|Speakers|Microphone|SmartSound|Dolby|DTS';
       S='In-Kernel'; D='snd_hda_intel / snd_sof (in-kernel) + ALSA/PipeWire';
       U=''; N='HD Audio / SoF is in-kernel; PipeWire/ALSA handle it. Vendor "audio enhancement" apps have no Linux driver.' }

    # ---- Cameras / webcams / imaging ----
    @{ Cls='Camera|Image'; Ven=''; Name='Camera|Webcam|HD User Facing|Integrated Camera|IR Camera';
       S='In-Kernel'; D='uvcvideo (in-kernel)'; U=''; N='UVC webcams are driven by uvcvideo in-kernel (v4l2).' }
    @{ Cls='Image'; Ven='03F0'; Name=''; S='Vendor Driver'; D='hplip (HP scanners) + SANE';
       U='https://developers.hp.com/hp-linux-imaging-and-printing'; N='HP scanner — use HPLIP + SANE.' }
    @{ Cls='Image'; Ven=''; Name='Scanner';
       S='Vendor Driver; Generic Driver'; D='SANE (sane-utils) + vendor backend';
       U='http://www.sane-project.org/'; N='Scanner — SANE drives most; some need a vendor backend.' }

    # ---- Printers ----
    @{ Cls='Printer|PrintQueue'; Ven='03F0'; Name='';
       S='Vendor Driver'; D='hplip (HP Linux Imaging & Printing)';
       U='https://developers.hp.com/hp-linux-imaging-and-printing'; N='HP printer — install HPLIP (covers print + scan).' }
    @{ Cls='Printer|PrintQueue'; Ven=''; Name='HP ';
       S='Vendor Driver'; D='hplip'; U='https://developers.hp.com/hp-linux-imaging-and-printing'; N='HP printer — install HPLIP.' }
    @{ Cls='Printer|PrintQueue'; Ven=''; Name='';
       S='Generic Driver; Vendor Driver'; D='CUPS driverless (IPP Everywhere) — or vendor PPD / printer-driver-* package';
       U='https://www.openprinting.org/printers'; N='Printer — most modern printers are driverless via CUPS/IPP; older ones need a PPD.' }

    # ---- Fingerprint / biometric ----
    @{ Cls='Biometric'; Ven='06CB|27C6|138A|08FF|1C7A|138a';
       Name=''; S='Vendor Driver; Kernel Module (DKMS)'; D='fprintd + libfprint (check device support)';
       U='https://fprint.freedesktop.org/supported-devices.html';
       N='Fingerprint reader: install fprintd + libpam-fprintd; support depends on the exact chip (see libfprint list).' }
    @{ Cls='Biometric'; Ven=''; Name='';
       S='Vendor Driver; Needs Review'; D='fprintd + libfprint';
       U='https://fprint.freedesktop.org/supported-devices.html'; N='Biometric device — fprintd/libfprint covers many readers; verify yours.' }

    # ---- Storage ----
    @{ Cls='DiskDrive|SCSIAdapter|HDC|NVMe'; Ven=''; Name='NVMe';
       S='In-Kernel'; D='nvme (in-kernel)'; U=''; N='NVMe SSD — in-kernel, no driver needed.' }
    @{ Cls='DiskDrive|SCSIAdapter|HDC'; Ven=''; Name='';
       S='In-Kernel'; D='ahci / nvme / sd (in-kernel)'; U=''; N='Storage controller/disk — in-kernel.' }

    # ---- Chipset / CPU / platform ----
    @{ Cls='Processor'; Ven='8086'; Name=''; S='In-Kernel; Firmware Required'; D='kernel cpufreq + intel-microcode';
       U=''; N='Intel CPU: install intel-microcode for security/stability updates.' }
    @{ Cls='Processor'; Ven='1022|AMD'; Name=''; S='In-Kernel; Firmware Required'; D='kernel cpufreq + amd64-microcode';
       U=''; N='AMD CPU: install amd64-microcode for security/stability updates.' }
    @{ Cls='Processor'; Ven=''; Name=''; S='In-Kernel; Firmware Required'; D='kernel cpufreq + CPU microcode';
       U=''; N='CPU — in-kernel; install the matching microcode package.' }
    @{ Cls='System'; Ven=''; Name='Management Engine|MEI|IPMI|Platform Controller|Thermal|GPIO|SMBus|LPC|PCI Express Root|Host Bridge';
       S='In-Kernel'; D='in-kernel platform/MEI/i2c modules'; U=''; N='Chipset/platform device — in-kernel.' }

    # ---- USB controllers / hubs / HID ----
    @{ Cls='USB'; Ven=''; Name=''; S='In-Kernel'; D='xhci_hcd / ehci_hcd / usbcore (in-kernel)'; U=''; N='USB controller/hub — in-kernel.' }
    @{ Cls='HIDClass|HID|Keyboard|Mouse'; Ven=''; Name=''; S='In-Kernel'; D='usbhid / hid-generic (in-kernel)';
       U=''; N='Keyboard/mouse/HID — in-kernel. Vendor RGB/macro apps differ (Piper/OpenRGB/ckb-next).' }

    # ---- Memory-card / smartcard readers ----
    @{ Cls='SDHostController|MTD'; Ven=''; Name=''; S='In-Kernel'; D='sdhci / rtsx_pci (in-kernel)'; U=''; N='Card reader — in-kernel.' }
    @{ Cls='SmartCardReader|SmartCard'; Ven=''; Name=''; S='In-Kernel; Generic Driver'; D='pcsc-lite + CCID';
       U=''; N='Smartcard reader — install pcscd + libccid (CCID).' }

    # ---- Battery / ACPI / firmware ----
    @{ Cls='Battery|ACPI'; Ven=''; Name=''; S='In-Kernel'; D='ACPI battery/AC (in-kernel)'; U=''; N='Battery/ACPI — in-kernel.' }
    @{ Cls='Firmware|SoftwareComponent'; Ven=''; Name='';
       S='Firmware Required'; D='fwupd + LVFS (system & device firmware from the manufacturer)';
       U='https://fwupd.org/'; N='System firmware/UEFI: update via fwupd/LVFS (downloads directly from the manufacturer).' }

    # ---- Monitors ----
    @{ Cls='Monitor'; Ven=''; Name=''; S='Not Applicable'; D='handled by the GPU driver (EDID)';
       U=''; N='Monitors need no driver on Linux — the GPU driver reads EDID.' }

    # ---- Virtual / software / Microsoft inbox catch-alls ----
    @{ Cls='Net'; Ven=''; Name='WAN Miniport|Virtual|TAP|VPN|Loopback|WireGuard|WFP|Kernel Debug';
       S='Not Applicable'; D='Linux networking stack (NetworkManager/systemd-networkd)';
       U=''; N='Virtual network adapter — no driver; configure with NetworkManager/wireguard-tools.' }
    @{ Cls='System|SoftwareDevice|SoftwareComponent|Computer|Volume|UCM'; Ven=''; Name='';
       S='In-Kernel; Generic Driver'; D='in-kernel / generic'; U=''; N='Standard system device — covered by the kernel.' }
)

# Canonical flag order so the status column reads consistently on every row.
$FlagOrder = @(
    'In-Kernel', 'Generic Driver', 'Firmware Required', 'Kernel Module (DKMS)',
    'Proprietary Driver', 'Vendor Driver', 'Not Applicable', 'Needs Review'
)
function Format-Flags {
    param([string] $Status)
    $parts = $Status -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    $ordered = $parts | Sort-Object { $i = $FlagOrder.IndexOf($_); if ($i -lt 0) { 99 } else { $i } }
    return ($ordered -join '; ')
}

# Classify one driver row -> Status / Driver / Url / Notes via the first matching
# $DriverKB rule. Returns $null if nothing matched (caller marks "Needs Review").
function Classify-Driver {
    param([string] $Class, [string] $VendorId, [string] $Name, [string] $Bus)
    foreach ($rule in $DriverKB) {
        $ruleBus = if ($rule.ContainsKey('Bus')) { $rule.Bus } else { '' }
        if ($rule.Cls -and ($Class -notmatch $rule.Cls))    { continue }
        if ($rule.Ven -and ($VendorId -notmatch $rule.Ven)) { continue }
        if ($rule.Name -and ($Name -notmatch $rule.Name))   { continue }
        if ($ruleBus  -and ($Bus -notmatch $ruleBus))       { continue }
        return [pscustomobject]@{ Status = $rule.S; Driver = $rule.D; Url = $rule.U; Notes = $rule.N }
    }
    return $null
}

# ---------------------------------------------------------------------------
# 2. COLLECT  -- every signed PnP driver on the machine
# ---------------------------------------------------------------------------
Write-Host "Enumerating device drivers (Win32_PnPSignedDriver)..." -ForegroundColor Cyan
$rawDrivers = try {
    Get-CimInstance -ClassName Win32_PnPSignedDriver -ErrorAction SilentlyContinue
} catch {
    try { Get-WmiObject -Class Win32_PnPSignedDriver -ErrorAction SilentlyContinue } catch { @() }
}
if (-not $rawDrivers) { $rawDrivers = @() }

# ---------------------------------------------------------------------------
# 3. FILTER  -- keep real hardware buses; drop software/virtual unless asked
# ---------------------------------------------------------------------------
$virtualBuses = @('ROOT','SW','SWD','SWC','STORAGE','UMB','VMS')

$rows = foreach ($d in $rawDrivers) {
    $name  = Safe-Property $d 'DeviceName'
    $hwid  = Safe-Property $d 'HardWareID'
    $devid = Safe-Property $d 'DeviceID'
    $class = Safe-Property $d 'DeviceClass'
    if ([string]::IsNullOrWhiteSpace($name)) { continue }

    # Prefer HardWareID; fall back to DeviceID for the bus/vendor parse.
    $idForParse = if ($hwid) { [string]$hwid } else { [string]$devid }
    $bus = Get-BusPrefix $idForParse
    if (-not $bus) { $bus = Get-BusPrefix ([string]$devid) }

    $isVirtual = ($bus -in $virtualBuses -or $bus -eq '')
    if ($isVirtual -and -not $IncludeVirtualDevices) { continue }

    $provider = Safe-Property $d 'DriverProviderName'
    $vendorId = Get-VendorId $idForParse

    # Optionally drop generic Microsoft in-box drivers that need no Linux action.
    $isMsInbox = ($provider -match '^Microsoft' -and $bus -notin @('PCI','PCIE','USB'))
    if ($isMsInbox -and -not $IncludeMicrosoftInbox) { continue }

    # ---- machine columns ----
    $version = Safe-Property $d 'DriverVersion'
    $dateRaw = Safe-Property $d 'DriverDate'
    $date = ''
    if ($dateRaw) {
        try { $date = ([datetime]$dateRaw).ToString('yyyy-MM-dd') }
        catch {
            # WMI CIM_DATETIME fallback (yyyymmddHHMMSS...).
            try { $date = [System.Management.ManagementDateTimeConverter]::ToDateTime([string]$dateRaw).ToString('yyyy-MM-dd') } catch { $date = '' }
        }
    }
    $mfr = Safe-Property $d 'Manufacturer'

    # ---- knowledge columns ----
    $hit = Classify-Driver -Class ([string]$class) -VendorId $vendorId -Name ([string]$name) -Bus $bus
    if (-not $hit) {
        $hit = [pscustomobject]@{
            Status = 'Needs Review'
            Driver = 'unknown — run "lspci -nnk" / "lsusb" on Linux to find the module'
            Url    = ''
            Notes  = "Unclassified $class device (vendor $vendorId). Most are in-kernel; verify on Linux."
        }
    }

    $status = Format-Flags $hit.Status
    # DERIVE "Must install on Linux": yes only when something must be actively
    # installed beyond the in-box kernel + base linux-firmware.
    $mustInstall = if ($status -match 'Proprietary Driver|Kernel Module \(DKMS\)|Vendor Driver') { 'yes' } else { 'no' }

    [pscustomobject]([ordered]@{
        'Device Name'           = [string]$name
        'Device Class'          = [string]$class
        'Manufacturer'          = [string]$mfr
        'Driver Version'        = [string]$version
        'Driver Date'           = $date
        'Driver Provider'       = [string]$provider
        'Hardware ID'           = [string]$idForParse
        'Linux Driver Status'   = $status
        'Linux Driver / Module' = $hit.Driver
        'Vendor Download'       = $hit.Url
        'Notes'                 = $hit.Notes
        'Must install on Linux' = $mustInstall
    })
}

# De-duplicate: collapse identical (Device Name + Hardware ID) pairs that several
# child devices can report, keeping the first. Sort by class then name for reading.
$deduped = @($rows) |
    Sort-Object 'Device Class', 'Device Name' |
    Group-Object { "$($_.'Device Name')|$($_.'Hardware ID')" } |
    ForEach-Object { $_.Group[0] }

# ---------------------------------------------------------------------------
# 4. EXPORT
# ---------------------------------------------------------------------------
$deduped | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8

# ---------------------------------------------------------------------------
# 5. SUMMARY
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "Driver inventory written to: $OutputPath" -ForegroundColor Green
Write-Host ("Devices listed        : {0}" -f @($deduped).Count)
Write-Host ("Must install on Linux : {0}" -f @($deduped | Where-Object 'Must install on Linux' -eq 'yes').Count) -ForegroundColor Yellow
Write-Host ""
@($deduped) | Group-Object {
        $s = $_.'Linux Driver Status'
        if     ($s -match 'Proprietary Driver') { '1 Proprietary driver needed' }
        elseif ($s -match 'Kernel Module \(DKMS\)') { '2 DKMS / out-of-tree module' }
        elseif ($s -match 'Vendor Driver')      { '3 Vendor download needed' }
        elseif ($s -match 'Firmware Required')  { '4 In-kernel + firmware' }
        elseif ($s -match 'In-Kernel')          { '5 In-kernel (works OOTB)' }
        elseif ($s -match 'Not Applicable')     { '6 No driver needed' }
        else                                    { '9 Needs review' }
    } | Sort-Object Name |
    ForEach-Object { Write-Host ("  {0,-32} {1}" -f ($_.Name -replace '^\d ',''), $_.Count) }
Write-Host ""
Write-Host "Next: run 'install_device_drivers.sh' on the target Linux machine — it" -ForegroundColor Cyan
Write-Host "detects the hardware live and installs the drivers flagged above." -ForegroundColor Cyan
