<#
.SYNOPSIS
    Inventories all real installed software on Windows and rates how each app can be
    used on Linux: availability flags, the best alternative, an estimated performance
    competency, the Linux pricing model, and whether it is worth installing on Linux.

.DESCRIPTION
    The script produces B_installed_windows_software.csv with 10 columns:

      MACHINE-DERIVED (read live from this PC, never hand-authored):
        Name                       human-friendly product name
        Version                    installed version
        Publisher                  vendor
        Source                     Win32 (registry) or Store (UWP/Appx)

      KNOWLEDGE-DERIVED (looked up offline from B_applications.json, the companion
      JSON manifest that maps every Windows app to its Linux options):
        Linux Availability         one or more flags, normalised to a fixed order:
                                     Available on Linux ; Not Available ;
                                     Native Alternative ; Available as WebApp ;
                                     Linux Docker ; Windows Emulator (Wine/Proton)
        Best Linux Alternative     best current option when not natively available
        Alternative Competency     rough % of how the Linux app/alternative performs
                                   vs the Windows original (>100 = Linux is better);
                                   filled for natively-available apps too (~100%)
        Pricing model              Free (FOSS) / Free / Freemium / Shareware / Paid
                                   of the recommended Linux option
        Must be included on Linux  yes/no - DERIVED by the script: "yes" for the most
                                   competent installable option per product (native or
                                   alternative) whose competency >= -MustIncludeThreshold
        Can be synched to Linux alternative  whether the Windows app's data can be
                                     automatically synced with the Linux alternative
                                     through signing in (cloud): "Yes" or "No, manual transfer"

    How the data is sourced: the curated columns come from the offline
    B_applications.json manifest (the authoritative source, built from web research)
    via the Get-OfflineManifest function.  "Must be included on Linux" is computed
    from the competency figures.  The machine columns (Name, Version, Publisher,
    Source) are always read fresh from the registry / Appx and are never edited.

    Apps NOT found in B_applications.json are flagged with a WARNING and their
    curated columns are set to "Needs Review" / "Not in manifest".  You can
    manually edit the CSV afterwards.

    Noise removed before rating: Windows updates / hotfixes / KBs, and (unless
    -IncludeSystemComponents) redistributables, runtimes, drivers and SDK fragments.

.PARAMETER OutputPath
    CSV path. Default: B_installed_windows_software.csv beside this script.
.PARAMETER MustIncludeThreshold
    Minimum Alternative Competency (%) for "Must be included on Linux" = yes. Default 70.
.PARAMETER IncludeSystemComponents
    Keep redistributables, runtimes and drivers (off by default).
.PARAMETER IncludeStoreApps
    Include filtered Microsoft Store / UWP apps (on by default).
.PARAMETER Online
    For apps not in the knowledge base, query repology.org live to detect Linux
    packaging. Results are cached next to the CSV.

.EXAMPLE
    .\B_detect_B_installed_windows_software.ps1
    .\B_detect_B_installed_windows_software.ps1 -Online -MustIncludeThreshold 80
#>

[CmdletBinding()]
param(
    # Default is resolved in the body so an empty $PSScriptRoot (e.g. when launched
    # via Code Runner / a selection) can't break parameter binding.
    [string] $OutputPath,
    [int]    $MustIncludeThreshold = 70,
    [switch] $IncludeSystemComponents,
    [bool]   $IncludeStoreApps = $true,
    [switch] $Online
)

$ErrorActionPreference = 'Stop'

# Resolve the output path robustly: default to the parent (Migrate to Linux/) directory
# rather than the submodules/ folder.
if (-not $OutputPath) {
    $scriptDir = $PSScriptRoot
    if (-not $scriptDir -and $PSCommandPath)            { $scriptDir = Split-Path -Parent $PSCommandPath }
    if (-not $scriptDir -and $MyInvocation.MyCommand.Path) { $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
    if (-not $scriptDir)                               { $scriptDir = (Get-Location).Path }
    # Output to parent of submodules/ so the CSV lands in Migrate to Linux/
    $parentDir = Split-Path -Parent $scriptDir
    $OutputPath = Join-Path $parentDir 'B_installed_windows_software.csv'
}

# ---------------------------------------------------------------------------
# 0. HELPERS  (defined before use)
# ---------------------------------------------------------------------------

# Safely access a property that may not exist (needed because try/catch
# cannot be used directly inside Where-Object script blocks in pwsh 7+).
function Safe-Property {
    param($Obj, [string] $Name, $Default = $null)
    try { $Obj.$Name } catch { $Default }
}

# Turn a UWP package id into a readable name:
#   "Microsoft.WindowsCalculator" -> "Windows Calculator"
function Get-FriendlyAppxName {
    param([string] $Id)
    $map = @{
        'NotepadPlusPlus'                 = 'Notepad++'
        '19453.net.Rufus'                 = 'Rufus'
        'C27EB4BA.DROPBOX'                = 'Dropbox'
        '6F71D7A7.HotspotShieldFreeVPN'   = 'Hotspot Shield VPN'
        'CanonicalGroupLimited.Ubuntu'    = 'Ubuntu (WSL)'
        'Microsoft.WindowsCalculator'     = 'Windows Calculator'
        'Microsoft.WindowsCamera'         = 'Windows Camera'
        'Microsoft.WindowsSoundRecorder'  = 'Sound Recorder'
        'Microsoft.MicrosoftStickyNotes'  = 'Sticky Notes'
        'Microsoft.Todos'                 = 'Microsoft To Do'
        'Microsoft.WindowsTerminal'       = 'Windows Terminal'
        'Microsoft.BingSearch'            = 'Bing Search'
        'Microsoft.BingWeather'           = 'Weather'
        'Microsoft.WindowsAlarms'         = 'Alarms & Clock'
        'Microsoft.PowerAutomateDesktop'  = 'Power Automate'
        'Microsoft.GetHelp'               = 'Get Help'
        'SAMSUNGELECTRONICSCO.LTD.SamsungAccount' = 'Samsung Account'
        'ConduitPsiphon.PsiphonConduit'   = 'Psiphon Conduit'
        'E046963F.LenovoCompanion'        = 'Lenovo Vantage'
    }
    if ($map.ContainsKey($Id)) { return $map[$Id] }

    $name = $Id
    if ($name -match '^[A-Za-z0-9]+\.(.+)$') { $name = $Matches[1] }
    $name = ($name -split '\.')[-1]
    $name = $name -creplace '([a-z0-9])([A-Z])', '$1 $2'
    $name = $name -creplace '([A-Z]+)([A-Z][a-z])', '$1 $2'
    return $name.Trim()
}

# Tidy a Win32 display name for the friendly "Name" column.
function Get-CleanName {
    param([string] $Name)
    $n = $Name
    $n = $n -replace '\s*\(remove only\)', ''
    $n = $n -replace '\s*\(User\)', ''
    $n = $n -replace '\s*\(Preview\)\s*x64', ''
    $n = $n -replace '\s*\((?:\s*(?:x64|x86|64-bit|32-bit|64bit|32bit|64|32|bit)\b\s*)+\)\s*$', ''
    $n = $n -replace '\s+(?:x64|x86|64bit|32bit)\s*$', ''
    $n = $n -replace '\s{2,}', ' '
    return $n.Trim()
}

# De-dup key: drops vendor prefix, parentheticals and punctuation but KEEPS version
# digits, so distinct versions stay separate while cosmetic Win32/Store duplicates merge.
function Get-DedupKey {
    param([string] $Name)
    $k = $Name.ToLowerInvariant()
    $k = $k -replace '\([^)]*\)', ''
    $k = $k -replace '^microsoft\s+', ''
    $k = $k -replace '[^a-z0-9+]', ''
    return $k
}

# Identity key: like the dedup key but ALSO drops version numbers, arch and a few
# generic suffix words, so multiple builds of one product (e.g. three Python installs,
# two PowerShell entries) collapse to one identity for the "must include" selection.
function Get-IdentityKey {
    param([string] $Name)
    $k = $Name.ToLowerInvariant()
    $k = $k -replace '\([^)]*\)', ' '
    $k = $k -replace '^microsoft\s+', ''
    $k = $k -replace '\b(x64|x86|64-bit|32-bit|64bit|32bit|amd64)\b', ' '
    $k = $k -replace '\d+(\.\d+)*', ' '
    $k = $k -replace '\b(service|launcher|manager|client|desktop|viewer|server|edition|vpn|free)\b', ' '
    $k = ($k -replace '[^a-z+]', ' ').Trim()
    $k = $k -replace '\s+', ''
    return $k
}

# ---------------------------------------------------------------------------
# 1. COLLECT  -- Win32 (registry) software
# ---------------------------------------------------------------------------
$uninstallPaths = @(
    'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
)

$rawItems = try {
    Get-ItemProperty $uninstallPaths -ErrorAction SilentlyContinue
} catch { @() }
$win32 = $rawItems |
    Where-Object {
        $dn = Safe-Property $_ 'DisplayName'
        $dn -and $dn.Trim() -ne '' -and
        -not (Safe-Property $_ 'SystemComponent' $false) -and
        -not (Safe-Property $_ 'ParentKeyName' $false) -and
        -not (Safe-Property $_ 'ParentDisplayName' $false) -and
        ( (Safe-Property $_ 'WindowsInstaller' 0) -ne 1 -or (Safe-Property $_ 'UninstallString' $false) )
    } |
    Select-Object @{N='Name';      E={$_.DisplayName}},
                  @{N='Version';   E={$_.DisplayVersion}},
                  @{N='Publisher'; E={$_.Publisher}},
                  @{N='Source';    E={'Win32'}}

# ---------------------------------------------------------------------------
# 1b. COLLECT  -- Microsoft Store / UWP apps (human-friendly, noise removed)
# ---------------------------------------------------------------------------
$store = @()
if ($IncludeStoreApps) {
    $appxNoise = @(
        'VideoExtension','ImageExtension','MediaExtension','VCLibs','UI\.Xaml',
        'NET\.Native','WinAppRuntime','WindowsAppRuntime','DesktopAppInstaller',
        'Speech\.','WebExperience','StartExperiences','ActionsServer','Winget\.',
        'OfficePushNotification','XboxGameCallableUI','ShellExtension','SparseApp',
        'VirtualPrinter','GameAssist','SecHealthUI','ApplicationCompatibility',
        'RealtekAudioControl','ThunderboltControlCenter','IntelGraphicsExperience',
        'IntelArcSoftware','LenovoUtility','LenovoDisplayControlCenter','Provisioning',
        'WindowsSubsystemForLinux','CommandPalette','PowerToys\.','DevHome',
        'Microsoft\.6\d','Microsoft\.MicrosoftEdge','StickyNotes\.Dependency',
        '^aimgr$','GetHelp','Ink\.Handwriting','LanguageExperiencePack',
        'StorePurchaseApp','WidgetsPlatform','BingWallpaper'
    ) -join '|'

    $rawAppx = try {
        Get-AppxPackage -ErrorAction SilentlyContinue
    } catch { @() }
    $store = $rawAppx |
        Where-Object {
            -not (Safe-Property $_ 'IsFramework' $false) -and
            (Safe-Property $_ 'SignatureKind' '') -ne 'System' -and
            (Safe-Property $_ 'NonRemovable' $false) -ne $true -and
            (Safe-Property $_ 'Name' '') -notmatch $appxNoise
        } |
        Select-Object @{N='Name';      E={ try { Get-FriendlyAppxName $_.Name } catch { '' }}},
                      @{N='Version';   E={try { $_.Version } catch { '' }}},
                      @{N='Publisher'; E={ try { ($_.Publisher -replace '^CN=','' -replace ',.*$','') } catch { '' }}},
                      @{N='Source';    E={'Store'}}
}

$combined = @($win32) + @($store)

# ---------------------------------------------------------------------------
# 2. EXCLUDE  -- updates / hotfixes, then optionally system components
# ---------------------------------------------------------------------------
$kbList = @(Get-HotFix -ErrorAction SilentlyContinue | ForEach-Object { $_.HotFixID })

$updatePatterns = @(
    'KB\d{5,}', '\bSecurity Update\b', '\bHotfix\b', '\bService Pack\b',
    '\bCumulative Update\b', '\bUpdate for\b', '\bUpdate Health Tools\b',
    '\bPreview Update\b', '\(KB\d+\)'
) -join '|'

$systemPatterns = @(
    'Visual C\+\+ .*Redistributable', '\bRedistributable\b', 'XNA Framework',
    '\.NET.*Runtime', 'Windows Desktop Runtime', '\bRuntime\b - ',
    '\bDriver\b', 'Chipset Device Software', 'Serial IO', 'Dolby Vision',
    'psqlODBC', 'OLE DB Driver', 'ODBC Driver', '\bWinFsp\b', '\bOpenAL\b',
    'Windows SDK AddOn', 'vs_CoreEditorFonts', 'Help Viewer', 'Visual Studio Installer',
    'Visual Studio Tools for Applications', 'Maintenance Service', 'Meeting Add-in',
    'Provisioning Utility', 'Subsystem for Linux Update', 'XNA'
) -join '|'

$reUpdate = [regex]::new($updatePatterns, 'IgnoreCase')
$reSystem = [regex]::new($systemPatterns, 'IgnoreCase')

$filtered = $combined | Where-Object {
    $name = [string]$_.Name
    if ([string]::IsNullOrWhiteSpace($name)) { return $false }
    $isUpdate   = $reUpdate.IsMatch($name)
    $containsKB = ($kbList | Where-Object { $name -like "*$_*" }).Count -gt 0
    $isSystem   = (-not $IncludeSystemComponents) -and $reSystem.IsMatch($name)
    -not ($isUpdate -or $containsKB -or $isSystem)
}

# ---------------------------------------------------------------------------
# 3. CLEAN NAMES + de-duplicate
# ---------------------------------------------------------------------------
$clean = foreach ($app in $filtered) {
    $app.Name = Get-CleanName $app.Name
    $app
}

$deduped = $clean |
    Sort-Object @{E={$_.Source -ne 'Win32'}}, Name |
    Group-Object { Get-DedupKey $_.Name } |
    ForEach-Object { $_.Group[0] }

# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# 4. LOAD THE OFFLINE MANIFEST  -- B_applications.json
#
#    Every Windows application's availability, best alternative, competency,
#    pricing, and sync data is defined in the companion JSON manifest.
#    This script looks up every installed app in the manifest offline - no
#    web scraping, no AI calls, no pre-baked knowledge base inside the script.
# ---------------------------------------------------------------------------
$ManifestPath = $null
$candidates = @(
    # Same folder as the CSV output (default: the project's documents/ subfolder).
    (Join-Path (Split-Path -Parent $OutputPath) 'B_applications.json'),
    # Canonical location: <project root>\documents\B_applications.json
    (Join-Path (Split-Path $PSScriptRoot) 'documents\B_applications.json'),
    # Fallbacks for older layouts / standalone runs.
    (Join-Path (Split-Path $PSScriptRoot) 'B_applications.json'),
    (Join-Path $PSScriptRoot 'B_applications.json'),
    (Join-Path (Get-Location).Path 'documents\B_applications.json'),
    (Join-Path (Get-Location).Path 'B_applications.json')
)
foreach ($c in $candidates) {
    if (Test-Path $c) { $ManifestPath = $c; break }
}

$Global:ManifestData = $null
$Global:ManifestLoaded = $false

function Get-OfflineManifest {
    <#
    .SYNOPSIS
        Loads B_applications.json once per run and caches it globally.
        Looks up an installed Windows app by fuzzy-matching its name against
        the manifest, then extracts Linux Availability, Best Alternative,
        Competency, Pricing, and Syncability from the top-ranked alternative.
    .DESCRIPTION
        Returns [PSCustomObject] with members:
          Availability, BestAlternative, Competency, PricingModel, Syncability,
          AltName, DestType, MatchedByName.
        Returns $null if the app is not found in the manifest.
    #>
    param([string] $AppName)

    # Lazy-load the manifest on first call
    if (-not $Global:ManifestLoaded) {
        $Global:ManifestLoaded = $true
        if (-not $ManifestPath -or -not (Test-Path $ManifestPath)) {
            Write-Warning "B_applications.json NOT FOUND. No offline lookup possible."
            $Global:ManifestData = @{}
            return $null
        }
        try {
            $raw = Get-Content -Path $ManifestPath -Raw -Encoding UTF8 -ErrorAction Stop
            $data = $raw | ConvertFrom-Json -ErrorAction Stop
            $Global:ManifestData = $data
            Write-Host "Loaded offline manifest: $($data.applications.Count) Windows apps, $($data.stats.totalAlternatives) total Linux alternatives." -ForegroundColor Cyan
        }
        catch {
            Write-Warning "Failed to parse B_applications.json: $_"
            $Global:ManifestData = @{}
            return $null
        }
    }

    $data = $Global:ManifestData
    if (-not $data -or -not $data.applications) { return $null }

    # Helper: strip a string down to identity for fuzzy matching
    $matchKey = ($AppName.ToLowerInvariant() -replace '[^a-z0-9]', '').Trim()
    if ([string]::IsNullOrWhiteSpace($matchKey)) { return $null }

    $bestEntry = $null
    $bestScore = 0

    foreach ($entry in $data.applications) {
        $entryKey = ($entry.name.ToLowerInvariant() -replace '[^a-z0-9]', '').Trim()
        if ($entryKey -eq $matchKey) {
            $bestEntry = $entry
            $bestScore = 999
            break
        }
        $entryTokens = ($entry.name.ToLowerInvariant() -split '[^a-z0-9]' | Where-Object { $_ })
        $appTokens   = ([regex]::Replace($AppName, '[^a-z0-9 ]', '').ToLowerInvariant() -split '\s+' | Where-Object { $_ })
        $overlap = 0
        foreach ($t in $appTokens) {
            if ($entryTokens -contains $t -or $entryKey -match [regex]::Escape($t)) { $overlap++ }
        }
        if ($entryKey.Contains($matchKey) -or $matchKey.Contains($entryKey)) { $overlap += 3 }
        if ($overlap -gt $bestScore) { $bestScore = $overlap; $bestEntry = $entry }
    }

    if (-not $bestEntry -or $bestScore -lt 2) { return $null }

    $entry    = $bestEntry
    $firstAlt = if ($entry.alternatives -and $entry.alternatives.Count -gt 0) { $entry.alternatives[0] } else { $null }
    $avail    = if ($entry.linuxAvailability) { $entry.linuxAvailability } else { 'Needs Review' }

    # Build the "Best Alternative" description
    $altName = ''
    if ($firstAlt -and $firstAlt.name) {
        $altName = $firstAlt.name
        if ($firstAlt.installMethod) { $altName += " (install: $($firstAlt.installMethod))" }
    }
    elseif ($entry.destType) {
        $altName = "See $($entry.destType) alternative in manifest"
    }

    $pricing    = if ($firstAlt -and $firstAlt.pricingModel) { $firstAlt.pricingModel } else { 'Unknown' }
    $sync       = if ($firstAlt -and $firstAlt.canSync)      { $firstAlt.canSync }      else { 'No, manual transfer' }

    $competency = 70
    if ($firstAlt -and $firstAlt.competency) {
        $cstr = [string]$firstAlt.competency
        if ($cstr -eq 'N/A') { $competency = 0 }
        else { try { [int]$cstr } catch { 70 } }
    }

    # Extract downloadUrl and appType from the best alternative
    $downloadUrl = if ($firstAlt -and $firstAlt.downloadUrl) { $firstAlt.downloadUrl } else { '' }
    $appType     = if ($firstAlt -and $firstAlt.appType)     { $firstAlt.appType }     else { $entry.destType }

    return [PSCustomObject]@{
        Availability    = $avail
        BestAlternative = $altName
        Competency      = $competency
        PricingModel    = $pricing
        Syncability     = $sync
        AltName         = $altName
        DestType        = $entry.destType
        MatchedByName   = $entry.name
        DownloadUrl     = $downloadUrl
        AppType         = $appType
    }
}

Write-Host "Manifest search path: $ManifestPath" -ForegroundColor DarkGray

# ---------------------------------------------------------------------------
# 5. ENRICH - match each installed app against the offline manifest.
#
#    IMPORTANT NOTICE:
#    This script ONLY scans software that is ALREADY INSTALLED and REGISTERED
#    on your Windows system.  Portable applications, non-registered tools,
#    web-only services, and apps you plan to use on Linux that are not yet
#    installed will NOT be detected automatically.
#
#    You can MANUALLY add any such applications to the output CSV file
#    (B_installed_windows_software.csv) after this script finishes.
#
#    Apps NOT found in B_applications.json are flagged with a WARNING and
#    their curated columns are set to "Needs Review" / "Not in manifest".
# ---------------------------------------------------------------------------

$matched   = 0
$unmatched = 0
$warnings  = @()

$enriched = foreach ($app in $deduped) {
    $name  = $app.Name
    $kb    = Get-OfflineManifest -AppName $name

    if (-not $kb) {
        $unmatched++
        $warningMsg = "WARNING: '$name' was NOT FOUND in B_applications.json. Curated columns set to 'Needs Review'. You may manually edit the output CSV to add proper alternatives."
        Write-Warning $warningMsg
        $warnings += $warningMsg

        # Placeholder for unmatched apps
        [PSCustomObject]@{
            Name                          = $name
            Version                       = [string]$app.Version
            Publisher                     = [string]$app.Publisher
            Source                        = $app.Source
            'Linux Availability'          = 'Needs Review - NOT IN MANIFEST'
            'Best Linux Alternative'      = 'Not in manifest - research manually or add to B_applications.json'
            'Alternative Competency'      = ''
            'Pricing model'               = ''
            'Must be included on Linux'   = 'no'
            'Can be synched to Linux alternative' = 'No, manual transfer'
            'Linux Alternative Type'      = ''
            'Download URL'                = ''
        }
    }
    else {
        $matched++

        # Determine MustInclude
        $mustInclude = if ($kb.Competency -ge $MustIncludeThreshold) { 'yes' } else { 'no' }

        [PSCustomObject]@{
            Name                          = $name
            Version                       = [string]$app.Version
            Publisher                     = [string]$app.Publisher
            Source                        = $app.Source
            'Linux Availability'          = $kb.Availability
            'Best Linux Alternative'      = $kb.BestAlternative
            'Alternative Competency'      = $kb.Competency
            'Pricing model'               = $kb.PricingModel
            'Must be included on Linux'   = $mustInclude
            'Can be synched to Linux alternative' = $kb.Syncability
            'Linux Alternative Type'      = $kb.AppType
            'Download URL'                = $kb.DownloadUrl
        }
    }
}

# ---------------------------------------------------------------------------
# 5b. POST-MATCH SUMMARY - print to console
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '==================== MATCH SUMMARY ====================' -ForegroundColor Yellow
Write-Host "Total installed apps scanned       : $($deduped.Count)" -ForegroundColor Cyan
Write-Host "  Matched in B_applications.json    : $matched"        -ForegroundColor Green
Write-Host "  NOT found in manifest (WARNING)   : $unmatched"       -ForegroundColor Red
if ($unmatched -gt 0) {
    Write-Host ''
    Write-Host '==============================================================' -ForegroundColor Yellow
    Write-Host 'IMPORTANT NOTICE:'                                              -ForegroundColor Yellow
    Write-Host '  This script ONLY scans software that is ALREADY INSTALLED'     -ForegroundColor Yellow
    Write-Host '  and REGISTERED on your Windows system.'                        -ForegroundColor Yellow
    Write-Host ''                                                                -ForegroundColor Yellow
    Write-Host '  Applications NOT found in the manifest are marked with'        -ForegroundColor Yellow
    Write-Host '  "Needs Review" in the output CSV.  You can MANUALLY edit'      -ForegroundColor Yellow
    Write-Host '  the CSV file to add proper Linux alternatives, or you can'     -ForegroundColor Yellow
    Write-Host '  add entries to B_applications.json and re-run this script.'    -ForegroundColor Yellow
    Write-Host ''                                                                -ForegroundColor Yellow
    Write-Host '  Portable apps, non-registered tools, and web-only services'    -ForegroundColor Yellow
    Write-Host '  are NOT detected by this script.  Add them to the CSV'         -ForegroundColor Yellow
    Write-Host '  manually if you need their Linux alternatives evaluated.'      -ForegroundColor Yellow
    Write-Host '==============================================================' -ForegroundColor Yellow
    Write-Host ''
    foreach ($w in $warnings) {
        Write-Host $w -ForegroundColor DarkYellow
    }
}
Write-Host '=======================================================' -ForegroundColor Yellow

# ---------------------------------------------------------------------------
# 6. EXPORT - write the enriched CSV
# ---------------------------------------------------------------------------
Write-Host "Writing CSV to $OutputPath ..." -ForegroundColor Cyan
try {
    $enriched | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
    Write-Host "OK - CSV written with $($enriched.Count) rows." -ForegroundColor Green
    Write-Host "  File: $OutputPath" -ForegroundColor Green
    Write-Host ""
}
catch {
    Write-Error "Failed to write CSV: $_"
    exit 3
}

# Summary stats
if ($unmatched -gt 0) {
    Write-Host "REMINDER: $unmatched app(s) were NOT found in B_applications.json." -ForegroundColor Yellow
    Write-Host "  Their curated columns are placeholder values." -ForegroundColor Yellow
    Write-Host "  You may manually edit the CSV to fill in proper alternatives," -ForegroundColor Yellow
    Write-Host "  or add entries to B_applications.json and re-run this script." -ForegroundColor Yellow
    Write-Host ""
}

Write-Host "Done." -ForegroundColor Green
