<#
.SYNOPSIS
    Inventories EVERY device driver on this Windows PC and rates how each device is
    handled on macOS: whether Apple ships the driver in the OS, whether the device is
    class-compliant, whether it needs a vendor kext / DriverKit system extension, or
    whether it simply has no macOS support at all - plus the macOS driver name, the
    manufacturer's macOS download page (when a vendor driver is needed), and whether
    you must actively install something on macOS.

.DESCRIPTION
    The script produces A_installed_windows_drivers.csv with 12 columns:

      MACHINE-DERIVED (read live from this PC via Win32_PnPSignedDriver, never
      hand-authored):
        Device Name        the PnP device's friendly name
        Device Class       PnP class (Display, Net, Bluetooth, Printer, ...)
        Manufacturer       device manufacturer
        Driver Version     installed driver version
        Driver Date        driver date (yyyy-MM-dd)
        Driver Provider    who signed/provides the driver (NVIDIA, Microsoft, ...)
        Hardware ID        the bus ID (PCI\VEN_10DE&DEV_... or USB\VID_...&PID_...)
                           - the only reliable key to the real silicon

      KNOWLEDGE-DERIVED (classified in code from the class + the PCI/USB vendor ID
      in the Hardware ID - the single place to tweak is the $DriverKB table below):
        macOS Driver Status   one or more flags, normalised to a fixed order:
                                In-OS ; Generic Driver ; Vendor Driver ;
                                Not Supported ; Not Applicable ; Needs Review
        macOS Driver / Module the driver family or package that handles the device
                              on macOS (IO80211Family, AppleHDA, IOUSBHostFamily,
                              AirPrint/CUPS, ftdi-vcp-driver, ...)
        Vendor Download       the manufacturer's official macOS driver page, filled
                              only when a vendor download is actually needed
        Notes                 short human note about the macOS situation
        Must install on macOS yes/no - DERIVED: "yes" when the device needs an
                              actively-installed driver (a vendor kext / DriverKit
                              system extension / vendor installer); "no" when macOS
                              already drives it, or when the device has no macOS
                              support at all and therefore cannot be carried over.

    How the data is sourced: the machine columns are read fresh from
    Win32_PnPSignedDriver and are never edited. The four curated columns are derived
    by Classify-Driver from the device class and the PCI/USB vendor ID embedded in
    the Hardware ID, using the $DriverKB rule table.

    IMPORTANT context for macOS: a Mac is not a PC with a different OS on it. Apple
    ships every driver its own hardware needs inside macOS and updates them through
    Software Update, so the vast majority of this report reads "In-OS" or "Not
    Applicable" - there is nothing to install. The rows worth reading are the ones
    flagged "Vendor Driver" (a peripheral you will carry over that needs its own
    macOS driver, e.g. a USB-to-serial bridge or an older printer/scanner) and
    "Not Supported" (PC-only hardware such as an NVIDIA GPU or a PC fingerprint
    reader, which simply has no macOS counterpart).

    Noise removed before rating: by default only real hardware buses are listed
    (PCI, USB, ACPI, HID, SCSI, NVMe, etc.). Root-enumerated / software / SWD
    virtual devices are dropped unless -IncludeVirtualDevices is given.

.PARAMETER OutputPath
    CSV path. Default: A_installed_windows_drivers.csv beside this script.
.PARAMETER IncludeVirtualDevices
    Keep ROOT\, SW\ and SWD\ software/virtual devices (off by default).
.PARAMETER IncludeMicrosoftInbox
    Keep generic Microsoft in-box drivers for standard devices that need no action
    on macOS (off by default - they only add noise to the report).

.EXAMPLE
    .\A_detect_installed_drivers.ps1
    .\A_detect_installed_drivers.ps1 -IncludeVirtualDevices
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
    $OutputPath = Join-Path $scriptDir 'A_installed_windows_drivers.csv'
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
    '0403'='FTDI'; '1A86'='WCH (CH34x)'; '10C4'='Silicon Labs'; '067B'='Prolific'; '056A'='Wacom'
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
#       S    = macOS Driver Status flags (';'-separated)
#       D    = macOS driver family / package
#       U    = vendor macOS download page (only when a vendor download is needed)
#       N    = short note
# ---------------------------------------------------------------------------
$DriverKB = @(
    # ---- Paired Bluetooth peripherals (host BT radio handles the link) ----
    @{ Cls=''; Ven=''; Name=''; Bus='^BTH'; S='Not Applicable';
       D='IOBluetoothFamily (built into macOS)';
       U=''; N='Paired Bluetooth peripheral (headset/phone/etc.) - nothing to install; pair it again in System Settings > Bluetooth.' }

    # ---- USB4 / Thunderbolt ----
    @{ Cls=''; Ven=''; Name='USB4|Thunderbolt'; Bus=''; S='In-OS';
       D='IOThunderboltFamily (built into macOS)'; U=''; N='USB4/Thunderbolt is native to every Mac - Apple invented Thunderbolt; nothing to install.' }

    # ---- USB-to-serial bridges: the classic "needs a vendor kext" case ----
    @{ Cls='Ports|USB'; Ven='0403'; Name=''; S='Vendor Driver';
       D='ftdi-vcp-driver (Homebrew Cask)';
       U='https://ftdichip.com/drivers/vcp-drivers/';
       N='FTDI USB-serial adapter: recent macOS has an in-box driver, but the FTDI VCP driver is still needed on older releases and for full feature support.' }
    @{ Cls='Ports|USB'; Ven='1A86'; Name='CH340|CH341'; S='Vendor Driver';
       D='wch-ch34x-usb-serial-driver (Homebrew Cask)';
       U='https://www.wch-ic.com/downloads/CH341SER_MAC_ZIP.html';
       N='CH340/CH341 USB-serial adapter: macOS has NO in-box driver - install the WCH driver.' }
    @{ Cls='Ports|USB'; Ven='10C4'; Name=''; S='Vendor Driver';
       D='silicon-labs-vcp-driver (Homebrew Cask)';
       U='https://www.silabs.com/developer-tools/usb-to-uart-bridge-vcp-drivers';
       N='Silicon Labs CP210x USB-serial adapter - install the Silicon Labs VCP driver.' }
    @{ Cls='Ports|USB'; Ven='067B'; Name=''; S='Vendor Driver';
       D='prolific-pl2303-driver (Homebrew Cask)';
       U='https://www.prolific.com.tw/US/ShowProduct.aspx?p_id=229&pcid=41';
       N='Prolific PL2303 USB-serial adapter - install the Prolific macOS driver (older clones are unsupported).' }

    # ---- Graphics tablets ----
    @{ Cls='HIDClass|HID|Mouse|Pointer'; Ven='056A'; Name=''; S='Vendor Driver';
       D='wacom-tablet (Homebrew Cask)'; U='https://www.wacom.com/support/product-support/drivers';
       N='Wacom tablet: it works as a plain pointer without a driver, but pressure/tilt/ExpressKeys need the Wacom macOS driver.' }

    # ---- Neural / AI accelerators (NPU) ----
    @{ Cls='ComputeAccelerator'; Ven='8086'; Name='AI Boost|NPU|Neural|VPU';
       S='Not Supported'; D='Apple Neural Engine (Core ML) is the macOS equivalent';
       U='https://developer.apple.com/machine-learning/core-ml/';
       N='The Intel NPU has no macOS driver. Every Apple Silicon Mac has a Neural Engine instead, used automatically through Core ML.' }
    @{ Cls='ComputeAccelerator'; Ven=''; Name=''; S='Not Supported';
       D='Apple Neural Engine / Metal Performance Shaders';
       U=''; N='PC compute accelerators have no macOS driver; on a Mac the Neural Engine and the GPU (via Metal) do this work.' }

    # ---- Audio post-processing software (no macOS driver) ----
    @{ Cls='AudioProcessingObject'; Ven=''; Name=''; S='Not Applicable';
       D='Audio MIDI Setup + eqMac / Background Music';
       U=''; N='Vendor audio enhancement (Nahimic/Dolby/DTS APO) has no macOS driver; eqMac gives system-wide EQ and Background Music per-app volume.' }

    # ---- GPU / Display ----
    @{ Cls='Display'; Ven='10DE'; Name=''; S='Not Supported';
       D='none - use the Mac''s own GPU (Apple Silicon) or an AMD card on Intel Macs';
       U='https://support.apple.com/en-us/102363';
       N='NVIDIA GPUs are NOT supported on macOS: the web drivers ended with High Sierra and Apple Silicon Macs have no PCIe GPU support at all. Your Mac''s built-in GPU replaces it.' }
    @{ Cls='Display'; Ven='1002'; Name=''; S='In-OS';
       D='AMDRadeonX6000 family (built into macOS)';
       U=''; N='AMD GPUs are driven in-OS on Intel Macs (including eGPU enclosures) - nothing to install. Apple Silicon Macs use their own integrated GPU.' }
    @{ Cls='Display'; Ven='8086'; Name=''; S='In-OS';
       D='AppleIntelGraphics (built into macOS on Intel Macs)';
       U=''; N='Intel integrated graphics are driven in-OS on Intel Macs. On Apple Silicon the built-in Apple GPU takes over; nothing to install either way.' }
    @{ Cls='Display'; Ven=''; Name=''; S='In-OS';
       D='Apple GPU / Metal driver (built into macOS)'; U=''; N='Display hardware is driven by macOS itself and updated through Software Update.' }

    # ---- Networking: Wi-Fi vs Ethernet ----
    @{ Cls='Net'; Ven='0BDA'; Name='Wireless|Wi-?Fi|WLAN|802\.11|88\d\d';
       S='Vendor Driver'; D='vendor macOS driver (Realtek USB Wi-Fi)';
       U='https://www.realtek.com/Download/List?cate_id=584';
       N='Realtek USB Wi-Fi dongle: macOS has no in-box driver and vendor support is patchy - your Mac''s own Wi-Fi is the better answer.' }
    @{ Cls='Net'; Ven=''; Name='Wireless|Wi-?Fi|WLAN|802\.11|AX\d|AC \d|Wireless-AC|BCM43';
       S='In-OS'; D='IO80211Family / AirPort (built into macOS)';
       U=''; N='Wi-Fi on a Mac is Apple/Broadcom silicon driven entirely in-OS. A PC Wi-Fi card cannot be transplanted into a Mac, and no driver is needed for the Mac''s own radio.' }
    @{ Cls='Net'; Ven='0BDA'; Name=''; S='In-OS';
       D='AppleUSBECM / AppleUSBNCM (built into macOS)';
       U='https://www.realtek.com/Download/List?cate_id=585';
       N='Realtek USB Ethernet: most RTL8153-class adapters are class-compliant and work out of the box; a few older ones need Realtek''s macOS driver.' }
    @{ Cls='Net'; Ven='8086|10EC|14E4|1969|11AB|10DE'; Name=''; S='In-OS';
       D='AppleEthernet / built-in NIC driver (built into macOS)';
       U=''; N='Wired Ethernet on a Mac (built-in or via a Thunderbolt/USB adapter) is driven in-OS; a PC NIC card has no macOS driver but is not needed.' }
    @{ Cls='Net'; Ven=''; Name=''; S='In-OS; Needs Review';
       D='macOS networking stack (built-in)';
       U=''; N='Network device - the Mac''s own interfaces are driven in-OS. Check System Information > Network on the Mac for what it actually has.' }

    # ---- Bluetooth ----
    @{ Cls='Bluetooth'; Ven=''; Name=''; S='In-OS'; D='IOBluetoothFamily (built into macOS)';
       U=''; N='Bluetooth is built into every Mac and driven in-OS; just re-pair your devices.' }

    # ---- Audio ----
    @{ Cls='MEDIA|AudioEndpoint|Audio|SoftwareDevice'; Ven=''; Name='Audio|Realtek Audio|High Definition Audio|Sound|Speakers|Microphone|SmartSound|Dolby|DTS';
       S='In-OS'; D='AppleHDA / USB Audio Class (built into macOS) + Core Audio';
       U=''; N='Audio is handled by Core Audio in-OS. USB and Thunderbolt audio interfaces are class-compliant; only a few pro interfaces ship their own macOS driver.' }

    # ---- Cameras / webcams / imaging ----
    @{ Cls='Camera|Image'; Ven=''; Name='Camera|Webcam|HD User Facing|Integrated Camera|IR Camera';
       S='In-OS'; D='CoreMediaIO UVC driver (built into macOS)';
       U=''; N='UVC webcams work out of the box on macOS. Windows Hello IR cameras have no macOS equivalent - Macs use Touch ID / Apple Watch unlock instead.' }
    @{ Cls='Image'; Ven='03F0'; Name=''; S='Vendor Driver';
       D='HP Easy Start (or Image Capture for driverless scanning)';
       U='https://support.hp.com/us-en/drivers'; N='HP scanner - Image Capture drives most models; HP Easy Start adds the full feature set.' }
    @{ Cls='Image'; Ven=''; Name='Scanner';
       S='Generic Driver; Vendor Driver'; D='Image Capture (ICA) + vendor macOS driver';
       U='https://support.apple.com/en-us/HT201465'; N='Scanner - Image Capture drives most; older models need the vendor''s macOS driver.' }

    # ---- Printers ----
    @{ Cls='Printer|PrintQueue'; Ven='03F0'; Name='';
       S='Generic Driver; Vendor Driver'; D='AirPrint (built into macOS) or HP Easy Start';
       U='https://support.hp.com/us-en/drivers'; N='HP printer - AirPrint covers most models driverless; HP Easy Start adds scanning and the full feature set.' }
    @{ Cls='Printer|PrintQueue'; Ven=''; Name='HP ';
       S='Generic Driver; Vendor Driver'; D='AirPrint (built into macOS) or HP Easy Start';
       U='https://support.hp.com/us-en/drivers'; N='HP printer - AirPrint driverless, or HP Easy Start for full features.' }
    @{ Cls='Printer|PrintQueue'; Ven=''; Name='';
       S='Generic Driver'; D='AirPrint / IPP Everywhere via CUPS (built into macOS)';
       U='https://support.apple.com/en-us/HT201465'; N='Printer - macOS uses CUPS (an Apple project) and AirPrint; most printers add themselves with no driver at all.' }

    # ---- Fingerprint / biometric ----
    @{ Cls='Biometric'; Ven=''; Name='';
       S='Not Supported'; D='Touch ID (Apple hardware) is the macOS equivalent';
       U='https://support.apple.com/en-us/102528';
       N='PC fingerprint readers have no macOS driver. Macs use the built-in Touch ID sensor, or unlock with an Apple Watch.' }

    # ---- Storage ----
    @{ Cls='DiskDrive|SCSIAdapter|HDC|NVMe'; Ven=''; Name='NVMe';
       S='In-OS'; D='IONVMeFamily (built into macOS)'; U=''; N='NVMe SSDs are driven in-OS. Note: the internal SSD of an Apple Silicon Mac is not user-replaceable.' }
    @{ Cls='DiskDrive|SCSIAdapter|HDC'; Ven=''; Name='';
       S='In-OS'; D='IOAHCIFamily / IOStorageFamily (built into macOS)'; U=''; N='Storage controller/disk - driven in-OS. NTFS volumes are read-only on macOS unless you add a third-party driver.' }

    # ---- Chipset / CPU / platform ----
    @{ Cls='Processor'; Ven=''; Name=''; S='Not Applicable'; D='CPU support is part of macOS and its firmware';
       U=''; N='There is no microcode package to install on macOS: CPU and platform firmware arrive through Software Update.' }
    @{ Cls='System'; Ven=''; Name='Management Engine|MEI|IPMI|Platform Controller|Thermal|GPIO|SMBus|LPC|PCI Express Root|Host Bridge';
       S='In-OS'; D='Apple platform drivers (built into macOS)'; U=''; N='Chipset/platform device - the Mac has its own equivalent, driven in-OS.' }

    # ---- USB controllers / hubs / HID ----
    @{ Cls='USB'; Ven=''; Name=''; S='In-OS'; D='IOUSBHostFamily (built into macOS)'; U=''; N='USB controller/hub - driven in-OS.' }
    @{ Cls='HIDClass|HID|Keyboard|Mouse'; Ven=''; Name=''; S='In-OS'; D='IOHIDFamily (built into macOS)';
       U=''; N='Keyboard/mouse/HID work out of the box. Vendor RGB/macro software differs on macOS: Logi Options+, Razer Synapse and Corsair iCUE all have Mac builds.' }

    # ---- Memory-card / smartcard readers ----
    @{ Cls='SDHostController|MTD'; Ven=''; Name=''; S='In-OS'; D='AppleSDXC (built into macOS)'; U=''; N='SD card reader - driven in-OS on Macs that have one; USB readers are class-compliant.' }
    @{ Cls='SmartCardReader|SmartCard'; Ven=''; Name=''; S='In-OS'; D='CryptoTokenKit + CCID (built into macOS)';
       U=''; N='Smartcard readers use the CCID class driver that ships with macOS - nothing to install.' }

    # ---- Battery / ACPI / firmware ----
    @{ Cls='Battery|ACPI'; Ven=''; Name=''; S='Not Applicable'; D='Apple SMC / power management (built into macOS)'; U=''; N='Battery and power management are part of macOS; configure them in System Settings > Battery.' }
    @{ Cls='Firmware|SoftwareComponent'; Ven=''; Name='';
       S='Not Applicable'; D='Software Update (Apple firmware delivery)';
       U='https://support.apple.com/en-us/HT201541'; N='Mac firmware is updated by Apple through Software Update - there is no fwupd/LVFS equivalent to install.' }

    # ---- Monitors ----
    @{ Cls='Monitor'; Ven=''; Name=''; S='Not Applicable'; D='handled by macOS (EDID)';
       U=''; N='Monitors need no driver on macOS; use System Settings > Displays (BetterDisplay adds custom scaled modes).' }

    # ---- Virtual / software / Microsoft inbox catch-alls ----
    @{ Cls='Net'; Ven=''; Name='WAN Miniport|Virtual|TAP|VPN|Loopback|WireGuard|WFP|Kernel Debug';
       S='Not Applicable'; D='macOS networking stack (networksetup / Network settings)';
       U=''; N='Virtual network adapter - no driver; configure it in System Settings > Network or with the VPN app itself.' }
    @{ Cls='System|SoftwareDevice|SoftwareComponent|Computer|Volume|UCM'; Ven=''; Name='';
       S='In-OS'; D='built into macOS'; U=''; N='Standard system device - the Mac equivalent is part of macOS.' }
)

# Canonical flag order so the status column reads consistently on every row.
$FlagOrder = @(
    'In-OS', 'Generic Driver', 'Vendor Driver', 'Not Supported',
    'Not Applicable', 'Needs Review'
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

    # Optionally drop generic Microsoft in-box drivers that need no macOS action.
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
            Driver = 'unknown - check System Information > Hardware on the Mac, or "system_profiler SPUSBDataType"'
            Url    = ''
            Notes  = "Unclassified $class device (vendor $vendorId). Most peripherals are class-compliant on macOS; verify on the Mac."
        }
    }

    $status = Format-Flags $hit.Status
    # DERIVE "Must install on macOS": yes only when a vendor kext / DriverKit system
    # extension / vendor installer is genuinely required. "Not Supported" is NOT a
    # "yes": there is nothing to install for hardware macOS cannot drive at all.
    $mustInstall = if ($status -match 'Vendor Driver') { 'yes' } else { 'no' }

    [pscustomobject]([ordered]@{
        'Device Name'           = [string]$name
        'Device Class'          = [string]$class
        'Manufacturer'          = [string]$mfr
        'Driver Version'        = [string]$version
        'Driver Date'           = $date
        'Driver Provider'       = [string]$provider
        'Hardware ID'           = [string]$idForParse
        'macOS Driver Status'   = $status
        'macOS Driver / Module' = $hit.Driver
        'Vendor Download'       = $hit.Url
        'Notes'                 = $hit.Notes
        'Must install on macOS' = $mustInstall
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
Write-Host ("Must install on macOS : {0}" -f @($deduped | Where-Object 'Must install on macOS' -eq 'yes').Count) -ForegroundColor Yellow
Write-Host ("No macOS support      : {0}" -f @($deduped | Where-Object { $_.'macOS Driver Status' -match 'Not Supported' }).Count) -ForegroundColor Yellow
Write-Host ""
@($deduped) | Group-Object {
        $s = $_.'macOS Driver Status'
        if     ($s -match 'Vendor Driver')   { '1 Vendor driver download needed' }
        elseif ($s -match 'Not Supported')   { '2 No macOS support (PC-only hardware)' }
        elseif ($s -match 'Generic Driver')  { '3 Class-compliant (works OOTB)' }
        elseif ($s -match 'In-OS')           { '4 Driver ships with macOS' }
        elseif ($s -match 'Not Applicable')  { '5 No driver needed' }
        else                                 { '9 Needs review' }
    } | Sort-Object Name |
    ForEach-Object { Write-Host ("  {0,-32} {1}" -f ($_.Name -replace '^\d ',''), $_.Count) }
Write-Host ""
Write-Host "Next: run 'install_device_drivers.sh' on the target Mac - it detects the Mac's" -ForegroundColor Cyan
Write-Host "own hardware live, installs Rosetta 2 where needed, and offers the vendor" -ForegroundColor Cyan
Write-Host "drivers for the few peripherals macOS does not cover in-box." -ForegroundColor Cyan
