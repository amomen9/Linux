<#
.SYNOPSIS
    Runs all migration detection scripts in the correct order:
      1.  C_detect_windows_settings.ps1    (config)
      2.  B_detect_installed_windows_software.ps1  (software)
      3.  A_detect_installed_drivers.ps1   (driver)

.DESCRIPTION
    Orchestrates the full Windows-to-Linux migration detection pipeline.
    Each individual script writes its own CSV output:
      - C_windows_configs.csv
      - B_installed_windows_software.csv
      - A_installed_windows_drivers.csv

    By default all three run sequentially.  If any script fails the pipeline
    stops immediately unless -ContinueOnError is supplied.

    Common parameters (OutputPath, IncludeSystemComponents, etc.) are exposed
    here and forwarded to the relevant sub-script.  Parameters that only one
    sub-script understands are forwarded only to that script; others are ignored.

.PARAMETER OutputDir
    Directory where all three CSV files will be written.
    Default: the Migrate to Linux folder (same folder as this script).

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

.EXAMPLE
    .\run_all.ps1
    .\run_all.ps1 -IncludeSystemComponents -MustIncludeThreshold 80
    .\run_all.ps1 -ContinueOnError -Online
    .\run_all.ps1 -OutputDir C:\migration_reports -IncludeVirtualDevices
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
    [switch] $IncludeMicrosoftInbox
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
    $OutputDir = $scriptDir
}
# Ensure $OutputDir exists
if (-not (Test-Path $OutputDir -PathType Container)) {
    New-Item -Path $OutputDir -ItemType Directory -Force | Out-Null
}

# Full paths to each sub-script
$scriptConfig   = Join-Path $scriptDir 'C_detect_windows_settings.ps1'
$scriptSoftware = Join-Path $scriptDir 'B_detect_installed_windows_software.ps1'
$scriptDriver   = Join-Path $scriptDir 'A_detect_installed_drivers.ps1'

# ---------------------------------------------------------------------------
# Validate sub-scripts exist
# ---------------------------------------------------------------------------
$missing = @()
if (-not (Test-Path $scriptConfig))   { $missing += "C_detect_windows_settings.ps1" }
if (-not (Test-Path $scriptSoftware)) { $missing += "B_detect_installed_windows_software.ps1" }
if (-not (Test-Path $scriptDriver))   { $missing += "A_detect_installed_drivers.ps1" }
if ($missing.Count -gt 0) {
    Write-Error "Cannot find required sub-scripts in '$scriptDir':`n  $($missing -join "`n  ")"
    exit 1
}

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

    $baseArgs = @{
        FilePath          = $ScriptPath
        ArgumentList      = @("-OutputPath", $OutputPath)
        NoNewWindow       = $true
        Wait              = $true
        PassThru          = $true
        ErrorAction       = if ($ContinueOnError) { 'SilentlyContinue' } else { 'Stop' }
    }

    # Append extra arguments from the caller
    if ($ExtraArgs) {
        $extraList = & $ExtraArgs
        if ($extraList) {
            $baseArgs.ArgumentList += $extraList
        }
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
# 1. CONFIG  — C_detect_windows_settings.ps1
# ---------------------------------------------------------------------------
$configOutput = Join-Path $OutputDir 'C_windows_configs.csv'
Invoke-Step -StepLabel '1/3  Config (Windows settings)' `
            -ScriptPath $scriptConfig `
            -OutputPath $configOutput

# ---------------------------------------------------------------------------
# 2. SOFTWARE  — B_detect_installed_windows_software.ps1
# ---------------------------------------------------------------------------
$softwareOutput = Join-Path $OutputDir 'B_installed_windows_software.csv'
Invoke-Step -StepLabel '2/3  Software (installed applications)' `
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

# ---------------------------------------------------------------------------
# 3. DRIVER  — A_detect_installed_drivers.ps1
# ---------------------------------------------------------------------------
$driverOutput = Join-Path $OutputDir 'A_installed_windows_drivers.csv'
Invoke-Step -StepLabel '3/3  Drivers (device drivers)' `
            -ScriptPath $scriptDriver `
            -OutputPath $driverOutput `
            -ExtraArgs {
                $args = @()
                if ($IncludeVirtualDevices)  { $args += "-IncludeVirtualDevices" }
                if ($IncludeMicrosoftInbox)  { $args += "-IncludeMicrosoftInbox" }
                return $args
            }

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  ALL DONE" -ForegroundColor Green
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Output directory:  $OutputDir" -ForegroundColor White
Write-Host ""
Write-Host "  Generated files:" -ForegroundColor White
Write-Host "    $configOutput" -ForegroundColor Gray
Write-Host "    $softwareOutput" -ForegroundColor Gray
Write-Host "    $driverOutput" -ForegroundColor Gray
Write-Host ""
Write-Host "  Next steps on Linux:" -ForegroundColor Yellow
Write-Host "    1. Copy these CSV files to your Linux machine."
Write-Host "    2. Look at Linux distributions under ./Linux */ for apply scripts."
Write-Host "    3. Run the corresponding install_device_drivers.sh,"
Write-Host "       install_must_have_software.sh, and apply_settings.sh."
Write-Host "================================================================" -ForegroundColor Cyan
