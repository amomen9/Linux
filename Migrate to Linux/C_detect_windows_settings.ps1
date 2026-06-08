<#
.SYNOPSIS
    Extracts common Windows user-facing settings and writes them to
    C_windows_configs.csv for later application on Linux.

.DESCRIPTION
    Extracts six categories of settings:
      1. Power settings  —  what closing the lid does (on battery / on AC)
      2. Display resolution & scaling
      3. Keyboard layout (language) and common shortcuts
      4. Telemetry level and location-service state
      5. (placeholder) scheduled auto-update service/timer mapping
      6. Lock-screen / blank timeout (secure screensaver or display-off idle)

    Output is written to C_windows_configs.csv (UTF-8, -NoTypeInformation).

    This script does NOT require admin rights. It reads current-user
    settings directly from the registry and WMI.

.PARAMETER OutputPath
    CSV path. Default: C_windows_configs.csv beside this script.
#>

[CmdletBinding()]
param(
    [string] $OutputPath
)

$ErrorActionPreference = 'Stop'

if (-not $OutputPath) {
    $scriptDir = $PSScriptRoot
    if (-not $scriptDir -and $PSCommandPath)            { $scriptDir = Split-Path -Parent $PSCommandPath }
    if (-not $scriptDir -and $MyInvocation.MyCommand.Path) { $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
    if (-not $scriptDir)                                 { $scriptDir = (Get-Location).Path }
    $OutputPath = Join-Path $scriptDir 'C_windows_configs.csv'
}

# Safely access a property that may not exist.
function Safe-Property { param($Obj, [string] $Name, $Default = $null); try { $Obj.$Name } catch { $Default } }

# -----------------------------------------------------------------------
# 1. POWER SETTINGS — lid-close action (battery / AC)
# -----------------------------------------------------------------------
$configRows = [System.Collections.Generic.List[pscustomobject]]::new()

function Add-Row {
    param([string]$Category, [string]$ConfigKey, [string]$WindowsValue, [string]$LinuxCommand, [string]$Notes = '')
    $configRows.Add([pscustomobject]@{
        Category      = $Category
        ConfigKey     = $ConfigKey
        WindowsValue  = $WindowsValue
        LinuxCommand  = $LinuxCommand
        Notes         = $Notes
    })
}

$powerPlanGuid = $null
try {
    $powerPlanGuid = (Get-WmiObject -Namespace root\cimv2\power -Class Win32_PowerPlan -Filter "IsActive='True'" -ErrorAction SilentlyContinue |
                      Select-Object -First 1).InstanceID
} catch {}

$lidBatteryIndex = $null
$lidACIndex     = $null
try {
    if ($powerPlanGuid) {
        $lidBatteryIndex = (Get-WmiObject -Namespace root\cimv2\power -Class Win32_PowerSettingDataIndex -Filter "InstanceID LIKE '%$powerPlanGuid%5ca673a8e-0e47-b2fd-5cb6-ef6e1e0a9c3e%'" -ErrorAction SilentlyContinue |
                           Select-Object -First 1).SettingIndexValue
        $lidACIndex      = (Get-WmiObject -Namespace root\cimv2\power -Class Win32_PowerSettingDataIndex -Filter "InstanceID LIKE '%$powerPlanGuid%5ca673a8e-0e47-b2fd-5cb6-ef6e1e0a9c3e%DC%'" -ErrorAction SilentlyContinue |
                           Select-Object -First 1).SettingIndexValue
    }
} catch {}

# Lid-action index mapping (standard Windows GUID: 5CA673A8...)
$acIndexMap  = @{ 0 = 'do nothing'; 1 = 'sleep'; 2 = 'hibernate'; 3 = 'shut down'; 4 = 'turn off display' }
$dcIndexMap  = @{ 0 = 'do nothing'; 1 = 'sleep'; 2 = 'hibernate'; 3 = 'shut down'; 4 = 'turn off display' }

# Also try fallback via the registry (powercfg /Q alternative):
try {
    if ($null -eq $lidACIndex) {
        $acReg = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes\*\5ca673a8-0e47-b2fd-5cb6-ef6e1e0a9c3e\*' -ErrorAction SilentlyContinue
        if ($acReg) { $lidACIndex = $acReg.ACSettingIndex }
        if ($null -eq $lidBatteryIndex) { $lidBatteryIndex = $acReg.DCSettingIndex }
    }
} catch {}

$acAction  = if ($null -ne $lidACIndex)     { $acIndexMap[[int]$lidACIndex] }     else { 'unknown' }
$dcAction  = if ($null -ne $lidBatteryIndex) { $dcIndexMap[[int]$lidBatteryIndex] } else { 'unknown' }

Write-Host "Power: lid-close on AC      = $acAction"
Write-Host "Power: lid-close on battery = $dcAction"

# Map Windows lid actions to logind.conf HandleLidSwitch values
$winToLinuxLid = @{
    'do nothing'       = 'ignore'
    'sleep'            = 'suspend'
    'hibernate'        = 'hibernate'
    'shut down'        = 'poweroff'
    'turn off display' = 'lock'
    'unknown'          = 'suspend'
}

Add-Row 'Power' 'lid_close_on_ac'      $acAction '' "logind.conf: HandleLidSwitchExternalPower=$($winToLinuxLid[$acAction])"
Add-Row 'Power' 'lid_close_on_battery' $dcAction '' "logind.conf: HandleLidSwitch=$($winToLinuxLid[$dcAction])"

# -----------------------------------------------------------------------
# 2. DISPLAY RESOLUTION & SCALING
# -----------------------------------------------------------------------
$resolution  = ''
$scalePercent = ''
try {
    # WMI: Win32_VideoController gives CurrentHorizontalResolution / CurrentVerticalResolution
    $video = Get-CimInstance -ClassName CIM_VideoController -ErrorAction SilentlyContinue |
             Where-Object { $_.CurrentHorizontalResolution -gt 0 } |
             Select-Object -First 1
    if ($video) {
        $resW = $video.CurrentHorizontalResolution
        $resH = $video.CurrentVerticalResolution
        $resolution = "${resW}x${resH}"
    }
} catch {}

try {
    # Scaling: read from registry
    # HKCU:\Control Panel\Desktop\WindowMetrics AppliedDPI (decimal) = scale percentage hint
    # Or HKCU:\Control Panel\Desktop\PerMonitorSettings\ monitor-specific
    $dpiReg = Get-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name 'LogPixels' -ErrorAction SilentlyContinue
    if ($dpiReg -and $dpiReg.LogPixels) {
        $rawDpi = [int]$dpiReg.LogPixels
        $scalePercent = [math]::Round(($rawDpi / 96) * 100)
    }
    # Fallback: get scaling from monitor info
    if (-not $scalePercent -or $scalePercent -eq 0) {
        try {
            $monitorScale = Get-ItemProperty -Path 'HKCU:\Control Panel\Desktop\WindowMetrics' -Name 'AppliedDPI' -ErrorAction SilentlyContinue
            if ($monitorScale -and $monitorScale.AppliedDPI) {
                $scalePercent = [math]::Round(([int]$monitorScale.AppliedDPI / 96) * 100)
            }
        } catch {}
    }
    if (-not $scalePercent -or $scalePercent -eq 0) { $scalePercent = 100 }
} catch { $scalePercent = 100 }

Write-Host "Display: resolution = $resolution"
Write-Host "Display: scaling    = ${scalePercent}%"

Add-Row 'Display' 'resolution' $resolution '' "xrandr / GNOME Settings > Displays"
Add-Row 'Display' 'scaling' "${scalePercent}%" '' "GNOME text-scaling-factor (system-wide dconf, all users)"

# -----------------------------------------------------------------------
# 3. KEYBOARD LAYOUT & SHORTCUTS
# -----------------------------------------------------------------------
$keyboardLayout  = ''
$inputMethodTips = ''

try {
    # Language list from Win32_KeyboardLayout or current culture
    $culture = [System.Globalization.CultureInfo]::CurrentCulture
    $keyboardLayout = "$($culture.DisplayName) ($($culture.Name))"

    # Get installed input methods
    $langList = Get-WinUserLanguageList -ErrorAction SilentlyContinue
    if ($langList) {
        $layoutNames = ($langList | ForEach-Object { "$($_.LanguageTag)" }) -join ', '
        if ($layoutNames) { $inputMethodTips = $layoutNames }
    }
} catch {}

Write-Host "Keyboard: layout = $keyboardLayout"
Write-Host "Keyboard: input languages = $inputMethodTips"

Add-Row 'Keyboard' 'layout' $keyboardLayout $inputMethodTips "setxkbmap / localectl set-x11-keymap"

# Common shortcuts: these are Windows conventions we want to know about
# We note the standard Windows shortcuts that a power user wants on Linux
$windowsShortcuts = @(
    'Ctrl+C/V/X/Z = Copy/Paste/Cut/Undo',
    'Win+E = File Explorer',
    'Win+L = Lock screen',
    'Win+D = Show desktop',
    'Win+R = Run dialog',
    'Alt+Tab = Switch windows',
    'Ctrl+Shift+Esc = Task Manager',
    'Win+Shift+S = Screenshot snipping'
)
Add-Row 'Keyboard' 'shortcuts_note' ($windowsShortcuts -join ' ; ') '' 'Map to GNOME/KDE equivalents in apply_settings.sh'

# -----------------------------------------------------------------------
# 4. TELEMETRY & LOCATION
# -----------------------------------------------------------------------
$telemetryLevel = ''
$locationEnabled = ''

try {
    # Telemetry — HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection
    # AllowTelemetry: 0=Security, 1=Basic, 2=Enhanced, 3=Full (Enterprise)
    $telReg = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection' -Name 'AllowTelemetry' -ErrorAction SilentlyContinue
    if ($telReg -and $null -ne $telReg.AllowTelemetry) {
        $telMap = @{ 0 = 'Security (off)'; 1 = 'Basic'; 2 = 'Enhanced'; 3 = 'Full' }
        $telemetryLevel = $telMap[[int]$telReg.AllowTelemetry]
    }
    # Also check the "Diagnostic data" consent key
    if (-not $telemetryLevel) {
        $diagReg = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection' -Name 'AllowDeviceNameInTelemetry' -ErrorAction SilentlyContinue
        if ($diagReg) {
            try {
                $diagConsent = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack' -Name 'DiagTrackAuthorization' -ErrorAction SilentlyContinue
                if ($diagConsent) { $telemetryLevel = "Consent: $($diagConsent.DiagTrackAuthorization)" }
            } catch {}
        }
    }
    if (-not $telemetryLevel) { $telemetryLevel = 'unknown' }
} catch { $telemetryLevel = 'unknown' }

try {
    # Location — check if location service is globally enabled
    $locReg = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location' -Name 'Value' -ErrorAction SilentlyContinue
    if ($locReg) {
        $locationEnabled = if ([string]$locReg.Value -eq 'Allow') { 'enabled' } else { 'disabled' }
    }
    if (-not $locationEnabled) {
        $locUserReg = Get-ItemProperty -Path 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\DeviceAccess\Global\{E6AD100E-5F4E-44CD-BE0F-2265D88D0CDB}' -Name 'Value' -ErrorAction SilentlyContinue
        if ($locUserReg) {
            $locationEnabled = if ([string]$locUserReg.Value -eq 'Allow') { 'enabled' } else { 'disabled' }
        }
    }
    if (-not $locationEnabled) { $locationEnabled = 'unknown' }
} catch { $locationEnabled = 'unknown' }

Write-Host "Telemetry: level     = $telemetryLevel"
Write-Host "Location service:    = $locationEnabled"

Add-Row 'Telemetry' 'telemetry_level' $telemetryLevel '' "Disable telemetry: mask telemetry in /etc/hosts + disable services"
Add-Row 'Telemetry' 'location_service' $locationEnabled '' "Disable location: systemctl disable geoclue + gnome-control-center"

# -----------------------------------------------------------------------
# 5. AUTO-UPDATE: note that system_update.service / .timer should be installed
# -----------------------------------------------------------------------
Write-Host "Auto-update: will install system_update.service + system_update.timer from repo"

Add-Row 'AutoUpdate' 'install_service_files' 'system_update' '' 'Install system_update.service + system_update.timer from the repo (see Scheduled systemd Automatic Update/Debian/service files/)'

# -----------------------------------------------------------------------
# 6. LOCK SCREEN TIMEOUT — how long before the screen locks / blanks.
#    Primary signal: a SECURE screen saver (locks on resume). Fallback: the
#    power "turn off display after" (VIDEOIDLE) idle timeout on AC. If nothing
#    locks the screen, the value is "never" — so Linux disables lock/blanking
#    too (mirroring a Windows box that has no lock-screen timeout).
# -----------------------------------------------------------------------
$lockTimeoutSec = $null
try {
    $desk = Get-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -ErrorAction SilentlyContinue
    $ssActive  = [int](Safe-Property $desk 'ScreenSaveActive'    0)
    $ssSecure  = [int](Safe-Property $desk 'ScreenSaverIsSecure' 0)
    $ssTimeout = [int](Safe-Property $desk 'ScreenSaveTimeOut'   0)
    if ($ssActive -eq 1 -and $ssSecure -eq 1 -and $ssTimeout -gt 0) {
        $lockTimeoutSec = $ssTimeout
    }
} catch {}

# Fallback: power "turn off display after" (SUB_VIDEO\VIDEOIDLE) on AC, in seconds.
if ($null -eq $lockTimeoutSec) {
    try {
        $vid = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes\*\7516b95f-f776-4464-8c53-06167f40cc99\3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e' -ErrorAction SilentlyContinue |
               Select-Object -First 1
        $ac = Safe-Property $vid 'ACSettingIndex'
        if ($null -ne $ac -and [int]$ac -gt 0) { $lockTimeoutSec = [int]$ac }
    } catch {}
}

if ($null -ne $lockTimeoutSec -and $lockTimeoutSec -gt 0) {
    $lockMinutes = [math]::Round($lockTimeoutSec / 60)
    if ($lockMinutes -lt 1) { $lockMinutes = 1 }
    $lockValue = "$lockMinutes min"
} else {
    $lockValue = 'never'
}

Write-Host "Screen: lock timeout = $lockValue"

Add-Row 'Screen' 'lock_screen_timeout' $lockValue '' 'GNOME (system-wide dconf, all users): session idle-delay + screensaver lock-enabled; "never" => disable lock & blanking'

# -----------------------------------------------------------------------
# EXPORT CSV
# -----------------------------------------------------------------------
$configRows | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8

Write-Host ""
Write-Host "Settings extracted to: $OutputPath" -ForegroundColor Green
Write-Host "Categories: $($configRows.Count) config rows written"
Write-Host ""
$configRows | ForEach-Object { Write-Host "  $($_.Category) / $($_.ConfigKey) = $($_.WindowsValue)" }
