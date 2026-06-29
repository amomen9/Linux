<#
.SYNOPSIS
    Project orchestrator that runs all detection and generation scripts in order:

      1. C_detect_windows_settings.ps1    (config -- Windows settings extraction)
      2. B_detect_installed_windows_software.ps1  (software -- installed apps)
      3. A_detect_installed_drivers.ps1   (driver -- device driver inventory)
      4. D_compile_and_generate_shell_script.ps1  (generates the universal .sh
                                                    installer set for all distros)
      5. Generate Supported Distributions.txt from the manifest (dynamic)

.DESCRIPTION
    Orchestrates the full Windows-to-Linux migration detection pipeline in one shot.

    Steps 1-3 (Windows) run the three detection scripts and write their CSV output
    to "Migrate to Linux/documents/".  Step 4 (Generator) reads those CSV files
    together with documents/B_applications.json and the root-level
    Additional_Manual_Linux_Software_Requirments.csv, then generates ONE universal
    shell-installer set (execute_all.sh, apply_settings.sh,
    install_must_have_software.sh, install_device_drivers.sh) into the
    "Execute on Linux!" folder.  The generated scripts detect the Linux distro
    family (apt/dnf/zypper/pacman) and CPU architecture at runtime, so the same set
    runs on every supported distribution.

    Step 5 reads the manifest (B_applications.json) and dynamically generates
    Supported Distributions.txt, reflecting exactly which package-manager families
    have native entries and how complete that coverage is.

    If any detection script fails the pipeline stops immediately unless
    -ContinueOnError is supplied.

.PARAMETER OutputDir
    Directory where all three CSV files will be written.
    Default: the "documents" subfolder of the Migrate to Linux folder.

.PARAMETER ContinueOnError
    If set, the pipeline continues with the next script even when one fails.
    Default: stop on first failure.

.PARAMETER MustIncludeThreshold
    Minimum Alternative Competency (%) for "Must be included on Linux" = yes in
    the software report.  Forwarded to B_detect_installed_windows_software.ps1.
    Default: 70.

.PARAMETER IncludeSystemComponents
    If set, redistributables, runtimes and drivers are included in the software
    report.  Forwarded to B_detect_installed_windows_software.ps1.

.PARAMETER IncludeStoreApps
    Whether to include Microsoft Store / UWP apps in the software report.
    Forwarded to B_detect_installed_windows_software.ps1.  Default: $true.

.PARAMETER Online
    If set, B_detect_installed_windows_software.ps1 queries repology.org live
    for apps not in the local manifest.  Forwarded to that script.

.PARAMETER IncludeVirtualDevices
    If set, A_detect_installed_drivers.ps1 keeps ROOT\ and SW\ virtual devices.
    Forwarded to that script.

.PARAMETER IncludeMicrosoftInbox
    If set, A_detect_installed_drivers.ps1 keeps generic Microsoft in-box drivers
    for standard devices.  Forwarded to that script.

.PARAMETER SkipDetection
    If set, skip steps 1-3 and only run the generator (step 4).
    Requires the CSV files to already exist.

.PARAMETER SkipGenerator
    If set, skip the generator step (step 4) and only run detection (steps 1-3).

.EXAMPLE
    .\run_project.ps1
    .\run_project.ps1 -IncludeSystemComponents -MustIncludeThreshold 80
    .\run_project.ps1 -ContinueOnError -Online
    .\run_project.ps1 -SkipDetection   # regenerate scripts from existing CSVs
#>

[CmdletBinding()]
param(
    [string] $OutputDir,

    [switch] $ContinueOnError,

    # ---- B (software) parameters ----
    [int]    $MustIncludeThreshold = 70,
    [switch] $IncludeSystemComponents,
    [bool]   $IncludeStoreApps = $true,
    [switch] $Online,

    # ---- A (driver) parameters ----
    [switch] $IncludeVirtualDevices,
    [switch] $IncludeMicrosoftInbox,

    # ---- Orchestration ----
    [switch] $SkipDetection,
    [switch] $SkipGenerator,

    # Encryption password for the exported sensitive data (WiFi/SSH/Contacts/wallpaper).
    # When supplied, the interactive transfer-password prompt is skipped. Usable as
    # -EncPwd "secret", -enc_pwd "secret", or the literal --enc_pwd / --enc_pwd=secret.
    [Alias('enc_pwd')]
    [string] $EncPwd,

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]] $ExtraArgs
)

# Accept the literal "--enc_pwd SECRET" / "--enc_pwd=SECRET" form (mirrors the .sh --dec_pwd).
if (-not $EncPwd -and $ExtraArgs) {
    for ($i = 0; $i -lt $ExtraArgs.Count; $i++) {
        $a = [string]$ExtraArgs[$i]
        if ($a -like '--enc_pwd=*') { $EncPwd = $a.Substring(10) }
        elseif ($a -eq '--enc_pwd' -and ($i + 1) -lt $ExtraArgs.Count) { $EncPwd = [string]$ExtraArgs[$i + 1]; $i++ }
    }
}

$ErrorActionPreference = 'Stop'

# Forward -Verbose to the detection step ONLY when it was explicitly passed to this
# script (not when merely inherited from the session's $VerbosePreference).
$forwardVerbose = $PSBoundParameters.ContainsKey('Verbose')

# ---------------------------------------------------------------------------
# Resolve paths
# ---------------------------------------------------------------------------
$scriptDir = $PSScriptRoot
if (-not $scriptDir -and $PSCommandPath) {
    $scriptDir = Split-Path -Parent $PSCommandPath
}
if (-not $scriptDir -and $MyInvocation.MyCommand.Path) {
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
}
if (-not $scriptDir) {
    $scriptDir = (Get-Location).Path
}
if (-not $OutputDir) {
    # All generated CSVs and the B_applications.json manifest live in documents/.
    $OutputDir = Join-Path $scriptDir 'documents'
}
# Ensure $OutputDir exists
if (-not (Test-Path $OutputDir -PathType Container)) {
    New-Item -Path $OutputDir -ItemType Directory -Force | Out-Null
}

# Full paths to sub-scripts (in submodules/)
$submodulesDir = Join-Path $scriptDir 'submodules'
$scriptConfig   = Join-Path $submodulesDir 'C_detect_windows_settings.ps1'
$scriptSoftware = Join-Path $submodulesDir 'B_detect_installed_windows_software.ps1'
$scriptDriver   = Join-Path $submodulesDir 'A_detect_installed_drivers.ps1'
$scriptGenerator = Join-Path $submodulesDir 'D_compile_and_generate_shell_script.ps1'

# Path to the manifest
$manifestPath = Join-Path $OutputDir 'B_applications.json'

# PowerShell host executable used to launch the sub-scripts in a child process.
# Start-Process cannot run a .ps1 directly: with -NoNewWindow it calls CreateProcess
# on the script file, which fails with "%1 is not a valid Win32 application".
# So every step is launched as:
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File <script> ...
$psExe = (Get-Process -Id $PID).Path
if (-not $psExe) {
    $psExe = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' }
}

# Build a single, properly-quoted argument string. Start-Process's array
# -ArgumentList does NOT quote tokens that contain spaces in Windows PowerShell 5.1,
# which would break paths like "Migrate to Linux".
function Get-ArgLine {
    param([object[]] $Tokens)
    ($Tokens | ForEach-Object {
        $s = [string] $_
        if ($s -match '\s') { '"' + $s + '"' } else { $s }
    }) -join ' '
}

# ===========================================================================
# FUNCTION: Write-SupportedDistributions
# ---------------------------------------------------------------------------
# Reads B_applications.json and dynamically generates Supported Distributions.txt
# based on which package-manager families actually have native entries in the
# manifest.
# ===========================================================================
function Write-SupportedDistributions {
    param(
        [string] $ManifestPath,
        [string] $OutputPath
    )

    if (-not (Test-Path $ManifestPath)) {
        Write-Warning "Manifest not found at '$ManifestPath'.  Skipping Supported Distributions generation."
        return
    }

    Write-Host "  Scanning manifest for per-distro entries..." -ForegroundColor Gray

    # ---- Family metadata ----
    $familyDefs = @{
        'apt' = [ordered]@{
            Name      = 'Debian / Ubuntu'
            PM        = 'apt (apt-get)'
            Distros   = @('Linux Mint (Ubuntu)', 'Ubuntu', 'Debian', 'Zorin OS', 'Kubuntu', 'Winux 11')
            Auto      = 'Pop!_OS, elementary OS, and other Ubuntu/Debian derivatives.'
            Note      = $null
        }
        'dnf' = [ordered]@{
            Name      = 'RHEL / Fedora'
            PM        = 'dnf'
            Distros   = @('Fedora', 'Rocky Linux', 'Red Hat Enterprise Linux (RHEL)', 'Oracle Linux')
            Auto      = 'AlmaLinux, CentOS Stream.'
            Note      = 'RHEL rebuilds may need EPEL enabled for a few packages.'
        }
        'zypper' = [ordered]@{
            Name      = 'openSUSE / SUSE'
            PM        = 'zypper'
            Distros   = @('openSUSE (Leap / Tumbleweed)')
            Auto      = 'SLE (SLES / SLED).'
            Note      = $null
        }
        'pacman' = [ordered]@{
            Name      = 'Arch'
            PM        = 'pacman'
            Distros   = @('Arch Linux')
            Auto      = 'Manjaro, EndeavourOS.'
            Note      = $null
        }
    }

    # ---- Scan manifest ----
    $manifest = Get-Content -Raw -Path $ManifestPath | ConvertFrom-Json
    $apps = $manifest.applications

    $pmCounts = @{ apt = 0; dnf = 0; zypper = 0; pacman = 0 }
    $pmReviewCounts = @{ apt = 0; dnf = 0; zypper = 0; pacman = 0 }
    $totalMustInclude = 0
    $flatpakCount = 0
    $hasArchConstraint = $false
    $archSet = @{}

    foreach ($app in $apps) {
        $name = [string]$app.name
        foreach ($alt in $app.alternatives) {
            $must = [string]$alt.mustInclude
            if ($must -notmatch '^(?i)\s*yes') { continue }

            $totalMustInclude++
            $install = $alt.install
            if (-not $install) { continue }

            # Native package manager entries
            $native = $install.native
            if ($native) {
                foreach ($prop in $native.PSObject.Properties) {
                    $pm = $prop.Name
                    if ($pmCounts.ContainsKey($pm) -and [string]$prop.Value) {
                        $pmCounts[$pm]++
                        if ($install.review -eq $true) { $pmReviewCounts[$pm]++ }
                    }
                }
            }

            # Flatpak (distro-agnostic)
            if ($install.flatpakId) { $flatpakCount++ }

            # Architecture constraints
            $archField = $install.arch
            if ($archField) {
                $hasArchConstraint = $true
                foreach ($a in $archField) { $archSet[$a] = $true }
            }
        }
    }

    # ---- Which families are truly supported ----
    $hasFamily = @{}
    foreach ($pm in $pmCounts.Keys) { $hasFamily[$pm] = ($pmCounts[$pm] -gt 0) }
    $noneHaveEntries = ($hasFamily.Values -notcontains $true)

    # ---- Assemble output ----
    $lines = New-Object System.Collections.Generic.List[string]

    $lines.Add('============================================================================')
    $lines.Add('  SUPPORTED LINUX DISTRIBUTIONS')
    $lines.Add(('  (Auto-generated from manifest: {0:yyyy-MM-dd HH:mm})' -f (Get-Date)))
    $lines.Add('============================================================================')
    $lines.Add('')
    $lines.Add('This file is generated by run_project.ps1 by scanning the per-distro install')
    $lines.Add('descriptors in documents/B_applications.json.  Only families with at least')
    $lines.Add('one app providing a native package name are listed as "supported."')
    $lines.Add('')
    $lines.Add('The generated installer in "Execute on Linux!/" is UNIVERSAL: it detects the')
    $lines.Add('running distribution FAMILY and CPU ARCHITECTURE at runtime and dispatches to')
    $lines.Add('the correct package manager.  Distributions are grouped by their parent family,')
    $lines.Add('so adding a derivative (e.g. Pop!_OS, AlmaLinux, Manjaro) needs no new code --')
    $lines.Add('it is matched automatically via /etc/os-release ID_LIKE.')
    $lines.Add('')
    $lines.Add('Application delivery is FLATPAK-FIRST (Flathub app ids are identical on every')
    $lines.Add('distro and every architecture).  The native package manager is used only for')
    $lines.Add('the base layer: installing Flatpak itself, CLI/developer tools, drivers and')
    $lines.Add('system components.')
    $lines.Add('')
    $lines.Add('----------------------------------------------------------------------------')
    $lines.Add('  FAMILY            PACKAGE MANAGER   NATIVE APPS IN MANIFEST')
    $lines.Add('----------------------------------------------------------------------------')
    $lines.Add('')

    $hasAny = $false
    foreach ($pm in @('apt', 'dnf', 'zypper', 'pacman')) {
        $def = $familyDefs[$pm]
        $count = $pmCounts[$pm]
        $r = $pmReviewCounts[$pm]
        $hasAny = $hasAny -or ($count -gt 0)

        if ($count -gt 0) {
            $lines.Add(('  [ {0} ] {1,-22} {2} app(s)' -f $def.Name, $def.PM, $count))
            if ($r -gt 0) {
                $lines.Add(('    * {0} app(s) flagged for review on this family' -f $r))
            }
        } else {
            $lines.Add(('  [ {0} ] {1,-22} (no native entries)' -f $def.Name, $def.PM))
        }
        foreach ($distro in $def.Distros) {
            $lines.Add("      - $distro")
        }
        if ($def.Auto) { $lines.Add("    Also auto-detected: $($def.Auto)") }
        if ($def.Note) { $lines.Add("    Note: $($def.Note)") }
        $lines.Add('')
    }

    if (-not $hasAny) {
        $lines.Add('  NOTE: The manifest contains no native package-manager entries for any')
        $lines.Add('  family.  All installs will use Flatpak, web-apps, or manual methods.')
        $lines.Add('  See documents/B_applications.json and add install{} descriptors to')
        $lines.Add('  enable native package manager support.')
        $lines.Add('')
    }

    $lines.Add('----------------------------------------------------------------------------')
    $lines.Add('  CPU ARCHITECTURES')
    $lines.Add('----------------------------------------------------------------------------')
    $lines.Add('')

    $lines.Add('  x86_64  (amd64)   - fully supported')
    $lines.Add('  aarch64 (arm64)   - supported; Flatpak/Flathub and native repos serve the')
    $lines.Add('                      matching build automatically')

    if ($archSet.Count -gt 0) {
        $explicitArchs = @($archSet.Keys)
        $lines.Add(('  ARCHITECTURE CONSTRAINT: {0} app(s) explicitly constrain to: {1}' -f $explicitArchs.Count, ($explicitArchs -join ', ')))
    }
    if ($archSet.Count -eq 0 -or -not $archSet.ContainsKey('aarch64')) {
        $lines.Add('  Windows-app compatibility (Wine via Bottles) is x86_64-only and is skipped')
        $lines.Add('  on ARM with a message.')
    }
    $lines.Add('')
    $lines.Add('  Notes:')
    $lines.Add('    - Flatpak and native package installs are architecture-transparent.')
    $lines.Add('    - Only direct downloads (.deb/.rpm/AppImage/GitHub-release assets) need an')
    $lines.Add('      architecture-specific URL; the installer picks it from `uname -m`.')
    $lines.Add('    - Windows-app compatibility (Wine via Bottles) is x86_64-only and is skipped')
    $lines.Add('      on ARM with a message.')
    $lines.Add('')
    $lines.Add('----------------------------------------------------------------------------')
    $lines.Add('  COVERAGE NOTES')
    $lines.Add('----------------------------------------------------------------------------')
    $lines.Add('')

    $lines.Add(('  Of {0:N0} "must-include" applications in the manifest:' -f $totalMustInclude))
    $lines.Add(('    - {0,4} have apt entries' -f $pmCounts['apt']))
    $lines.Add(('    - {0,4} have dnf entries' -f $pmCounts['dnf']))
    $lines.Add(('    - {0,4} have zypper entries' -f $pmCounts['zypper']))
    $lines.Add(('    - {0,4} have pacman entries' -f $pmCounts['pacman']))
    if ($flatpakCount -gt 0) {
        $lines.Add(('    - {0,4} have Flatpak IDs (distro-agnostic)' -f $flatpakCount))
    }
    $lines.Add('')

    # Determine the best-covered family
    $sorted = $pmCounts.GetEnumerator() | Where-Object { $_.Value -gt 0 } | Sort-Object Value -Descending
    if ($sorted) {
        $bestPM = $sorted | Select-Object -First 1
        $bestName = $familyDefs[$bestPM.Key].Name
        $lines.Add("  The $bestName ($($bestPM.Key)) path has the most native entries and is the")
        $lines.Add('  most heavily tested.  Native package names for the other families are')
        $lines.Add('  best-effort based on what has been curated in the manifest.  Entries')
        $lines.Add("  flagged with 'review: true' need verification on a real system of that")
        $lines.Add('  family.')
    } else {
        $lines.Add('  No family has native package manager entries in the manifest.  Review')
        $lines.Add('  documents/B_applications.json and add install{} descriptors to enable')
        $lines.Add('  native package support.')
    }
    $lines.Add('')
    $lines.Add('============================================================================')

    # Write with LF (Unix-compatible) - new Windows PowerShell (7+) defaults to BOM-less UTF-8
    $content = ($lines -join "`r`n")
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($OutputPath, $content, $enc)

    Write-Host ('  Families with entries: {0}' -f (@($pmCounts.Keys | Where-Object { $pmCounts[$_] -gt 0 }) -join ', ')) -ForegroundColor White
}

# ---------------------------------------------------------------------------
# Validate sub-scripts exist
# ---------------------------------------------------------------------------
$missing = @()
if (-not (Test-Path $scriptConfig))   { $missing += "submodules\C_detect_windows_settings.ps1" }
if (-not (Test-Path $scriptSoftware)) { $missing += "submodules\B_detect_installed_windows_software.ps1" }
if (-not (Test-Path $scriptDriver))   { $missing += "submodules\A_detect_installed_drivers.ps1" }
if (-not (Test-Path $scriptGenerator)) { $missing += "submodules\D_compile_and_generate_shell_script.ps1" }
if ($missing.Count -gt 0) {
    Write-Error "Cannot find required sub-scripts in '$submodulesDir':`n  $($missing -join "`n  ")"
    exit 1
}

# ---------------------------------------------------------------------------
# Output folder for the generated universal installer scripts
# ---------------------------------------------------------------------------
$installerDir = Join-Path $scriptDir 'Execute on Linux!'

# ---------------------------------------------------------------------------
# Runner helper
# ---------------------------------------------------------------------------
function Invoke-Step {
    param(
        [string] $StepLabel,
        [string] $ScriptPath,
        [string] $OutputPath,
        [scriptblock] $ExtraArgs
    )
    $border = '=' * 70
    Write-Host "`n$border" -ForegroundColor Cyan
    Write-Host "  STEP: $StepLabel" -ForegroundColor Yellow
    Write-Host "  Script: $ScriptPath" -ForegroundColor Gray
    Write-Host "$border" -ForegroundColor Cyan
    Write-Host ""

    $childTokens = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath, '-OutputPath', $OutputPath)

    # Append extra arguments from the caller
    if ($ExtraArgs) {
        $extraList = & $ExtraArgs
        if ($extraList) {
            $childTokens += $extraList
        }
    }

    $baseArgs = @{
        FilePath          = $psExe
        ArgumentList      = (Get-ArgLine $childTokens)
        NoNewWindow       = $true
        Wait              = $true
        PassThru          = $true
        ErrorAction       = if ($ContinueOnError) { 'SilentlyContinue' } else { 'Stop' }
    }

    try {
        $proc = Start-Process @baseArgs
        if ($proc.ExitCode -ne 0) {
            $msg = "Step '$StepLabel' exited with code $($proc.ExitCode)."
            if ($ContinueOnError) {
                Write-Warning $msg
            } else {
                throw $msg
            }
        } else {
            Write-Host "  >> Step '$StepLabel' completed successfully." -ForegroundColor Green
        }
    }
    catch {
        Write-Host "  >> Step '$StepLabel' FAILED: $_" -ForegroundColor Red
        if (-not $ContinueOnError) {
            throw
        }
    }
}

# ---------------------------------------------------------------------------
# MEGA-TITLE + transfer-password prompt -- shown FIRST, before any "STEP n/5"
# section banner. run_project owns the prompt so it precedes every section title;
# the answer is handed to step 1 (C_detect) via $env:MIGRATE_XFER_PWD.
# ---------------------------------------------------------------------------
$xferPromptShared = Join-Path $submodulesDir '_xfer_password.ps1'
$xferPwd = ''
if (Test-Path $xferPromptShared) {
    . $xferPromptShared
    Show-MegaTitle
    if ($EncPwd) { $xferPwd = $EncPwd }                                  # supplied on cmd line: no prompt
    elseif (-not $SkipDetection) { $xferPwd = Get-XferPassword -TimeoutSec 15 }
} elseif ($EncPwd) {
    $xferPwd = $EncPwd
}

# ---------------------------------------------------------------------------
# 1. CONFIG  - C_detect_windows_settings.ps1
# ---------------------------------------------------------------------------
if (-not $SkipDetection) {
    $configOutput = Join-Path $OutputDir 'C_windows_configs.csv'
    # Hand the already-entered password to C_detect for this step only, then clear it
    # so the later steps (B/A/D) don't inherit it in their environment.
    $env:MIGRATE_XFER_PROMPTED = '1'
    $env:MIGRATE_XFER_PWD = $xferPwd
    Invoke-Step -StepLabel '1/5  Config (Windows settings extraction)' `
                -ScriptPath $scriptConfig `
                -OutputPath $configOutput `
                -ExtraArgs { if ($forwardVerbose) { '-Verbose' } }
    Remove-Item Env:\MIGRATE_XFER_PWD -ErrorAction SilentlyContinue
    Remove-Item Env:\MIGRATE_XFER_PROMPTED -ErrorAction SilentlyContinue

    # -----------------------------------------------------------------------
    # 2. SOFTWARE  - B_detect_installed_windows_software.ps1
    # -----------------------------------------------------------------------
    $softwareOutput = Join-Path $OutputDir 'B_installed_windows_software.csv'
    Invoke-Step -StepLabel '2/5  Software (installed applications detection)' `
                -ScriptPath $scriptSoftware `
                -OutputPath $softwareOutput `
                -ExtraArgs {
                    $args = @(
                        "-MustIncludeThreshold", $MustIncludeThreshold
                    )
                    if ($IncludeSystemComponents) { $args += "-IncludeSystemComponents" }
                    if (-not $IncludeStoreApps)    { $args += "-IncludeStoreApps:`$false" }
                    if ($Online)                   { $args += "-Online" }
                    return $args
                }

    # -----------------------------------------------------------------------
    # 3. DRIVER  - A_detect_installed_drivers.ps1
    # -----------------------------------------------------------------------
    $driverOutput = Join-Path $OutputDir 'A_installed_windows_drivers.csv'
    Invoke-Step -StepLabel '3/5  Drivers (device driver inventory)' `
                -ScriptPath $scriptDriver `
                -OutputPath $driverOutput `
                -ExtraArgs {
                    $args = @()
                    if ($IncludeVirtualDevices)  { $args += "-IncludeVirtualDevices" }
                    if ($IncludeMicrosoftInbox)  { $args += "-IncludeMicrosoftInbox" }
                    return $args
                }
} else {
    Write-Host "`n[Skipping detection steps 1-3]" -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# 4. GENERATOR  - D_compile_and_generate_shell_script.ps1
# ---------------------------------------------------------------------------
if (-not $SkipGenerator) {
    Write-Host "`n$('=' * 70)" -ForegroundColor Cyan
    Write-Host "  STEP: 4/5  Generator (universal installer set)" -ForegroundColor Yellow
    Write-Host "  Script: $scriptGenerator" -ForegroundColor Gray
    Write-Host "  Target: $installerDir" -ForegroundColor Gray
    Write-Host "$('=' * 70)" -ForegroundColor Cyan
    Write-Host ""

    try {
        $genTokens = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $scriptGenerator, '-OutputDir', $installerDir)
        $genProc = Start-Process -FilePath $psExe -ArgumentList (Get-ArgLine $genTokens) -NoNewWindow -Wait -PassThru
        if ($genProc.ExitCode -ne 0) {
            $msg = "Generator exited with code $($genProc.ExitCode)."
            if ($ContinueOnError) {
                Write-Warning $msg
            } else {
                throw $msg
            }
        } else {
            Write-Host "  >> Generator completed successfully." -ForegroundColor Green
        }
    }
    catch {
        Write-Host "  >> Generator FAILED: $_" -ForegroundColor Red
        if (-not $ContinueOnError) {
            throw
        }
    }
} else {
    Write-Host "`n[Skipping generator step 4]" -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# 5. SUPPORTED DISTRIBUTIONS  - generate dynamically from manifest
# ---------------------------------------------------------------------------
Write-Host "`n$('=' * 70)" -ForegroundColor Cyan
Write-Host "  STEP: 5/5  Supported Distributions (dynamic from manifest)" -ForegroundColor Yellow
Write-Host "  Manifest: $manifestPath" -ForegroundColor Gray
Write-Host "$('=' * 70)" -ForegroundColor Cyan
Write-Host ""

$supportedDistPath = Join-Path $scriptDir 'Supported Distributions.txt'

try {
    Write-SupportedDistributions -ManifestPath $manifestPath -OutputPath $supportedDistPath
    Write-Host "  >> Generated: $(Split-Path -Leaf $supportedDistPath)" -ForegroundColor Green
}
catch {
    Write-Host "  >> Supported Distributions generation FAILED: $_" -ForegroundColor Red
    if (-not $ContinueOnError) {
        throw
    }
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  ALL DONE" -ForegroundColor Green
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  CSV output:        $OutputDir" -ForegroundColor White
Write-Host "  Installer scripts: $installerDir" -ForegroundColor White
Write-Host ""
if (-not $SkipDetection) {
    Write-Host "  Generated CSV files:" -ForegroundColor White
    Write-Host "    $OutputDir\C_windows_configs.csv" -ForegroundColor Gray
    Write-Host "    $OutputDir\B_installed_windows_software.csv" -ForegroundColor Gray
    Write-Host "    $OutputDir\A_installed_windows_drivers.csv" -ForegroundColor Gray
}
if (-not $SkipGenerator) {
    Write-Host "  Universal installer (one set, runs on every supported distro):" -ForegroundColor White
    Write-Host "    $installerDir\execute_all.sh" -ForegroundColor Gray
    Write-Host "    $installerDir\apply_settings.sh" -ForegroundColor Gray
    Write-Host "    $installerDir\install_must_have_software.sh" -ForegroundColor Gray
    Write-Host "    $installerDir\install_device_drivers.sh" -ForegroundColor Gray
}
Write-Host "  Supported Distributions:" -ForegroundColor White
Write-Host "    $supportedDistPath" -ForegroundColor Gray
Write-Host ""
Write-Host "  Next steps on Linux:" -ForegroundColor Yellow
Write-Host "    1. Copy the 'Execute on Linux!' folder to your Linux machine."
Write-Host "    2. cd into 'Execute on Linux!'."
Write-Host "    3. Run:  sudo ./execute_all.sh"
Write-Host "================================================================" -ForegroundColor Cyan
