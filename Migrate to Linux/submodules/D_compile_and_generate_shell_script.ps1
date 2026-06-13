<#
.SYNOPSIS
    Generates the universal "Execute on Linux!" installer scripts from the
    enriched manifest (B_applications.json) and the detection CSVs.

.DESCRIPTION
    Reads the install data and inlines the runtime engine (submodules/templates/
    _common.sh) into four templates, producing four STANDALONE shell scripts that
    detect the Linux distribution family (apt/dnf/zypper/pacman) and CPU arch at
    runtime and install everything Flatpak-first with native fallbacks:

      execute_all.sh                 - orchestrator
      install_device_drivers.sh      - firmware / GPU / printing + device report
      install_must_have_software.sh  - the application install list
      apply_settings.sh              - Windows settings -> Linux desktop

    All output is written with LF newlines and no BOM so it runs on Linux as-is.

.PARAMETER OutputDir
    Destination folder for the generated scripts.  Default: the "Execute on Linux!"
    folder at the project root (parent of submodules/).

.PARAMETER ManifestPath / AdditionalCsv / ConfigCsv / DriverCsv
    Input data files.  Defaults resolve to documents/ and the project root.
#>
[CmdletBinding()]
param(
    [string] $OutputDir,
    [string] $ManifestPath,
    [string] $AdditionalCsv,
    [string] $ConfigCsv,
    [string] $DriverCsv
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Resolve paths
# ---------------------------------------------------------------------------
$scriptDir = $PSScriptRoot
if (-not $scriptDir) { $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
$projRoot     = Split-Path -Parent $scriptDir
$templatesDir = Join-Path $scriptDir 'templates'
$documentsDir = Join-Path $projRoot 'documents'

if (-not $OutputDir)     { $OutputDir     = Join-Path $projRoot 'Execute on Linux!' }
if (-not $ManifestPath)  { $ManifestPath  = Join-Path $documentsDir 'B_applications.json' }
if (-not $AdditionalCsv) { $AdditionalCsv = Join-Path $projRoot 'Additional_Manual_Linux_Software_Requirments.csv' }
if (-not $ConfigCsv)     { $ConfigCsv     = Join-Path $documentsDir 'C_windows_configs.csv' }
if (-not $DriverCsv)     { $DriverCsv     = Join-Path $documentsDir 'A_installed_windows_drivers.csv' }

$commonPath = Join-Path $templatesDir '_common.sh'
foreach ($p in @($templatesDir, $commonPath, $ManifestPath)) {
    if (-not (Test-Path $p)) { Write-Error "Required input not found: $p"; exit 1 }
}
if (-not (Test-Path $OutputDir -PathType Container)) {
    New-Item -Path $OutputDir -ItemType Directory -Force | Out-Null
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Get-Prop {
    param($Object, [string] $Name)
    if ($null -eq $Object) { return $null }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

# Escape a value for embedding inside a bash double-quoted string.
function ConvertTo-BashString {
    param([string] $Value)
    if ($null -eq $Value) { return '' }
    $s = $Value.Replace("`r", ' ').Replace("`n", ' ')
    $s = $s.Replace('\', '\\').Replace('"', '\"').Replace('$', '\$').Replace('`', '\`')
    return $s
}

# Append `<flag> "<escaped value>"` to the list, skipping null/empty values.
function Add-Flag {
    param([System.Collections.Generic.List[string]] $List, [string] $Flag, $Value, [switch] $Bare)
    if ($null -eq $Value) { return }
    $s = [string] $Value
    if ($s -eq '') { return }
    if ($Bare) { $List.Add($Flag + ' ' + $s) }
    else       { $List.Add($Flag + ' "' + (ConvertTo-BashString $s) + '"') }
}

# Build one `install_app ...` line from an install descriptor object + name.
function New-InstallCall {
    param([string] $Name, $Install)
    $parts = New-Object System.Collections.Generic.List[string]
    $parts.Add('install_app')
    Add-Flag $parts '--name' $Name

    $method = Get-Prop $Install 'method'
    if (-not $method) { $method = 'manual' }
    Add-Flag $parts '--method' $method -Bare

    Add-Flag $parts '--flatpak' (Get-Prop $Install 'flatpakId')
    Add-Flag $parts '--snap'    (Get-Prop $Install 'snap')

    $native = Get-Prop $Install 'native'
    if ($native) {
        foreach ($fam in 'apt','dnf','zypper','pacman') {
            Add-Flag $parts ('--' + $fam) (Get-Prop $native $fam)
        }
    }

    $arch = Get-Prop $Install 'arch'
    if ($arch) { Add-Flag $parts '--arch' (($arch) -join ' ') }

    $dl = Get-Prop $Install 'downloadUrl'
    if ($dl) {
        Add-Flag $parts '--url-x86' (Get-Prop $dl 'x86_64')
        Add-Flag $parts '--url-arm' (Get-Prop $dl 'aarch64')
    }

    Add-Flag $parts '--webapp' (Get-Prop $Install 'webappUrl')
    Add-Flag $parts '--docker' (Get-Prop $Install 'dockerImage')
    Add-Flag $parts '--github' (Get-Prop $Install 'githubRepo')
    Add-Flag $parts '--note'   (Get-Prop $Install 'note')

    return ($parts -join ' ')
}

# Map a legacy installMethod to a descriptor when no enriched install{} exists.
function New-FallbackInstall {
    param($Alt)
    $im = [string](Get-Prop $Alt 'installMethod')
    $obj = [ordered]@{}
    switch -Regex ($im) {
        '^flatpak$' { $obj['method'] = 'flatpak' }
        '^snap$'    { $obj['method'] = 'snap' }
        '^web$'     { $obj['method'] = 'webapp'; $obj['webappUrl'] = [string](Get-Prop $Alt 'downloadUrl') }
        '^docker$'  { $obj['method'] = 'docker' }
        '^apt$'     { $obj['method'] = 'native' }   # native pkg name unknown until enriched
        default     { $obj['method'] = 'manual' }
    }
    $note = 'needs manifest enrichment'
    $url = [string](Get-Prop $Alt 'downloadUrl')
    if ($url) { $note = "$note - see $url" }
    $obj['note'] = $note
    return [pscustomobject]$obj
}

# ---------------------------------------------------------------------------
# 1. APPLICATION LIST  (from B_applications.json + Additional CSV)
# ---------------------------------------------------------------------------
Write-Host "Reading manifest: $ManifestPath" -ForegroundColor Gray
$manifest = Get-Content -Raw -Path $ManifestPath | ConvertFrom-Json
$apps = $manifest.applications

$appLines = New-Object System.Collections.Generic.List[string]
$emittedNames = New-Object System.Collections.Generic.HashSet[string]
$enriched = 0; $fallback = 0

foreach ($app in $apps) {
    $best = $null; $bestScore = -1
    foreach ($alt in (Get-Prop $app 'alternatives')) {
        if ([string](Get-Prop $alt 'mustInclude') -match '^(?i)yes$') {
            $c = 0.0; [double]::TryParse(((''+(Get-Prop $alt 'competency')) -replace '[^0-9.]',''), [ref]$c) | Out-Null
            if ($c -gt $bestScore) { $bestScore = $c; $best = $alt }
        }
    }
    if (-not $best) { continue }

    $name = [string](Get-Prop $app 'name')
    $install = Get-Prop $best 'install'
    if ($install) { $enriched++ } else { $install = New-FallbackInstall $best; $fallback++ }

    $appLines.Add(('  ' + (New-InstallCall -Name $name -Install $install)))
    [void]$emittedNames.Add($name.ToLowerInvariant())
}

# Additional hand-curated CSV (free-text) -> manual entries, de-duped by name.
if (Test-Path $AdditionalCsv) {
    Write-Host "Reading additional CSV: $AdditionalCsv" -ForegroundColor Gray
    foreach ($row in (Import-Csv -Path $AdditionalCsv)) {
        $name = [string]$row.Name
        if (-not $name) { continue }
        if ($emittedNames.Contains($name.ToLowerInvariant())) { continue }
        $pkgs = [string]$row.'Linux Package(s)'
        $src  = [string]$row.'Source / URL'
        $url  = [string]$row.'Download URL'
        $note = (@($pkgs, $src) | Where-Object { $_ }) -join ' | '
        $inst = [pscustomobject]@{ method = 'manual'; note = $note }
        if ($url) { $inst | Add-Member -NotePropertyName downloadUrl -NotePropertyValue ([pscustomobject]@{ x86_64 = $url }) }
        $appLines.Add(('  ' + (New-InstallCall -Name $name -Install $inst)))
        [void]$emittedNames.Add($name.ToLowerInvariant())
    }
}

$appsData = ($appLines -join "`n")
Write-Host ("  apps: {0} total ({1} enriched, {2} fallback)" -f $appLines.Count, $enriched, $fallback) -ForegroundColor Green

# ---------------------------------------------------------------------------
# 2. SETTINGS  (from C_windows_configs.csv)
# ---------------------------------------------------------------------------
$cfgMap = @{
    'scaling'             = 'CFG_scaling'
    'lock_screen_timeout' = 'CFG_lock_timeout'
    'layout'              = 'CFG_keyboard_layout'
    'telemetry_level'     = 'CFG_telemetry'
    'location_service'    = 'CFG_location'
}
$settingsLines = New-Object System.Collections.Generic.List[string]
if (Test-Path $ConfigCsv) {
    foreach ($row in (Import-Csv -Path $ConfigCsv)) {
        $key = [string]$row.ConfigKey
        if ($cfgMap.ContainsKey($key)) {
            $settingsLines.Add($cfgMap[$key] + '="' + (ConvertTo-BashString ([string]$row.WindowsValue)) + '"')
        }
    }
}
if ($settingsLines.Count -eq 0) { $settingsLines.Add('# (no mappable settings found in C_windows_configs.csv)') }
$settingsData = ($settingsLines -join "`n")

# ---------------------------------------------------------------------------
# 3. DRIVERS  (from A_installed_windows_drivers.csv) - reference list
# ---------------------------------------------------------------------------
$driverLines = New-Object System.Collections.Generic.List[string]
$covered = 0
if (Test-Path $DriverCsv) {
    foreach ($row in (Import-Csv -Path $DriverCsv)) {
        $dev = [string]$row.'Device Name'
        $cls = [string]$row.'Device Class'
        $st  = [string]$row.'Linux Driver Status'
        $must = [string]$row.'Must install on Linux'
        if (($must -match '^(?i)\s*yes') -or ($st -notmatch 'In-Kernel')) {
            $driverLines.Add('  info "' + (ConvertTo-BashString $dev.Trim()) + ' [' + (ConvertTo-BashString $cls) + '] -> ' + (ConvertTo-BashString $st) + '"')
        } else { $covered++ }
    }
}
if ($driverLines.Count -eq 0) { $driverLines.Add('  info "All detected devices are covered by the in-kernel/generic drivers."') }
else { $driverLines.Add('  info "(' + $covered + ' additional devices are covered by in-kernel/generic drivers.)"') }
$driversData = ($driverLines -join "`n")

# ---------------------------------------------------------------------------
# 4. RENDER TEMPLATES -> standalone LF scripts
# ---------------------------------------------------------------------------
$common = (Get-Content -Raw -Path $commonPath)
# Drop the engine's own shebang line; each output script has its own.
$common = ($common -replace '^\#\![^\r\n]*\r?\n', '')

$enc = New-Object System.Text.UTF8Encoding($false)
$map = @{
    'install_must_have_software.sh.tmpl' = @{ apps = $appsData }
    'apply_settings.sh.tmpl'             = @{ settings = $settingsData }
    'install_device_drivers.sh.tmpl'     = @{ drivers = $driversData }
    'execute_all.sh.tmpl'                = @{}
}

foreach ($tmplName in $map.Keys) {
    $tmplPath = Join-Path $templatesDir $tmplName
    if (-not (Test-Path $tmplPath)) { Write-Error "Missing template: $tmplPath"; exit 1 }
    $content = Get-Content -Raw -Path $tmplPath

    $content = $content.Replace('### __COMMON__ ###', $common)
    if ($map[$tmplName].ContainsKey('apps'))     { $content = $content.Replace('### __APPS_DATA__ ###', $map[$tmplName].apps) }
    if ($map[$tmplName].ContainsKey('settings')) { $content = $content.Replace('### __SETTINGS_DATA__ ###', $map[$tmplName].settings) }
    if ($map[$tmplName].ContainsKey('drivers'))  { $content = $content.Replace('### __DRIVERS_DATA__ ###', $map[$tmplName].drivers) }

    # Normalize to LF, no trailing CR, no BOM.
    $content = $content -replace "`r`n", "`n" -replace "`r", "`n"
    $outName = $tmplName -replace '\.tmpl$', ''
    $outPath = Join-Path $OutputDir $outName
    [System.IO.File]::WriteAllText($outPath, $content, $enc)
    Write-Host "  generated: $outName" -ForegroundColor Green
}

Write-Host "`nDone. Universal installer written to: $OutputDir" -ForegroundColor Cyan
