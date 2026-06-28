<#
.SYNOPSIS
    Extracts common Windows user-facing settings and writes them to
    C_windows_configs.csv for later application on Linux.

.DESCRIPTION
    Extracts user-facing settings and writes them to C_windows_configs.csv:
      1. Power settings  -  what closing the lid does (on battery / on AC)
      2. Display resolution & scaling
      3. Keyboard layout, repeat speed and NumLock state
      4. Telemetry level and location-service state
      5. (placeholder) scheduled auto-update service/timer mapping
      6. Lock-screen / blank timeout (secure screensaver or display-off idle)
      7. Mouse pointer size, speed and acceleration
      8. Accessibility (sticky/slow/mouse keys, high contrast, magnifier)
      9. Timezone and time synchronization (non-Microsoft NTP server)
     10. WiFi known networks + profiles (passwords optionally encrypted)
     11. Firewall rules (all rules, for ufw/firewalld on Linux)
    POST-INSTALL items (Phase=post; applied AFTER apps are installed):
     12. Shortcuts (Quick Launch / Start-menu pinned / Desktop) -> installed apps
     13. Startup items (-> autostart) + auto-start third-party services
     14. ~/.ssh (all files) + 15. Contacts folder

    The personal files for 14-15 are bundled into ONE encrypted archive
    "Execute on Linux!/migrated_user_data.tar.enc" (tar + OpenSSL AES-256-CBC/PBKDF2
    using the transfer password); the clear-text staging dir is then deleted, so no
    unencrypted personal data is ever left on disk.

    Every row carries a Phase (pre|post) and Scope (User|System) column. Personal
    files for the post items are staged into "Execute on Linux!/migrated_user_data/".

    Output is written to C_windows_configs.csv (UTF-8, -NoTypeInformation).

    WiFi password export prompts for an optional encryption password; when given
    (and OpenSSL is available, installed on demand) each key is AES-256-CBC /
    PBKDF2 encrypted in OpenSSL's salted format so apply_settings.sh can decrypt
    it. Without it, WiFi networks are exported WITHOUT passwords.

    This script reads current-user settings from the registry/WMI and does not
    strictly require admin rights, though firewall export and OpenSSL install are
    more complete when run elevated.

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

# =======================================================================
#  TRANSFER PASSWORD
#  When launched by run_project.ps1 the mega-title + password prompt have ALREADY
#  been shown (before the "STEP n/5" banners) and the answer is handed over via
#  $env:MIGRATE_XFER_PWD. When run standalone we show the title + prompt here.
#  The password protects every exported secret (WiFi passwords AND SSH private keys
#  / the personal-data archive).
# =======================================================================
# Shared mega-title + prompt helpers (Show-MegaTitle / Get-XferPassword).
$xferPromptShared = Join-Path $PSScriptRoot '_xfer_password.ps1'
if (Test-Path $xferPromptShared) { . $xferPromptShared }

if ($env:MIGRATE_XFER_PROMPTED -eq '1') {
    $xferPwd = [string]$env:MIGRATE_XFER_PWD          # already prompted by run_project
} elseif (Get-Command Get-XferPassword -ErrorAction SilentlyContinue) {
    Show-MegaTitle
    $xferPwd = Get-XferPassword -TimeoutSec 15
} else {
    $xferPwd = ''
}

# Locate openssl on Windows so secrets can be encrypted in the exact OpenSSL
# "Salted__"/PBKDF2 format that apply_settings.sh decrypts (install on demand).
function Resolve-OpenSSL {
    $c = Get-Command openssl -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    foreach ($p in @(
        "$env:ProgramFiles\Git\usr\bin\openssl.exe",
        "$env:ProgramFiles\Git\mingw64\bin\openssl.exe",
        "${env:ProgramFiles(x86)}\Git\usr\bin\openssl.exe")) {
        if (Test-Path $p) { return $p }
    }
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        foreach ($id in @('ShiningLight.OpenSSL.Light', 'FireDaemon.OpenSSL')) {
            try {
                Write-Host "  Installing OpenSSL ($id) via winget so exported secrets can be encrypted ..." -ForegroundColor Yellow
                winget install --id $id -e --accept-source-agreements --accept-package-agreements --silent 2>$null | Out-Null
            } catch {}
            $c = Get-Command openssl -ErrorAction SilentlyContinue
            if ($c) { return $c.Source }
        }
    }
    return $null
}

$opensslExe = $null
if ($xferPwd) {
    $opensslExe = Resolve-OpenSSL
    if (-not $opensslExe) {
        Write-Host "OpenSSL not available and could not be installed - WiFi exported WITHOUT passwords and SSH private keys will be skipped." -ForegroundColor Yellow
    }
}

# Encrypt one secret (WiFi key) into OpenSSL salted/PBKDF2 base64.
function Protect-Secret { param([string]$Plain, [string]$Passphrase, [string]$OpenSsl)
    if (-not $Plain -or -not $Passphrase -or -not $OpenSsl) { return $null }
    $tmp = [System.IO.Path]::GetTempFileName()
    try {
        [System.IO.File]::WriteAllText($tmp, $Plain, (New-Object System.Text.UTF8Encoding($false)))
        $enc = & $OpenSsl enc -aes-256-cbc -pbkdf2 -salt -base64 -A -pass "pass:$Passphrase" -in $tmp 2>$null
        if ($LASTEXITCODE -eq 0 -and $enc) { return ([string]$enc).Trim() }
    } catch {} finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
    return $null
}

# Safely access a property that may not exist.
function Safe-Property { param($Obj, [string] $Name, $Default = $null); try { $Obj.$Name } catch { $Default } }

# --verbose / -v (the built-in CmdletBinding -Verbose switch) -> list every item's
# name per category; otherwise just print the count + a hint. (Task 15)
# Use the EXPLICITLY-BOUND parameter (not $VerbosePreference, which can be inherited
# from the session and would wrongly enable verbose when -Verbose was never passed).
$Script:IsVerbose = $PSBoundParameters.ContainsKey('Verbose')
# ...then silence cmdlet/module verbose so -Verbose lists OUR items, not CIM/WMI chatter
# (incl. the NetSecurity module-import + per-rule flood from Get-NetFirewallRule). Must
# be GLOBAL: module imports/cmdlets read the global preference, so a script-scoped
# override would not suppress them when the session inherited a verbose preference.
$global:VerbosePreference = 'SilentlyContinue'
function Write-ExportSummary { param([string]$Title, $Names)
    $arr = @($Names | Where-Object { $_ })
    Write-Host ''
    Write-Host ("{0}:" -f $Title)
    if ($Script:IsVerbose) {
        Write-Host ("  {0} items exported:" -f $arr.Count)
        foreach ($n in $arr) { Write-Host "    - $n" }
    } else {
        Write-Host ("  {0} items exported (Re-run the script with --verbose to see the list)" -f $arr.Count)
    }
}
# Per-category name lists (populated during detection, printed via Write-ExportSummary).
$fwNames = New-Object System.Collections.Generic.List[string]
$qlNames = New-Object System.Collections.Generic.List[string]
$smNames = New-Object System.Collections.Generic.List[string]
$dtNames = New-Object System.Collections.Generic.List[string]
$startNames = New-Object System.Collections.Generic.List[string]
$svcNames = New-Object System.Collections.Generic.List[string]

# -----------------------------------------------------------------------
# 1. POWER SETTINGS - lid-close action (battery / AC)
# -----------------------------------------------------------------------
$configRows = [System.Collections.Generic.List[pscustomobject]]::new()

function Add-Row {
    # Phase = pre|post  -> whether the setting is applied BEFORE or AFTER app installation.
    # Scope = User|System -> whose settings these are. Both columns are always non-empty.
    param([string]$Category, [string]$ConfigKey, [string]$WindowsValue, [string]$LinuxCommand,
          [string]$Notes = '', [string]$Phase = 'pre', [string]$Scope = 'User')
    $configRows.Add([pscustomobject]@{
        Category      = $Category
        ConfigKey     = $ConfigKey
        WindowsValue  = $WindowsValue
        LinuxCommand  = $LinuxCommand
        Notes         = $Notes
        Phase         = $Phase
        Scope         = $Scope
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

Add-Row 'Power' 'lid_close_on_ac'      $acAction '' "logind.conf: HandleLidSwitchExternalPower=$($winToLinuxLid[$acAction])" -Scope 'System'
Add-Row 'Power' 'lid_close_on_battery' $dcAction '' "logind.conf: HandleLidSwitch=$($winToLinuxLid[$dcAction])" -Scope 'System'

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
    # Telemetry - HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection
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
    # Location - check if location service is globally enabled
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

Add-Row 'AutoUpdate' 'install_service_files' 'system_update' '' 'Install system_update.service + system_update.timer from the repo (see Scheduled systemd Automatic Update/Debian/service files/)' -Scope 'System'

# -----------------------------------------------------------------------
# 6. LOCK SCREEN TIMEOUT - how long before the screen locks / blanks.
#    Primary signal: a SECURE screen saver (locks on resume). Fallback: the
#    power "turn off display after" (VIDEOIDLE) idle timeout on AC. If nothing
#    locks the screen, the value is "never" - so Linux disables lock/blanking
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
# 7. MOUSE - pointer size, speed, acceleration
# -----------------------------------------------------------------------
$mouseSize = ''; $mouseSpeed = ''; $mouseAccel = ''; $mouseSwap = ''; $mouseDbl = ''
try {
    $m = Get-ItemProperty -Path 'HKCU:\Control Panel\Mouse' -ErrorAction SilentlyContinue
    # Sensitivity 1..20 (default 10)  ->  GNOME peripherals.mouse speed -1..1 (default 0).
    $sens = [int](Safe-Property $m 'MouseSensitivity' 10)
    if ($sens -lt 1) { $sens = 10 }
    $mouseSpeed = ([math]::Round((($sens - 10) / 10.0), 2)).ToString([System.Globalization.CultureInfo]::InvariantCulture)
    # MouseSpeed 0 = no pointer acceleration ("flat"); >0 = Windows "enhance precision".
    $accelRaw = [int](Safe-Property $m 'MouseSpeed' 1)
    $mouseAccel = if ($accelRaw -eq 0) { 'flat' } else { 'default' }
    # Primary-button swap (left-handed) and double-click speed (ms).
    $mouseSwap = if ([int](Safe-Property $m 'SwapMouseButtons' 0) -eq 1) { 'true' } else { 'false' }
    $dbl = [int](Safe-Property $m 'DoubleClickSpeed' 0)
    if ($dbl -gt 0) { $mouseDbl = [string]$dbl }
} catch {}
try {
    $cur = Get-ItemProperty -Path 'HKCU:\Control Panel\Cursors' -ErrorAction SilentlyContinue
    $base = [int](Safe-Property $cur 'CursorBaseSize' 0)
    if ($base -gt 0) { $mouseSize = [string]$base }
} catch {}

Write-Host "Mouse: pointer size = $mouseSize ; speed = $mouseSpeed ; accel = $mouseAccel ; swap = $mouseSwap"
Add-Row 'Mouse' 'mouse_size'  $mouseSize  '' 'GNOME org.gnome.desktop.interface cursor-size'
Add-Row 'Mouse' 'mouse_speed' $mouseSpeed '' 'GNOME org.gnome.desktop.peripherals.mouse speed (-1..1)'
Add-Row 'Mouse' 'mouse_accel' $mouseAccel '' 'GNOME org.gnome.desktop.peripherals.mouse accel-profile'
Add-Row 'Mouse' 'mouse_swap'  $mouseSwap  '' 'GNOME org.gnome.desktop.peripherals.mouse left-handed'
Add-Row 'Mouse' 'mouse_dblclick' $mouseDbl '' 'GNOME org.gnome.desktop.peripherals.mouse double-click (ms)'

# -----------------------------------------------------------------------
# 8. ACCESSIBILITY - sticky/slow/mouse keys, high contrast, magnifier
# -----------------------------------------------------------------------
# Each Windows "...\Flags" value is a string bitmask; bit 0 (value -band 1) = feature on.
function Test-AccFlag { param([string]$Path)
    try {
        $p = Get-ItemProperty -Path $Path -Name 'Flags' -ErrorAction SilentlyContinue
        if ($p -and $null -ne $p.Flags) { return ([int]$p.Flags -band 1) -eq 1 }
    } catch {}
    return $false
}
# Accessibility values are 'true'/'false' literals (gsettings boolean form).
$a11yStick = if (Test-AccFlag 'HKCU:\Control Panel\Accessibility\StickyKeys')       { 'true' } else { 'false' }
$a11ySlow  = if (Test-AccFlag 'HKCU:\Control Panel\Accessibility\Keyboard Response') { 'true' } else { 'false' }
$a11yMouse = if (Test-AccFlag 'HKCU:\Control Panel\Accessibility\MouseKeys')         { 'true' } else { 'false' }
$a11yHC    = if (Test-AccFlag 'HKCU:\Control Panel\Accessibility\HighContrast')      { 'true' } else { 'false' }
$a11yMag   = 'false'
try {
    $mag = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\ScreenMagnifier' -Name 'RunningState' -ErrorAction SilentlyContinue
    if ($mag -and [int]$mag.RunningState -eq 1) { $a11yMag = 'true' }
} catch {}

Write-Host "Accessibility: sticky=$a11yStick slow=$a11ySlow mousekeys=$a11yMouse highcontrast=$a11yHC magnifier=$a11yMag"
Add-Row 'Accessibility' 'a11y_stickykeys'   $a11yStick '' 'GNOME a11y.keyboard stickykeys-enable'
Add-Row 'Accessibility' 'a11y_slowkeys'     $a11ySlow  '' 'GNOME a11y.keyboard slowkeys-enable'
Add-Row 'Accessibility' 'a11y_mousekeys'    $a11yMouse '' 'GNOME a11y.keyboard mousekeys-enable'
Add-Row 'Accessibility' 'a11y_highcontrast' $a11yHC    '' 'GNOME a11y.interface high-contrast'
Add-Row 'Accessibility' 'a11y_magnifier'    $a11yMag   '' 'GNOME a11y.applications screen-magnifier-enabled'

# -----------------------------------------------------------------------
# 9. KEYBOARD repeat speed + NumLock state
# -----------------------------------------------------------------------
$kbDelayMs = ''; $kbRateMs = ''; $numlock = ''
try {
    $kb = Get-ItemProperty -Path 'HKCU:\Control Panel\Keyboard' -ErrorAction SilentlyContinue
    # KeyboardDelay 0..3  ->  250/500/750/1000 ms before auto-repeat.
    $kd = [int](Safe-Property $kb 'KeyboardDelay' 1)
    if ($kd -lt 0) { $kd = 1 }; if ($kd -gt 3) { $kd = 3 }
    $kbDelayMs = [string](($kd + 1) * 250)
    # KeyboardSpeed 0..31 (chars/sec ~2.5..30)  ->  ms BETWEEN repeats (GNOME repeat-interval).
    $ks = [int](Safe-Property $kb 'KeyboardSpeed' 31)
    if ($ks -lt 0) { $ks = 0 }; if ($ks -gt 31) { $ks = 31 }
    $cps = 2.5 + ($ks / 31.0) * 27.5
    $kbRateMs = [string]([math]::Round(1000.0 / $cps))
    # InitialKeyboardIndicators: NumLock flag = 0x2.
    $ind = Safe-Property $kb 'InitialKeyboardIndicators' '0'
    $numlock = if (([int64]$ind -band 2) -eq 2) { 'true' } else { 'false' }
} catch {}

Write-Host "Keyboard: repeat-delay=${kbDelayMs}ms repeat-interval=${kbRateMs}ms numlock=$numlock"
Add-Row 'Keyboard' 'key_repeat_delay' $kbDelayMs '' 'GNOME peripherals.keyboard delay (uint32 ms)'
Add-Row 'Keyboard' 'key_repeat_rate'  $kbRateMs  '' 'GNOME peripherals.keyboard repeat-interval (uint32 ms)'
Add-Row 'Keyboard' 'numlock'          $numlock   '' 'GNOME peripherals.keyboard numlock-state'

# -----------------------------------------------------------------------
# 10. TIMEZONE + TIME SYNCHRONIZATION (non-Microsoft NTP)
# -----------------------------------------------------------------------
$ianaTz = 'unknown'
try {
    $winTz = [System.TimeZoneInfo]::Local.Id
    $tmp = ''
    # .NET 6+ (PowerShell 7) can convert directly; Windows PowerShell 5.1 cannot.
    if ([System.TimeZoneInfo].GetMethod('TryConvertWindowsIdToIanaId', [type[]]@([string], [string].MakeByRefType()))) {
        if ([System.TimeZoneInfo]::TryConvertWindowsIdToIanaId($winTz, [ref]$tmp)) { $ianaTz = $tmp }
    }
    if ($ianaTz -eq 'unknown') {
        $tzMap = @{
            'Iran Standard Time'        = 'Asia/Tehran'
            'GMT Standard Time'         = 'Europe/London'
            'Central Europe Standard Time' = 'Europe/Budapest'
            'W. Europe Standard Time'   = 'Europe/Berlin'
            'Romance Standard Time'     = 'Europe/Paris'
            'Eastern Standard Time'     = 'America/New_York'
            'Central Standard Time'     = 'America/Chicago'
            'Pacific Standard Time'     = 'America/Los_Angeles'
            'UTC'                       = 'Etc/UTC'
            'Arabian Standard Time'     = 'Asia/Dubai'
            'India Standard Time'       = 'Asia/Kolkata'
            'Tokyo Standard Time'       = 'Asia/Tokyo'
            'China Standard Time'       = 'Asia/Shanghai'
            'AUS Eastern Standard Time' = 'Australia/Sydney'
        }
        if ($tzMap.ContainsKey($winTz)) { $ianaTz = $tzMap[$winTz] }
    }
} catch {}

$ntpServer = 'pool.ntp.org'
try {
    $w32 = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Parameters' -Name 'NtpServer' -ErrorAction SilentlyContinue
    if ($w32 -and $w32.NtpServer) {
        $first = (([string]$w32.NtpServer) -split '\s+')[0]    # e.g. "time.windows.com,0x9"
        $first = ($first -split ',')[0]
        if ($first -and $first -notmatch 'time\.windows\.com|microsoft') { $ntpServer = $first }
    }
} catch {}

Write-Host "Timezone: $ianaTz ; NTP server: $ntpServer"
Add-Row 'Time' 'timezone'   $ianaTz    '' 'Linux: timedatectl set-timezone' -Scope 'System'
Add-Row 'Time' 'ntp_server' $ntpServer '' 'Linux: systemd-timesyncd NTP= (non-Microsoft)' -Scope 'System'

# -----------------------------------------------------------------------
# 10b. EXTRA DESKTOP/SYSTEM SETTINGS (theme, accent, locale, proxy, touchpad,
#      sleep timeouts, night light) + hosts file, network printers, static IP/DNS.
# -----------------------------------------------------------------------
# THEME (dark/light)
$colorScheme = ''
try {
    $pz = Get-ItemProperty -Path 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize' -ErrorAction SilentlyContinue
    if ($pz -and $null -ne $pz.AppsUseLightTheme) { $colorScheme = if ([int]$pz.AppsUseLightTheme -eq 0) { 'prefer-dark' } else { 'default' } }
} catch {}
Add-Row 'Appearance' 'color_scheme' $colorScheme '' 'GNOME org.gnome.desktop.interface color-scheme'

# ACCENT COLOR -> nearest GNOME accent (GNOME 47+).
function Get-NearestAccent { param([int]$R, [int]$G, [int]$B)
    $cands = @{ blue='3584e4'; teal='2190a4'; green='3a944a'; yellow='c88800'; orange='ed5b00'; red='e62d42'; pink='d56199'; purple='9141ac'; slate='6f8396' }
    $best = ''; $bestD = [double]::MaxValue
    foreach ($k in $cands.Keys) {
        $h = $cands[$k]
        $r2 = [Convert]::ToInt32($h.Substring(0,2),16); $g2 = [Convert]::ToInt32($h.Substring(2,2),16); $b2 = [Convert]::ToInt32($h.Substring(4,2),16)
        $d = [math]::Pow($R-$r2,2) + [math]::Pow($G-$g2,2) + [math]::Pow($B-$b2,2)
        if ($d -lt $bestD) { $bestD = $d; $best = $k }
    }
    return $best
}
$accent = ''
try {
    $dwm = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\DWM' -Name 'AccentColor' -ErrorAction SilentlyContinue
    if ($dwm -and $null -ne $dwm.AccentColor) {
        $abgr = [uint32]$dwm.AccentColor          # stored 0xAABBGGRR
        $r = [int]($abgr -band 0xFF); $g = [int](($abgr -shr 8) -band 0xFF); $b = [int](($abgr -shr 16) -band 0xFF)
        $accent = Get-NearestAccent -R $r -G $g -B $b
    }
} catch {}
Add-Row 'Appearance' 'accent_color' $accent '' 'GNOME org.gnome.desktop.interface accent-color (GNOME 47+)'

# LOCALE / regional formats
$posixLocale = ''
try {
    $intl = Get-ItemProperty -Path 'HKCU:\Control Panel\International' -Name 'LocaleName' -ErrorAction SilentlyContinue
    $ln = if ($intl) { [string]$intl.LocaleName } else { (Get-Culture).Name }
    if ($ln) { $posixLocale = ($ln -replace '-', '_') + '.UTF-8' }
} catch {}
Add-Row 'Locale' 'locale' $posixLocale '' 'Linux: localectl set-locale LANG=' -Scope 'System'

# PROXY (WinINET)
$proxyMode = 'none'; $proxyHost = ''; $proxyPort = ''; $proxyAuto = ''
try {
    $is = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
    if ($is) {
        if ($is.AutoConfigURL) { $proxyMode = 'auto'; $proxyAuto = [string]$is.AutoConfigURL }
        elseif ([int](Safe-Property $is 'ProxyEnable' 0) -eq 1 -and $is.ProxyServer) {
            $proxyMode = 'manual'
            $ps = [string]$is.ProxyServer
            if ($ps -match 'http=([^;]+)') { $ps = $Matches[1] } elseif ($ps -match ';') { $ps = ($ps -split ';')[0] }
            $ps = $ps -replace '^[a-z]+=', ''
            $proxyHost = ($ps -split ':')[0]; $proxyPort = ($ps -split ':')[1]
        }
    }
} catch {}
Add-Row 'Proxy' 'proxy_mode'       $proxyMode '' 'GNOME org.gnome.system.proxy mode'
Add-Row 'Proxy' 'proxy_host'       $proxyHost '' 'GNOME org.gnome.system.proxy.http host'
Add-Row 'Proxy' 'proxy_port'       $proxyPort '' 'GNOME org.gnome.system.proxy.http port'
Add-Row 'Proxy' 'proxy_autoconfig' $proxyAuto '' 'GNOME org.gnome.system.proxy autoconfig-url'

# TOUCHPAD (only if a precision touchpad is configured)
$tpTap = ''; $tpNatural = ''
try {
    $tp = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\PrecisionTouchPad' -ErrorAction SilentlyContinue
    if ($tp) {
        if ($null -ne $tp.TapsEnabled)    { $tpTap = if ([int]$tp.TapsEnabled -eq 1) { 'true' } else { 'false' } }
        if ($null -ne $tp.ScrollDirection){ $tpNatural = if ([int]$tp.ScrollDirection -eq 1) { 'true' } else { 'false' } }
    }
} catch {}
Add-Row 'Touchpad' 'touchpad_tap'     $tpTap     '' 'GNOME org.gnome.desktop.peripherals.touchpad tap-to-click'
Add-Row 'Touchpad' 'touchpad_natural' $tpNatural '' 'GNOME org.gnome.desktop.peripherals.touchpad natural-scroll'

# SLEEP timeouts (seconds; STANDBYIDLE on AC/DC from the active power scheme)
$sleepAc = ''; $sleepDc = ''
try {
    $sl = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes\*\238c9fa8-0aad-41ed-83f4-97be242c8f20\29f6c1db-86da-48c5-9fdb-f2b67b1f44da' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($sl) { if ($null -ne $sl.ACSettingIndex) { $sleepAc = [string][int]$sl.ACSettingIndex }; if ($null -ne $sl.DCSettingIndex) { $sleepDc = [string][int]$sl.DCSettingIndex } }
} catch {}
Add-Row 'Power' 'sleep_ac' $sleepAc '' 'GNOME power sleep-inactive-ac-timeout (s)' -Scope 'System'
Add-Row 'Power' 'sleep_dc' $sleepDc '' 'GNOME power sleep-inactive-battery-timeout (s)' -Scope 'System'

# NIGHT LIGHT (blue-light reduction) on/off -- best-effort blob read.
function Test-NightLight {
    try {
        $p = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\CloudStore\Store\DefaultAccount\Current\default$windows.data.bluelightreduction.bluelightreductionstate\windows.data.bluelightreduction.bluelightreductionstate'
        $d = (Get-ItemProperty -Path $p -Name 'Data' -ErrorAction SilentlyContinue).Data
        if (-not $d) { return '' }
        for ($i = 0; $i -lt $d.Length - 5; $i++) {
            if ($d[$i] -eq 0x10 -and $d[$i+1] -eq 0 -and $d[$i+2] -eq 0 -and $d[$i+3] -eq 0) {
                if ($d[$i+4] -eq 0x02 -and $d[$i+5] -eq 0x01) { return 'true' } else { return 'false' }
            }
        }
        return 'false'
    } catch { return '' }
}
$nightLight = Test-NightLight
Add-Row 'Appearance' 'night_light' $nightLight '' 'GNOME org.gnome.settings-daemon.plugins.color night-light-enabled'

# DEFAULT WEB BROWSER (applied post-install once the equivalent is installed)
$defBrowser = ''
try {
    $uc = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\https\UserChoice' -Name 'ProgId' -ErrorAction SilentlyContinue
    switch -Wildcard ([string]$uc.ProgId) {
        'ChromeHTML*' { $defBrowser = 'chrome' }
        'FirefoxURL*' { $defBrowser = 'firefox' }
        'MSEdgeHTM*'  { $defBrowser = 'edge' }
        'BraveHTML*'  { $defBrowser = 'brave' }
        'OperaStable*'{ $defBrowser = 'opera' }
    }
} catch {}
Add-Row 'DefaultApps' 'default_browser' $defBrowser '' 'Linux: xdg-settings set default-web-browser' -Phase 'post' -Scope 'User'

# HOSTS file -- custom (non-default) entries only.
$hostsCount = 0
try {
    $hp = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
    if (Test-Path $hp) {
        Get-Content $hp -ErrorAction SilentlyContinue | ForEach-Object {
            $line = ($_ -replace '#.*$', '').Trim()
            if (-not $line) { return }
            $parts = $line -split '\s+', 2
            if ($parts.Count -lt 2) { return }
            $ip = $parts[0]
            # skip the default loopback boilerplate
            if ($ip -in @('127.0.0.1', '::1') -and $parts[1] -match '^(localhost)\s*$') { return }
            Add-Row 'Hosts' 'host_entry' (($line -replace '\|', ' ')) '' 'Linux: merge into /etc/hosts' -Scope 'System'
            $hostsCount++
        }
    }
} catch {}
if ($hostsCount -eq 0) { Add-Row 'Hosts' 'host_entry' '' '' 'No custom hosts entries (placeholder)' -Scope 'System' }
Write-Host "Hosts: $hostsCount custom entr(ies)"

# NETWORK PRINTERS (network/shared; local USB drivers are not portable).
$prnCount = 0
try {
    Get-Printer -ErrorAction SilentlyContinue | Where-Object {
        $_.PortName -and ($_.PortName -match '^(IP_|WSD|https?://)' -or $_.Shared -eq $true -or $_.Type -eq 'Connection')
    } | ForEach-Object {
        $hostp = ($_.PortName -replace '^IP_', '')
        $packed = (@($_.Name, $hostp) | ForEach-Object { ([string]$_ -replace '\|', ' ') }) -join '|'
        Add-Row 'Printers' 'printer' $packed '' 'Linux: CUPS lpadmin (best-effort)' -Scope 'System'
        $prnCount++
    }
} catch {}
if ($prnCount -eq 0) { Add-Row 'Printers' 'printer' '' '' 'No network printers (placeholder)' -Scope 'System' }
Write-Host "Printers: $prnCount network printer(s)"

# STATIC IP / DNS (captured as a MANUAL note -- never auto-applied, so migration
# cannot break the user's network).
$netCount = 0
try {
    Get-NetIPConfiguration -ErrorAction SilentlyContinue | ForEach-Object {
        $cfg = $_
        $man = $cfg.IPv4Address | Where-Object { $_.PrefixOrigin -eq 'Manual' }
        $dns = ($cfg.DNSServer | Where-Object { $_.AddressFamily -eq 2 } | ForEach-Object { $_.ServerAddresses }) -join ','
        if ($man -or $dns) {
            $ip = if ($man) { ($man | Select-Object -First 1).IPAddress } else { '' }
            $gw = [string]$cfg.IPv4DefaultGateway.NextHop
            $packed = (@($cfg.InterfaceAlias, $ip, $gw, $dns) | ForEach-Object { ([string]$_ -replace '\|', ' ') }) -join '|'
            Add-Row 'NetConfig' 'static_net' $packed '' 'Linux: configure via NetworkManager (manual note)' -Scope 'System'
            $netCount++
        }
    }
} catch {}
if ($netCount -eq 0) { Add-Row 'NetConfig' 'static_net' '' '' 'No static IP/DNS config (placeholder)' -Scope 'System' }
Write-Host "Static network config: $netCount adapter(s)"

# -----------------------------------------------------------------------
# 11. WIFI known networks + (optionally encrypted) passwords
#     (the transfer password + openssl were prompted/resolved at the top.)
# -----------------------------------------------------------------------
$wifiCount = 0
try {
    $profOut = netsh wlan show profiles 2>$null
    $names = $profOut | Select-String 'All User Profile\s*:\s*(.+)$' | ForEach-Object { $_.Matches[0].Groups[1].Value.Trim() }
    foreach ($n in $names) {
        if (-not $n) { continue }
        $detail = netsh wlan show profile name="$n" key=clear 2>$null
        $ssid = ($detail | Select-String 'SSID name\s*:\s*"?(.*?)"?\s*$' | Select-Object -First 1).Matches[0].Groups[1].Value
        if (-not $ssid) { $ssid = $n }
        $authLine = ($detail | Select-String 'Authentication\s*:\s*(.+)$' | Select-Object -First 1)
        $authRaw = if ($authLine) { $authLine.Matches[0].Groups[1].Value.Trim() } else { '' }
        $auth = if ($authRaw -match 'Open') { 'open' } else { 'wpa' }
        $keyLine = ($detail | Select-String 'Key Content\s*:\s*(.+)$' | Select-Object -First 1)
        $key = if ($keyLine) { $keyLine.Matches[0].Groups[1].Value.Trim() } else { '' }

        $secret = ''; $sectype = 'none'
        if ($auth -ne 'open' -and $key) {
            $enc = Protect-Secret -Plain $key -Passphrase $xferPwd -OpenSsl $opensslExe
            if ($enc) { $secret = $enc; $sectype = 'enc' }
        }
        # Pipe-pack the fields (strip embedded '|' so the delimiter stays unambiguous).
        $packed = (@($ssid, $auth, $secret, $sectype) | ForEach-Object { ([string]$_ -replace '\|', ' ') }) -join '|'
        Add-Row 'Wifi' 'wifi_profile' $packed '' 'Linux: nmcli connection add type wifi' -Scope 'System'
        $wifiCount++
    }
} catch {}
if ($wifiCount -eq 0) { Add-Row 'Wifi' 'wifi_profile' '' '' 'No WiFi profiles found (category placeholder)' -Scope 'System' }
$wifiMode = if ($opensslExe) { 'with encrypted passwords' } else { 'without passwords' }
Write-Host "WiFi: $wifiCount profile(s) exported ($wifiMode)"

# -----------------------------------------------------------------------
# 12. FIREWALL rules (all rules; mapped to ufw/firewalld on Linux)
# -----------------------------------------------------------------------
$fwCount = 0
try {
    # -Verbose:$false stops these module cmdlets from streaming per-rule verbose lines
    # when the SESSION's $VerbosePreference is set (module cmdlets read the global
    # preference, which a script-scoped override does not change).
    $rules = Get-NetFirewallRule -ErrorAction SilentlyContinue -Verbose:$false
    foreach ($r in $rules) {
        $pf = $null
        try { $pf = $r | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue -Verbose:$false } catch {}
        $proto = if ($pf) { [string]$pf.Protocol } else { '' }
        $port  = if ($pf -and $pf.LocalPort) { (@($pf.LocalPort) -join ',') } else { '' }
        $packed = (@($r.DisplayName, $r.Direction, $r.Action, $r.Enabled, $proto, $port) | ForEach-Object { ([string]$_ -replace '\|', ' ') }) -join '|'
        Add-Row 'Firewall' 'fw_rule' $packed '' 'Linux: ufw / firewalld' -Scope 'System'
        $fwNames.Add([string]$r.DisplayName)
        $fwCount++
    }
} catch {}
if ($fwCount -eq 0) { Add-Row 'Firewall' 'fw_rule' '' '' 'No firewall rules found (category placeholder)' -Scope 'System' }
Write-ExportSummary 'Firewall Rules export' $fwNames

# =======================================================================
#  POST-INSTALL items (Phase=post): applied AFTER apps are installed.
#  Personal files travel to Linux inside "Execute on Linux!/migrated_user_data/"
#  (the folder the user copies over). C_detect runs before the generator, and the
#  generator does not wipe that folder, so the staged files survive.
# =======================================================================
$projRoot = $null
if ($PSScriptRoot) { $projRoot = Split-Path -Parent $PSScriptRoot }
if (-not $projRoot) { $projRoot = Split-Path -Parent (Split-Path -Parent $OutputPath) }  # documents\.. = root
$stageRoot = Join-Path $projRoot 'Execute on Linux!\migrated_user_data'
try { New-Item -ItemType Directory -Force -Path $stageRoot | Out-Null } catch {}

# -----------------------------------------------------------------------
# 13. SHORTCUTS - Quick Launch (taskbar pinned), Start-menu pinned, Desktop.
#     Each resolves to an installed Linux app ON THE LINUX SIDE; here we only
#     record the display name + target exe base name.
# -----------------------------------------------------------------------
$wshell = $null
try { $wshell = New-Object -ComObject WScript.Shell } catch {}
function Get-LnkTargetBase { param([string]$Lnk)
    if (-not $wshell) { return '' }
    try {
        $t = $wshell.CreateShortcut($Lnk).TargetPath
        if ($t) { return [System.IO.Path]::GetFileNameWithoutExtension($t) }
    } catch {}
    return ''
}
$shortcutSources = @(
    @{ Kind = 'quicklaunch'; Path = (Join-Path $env:APPDATA 'Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar') },
    @{ Kind = 'startmenu';   Path = (Join-Path $env:APPDATA 'Microsoft\Internet Explorer\Quick Launch\User Pinned\StartMenu') },
    @{ Kind = 'desktop';     Path = [Environment]::GetFolderPath('Desktop') },
    @{ Kind = 'desktop';     Path = [Environment]::GetFolderPath('CommonDesktopDirectory') }
)
$scCount = 0
foreach ($src in $shortcutSources) {
    if (-not $src.Path -or -not (Test-Path $src.Path)) { continue }
    try {
        Get-ChildItem -Path $src.Path -Filter '*.lnk' -File -ErrorAction SilentlyContinue | ForEach-Object {
            $disp = [System.IO.Path]::GetFileNameWithoutExtension($_.Name)
            $exe  = Get-LnkTargetBase $_.FullName
            $packed = (@($disp, $exe) | ForEach-Object { ([string]$_ -replace '\|', ' ') }) -join '|'
            Add-Row 'Shortcuts' $src.Kind $packed '' 'Linux: resolve to an installed .desktop (favourite / desktop file)' -Phase 'post' -Scope 'User'
            switch ($src.Kind) { 'quicklaunch' { $qlNames.Add($disp) } 'startmenu' { $smNames.Add($disp) } 'desktop' { $dtNames.Add($disp) } }
            $scCount++
        }
    } catch {}
}
if ($scCount -eq 0) { Add-Row 'Shortcuts' 'desktop' '' '' 'No transferable shortcuts found (category placeholder)' -Phase 'post' -Scope 'User' }
Write-ExportSummary 'Shortcuts / Quick Launch export' $qlNames
Write-ExportSummary 'Shortcuts / Start Menu export'   $smNames
Write-ExportSummary 'Shortcuts / Desktop export'      $dtNames

# -----------------------------------------------------------------------
# 13b. STARTUP ITEMS + auto-start SERVICES (Phase=post). Scope is preserved:
#      Windows machine-wide (HKLM Run / Common Startup / services) -> System on
#      Linux; current-user (HKCU Run / user Startup) -> User. The Linux side only
#      acts on items that resolve to an installed app / matching systemd unit;
#      everything else is recorded log-only and harmless.
# -----------------------------------------------------------------------
$startupCount = 0
function Get-ExeBaseFromCommand { param([string]$Cmd)
    if (-not $Cmd) { return '' }
    $c = $Cmd.Trim()
    if ($c.StartsWith('"')) { $end = $c.IndexOf('"', 1); if ($end -gt 0) { $c = $c.Substring(1, $end - 1) } }
    else { $c = ($c -split '\s+')[0] }
    try { return [System.IO.Path]::GetFileNameWithoutExtension($c) } catch { return '' }
}
function Add-StartupRows { param([string]$RegPath, [string]$FolderPath, [string]$Scope)
    if ($RegPath) {
        try {
            $k = Get-ItemProperty -Path $RegPath -ErrorAction SilentlyContinue
            if ($k) {
                foreach ($p in $k.PSObject.Properties) {
                    if ($p.Name -match '^PS(Path|ParentPath|ChildName|Drive|Provider)$') { continue }
                    $exe = Get-ExeBaseFromCommand ([string]$p.Value)
                    $packed = (@($p.Name, $exe) | ForEach-Object { ([string]$_ -replace '\|', ' ') }) -join '|'
                    Add-Row 'Startup' 'startup_item' $packed '' 'Linux: autostart if it resolves to an installed app' -Phase 'post' -Scope $Scope
                    $script:startNames.Add([string]$p.Name)
                    $script:startupCount++
                }
            }
        } catch {}
    }
    if ($FolderPath -and (Test-Path $FolderPath)) {
        Get-ChildItem -Path $FolderPath -Filter '*.lnk' -File -ErrorAction SilentlyContinue | ForEach-Object {
            $name = [System.IO.Path]::GetFileNameWithoutExtension($_.Name)
            $exe  = Get-LnkTargetBase $_.FullName
            $packed = (@($name, $exe) | ForEach-Object { ([string]$_ -replace '\|', ' ') }) -join '|'
            Add-Row 'Startup' 'startup_item' $packed '' 'Linux: autostart if it resolves to an installed app' -Phase 'post' -Scope $Scope
            $script:startNames.Add([string]$name)
            $script:startupCount++
        }
    }
}
Add-StartupRows -RegPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -FolderPath ([Environment]::GetFolderPath('Startup')) -Scope 'User'
Add-StartupRows -RegPath 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run' -FolderPath ([Environment]::GetFolderPath('CommonStartup')) -Scope 'System'
Add-StartupRows -RegPath 'HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Run' -FolderPath $null -Scope 'System'
if ($startupCount -eq 0) { Add-Row 'Startup' 'startup_item' '' '' 'No startup items found (placeholder)' -Phase 'post' -Scope 'User' }
Write-ExportSummary 'Startup Items export' $startNames

# Auto-start, third-party services (exclude C:\Windows\ OS services that can never map).
$svcCount = 0
try {
    Get-CimInstance Win32_Service -ErrorAction SilentlyContinue | Where-Object {
        $_.StartMode -eq 'Auto' -and $_.PathName -and ($_.PathName -notmatch '(?i)\\Windows\\')
    } | ForEach-Object {
        $packed = (@($_.DisplayName, $_.Name) | ForEach-Object { ([string]$_ -replace '\|', ' ') }) -join '|'
        Add-Row 'Services' 'service' $packed '' 'Linux: systemctl enable if a clearly-matching unit exists' -Phase 'post' -Scope 'System'
        $svcNames.Add([string]$_.DisplayName)
        $svcCount++
    }
} catch {}
if ($svcCount -eq 0) { Add-Row 'Services' 'service' '' '' 'No auto-start third-party services found (placeholder)' -Phase 'post' -Scope 'System' }
Write-ExportSummary 'Services export' $svcNames

# -----------------------------------------------------------------------
# 13c. SCHEDULED TASKS (manually created; Phase=post). Only non-Microsoft, enabled
#      tasks are considered. Scope follows the task principal (SYSTEM/service ->
#      System; otherwise User). The Linux side turns each into a cron entry IF its
#      program resolves to an installed app; non-resolving ones are log-only.
#      Packed: name|scope|schedule|exeBase   (schedule uses commas, not '|').
# -----------------------------------------------------------------------
$taskCount = 0
try {
    Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {
        $_.TaskPath -notmatch '^\\Microsoft\\' -and $_.State -ne 'Disabled'
    } | ForEach-Object {
        $t = $_
        # Scope: SYSTEM / service accounts -> System; otherwise the current user.
        $scope = 'User'
        try {
            $uid = [string]$t.Principal.UserId; $lt = [string]$t.Principal.LogonType
            if ($uid -match '(?i)system|S-1-5-18|S-1-5-19|S-1-5-20|LocalService|NetworkService' -or $lt -match '(?i)ServiceAccount') { $scope = 'System' }
        } catch {}
        # First exec action -> the program to run.
        $act = $t.Actions | Where-Object { $_.Execute } | Select-Object -First 1
        $exePath = if ($act) { [string]$act.Execute } else { '' }
        $exeBase = if ($exePath) { [System.IO.Path]::GetFileNameWithoutExtension(($exePath -replace '"', '')) } else { '' }
        # First trigger -> a portable schedule string.
        $trig = $t.Triggers | Select-Object -First 1
        $cls  = if ($trig) { [string]$trig.CimClass.CimClassName } else { '' }
        $hh = ''; $mm = ''
        try { if ($trig.StartBoundary) { $dt = [datetime]$trig.StartBoundary; $hh = $dt.ToString('HH'); $mm = $dt.ToString('mm') } } catch {}
        $sched = 'unsupported'
        switch -Wildcard ($cls) {
            '*DailyTrigger'  { $sched = "daily,$hh,$mm" }
            '*TimeTrigger'   { $sched = "daily,$hh,$mm" }
            '*WeeklyTrigger' { $mask = 0; try { $mask = [int]$trig.DaysOfWeek } catch {}; $sched = "weekly,$mask,$hh,$mm" }
            '*LogonTrigger'  { $sched = 'onlogon' }
            '*BootTrigger'   { $sched = 'onstart' }
        }
        $packed = (@($t.TaskName, $scope, $sched, $exeBase) | ForEach-Object { ([string]$_ -replace '\|', ' ') }) -join '|'
        Add-Row 'ScheduledTasks' 'task' $packed '' 'Linux: cron entry if the program resolves to an installed app' -Phase 'post' -Scope $scope
        $taskCount++
    }
} catch {}
if ($taskCount -eq 0) { Add-Row 'ScheduledTasks' 'task' '' '' 'No user-created scheduled tasks found (placeholder)' -Phase 'post' -Scope 'User' }
Write-Host "Scheduled tasks: $taskCount recorded"

# -----------------------------------------------------------------------
# 14. SSH - stage the whole ~/.ssh verbatim (private keys included). The entire
#     migrated_user_data folder is encrypted into one archive below (section 16),
#     so nothing personal is ever left on disk in the clear.
# -----------------------------------------------------------------------
$sshSrc = Join-Path $env:USERPROFILE '.ssh'
$sshStaged = 0
if (Test-Path $sshSrc) {
    $sshDst = Join-Path $stageRoot 'ssh'
    try { New-Item -ItemType Directory -Force -Path $sshDst | Out-Null } catch {}
    Get-ChildItem -Path $sshSrc -File -ErrorAction SilentlyContinue | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $sshDst $_.Name) -Force -ErrorAction SilentlyContinue
        $sshStaged++
    }
    Add-Row 'SSH' 'ssh_dir' 'staged: migrated_user_data (encrypted archive)' '' 'Linux: decrypt the archive, copy into ~/.ssh; perms 600/700' -Phase 'post' -Scope 'User'
} else {
    Add-Row 'SSH' 'ssh_dir' '' '' 'No ~/.ssh found (category placeholder)' -Phase 'post' -Scope 'User'
}
Write-Host "SSH: $sshStaged file(s) staged"

# -----------------------------------------------------------------------
# 15. CONTACTS - stage %USERPROFILE%\Contacts verbatim.
# -----------------------------------------------------------------------
$contactsSrc = Join-Path $env:USERPROFILE 'Contacts'
$contactsCount = 0
if (Test-Path $contactsSrc) {
    $contactsDst = Join-Path $stageRoot 'contacts'
    try {
        New-Item -ItemType Directory -Force -Path $contactsDst | Out-Null
        Copy-Item -Path (Join-Path $contactsSrc '*') -Destination $contactsDst -Recurse -Force -ErrorAction SilentlyContinue
        $contactsCount = @(Get-ChildItem -Path $contactsDst -Recurse -File -ErrorAction SilentlyContinue).Count
    } catch {}
    Add-Row 'Contacts' 'contacts_dir' 'staged: migrated_user_data (encrypted archive)' '' 'Linux: decrypt the archive, copy into ~/Contacts (.contact files are XML)' -Phase 'post' -Scope 'User'
} else {
    Add-Row 'Contacts' 'contacts_dir' '' '' 'No Contacts folder found (category placeholder)' -Phase 'post' -Scope 'User'
}
Write-Host "Contacts: $contactsCount file(s) staged"

# -----------------------------------------------------------------------
# 15b. FONTS - stage user-installed fonts (cross-platform .ttf/.otf). They ride
#      inside the same encrypted archive and land in ~/.local/share/fonts.
# -----------------------------------------------------------------------
$fontCount = 0
try {
    $fontSrc = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Fonts'
    if (Test-Path $fontSrc) {
        $fontDst = Join-Path $stageRoot 'fonts'
        New-Item -ItemType Directory -Force -Path $fontDst | Out-Null
        Get-ChildItem -Path $fontSrc -Include *.ttf, *.otf, *.ttc -File -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination $fontDst -Force -ErrorAction SilentlyContinue; $fontCount++
        }
    }
} catch {}
Add-Row 'Fonts' 'fonts_dir' $(if ($fontCount -gt 0) { 'staged: migrated_user_data (encrypted archive)' } else { '' }) '' 'Linux: copy into ~/.local/share/fonts + fc-cache' -Phase 'post' -Scope 'User'
Write-Host "Fonts: $fontCount user font(s) staged"

# -----------------------------------------------------------------------
# 15c. WALLPAPER - stage the current desktop wallpaper image.
# -----------------------------------------------------------------------
$wpStaged = 0
try {
    $wp = (Get-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name 'WallPaper' -ErrorAction SilentlyContinue).WallPaper
    if ($wp -and (Test-Path $wp)) {
        $wpDst = Join-Path $stageRoot 'wallpaper'
        New-Item -ItemType Directory -Force -Path $wpDst | Out-Null
        Copy-Item -LiteralPath $wp -Destination (Join-Path $wpDst ([System.IO.Path]::GetFileName($wp))) -Force -ErrorAction SilentlyContinue
        $wpStaged = 1
    }
} catch {}
Add-Row 'Wallpaper' 'wallpaper_file' $(if ($wpStaged) { 'staged: migrated_user_data (encrypted archive)' } else { '' }) '' 'Linux: set org.gnome.desktop.background picture-uri' -Phase 'post' -Scope 'User'
Write-Host "Wallpaper: $(if ($wpStaged) { 'staged' } else { 'none' })"

# -----------------------------------------------------------------------
# 16. ENCRYPT the staged personal data into ONE archive and remove the clear copy.
#     migrated_user_data/  --(tar)-->  .tar  --(openssl AES-256-CBC/PBKDF2)-->
#     migrated_user_data.tar.enc   (decrypted on Linux by apply_settings.sh).
#     Uses the SAME transfer password as WiFi. No password / no openssl / no tar
#     => the clear staging dir is DELETED and personal data is not migrated (we
#     never leave it unencrypted on disk).
# -----------------------------------------------------------------------
$stagedAnything = (Test-Path $stageRoot) -and (@(Get-ChildItem -Path $stageRoot -Recurse -File -ErrorAction SilentlyContinue).Count -gt 0)
$archivePath = Join-Path $projRoot 'Execute on Linux!\migrated_user_data.tar.enc'
if (Test-Path $archivePath) { Remove-Item -LiteralPath $archivePath -Force -ErrorAction SilentlyContinue }
if ($stagedAnything) {
    $tarExe = (Get-Command tar -ErrorAction SilentlyContinue).Source
    if ($xferPwd -and $opensslExe -and $tarExe) {
        $tarTmp = [System.IO.Path]::GetTempFileName()
        try {
            # Archive the CONTENTS of the staging dir (so it extracts as ssh/ contacts/...).
            & $tarExe -cf $tarTmp -C $stageRoot . 2>$null
            if ((Test-Path $tarTmp) -and ((Get-Item $tarTmp).Length -gt 0)) {
                & $opensslExe enc -aes-256-cbc -pbkdf2 -salt -pass "pass:$xferPwd" -in $tarTmp -out $archivePath 2>$null
            }
        } catch {} finally { Remove-Item $tarTmp -Force -ErrorAction SilentlyContinue }
        if (Test-Path $archivePath) {
            Write-Host "Personal data encrypted -> Execute on Linux!\migrated_user_data.tar.enc" -ForegroundColor Green
        } else {
            Write-Host "Could not create the encrypted archive - personal data NOT migrated." -ForegroundColor Yellow
        }
    } else {
        Write-Host "No transfer password / OpenSSL / tar available - personal data NOT migrated (left unencrypted nowhere)." -ForegroundColor Yellow
    }
}
# Always remove the clear-text staging dir: encrypted into the archive, or intentionally dropped.
if (Test-Path $stageRoot) { Remove-Item -LiteralPath $stageRoot -Recurse -Force -ErrorAction SilentlyContinue }

# -----------------------------------------------------------------------
# EXPORT CSV
# -----------------------------------------------------------------------
$configRows | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8

Write-Host ""
Write-Host "Settings extracted to: $OutputPath" -ForegroundColor Green
Write-Host "Categories: $($configRows.Count) config rows written"
Write-Host ""
# Full per-row dump only with -Verbose; otherwise the per-category counts above suffice.
if ($Script:IsVerbose) {
    $configRows | ForEach-Object { Write-Host "  $($_.Category) / $($_.ConfigKey) = $($_.WindowsValue)" }
}
