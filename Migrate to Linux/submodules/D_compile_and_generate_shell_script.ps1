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
    [string] $DriverCsv,
    [string] $SoftwareCsv
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
if (-not $SoftwareCsv)   { $SoftwareCsv   = Join-Path $documentsDir 'B_installed_windows_software.csv' }

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
    param([string] $Name, [string] $Alt, $Install, [string] $WinVer, [switch] $Paid, [string] $Launch, [string] $DlPage)
    $parts = New-Object System.Collections.Generic.List[string]
    $parts.Add('install_app')
    Add-Flag $parts '--name' $Name
    Add-Flag $parts '--alt' $Alt
    Add-Flag $parts '--launch' $Launch
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
        Add-Flag $parts '--url-deb' (Get-Prop $dl 'deb')
        Add-Flag $parts '--url-rpm' (Get-Prop $dl 'rpm')
    }

    Add-Flag $parts '--webapp' (Get-Prop $Install 'webappUrl')
    Add-Flag $parts '--docker' (Get-Prop $Install 'dockerImage')
    Add-Flag $parts '--github' (Get-Prop $Install 'githubRepo')
    # Download page (req): the app's saved vendor download page, opened (after a health
    # check) when package managers are unavailable/failed. Prefer install.downloadPage,
    # then the alternative's downloadUrl ($DlPage). Only real http(s) URLs, never pseudo
    # values like "apt install X".
    # NB: PowerShell variables are case-insensitive, so this local must NOT be named
    # $dlpage -- that would alias the $DlPage parameter and clobber it.
    $page = [string](Get-Prop $Install 'downloadPage')
    if (-not $page) { $page = $DlPage }
    if ($page -and ($page -match '^https?://')) { Add-Flag $parts '--dlpage' $page }
    Add-Flag $parts '--note'   (Get-Prop $Install 'note')

    # Custom post-install commands (install.postInstall: string or array of shell snippets).
    # Emitted as one --post 'CMD' per command; install_app runs them after a successful install.
    $post = Get-Prop $Install 'postInstall'
    if ($post) { foreach ($c in @($post)) { if ([string]$c -ne '') { Add-Flag $parts '--post' ([string]$c) } } }

    if (Get-Prop $Install 'security') { $parts.Add('--security') }
    if ($Paid) { $parts.Add('--paid') }

    return ($parts -join ' ')
}

# Guess a Linux package name from an alternative's display name: take the first component
# before a "/", "+" or "(", lowercase it, hyphenate spaces, drop other punctuation.
# e.g. "BorgBackup / Vorta" -> "borgbackup", "Ollama + Open WebUI" -> "ollama", "GIMP" -> "gimp".
function Get-PkgGuess {
    param([string] $Name)
    $s = ($Name.ToLowerInvariant() -split '\s*[/+(]\s*')[0].Trim()
    $s = $s -replace '\s+', '-'
    $s = $s -replace '[^a-z0-9.+-]', ''
    return $s
}

# Descriptor for an alternative with no enriched install{} block. We don't fabricate a
# specific method; instead we emit the alternative's NAME as a best-effort package name for
# every native package manager (the running distro tries its own, in the engine's normal
# order, until one works; otherwise it falls back to the manual download-page flow). Flatpak
# is intentionally NOT guessed (it needs reverse-DNS app ids, which a plain name never matches).
function New-FallbackInstall {
    param($Alt)
    $obj = [ordered]@{ method = 'native' }
    $im = [string](Get-Prop $Alt 'installMethod')
    if ($im -match '^(?i)web$') {
        $obj['method'] = 'webapp'; $obj['webappUrl'] = [string](Get-Prop $Alt 'downloadUrl')
    } else {
        $guess = Get-PkgGuess ([string](Get-Prop $Alt 'name'))
        if ($guess) { $obj['native'] = [ordered]@{ apt = $guess; dnf = $guess; zypper = $guess; pacman = $guess } }
        else        { $obj['method'] = 'manual' }
    }
    $url = [string](Get-Prop $Alt 'downloadUrl')
    if ($url -and ($url -match '^https?://')) { $obj['downloadPage'] = $url }
    $obj['note'] = 'auto-guessed install from the alternative name (unverified)'
    $obj['review'] = $true
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
# 1. APPLICATION LIST  (the UNION of B_installed_windows_software.csv + Additional CSV,
#    enriched with data from B_applications.json -- the manifest is a data holder only)
# ---------------------------------------------------------------------------
Write-Host "Reading manifest: $ManifestPath" -ForegroundColor Gray
$manifest = Get-Content -Raw -Path $ManifestPath -Encoding UTF8 | ConvertFrom-Json
$apps = $manifest.applications

# All manifest app names (lowercased) for the "not in manifest" check below.
$manifestNames = New-Object System.Collections.Generic.HashSet[string]
$nameToApp = @{}
foreach ($app in $apps) {
    $nm = ([string](Get-Prop $app 'name')).ToLowerInvariant()
    [void]$manifestNames.Add($nm)
    if (-not $nameToApp.ContainsKey($nm)) { $nameToApp[$nm] = $app }
}

# ---------------------------------------------------------------------------
# Match detected Windows apps to manifest entries by NORMALISED name, so that
# version/edition suffixes in the registry DisplayName (e.g. "WinRAR 7.22",
# "Microsoft 365 - en-us") still resolve to the static manifest entry. The
# stripped version/edition are written back into two DYNAMIC manifest fields
# (installedVersion / installedEdition) that are refreshed on every run; the
# "same version" mode reads installedVersion as its pin target.
# ---------------------------------------------------------------------------
function Get-BaseName([string]$n) {
    if (-not $n) { return '' }
    $s = $n.ToLowerInvariant()
    $s = $s -replace '\([^)]*\)', ' '                                   # (x64 en-US)
    $s = $s -replace '\s+-\s+[a-z]{2}-[a-z]{2}\b', ' '                  #  - en-us
    $s = $s -replace '\b(x64|x86|win64|win32|amd64|64-bit|32-bit)\b', ' '
    $s = $s -replace '\b(version|release|update|build|from visual studio)\b', ' '
    # Strip trailing version-ish tokens (a space-led token that contains a digit),
    # e.g. " 7.22", " 10.0.301", " py313_26.3.2-2". Repeated for multi-token tails.
    for ($i = 0; $i -lt 4; $i++) { $s = $s -replace '[\s\-_]+\S*\d\S*\s*$', ' ' }
    $s = $s -replace '[^a-z0-9]+', ' '
    return (($s -replace '\s+', ' ').Trim())
}
function Get-Edition([string]$raw, [string]$ver) {
    if (-not $raw) { return '' }
    $bits = New-Object System.Collections.Generic.List[string]
    foreach ($m in [regex]::Matches($raw, '\(([^)]*)\)'))           { if ($m.Groups[1].Value.Trim()) { $bits.Add($m.Groups[1].Value.Trim()) } }
    foreach ($m in [regex]::Matches($raw, '\b[a-z]{2}-[a-z]{2}\b')) { if (-not $bits.Contains($m.Value)) { $bits.Add($m.Value) } }
    if ($raw -match '(?i)\bapps for enterprise\b') { $bits.Add('Apps for enterprise') }
    return (($bits | Select-Object -Unique) -join ', ')
}
function Compare-Ver([string]$a, [string]$b) {
    $va = $null; $vb = $null
    # Treat every non-digit run as a separator (so "3.14-64" -> 3.14.64, not 3.1464),
    # and keep at most 4 components ([version] accepts up to four).
    $na = ((($a -replace '[^0-9]+', '.').Trim('.') -split '\.' | Select-Object -First 4) -join '.')
    $nb = ((($b -replace '[^0-9]+', '.').Trim('.') -split '\.' | Select-Object -First 4) -join '.')
    if ([version]::TryParse($na, [ref]$va) -and [version]::TryParse($nb, [ref]$vb)) { return $va.CompareTo($vb) }
    return [string]::Compare($a, $b)
}
# Curated aliases for names that normalisation alone cannot bridge (embedded
# numbers that are part of the name, or a different manifest wording). Key is a
# substring of the lowercased DisplayName; value is the exact manifest name.
$alias = [ordered]@{
    'microsoft 365 apps'        = 'Microsoft 365 / Office'
    'microsoft 365'             = 'Microsoft 365 / Office'
    'microsoft office hub'      = 'Microsoft 365 / Office'
    'visual studio build tools' = 'Visual Studio Build Tools / Community'
    'visual studio community'   = 'Visual Studio Build Tools / Community'
    'visual studio code'        = 'Visual Studio Code'
    'whatsapp'                  = 'WhatsApp Desktop'
    'whats app'                 = 'WhatsApp Desktop'
    'onedrive'                  = 'Microsoft OneDrive'
    'one drive'                 = 'Microsoft OneDrive'
    'powershell'                = 'PowerShell'
    'power shell'               = 'PowerShell'
    'quick share'              = 'Nearby Share / Quick Share'
    'nearby share'             = 'Nearby Share / Quick Share'
    'hotspot shield'           = 'Hotspot Shield'
    'zune music'               = 'Zune Music / Windows Media Player'
    'internet download manager' = 'Internet Download Manager (IDM)'
    'gnuwin32'                  = 'GnuWin32: Grep'
    'lenovo vantage'           = 'Lenovo Vantage / Lenovo Vantage Service'
    'lenovo go central'        = 'Lenovo Vantage / Lenovo Vantage Service'
}
$aliasKeys = @($alias.Keys | Sort-Object -Property Length -Descending)
# Manifest base names, longest first (most specific wins).
$appBases = @($apps | ForEach-Object { [pscustomobject]@{ App = $_; Base = (Get-BaseName ([string](Get-Prop $_ 'name'))) } } |
             Where-Object { $_.Base } | Sort-Object -Property @{ Expression = { $_.Base.Length } } -Descending)

function Find-ManifestApp([string]$csvName) {
    $low = $csvName.ToLowerInvariant()
    if ($nameToApp.ContainsKey($low)) { return $nameToApp[$low] }
    foreach ($k in $aliasKeys) { if ($low.Contains($k)) { return $nameToApp[$alias[$k].ToLowerInvariant()] } }
    $cb = Get-BaseName $csvName
    if ($cb) {
        # Exact base-name equality only: both sides have had version/edition suffixes
        # stripped, so the same product reduces to the same base. (Prefix matching is
        # avoided so distinct products like "Python Manager" don't fold into "Python".)
        foreach ($e in $appBases) { if ($cb -eq $e.Base) { return $e.App } }
    }
    return $null
}

$verByName = @{}; $edByName = @{}
$unmatchedLines = New-Object System.Collections.Generic.List[string]
$unmatchedNames = New-Object System.Collections.Generic.List[string]
# The install list is DETECTION-driven: only the Windows apps actually present on this
# machine (B_installed_windows_software.csv), matched to a manifest entry, are emitted.
# The manifest is a DATA HOLDER for enrichment, NOT the source of the app list.
$selectedApps = New-Object System.Collections.Generic.List[object]
$selectedKeys = New-Object System.Collections.Generic.HashSet[string]
if (Test-Path $SoftwareCsv) {
    Write-Host "Reading detected software: $SoftwareCsv" -ForegroundColor Gray
    foreach ($row in (Import-Csv -Path $SoftwareCsv)) {
        $cn = [string]$row.Name
        if (-not $cn) { continue }
        $app = Find-ManifestApp $cn
        if (-not $app) { $unmatchedLines.Add('  "' + (ConvertTo-BashString $cn) + '"'); $unmatchedNames.Add($cn); continue }
        $key = ([string](Get-Prop $app 'name')).ToLowerInvariant()
        if ($selectedKeys.Add($key)) { $selectedApps.Add($app) }
        $ver = [string]$row.Version
        if (-not $ver) { $m = [regex]::Match($cn, '\d[\w.\-]*'); if ($m.Success) { $ver = $m.Value } }
        if ($ver) {
            if (-not $verByName.ContainsKey($key) -or (Compare-Ver $ver $verByName[$key]) -gt 0) { $verByName[$key] = $ver }
        }
        $ed = Get-Edition $cn $ver
        if ($ed) {
            if (-not $edByName.ContainsKey($key)) { $edByName[$key] = New-Object System.Collections.Generic.List[string] }
            foreach ($p in ($ed -split ',\s*')) { if ($p -and -not $edByName[$key].Contains($p)) { $edByName[$key].Add($p) } }
        }
    }
}
# Write the dynamic fields onto the matched manifest entries (in memory).
function Set-Prop($obj, $n, $v) {
    if ($obj.PSObject.Properties[$n]) { $obj.$n = $v } else { $obj | Add-Member -NotePropertyName $n -NotePropertyValue $v }
}
$dynCount = 0
foreach ($app in $apps) {
    $key = ([string](Get-Prop $app 'name')).ToLowerInvariant()
    $iv = if ($verByName.ContainsKey($key)) { $verByName[$key] } else { $null }
    $ie = if ($edByName.ContainsKey($key)) { (($edByName[$key] | Select-Object -Unique) -join ', ') } else { $null }
    if ($iv -or $ie) {
        Set-Prop $app 'installedVersion' ([string]$iv)
        Set-Prop $app 'installedEdition' ([string]$ie)
        $dynCount++
    }
}
# Persist the manifest so the dynamic fields are stored alongside the static data.
try {
    $json = ($manifest | ConvertTo-Json -Depth 40)
    [System.IO.File]::WriteAllText($ManifestPath, $json, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host ("  refreshed installedVersion/installedEdition on {0} manifest entr(ies)" -f $dynCount) -ForegroundColor Green
} catch {
    Write-Host ("  WARNING: could not write dynamic fields back to manifest: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
}
$unmatchedData = ($unmatchedLines -join "`n")
# req27: report the not-in-manifest apps as a warning DURING this ps1 run (not only
# later inside execute_all.sh), so the user sees them the moment the toolkit runs.
if ($unmatchedNames.Count -gt 0) {
    Write-Host ""
    Write-Host ("WARNING: {0} detected Windows app(s) are NOT in the manifest -- no Linux equivalent will be installed for them:" -f $unmatchedNames.Count) -ForegroundColor Yellow
    foreach ($u in $unmatchedNames) { Write-Host ("    - {0}" -f $u) -ForegroundColor Yellow }
    Write-Host ("  Add them to the manifest ({0}) and re-run run_project.ps1." -f $ManifestPath) -ForegroundColor Yellow
    Write-Host "  (See the README 'Update the manifest with AI' section for a ready-to-paste prompt.)" -ForegroundColor Yellow
    Write-Host ""
} else {
    Write-Host "  all detected apps matched a manifest entry" -ForegroundColor Green
}

# Alternatives weaker than this competency (%) are ignored completely -- never emitted into
# the installer, so they take no part in ranking, the N count, or the threshold.
$MinCompetency = 60

$appLines = New-Object System.Collections.Generic.List[string]
$repoLines = New-Object System.Collections.Generic.List[string]
$repoSlugs = New-Object System.Collections.Generic.HashSet[string]
$manualLines = New-Object System.Collections.Generic.List[string]
$emittedNames = New-Object System.Collections.Generic.HashSet[string]
$enriched = 0; $fallback = 0

# Force-included manifest apps: emitted even when NOT detected on Windows (e.g. a Linux-only
# helper the user always wants, like a clipboard manager). Opt-in via "forceInclude": true
# on the manifest entry; purely additive, so detection-driven selection is unchanged for
# every other app. De-duped against detected apps by normalised name.
foreach ($app in $apps) {
    if ([string](Get-Prop $app 'forceInclude') -match '^(?i)(true|yes|1)$') {
        $key = ([string](Get-Prop $app 'name')).ToLowerInvariant()
        if ($selectedKeys.Add($key)) { $selectedApps.Add($app) }
    }
}

# Emit ONLY the detected apps (the union half coming from B_installed_windows_software.csv,
# matched to manifest entries above) plus any forceInclude apps. The Additional CSV adds
# the other union half below.
foreach ($app in $selectedApps) {
    # Rank ALL alternatives best-first by competency (no mustInclude gate). Wine/Proton
    # alternatives are excluded -- the separate wine prompt handles those. Each entry is
    # tagged native (appType "Native ...") vs non-native so the runtime can apply the
    # "N native installs + better-ranked web/docker ride along" deployment rule.
    $mustAlts = @()
    foreach ($alt in (Get-Prop $app 'alternatives')) {
        $at = [string](Get-Prop $alt 'appType')
        if ($at -match '(?i)wine|proton') { continue }
        $c = 0.0; [double]::TryParse(((''+(Get-Prop $alt 'competency')) -replace '[^0-9.]',''), [ref]$c) | Out-Null
        # Ignore weak alternatives entirely (competency below the minimum is never emitted).
        if ($c -lt $MinCompetency) { continue }
        $isNat = if ($at -match '^(?i)native') { 1 } else { 0 }
        $mustAlts += [pscustomobject]@{ Alt = $alt; Score = $c; IsNative = $isNat }
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
    # honour "same version" when the user picks it. Prefer the DYNAMIC installedVersion
    # (the actual version detected on this Windows machine) and fall back to the static
    # manifest version. Use the first version-looking token.
    $winver = ''
    if ($bestInstall -and (Get-Prop $bestInstall 'exactEquivalent')) {
        $vv = [string](Get-Prop $app 'installedVersion')
        if (-not $vv) { $vv = [string](Get-Prop $app 'version') }
        if ($vv -match '\d') {
            $tok = ($vv -split '[ /]') | Where-Object { $_ -match '^\d' } | Select-Object -First 1
            if ($tok) { $winver = [string]$tok }
        }
    }

    # Emit every ranked alternative as "app_alt RANK TOTAL install_app ...". The user's
    # answer to "How many best alternatives..." (MIGRATE_ALT_LIMIT) decides how many of
    # these best-first entries actually install at runtime, via the app_alt gate; TOTAL
    # lets app_alt detect the last alternative (for the all-paid free-only skip notice).
    $rank = 0
    $total = $mustAlts.Count
    foreach ($entry in $mustAlts) {
        $rank++
        $alt = $entry.Alt
        $altName = [string](Get-Prop $alt 'name')
        $install = Get-Prop $alt 'install'
        if ($install) { $enriched++ } else { $install = New-FallbackInstall $alt; $fallback++ }
        # Only the rank-1 (best) alt is the "exact equivalent" carrying the Windows version.
        $wv = if ($rank -eq 1) { $winver } else { '' }
        $altPaid = -not ([string](Get-Prop $alt 'pricingModel') -match '(?i)free')
        $comp = $entry.Score.ToString([System.Globalization.CultureInfo]::InvariantCulture)
        $appLines.Add(('  app_alt ' + $rank + ' ' + $total + ' ' + $entry.IsNative + ' ' + $comp + ' ' + (New-InstallCall -Name $name -Alt $altName -Install $install -WinVer $wv -Paid:$altPaid -Launch ([string](Get-Prop $alt 'launch')) -DlPage ([string](Get-Prop $alt 'downloadUrl')))))
    }

    # Wine (Windows emulator) option: for non-cross-platform Windows desktop apps (a
    # Win32 app with no native "Available on Linux" build), emit a wine_app call. It
    # runs only when the user answered yes to the wine prompt (MIGRATE_WINE_NONCROSS).
    # It auto-downloads the Windows installer when the manifest app provides one (the
    # optional "windowsInstaller" URL field); otherwise it asks for the path at runtime.
    $avail = [string](Get-Prop $app 'linuxAvailability')
    $src   = [string](Get-Prop $app 'sourceType')
    if (($src -match '(?i)win32') -and ($avail -notmatch '(?i)available on linux')) {
        $winUrl = [string](Get-Prop $app 'windowsInstaller')
        # "Not recommended" apps carry a short reason + recommended action, shown as a
        # yellow one-line warning before the wine install prompt.
        $nrReason = ''; $nrAction = ''
        if ([string](Get-Prop $app 'notRecommended') -match '^(?i)(yes|true|1)$') {
            $nrReason = [string](Get-Prop $app 'notRecommendedReason')
            $nrAction = [string](Get-Prop $app 'recommendedAction')
        }
        $appLines.Add('  wine_app "' + (ConvertTo-BashString $name) + '" "' + (ConvertTo-BashString $winUrl) + '" "' + (ConvertTo-BashString $nrReason) + '" "' + (ConvertTo-BashString $nrAction) + '"')
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
# ($unmatchedData / dynamic installedVersion+installedEdition computed during the
#  normalised-match pass above, right after the manifest was loaded.)

# ---------------------------------------------------------------------------
# 2. SETTINGS  (from C_windows_configs.csv)
# ---------------------------------------------------------------------------
$cfgMap = @{
    'scaling'             = 'CFG_scaling'
    'resolution'          = 'CFG_resolution'
    'lock_screen_timeout' = 'CFG_lock_timeout'
    'layout'              = 'CFG_keyboard_layout'
    'key_repeat_delay'    = 'CFG_key_repeat_delay'
    'key_repeat_rate'     = 'CFG_key_repeat_rate'
    'numlock'             = 'CFG_numlock'
    'telemetry_level'     = 'CFG_telemetry'
    'location_service'    = 'CFG_location'
    'mouse_size'          = 'CFG_mouse_size'
    'mouse_speed'         = 'CFG_mouse_speed'
    'mouse_accel'         = 'CFG_mouse_accel'
    'mouse_swap'          = 'CFG_mouse_swap'
    'mouse_dblclick'      = 'CFG_mouse_dblclick'
    'color_scheme'        = 'CFG_color_scheme'
    'accent_color'        = 'CFG_accent'
    'night_light'         = 'CFG_night_light'
    'locale'              = 'CFG_locale'
    'proxy_mode'          = 'CFG_proxy_mode'
    'proxy_host'          = 'CFG_proxy_host'
    'proxy_port'          = 'CFG_proxy_port'
    'proxy_autoconfig'    = 'CFG_proxy_autoconfig'
    'touchpad_tap'        = 'CFG_touchpad_tap'
    'touchpad_natural'    = 'CFG_touchpad_natural'
    'sleep_ac'            = 'CFG_sleep_ac'
    'sleep_dc'            = 'CFG_sleep_dc'
    'default_browser'     = 'CFG_default_browser'
    'a11y_stickykeys'     = 'CFG_a11y_stickykeys'
    'a11y_slowkeys'       = 'CFG_a11y_slowkeys'
    'a11y_bouncekeys'     = 'CFG_a11y_bouncekeys'
    'a11y_mousekeys'      = 'CFG_a11y_mousekeys'
    'a11y_highcontrast'   = 'CFG_a11y_highcontrast'
    'a11y_magnifier'      = 'CFG_a11y_magnifier'
    'a11y_screenreader'   = 'CFG_a11y_screenreader'
    'timezone'            = 'CFG_timezone'
    'ntp_server'          = 'CFG_ntp_server'
}
$settingsLines = New-Object System.Collections.Generic.List[string]
# WiFi / Firewall rows are multi-field (pipe-packed in WindowsValue). They are emitted
# as TAB-delimited lines into single-quoted heredocs in apply_settings.sh, so they must
# stay LITERAL (no bash escaping -- that would corrupt '$' in WiFi passwords). We only
# strip embedded tabs/newlines so the TSV layout is preserved.
$wifiLines = New-Object System.Collections.Generic.List[string]
$fwLines   = New-Object System.Collections.Generic.List[string]
$scLines   = New-Object System.Collections.Generic.List[string]
$startLines = New-Object System.Collections.Generic.List[string]
$svcLines   = New-Object System.Collections.Generic.List[string]
$taskLines  = New-Object System.Collections.Generic.List[string]
$hostsLines = New-Object System.Collections.Generic.List[string]
$prnLines   = New-Object System.Collections.Generic.List[string]
$netLines   = New-Object System.Collections.Generic.List[string]
function ConvertTo-TsvLine { param([string] $PipeValue)
    if ($null -eq $PipeValue) { return '' }
    $fields = $PipeValue -split '\|'
    $clean  = $fields | ForEach-Object { ($_ -replace "[`r`n`t]", ' ') }
    return ($clean -join "`t")
}
if (Test-Path $ConfigCsv) {
    foreach ($row in (Import-Csv -Path $ConfigCsv)) {
        $key = [string]$row.ConfigKey
        $cat = [string]$row.Category
        if ($cfgMap.ContainsKey($key)) {
            $settingsLines.Add($cfgMap[$key] + '="' + (ConvertTo-BashString ([string]$row.WindowsValue)) + '"')
        }
        elseif ($cat -eq 'Wifi' -and $key -eq 'wifi_profile') {
            $line = ConvertTo-TsvLine ([string]$row.WindowsValue)
            if ($line.Trim()) { $wifiLines.Add($line) }
        }
        elseif ($cat -eq 'Firewall' -and $key -eq 'fw_rule') {
            $line = ConvertTo-TsvLine ([string]$row.WindowsValue)
            if ($line.Trim()) { $fwLines.Add($line) }
        }
        elseif ($cat -eq 'Shortcuts') {
            # ConfigKey is the shortcut kind (quicklaunch|startmenu|desktop); prepend it.
            $line = ConvertTo-TsvLine (($key + '|' + [string]$row.WindowsValue))
            if ((($key + [string]$row.WindowsValue)).Trim()) { $scLines.Add($line) }
        }
        elseif ($cat -eq 'Startup' -and $key -eq 'startup_item') {
            # Carry Scope (user|system) as the first field:  scope<TAB>name<TAB>exeBase
            $line = ConvertTo-TsvLine (((([string]$row.Scope).ToLower()) + '|' + [string]$row.WindowsValue))
            if (([string]$row.WindowsValue).Trim()) { $startLines.Add($line) }
        }
        elseif ($cat -eq 'Services' -and $key -eq 'service') {
            $line = ConvertTo-TsvLine ([string]$row.WindowsValue)   # display<TAB>name
            if (([string]$row.WindowsValue).Trim()) { $svcLines.Add($line) }
        }
        elseif ($cat -eq 'ScheduledTasks' -and $key -eq 'task') {
            $line = ConvertTo-TsvLine ([string]$row.WindowsValue)   # name<TAB>scope<TAB>schedule<TAB>exeBase
            if (([string]$row.WindowsValue).Trim()) { $taskLines.Add($line) }
        }
        elseif ($cat -eq 'Hosts' -and $key -eq 'host_entry') {
            $v = ([string]$row.WindowsValue).Trim()                 # one /etc/hosts line, verbatim
            if ($v) { $hostsLines.Add($v) }
        }
        elseif ($cat -eq 'Printers' -and $key -eq 'printer') {
            $line = ConvertTo-TsvLine ([string]$row.WindowsValue)   # name<TAB>host
            if (([string]$row.WindowsValue).Trim()) { $prnLines.Add($line) }
        }
        elseif ($cat -eq 'NetConfig' -and $key -eq 'static_net') {
            $line = ConvertTo-TsvLine ([string]$row.WindowsValue)   # iface<TAB>ip<TAB>gw<TAB>dns
            if (([string]$row.WindowsValue).Trim()) { $netLines.Add($line) }
        }
    }
}
if ($settingsLines.Count -eq 0) { $settingsLines.Add('# (no mappable settings found in C_windows_configs.csv)') }
$settingsData = ($settingsLines -join "`n")
$wifiData     = ($wifiLines -join "`n")
$fwData       = ($fwLines -join "`n")
$scData       = ($scLines -join "`n")
$startData    = ($startLines -join "`n")
$svcData      = ($svcLines -join "`n")
$taskData     = ($taskLines -join "`n")
$hostsData    = ($hostsLines -join "`n")
$prnData      = ($prnLines -join "`n")
$netData      = ($netLines -join "`n")
Write-Host ("  settings: {0} scalar; wifi: {1}; firewall: {2}; shortcuts: {3}; startup: {4}; services: {5}; tasks: {6}; hosts: {7}; printers: {8}; netcfg: {9}" -f ($settingsLines.Count), $wifiLines.Count, $fwLines.Count, $scLines.Count, $startLines.Count, $svcLines.Count, $taskLines.Count, $hostsLines.Count, $prnLines.Count, $netLines.Count) -ForegroundColor Green

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
# Helper scripts live in a "submodules" subfolder of the output; only execute_all.sh
# stays at the top level as the single entry point.
$subDir = Join-Path $OutputDir 'submodules'
if (-not (Test-Path $subDir -PathType Container)) { New-Item -ItemType Directory -Path $subDir -Force | Out-Null }
$map = @{
    'install_must_have_software.sh.tmpl' = @{ apps = $appsData }
    'apply_settings.sh.tmpl'             = @{ settings = $settingsData; wifi = $wifiData; firewall = $fwData; shortcuts = $scData; startup = $startData; services = $svcData; tasks = $taskData; hosts = $hostsData; printers = $prnData; netcfg = $netData }
    'install_device_drivers.sh.tmpl'     = @{ drivers = $driversData }
    'execute_all.sh.tmpl'                = @{ manual = $manualData; unmatched = $unmatchedData }
}

foreach ($tmplName in $map.Keys) {
    $tmplPath = Join-Path $templatesDir $tmplName
    if (-not (Test-Path $tmplPath)) { Write-Error "Missing template: $tmplPath"; exit 1 }
    $content = Get-Content -Raw -Path $tmplPath

    $content = $content.Replace('### __COMMON__ ###', $common)
    if ($map[$tmplName].ContainsKey('apps'))     { $content = $content.Replace('### __APPS_DATA__ ###', $map[$tmplName].apps) }
    if ($map[$tmplName].ContainsKey('settings')) { $content = $content.Replace('### __SETTINGS_DATA__ ###', $map[$tmplName].settings) }
    if ($map[$tmplName].ContainsKey('wifi'))     { $content = $content.Replace('### __WIFI_DATA__ ###', $map[$tmplName].wifi) }
    if ($map[$tmplName].ContainsKey('firewall')) { $content = $content.Replace('### __FIREWALL_DATA__ ###', $map[$tmplName].firewall) }
    if ($map[$tmplName].ContainsKey('shortcuts')){ $content = $content.Replace('### __SHORTCUTS_DATA__ ###', $map[$tmplName].shortcuts) }
    if ($map[$tmplName].ContainsKey('startup'))  { $content = $content.Replace('### __STARTUP_DATA__ ###', $map[$tmplName].startup) }
    if ($map[$tmplName].ContainsKey('services')) { $content = $content.Replace('### __SERVICES_DATA__ ###', $map[$tmplName].services) }
    if ($map[$tmplName].ContainsKey('tasks'))    { $content = $content.Replace('### __SCHEDTASKS_DATA__ ###', $map[$tmplName].tasks) }
    if ($map[$tmplName].ContainsKey('hosts'))    { $content = $content.Replace('### __HOSTS_DATA__ ###', $map[$tmplName].hosts) }
    if ($map[$tmplName].ContainsKey('printers')) { $content = $content.Replace('### __PRINTERS_DATA__ ###', $map[$tmplName].printers) }
    if ($map[$tmplName].ContainsKey('netcfg'))   { $content = $content.Replace('### __NETCFG_DATA__ ###', $map[$tmplName].netcfg) }
    if ($map[$tmplName].ContainsKey('drivers'))  { $content = $content.Replace('### __DRIVERS_DATA__ ###', $map[$tmplName].drivers) }
    if ($map[$tmplName].ContainsKey('manual'))   { $content = $content.Replace('### __MANUAL_APPS__ ###', $map[$tmplName].manual) }
    if ($map[$tmplName].ContainsKey('unmatched')){ $content = $content.Replace('### __UNMATCHED_APPS__ ###', $map[$tmplName].unmatched) }

    # Normalize to LF, no trailing CR, no BOM.
    $content = $content -replace "`r`n", "`n" -replace "`r", "`n"
    $outName = $tmplName -replace '\.tmpl$', ''
    # execute_all.sh at the top; every other generated script under submodules/.
    if ($outName -eq 'execute_all.sh') { $destDir = $OutputDir; $label = $outName }
    else { $destDir = $subDir; $label = "submodules/$outName" }
    $outPath = Join-Path $destDir $outName
    [System.IO.File]::WriteAllText($outPath, $content, $enc)
    Write-Host "  generated: $label" -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# 5. CONFIG FILE  (default answers for execute_all.sh, beside it)
# ---------------------------------------------------------------------------
# An existing file is MERGED, not skipped: the user's saved values are preserved
# and any keys added in newer versions (e.g. WINE_NONCROSS) are written in with
# their default, so every question always appears in the config readout.
$configPath = Join-Path $OutputDir 'migrate.config'
$cfgHeader = @(
    '# Migrate to Linux -- saved answers for execute_all.sh'
    '# Edit these values, or delete this file to be asked each question interactively.'
    '# Yes/No = y/n ; VERSION_MODE = same|latest ; BEST_ALTERNATIVES = a whole number.'
)
# Canonical keys, in display order, each with its default value.
$cfgKeys = [ordered]@{
    INSTALL_DRIVERS   = 'y'
    INSTALL_APPS      = 'y'
    BEST_ALTERNATIVES = '1'
    VERSION_MODE      = 'same'
    UPDATE_EXISTING   = 'y'
    INSTALL_SECURITY  = 'n'
    FREE_ONLY         = 'n'
    WINE_NONCROSS     = 'y'
    APPLY_SETTINGS    = 'y'
    REBUILD_DOCKER    = 'y'
}
$existingVals = @{}
$hadConfig = Test-Path $configPath
if ($hadConfig) {
    foreach ($line in (Get-Content -Path $configPath)) {
        if ($line -match '^\s*#' -or $line -notmatch '=') { continue }
        $kv = $line -split '=', 2
        $k  = $kv[0].Trim()
        if ($cfgKeys.Contains($k)) { $existingVals[$k] = ($kv[1] -replace '#.*$', '').Trim() }
    }
}
$cfgLines = New-Object System.Collections.Generic.List[string]
foreach ($h in $cfgHeader) { $cfgLines.Add($h) }
foreach ($k in $cfgKeys.Keys) {
    $val = if ($existingVals.ContainsKey($k) -and $existingVals[$k] -ne '') { $existingVals[$k] } else { $cfgKeys[$k] }
    $cfgLines.Add("$k=$val")
}
[System.IO.File]::WriteAllText($configPath, (($cfgLines -join "`n") + "`n"), $enc)
if ($hadConfig) {
    Write-Host "  updated migrate.config (preserved saved answers; added any new keys)" -ForegroundColor Green
} else {
    Write-Host "  generated: migrate.config" -ForegroundColor Green
}

Write-Host "`nDone. Universal installer written to: $OutputDir" -ForegroundColor Cyan
