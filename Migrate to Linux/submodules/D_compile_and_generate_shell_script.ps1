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
    param([string] $Name, [string] $Alt, $Install, [string] $WinVer, [switch] $Paid)
    $parts = New-Object System.Collections.Generic.List[string]
    $parts.Add('install_app')
    Add-Flag $parts '--name' $Name
    Add-Flag $parts '--alt' $Alt
    Add-Flag $parts '--winver' $WinVer

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
    if (Get-Prop $Install 'security') { $parts.Add('--security') }
    if ($Paid) { $parts.Add('--paid') }

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

# Filesystem/function-safe slug from an app name (matches bash slugify in _common.sh).
function Get-Slug {
    param([string] $Name)
    $s = $Name.ToLowerInvariant() -replace ' ', '-'
    return ($s -replace '[^a-z0-9\-_]', '')
}

# Build a bash repo_setup_<slug>() function from a manifest install.repo object.
# install_app() runs this (if defined) before a native install, so the vendor's own
# repository is configured first and the latest upstream build is used.
function New-RepoFunc {
    param([string] $Name, $Repo)
    $fn = 'repo_setup_' + ((Get-Slug $Name) -replace '-', '_')
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add($fn + '() {')
    $lines.Add('  case "$PM" in')
    foreach ($fam in 'apt','dnf','zypper','pacman') {
        $sh = [string](Get-Prop $Repo $fam)
        if ($sh) {
            $lines.Add('    ' + $fam + ')')
            foreach ($ln in ($sh -split "`r?`n")) { $lines.Add('      ' + $ln) }
            $lines.Add('      ;;')
        }
    }
    $lines.Add('  esac')
    $lines.Add('}')
    return ($lines -join "`n")
}

# ---------------------------------------------------------------------------
# 1. APPLICATION LIST  (from B_applications.json + Additional CSV)
# ---------------------------------------------------------------------------
Write-Host "Reading manifest: $ManifestPath" -ForegroundColor Gray
$manifest = Get-Content -Raw -Path $ManifestPath | ConvertFrom-Json
$apps = $manifest.applications

$appLines = New-Object System.Collections.Generic.List[string]
$repoLines = New-Object System.Collections.Generic.List[string]
$repoSlugs = New-Object System.Collections.Generic.HashSet[string]
$manualLines = New-Object System.Collections.Generic.List[string]
$emittedNames = New-Object System.Collections.Generic.HashSet[string]
$enriched = 0; $fallback = 0

foreach ($app in $apps) {
    # Collect all mustInclude alternatives, ranked best-first by competency.
    $mustAlts = @()
    foreach ($alt in (Get-Prop $app 'alternatives')) {
        if ([string](Get-Prop $alt 'mustInclude') -match '^(?i)yes$') {
            $c = 0.0; [double]::TryParse(((''+(Get-Prop $alt 'competency')) -replace '[^0-9.]',''), [ref]$c) | Out-Null
            $mustAlts += [pscustomobject]@{ Alt = $alt; Score = $c }
        }
    }
    if ($mustAlts.Count -eq 0) { continue }
    $mustAlts = @($mustAlts | Sort-Object -Property Score -Descending)

    $name = [string](Get-Prop $app 'name')
    $best = $mustAlts[0].Alt
    $bestInstall = Get-Prop $best 'install'

    # Apps that need a user-downloaded file are handled at the END of execute_all.sh
    # (the manual-download phase), NOT in install_must_have_software.sh.
    if ($bestInstall -and (Get-Prop $bestInstall 'promptFile')) {
        $altName = [string](Get-Prop $best 'name')
        $pnote = [string](Get-Prop $bestInstall 'note')
        # Stable, version-less download page (req8): prefer install.downloadPage,
        # then install.downloadUrl.x86_64. Shown to the user and opened in the browser.
        $purl = [string](Get-Prop $bestInstall 'downloadPage')
        if (-not $purl) {
            $dl = Get-Prop $bestInstall 'downloadUrl'
            if ($dl) { $purl = [string](Get-Prop $dl 'x86_64') }
        }
        # MANUAL_APPS entry: "Windows app|Linux alternative|note|download page URL|paid(1/0)"
        $mpaid = if ([string](Get-Prop $best 'pricingModel') -match '(?i)free') { '0' } else { '1' }
        $manualLines.Add('  "' +
            (ConvertTo-BashString $name) + '|' +
            (ConvertTo-BashString ($altName -replace '\|', ' ')) + '|' +
            (ConvertTo-BashString ($pnote   -replace '\|', ' ')) + '|' +
            (ConvertTo-BashString ($purl    -replace '\|', ' ')) + '|' +
            $mpaid + '"')
        [void]$emittedNames.Add($name.ToLowerInvariant())
        continue
    }

    # Vendor repo (req5): emit a repo_setup_<slug>() once per app if the best
    # alternative declares install.repo. install_app runs it before native installs.
    if ($bestInstall) {
        $repo = Get-Prop $bestInstall 'repo'
        if ($repo) {
            $rkey = Get-Slug $name
            if (-not $repoSlugs.Contains($rkey)) {
                $repoLines.Add((New-RepoFunc -Name $name -Repo $repo))
                [void]$repoSlugs.Add($rkey)
            }
        }
    }

    # Windows version for exact native equivalents (req4): pass it so the runtime can
    # honour "same version" when the user picks it. Use the first version-looking token.
    $winver = ''
    if ($bestInstall -and (Get-Prop $bestInstall 'exactEquivalent')) {
        $vv = [string](Get-Prop $app 'version')
        if ($vv -match '\d') {
            $tok = ($vv -split '[ /]') | Where-Object { $_ -match '^\d' } | Select-Object -First 1
            if ($tok) { $winver = [string]$tok }
        }
    }

    # Emit every mustInclude alternative, ranked. The user's answer to
    # "How many best alternatives..." (MIGRATE_ALT_LIMIT) decides how many of these
    # best-first entries actually install at runtime, via the app_alt gate.
    $rank = 0
    foreach ($entry in $mustAlts) {
        $rank++
        $alt = $entry.Alt
        $altName = [string](Get-Prop $alt 'name')
        $install = Get-Prop $alt 'install'
        if ($install) { $enriched++ } else { $install = New-FallbackInstall $alt; $fallback++ }
        # Only the rank-1 (best) alt is the "exact equivalent" carrying the Windows version.
        $wv = if ($rank -eq 1) { $winver } else { '' }
        $altPaid = -not ([string](Get-Prop $alt 'pricingModel') -match '(?i)free')
        $appLines.Add(('  app_alt ' + $rank + ' ' + (New-InstallCall -Name $name -Alt $altName -Install $install -WinVer $wv -Paid:$altPaid)))
    }
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
        $appLines.Add(('  ' + (New-InstallCall -Name $name -Alt $pkgs -Install $inst)))
        [void]$emittedNames.Add($name.ToLowerInvariant())
    }
}

$appsData = ((@($repoLines) + @($appLines)) -join "`n")
$manualData = ($manualLines -join "`n")
Write-Host ("  vendor repo setups: {0}" -f $repoSlugs.Count) -ForegroundColor Green
Write-Host ("  apps: {0} total ({1} enriched, {2} fallback); {3} manual file-prompt app(s)" -f $appLines.Count, $enriched, $fallback, $manualLines.Count) -ForegroundColor Green

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
    'execute_all.sh.tmpl'                = @{ manual = $manualData }
}

foreach ($tmplName in $map.Keys) {
    $tmplPath = Join-Path $templatesDir $tmplName
    if (-not (Test-Path $tmplPath)) { Write-Error "Missing template: $tmplPath"; exit 1 }
    $content = Get-Content -Raw -Path $tmplPath

    $content = $content.Replace('### __COMMON__ ###', $common)
    if ($map[$tmplName].ContainsKey('apps'))     { $content = $content.Replace('### __APPS_DATA__ ###', $map[$tmplName].apps) }
    if ($map[$tmplName].ContainsKey('settings')) { $content = $content.Replace('### __SETTINGS_DATA__ ###', $map[$tmplName].settings) }
    if ($map[$tmplName].ContainsKey('drivers'))  { $content = $content.Replace('### __DRIVERS_DATA__ ###', $map[$tmplName].drivers) }
    if ($map[$tmplName].ContainsKey('manual'))   { $content = $content.Replace('### __MANUAL_APPS__ ###', $map[$tmplName].manual) }

    # Normalize to LF, no trailing CR, no BOM.
    $content = $content -replace "`r`n", "`n" -replace "`r", "`n"
    $outName = $tmplName -replace '\.tmpl$', ''
    $outPath = Join-Path $OutputDir $outName
    [System.IO.File]::WriteAllText($outPath, $content, $enc)
    Write-Host "  generated: $outName" -ForegroundColor Green
}

Write-Host "`nDone. Universal installer written to: $OutputDir" -ForegroundColor Cyan
