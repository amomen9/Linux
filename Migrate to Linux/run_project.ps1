<#
.SYNOPSIS
    Project orchestrator that runs all detection and generation scripts in order:

      1. C_detect_windows_settings.ps1    (config -- Windows settings extraction)
      2. B_detect_installed_windows_software.ps1  (software -- installed apps)
      3. A_detect_installed_drivers.ps1   (driver -- device driver inventory)
      4. D_compile_and_generate_shell_script.ps1  (generates the universal .sh
                                                    installer set for all distros)

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
    If set, skip steps 1-3 and only run the generator (step 4).  Requires the CSV
    files to already exist.

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
    [switch] $SkipGenerator
)

$ErrorActionPreference = 'Stop'

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
# 1. CONFIG  - C_detect_windows_settings.ps1
# ---------------------------------------------------------------------------
if (-not $SkipDetection) {
    $configOutput = Join-Path $OutputDir 'C_windows_configs.csv'
    Invoke-Step -StepLabel '1/4  Config (Windows settings extraction)' `
                -ScriptPath $scriptConfig `
                -OutputPath $configOutput

    # -----------------------------------------------------------------------
    # 2. SOFTWARE  - B_detect_installed_windows_software.ps1
    # -----------------------------------------------------------------------
    $softwareOutput = Join-Path $OutputDir 'B_installed_windows_software.csv'
    Invoke-Step -StepLabel '2/4  Software (installed applications detection)' `
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
    Invoke-Step -StepLabel '3/4  Drivers (device driver inventory)' `
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
    Write-Host "  STEP: 4/4  Generator (universal installer set)" -ForegroundColor Yellow
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
Write-Host ""
Write-Host "  Next steps on Linux:" -ForegroundColor Yellow
Write-Host "    1. Copy the 'Execute on Linux!' folder to your Linux machine."
Write-Host "    2. cd into 'Execute on Linux!'."
Write-Host "    3. Run:  sudo ./execute_all.sh"
Write-Host "================================================================" -ForegroundColor Cyan
