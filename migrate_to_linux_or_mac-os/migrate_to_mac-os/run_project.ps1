<#
.SYNOPSIS
    Project orchestrator that runs all detection and generation scripts in order:

      1. C_detect_windows_settings.ps1    (config -- Windows settings extraction)
      2. B_detect_installed_windows_software.ps1  (software -- installed apps)
      3. A_detect_installed_drivers.ps1   (driver -- device driver inventory)
      4. D_compile_and_generate_shell_script.ps1  (generates the universal .sh
                                                    installer set for all macOS versions)
      5. Generate "Supported Versions and Architechtures.txt" from the manifest (dynamic)

.DESCRIPTION
    Orchestrates the full Windows-to-macOS migration detection pipeline in one shot.

    Steps 1-3 (Windows) run the three detection scripts and write their CSV output
    to "migrate_to_mac-os/documents/".  Step 4 (Generator) reads those CSV files
    together with documents/B_applications.json and the root-level
    Additional_Manual_macOS_Software_Requirments.csv, then generates ONE universal
    shell-installer set (execute_all.sh, apply_settings.sh,
    install_must_have_software.sh, install_device_drivers.sh) into the
    "Execute on macOS!" folder.  The generated scripts detect the running macOS
    release (Catalina 10.15 through the latest) and the CPU architecture (Apple
    Silicon arm64 / Intel x86_64) at runtime, so the same set runs on every
    supported macOS version and on both architectures.

    Step 5 reads the manifest (B_applications.json) and dynamically generates
    "Supported Versions and Architechtures.txt", reflecting exactly which macOS
    releases and architectures are supported and how complete the per-channel
    (Cask / formula / Mac App Store / MacPorts) coverage is.

    If any detection script fails the pipeline stops immediately unless
    -ContinueOnError is supplied.

.PARAMETER OutputDir
    Directory where all three CSV files will be written.
    Default: the "documents" subfolder of the migrate_to_mac-os folder.

.PARAMETER ContinueOnError
    If set, the pipeline continues with the next script even when one fails.
    Default: stop on first failure.

.PARAMETER MustIncludeThreshold
    Minimum Alternative Competency (%) for "Must be included on macOS" = yes in
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

    # Full pipeline (detection + generation + everything), but the step-6 backup runs
    # AUTOMATICALLY: the "Back up ... now?" question is auto-answered YES with no timeout
    # wait, and E_'s low-disk-space confirmation is auto-answered YES too (-AssumeYes).
    # Every OTHER prompt (e.g. the transfer password) behaves normally.
    # Usable as -DataBackup or the literal --data-backup.
    [switch] $DataBackup,

    # Backup-ONLY mode: skip detection/generation and just create the data-backup archive in
    # the default location (Desktop) with NO prompts at all -- not even the low-disk-space
    # confirmation. Encrypts only if -EncPwd/--enc_pwd is supplied; otherwise unencrypted.
    # Usable as -DataBackupOnly or the literal --data-backup-only.
    [switch] $DataBackupOnly,

    # Backup archive format (forwarded to E_): 'zip' (default; AES-256 zip via 7-Zip),
    # '7z' (AES-256 7z, encrypted headers) or 'enctar' (tar+gzip+OpenSSL). --archive-format[=]VALUE.
    [ValidateSet('zip', '7z', 'enctar')]
    [string] $ArchiveFormat = 'zip',

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
# Accept the literal "--data-backup" / "--data-backup-only" / "--archive-format" forms.
if ($ExtraArgs) {
    for ($i = 0; $i -lt $ExtraArgs.Count; $i++) {
        $a = [string]$ExtraArgs[$i]
        if ($a -eq '--data-backup-only') { $DataBackupOnly = $true }
        elseif ($a -eq '--data-backup')  { $DataBackup = $true }
        elseif ($a -like '--archive-format=*') { $ArchiveFormat = $a.Substring(17) }
        elseif ($a -eq '--archive-format' -and ($i + 1) -lt $ExtraArgs.Count) { $ArchiveFormat = [string]$ExtraArgs[$i + 1]; $i++ }
    }
}
if ($ArchiveFormat -notin @('zip', '7z', 'enctar')) { $ArchiveFormat = 'zip' }
# Backup-ONLY mode reuses the existing skip logic so detection (1-3) and generation (4) are
# bypassed; only the step-6 backup runs (step 5 is guarded separately below). The plain
# --data-backup runs the FULL pipeline and only auto-confirms the step-6 prompts.
if ($DataBackupOnly) { $SkipDetection = $true; $SkipGenerator = $true }

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
$scriptBackup    = Join-Path $submodulesDir 'E_backup_user&application_data.ps1'

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
# which would break paths like "Execute on macOS!".
function Get-ArgLine {
    param([object[]] $Tokens)
    ($Tokens | ForEach-Object {
        $s = [string] $_
        if ($s -match '\s') { '"' + $s + '"' } else { $s }
    }) -join ' '
}

# ===========================================================================
# FUNCTION: Write-SupportedVersions
# ---------------------------------------------------------------------------
# Reads B_applications.json and dynamically generates
# "Supported Versions and Architechtures.txt": which macOS releases and CPU
# architectures the generated installer supports, and how completely the manifest
# covers each install channel (Homebrew Cask / Homebrew formula / Mac App Store /
# MacPorts).
# ===========================================================================
function Write-SupportedVersions {
    param(
        [string] $ManifestPath,
        [string] $OutputPath
    )

    if (-not (Test-Path $ManifestPath)) {
        Write-Warning "Manifest not found at '$ManifestPath'.  Skipping Supported Versions generation."
        return
    }

    Write-Host "  Scanning manifest for per-channel install entries..." -ForegroundColor Gray

    # ---- macOS release metadata ----
    # Rank 1 = newest.  $releaseOrder drives the render order of EVERY list in this
    # file, so the whole report reads newest-first (what a new Mac actually runs).
    $releaseDefs = @{
        'Tahoe' = [ordered]@{
            Rank      = 1
            Version   = '26'
            Darwin    = '25.x'
            Released  = '2025'
            BestFor   = 'The current release: newest hardware, newest APIs (safe default)'
            Arch      = 'Apple Silicon + Intel'
            Note      = $null
        }
        'Sequoia' = [ordered]@{
            Rank      = 2
            Version   = '15'
            Darwin    = '24.x'
            Released  = '2024'
            BestFor   = 'Previous release, still fully supported by Apple and Homebrew'
            Arch      = 'Apple Silicon + Intel'
            Note      = $null
        }
        'Sonoma' = [ordered]@{
            Rank      = 3
            Version   = '14'
            Darwin    = '23.x'
            Released  = '2023'
            BestFor   = 'Widely deployed; the oldest release Homebrew still builds bottles for on some formulae'
            Arch      = 'Apple Silicon + Intel'
            Note      = $null
        }
        'Ventura' = [ordered]@{
            Rank      = 4
            Version   = '13'
            Darwin    = '22.x'
            Released  = '2022'
            BestFor   = 'Older Intel Macs and early Apple Silicon still on a supported OS'
            Arch      = 'Apple Silicon + Intel'
            Note      = 'Out of Apple security support; Homebrew builds fewer bottles, so some formulae compile from source.'
        }
        'Monterey' = [ordered]@{
            Rank      = 5
            Version   = '12'
            Darwin    = '21.x'
            Released  = '2021'
            BestFor   = '2015-2017 Intel Macs kept on their last supported release'
            Arch      = 'Apple Silicon + Intel'
            Note      = 'Homebrew treats it as a Tier-3 (best-effort) platform: expect source builds and the occasional unavailable cask.'
        }
        'Big Sur' = [ordered]@{
            Rank      = 6
            Version   = '11'
            Darwin    = '20.x'
            Released  = '2020'
            BestFor   = 'The first Apple Silicon release; oldest OS with universal-binary support'
            Arch      = 'Apple Silicon + Intel'
            Note      = 'Homebrew Tier 3. Many current casks declare a higher minimum, so apps with a minOS above 11 are skipped with a clear reason.'
        }
        'Catalina' = [ordered]@{
            Rank      = 7
            Version   = '10.15'
            Darwin    = '19.x'
            Released  = '2019'
            BestFor   = 'The floor this toolkit targets: the last release before the 32-bit runtime was removed'
            Arch      = 'Intel only'
            Note      = 'macOS dropped 32-bit support here, so wine cannot run 32-bit Windows installers on this or any newer release. Homebrew no longer provides bottles; installs build from source.'
        }
    }
    # Render order for every list below: newest release first.
    $releaseOrder = @('Tahoe', 'Sequoia', 'Sonoma', 'Ventura', 'Monterey', 'Big Sur', 'Catalina')

    $channelDefs = [ordered]@{
        'cask' = @{ Name = 'Homebrew Cask';   Cmd = 'brew install --cask'; What = 'GUI applications (the primary channel)' }
        'brew' = @{ Name = 'Homebrew formula'; Cmd = 'brew install';        What = 'CLI / developer tools' }
        'mas'  = @{ Name = 'Mac App Store';    Cmd = 'mas install';         What = 'Store-only applications' }
        'port' = @{ Name = 'MacPorts';         Cmd = 'port install';        What = 'alternative package manager (optional fallback)' }
    }
    $channelOrder = @('cask', 'brew', 'mas', 'port')

    # ---- Scan manifest ----
    $manifest = Get-Content -Raw -Path $ManifestPath | ConvertFrom-Json
    $apps = $manifest.applications

    $chCounts       = @{ cask = 0; brew = 0; port = 0; mas = 0 }
    $chReviewCounts = @{ cask = 0; brew = 0; port = 0; mas = 0 }
    $totalMustInclude = 0
    $hasArchConstraint = $false
    $archSet = @{}
    $minOsSet = @{}

    foreach ($app in $apps) {
        foreach ($alt in $app.alternatives) {
            $must = [string]$alt.mustInclude
            if ($must -notmatch '^(?i)\s*yes') { continue }

            $totalMustInclude++
            $install = $alt.install
            if (-not $install) { continue }
            $isReview = ($install.review -eq $true)

            # Homebrew Cask (the universal GUI channel) and the Mac App Store.
            if ($install.caskId) { $chCounts['cask']++; if ($isReview) { $chReviewCounts['cask']++ } }
            if ($install.masId)  { $chCounts['mas']++;  if ($isReview) { $chReviewCounts['mas']++ } }

            # Per-package-manager CLI entries.
            $native = $install.native
            if ($native) {
                foreach ($prop in $native.PSObject.Properties) {
                    $pm = $prop.Name
                    if ($chCounts.ContainsKey($pm) -and [string]$prop.Value) {
                        $chCounts[$pm]++
                        if ($isReview) { $chReviewCounts[$pm]++ }
                    }
                }
            }

            # Architecture constraints.
            $archField = $install.arch
            if ($archField) {
                $hasArchConstraint = $true
                foreach ($a in $archField) { $archSet[$a] = $true }
            }
            # Minimum macOS version constraints (cross-version support).
            $minOs = [string]$install.minOS
            if ($minOs) { $minOsSet[$minOs] = 1 + [int]$minOsSet[$minOs] }
        }
    }

    # ---- Assemble output ----
    $lines = New-Object System.Collections.Generic.List[string]

    $lines.Add('============================================================================')
    $lines.Add('  SUPPORTED macOS VERSIONS AND ARCHITECTURES')
    $lines.Add(('  (Auto-generated from manifest: {0:yyyy-MM-dd HH:mm})' -f (Get-Date)))
    $lines.Add('============================================================================')
    $lines.Add('')
    $lines.Add('This file is generated by run_project.ps1 by scanning the install descriptors')
    $lines.Add('in documents/B_applications.json, together with the macOS release and CPU')
    $lines.Add('architecture matrix the generated installer detects at runtime.')
    $lines.Add('')
    $lines.Add('The generated installer in "Execute on macOS!/" is UNIVERSAL: ONE script set')
    $lines.Add('runs on every macOS version and on both CPU architectures.  At start-up it')
    $lines.Add('reads the release from sw_vers and the architecture from uname -m (plus')
    $lines.Add('sysctl.proc_translated, so a Rosetta shell on an Apple Silicon Mac is still')
    $lines.Add('recognised as arm64) and dispatches accordingly.')
    $lines.Add('')
    $lines.Add('Application delivery is CASK-FIRST (a Homebrew Cask token is identical on')
    $lines.Add('every macOS version and on both architectures -- Homebrew picks the matching')
    $lines.Add('build itself).  Homebrew formulae cover CLI/developer tools, the Mac App')
    $lines.Add('Store (mas) covers Store-only apps, and MacPorts is honoured when it is the')
    $lines.Add('package manager the machine actually has.')
    $lines.Add('')
    $lines.Add('----------------------------------------------------------------------------')
    $lines.Add('  OVERVIEW  (newest release first)')
    $lines.Add('----------------------------------------------------------------------------')
    $lines.Add('')
    $lines.Add('  #  RELEASE (version)           BEST FOR')
    $lines.Add('  -- ---------------------------- ------------------------------------------')
    foreach ($rel in $releaseOrder) {
        $def = $releaseDefs[$rel]
        $relCol = '{0} ({1})' -f $rel, $def.Version
        $lines.Add(('  {0,-2} {1,-28} {2}' -f $def.Rank, $relCol, $def.BestFor))
    }
    $lines.Add('')
    $lines.Add('----------------------------------------------------------------------------')
    $lines.Add('  RELEASE            macOS VERSION     ARCHITECTURES')
    $lines.Add('----------------------------------------------------------------------------')
    $lines.Add('')

    foreach ($rel in $releaseOrder) {
        $def = $releaseDefs[$rel]
        $lines.Add(('  [ {0} ] macOS {1,-16} {2}' -f $rel, $def.Version, $def.Arch))
        $lines.Add(('    Released: {0}   Darwin kernel: {1}' -f $def.Released, $def.Darwin))
        $lines.Add(('    Best for: {0}' -f $def.BestFor))
        if ($def.Note) { $lines.Add("    Note: $($def.Note)") }
        $lines.Add('')
    }
    $lines.Add('  Newer releases than the ones listed above are supported automatically: the')
    $lines.Add('  installer never rejects an unknown version, it just reports it as')
    $lines.Add('  "macOS <major>" and continues, because the tooling it drives (Homebrew,')
    $lines.Add('  defaults, networksetup, launchctl, pfctl) is version-stable.')
    $lines.Add('')

    $lines.Add('----------------------------------------------------------------------------')
    $lines.Add('  CPU ARCHITECTURES')
    $lines.Add('----------------------------------------------------------------------------')
    $lines.Add('')
    $lines.Add('  arm64   (Apple Silicon)  - fully supported.  M-series Macs; Homebrew lives')
    $lines.Add('                             in /opt/homebrew and serves arm64 bottles.')
    $lines.Add('  x86_64  (Intel)          - fully supported.  Homebrew lives in /usr/local')
    $lines.Add('                             and serves Intel bottles.')
    $lines.Add('  Rosetta 2                - installed on demand on Apple Silicon so')
    $lines.Add('                             Intel-only apps (and wine) still run.')
    $lines.Add('')
    if ($archSet.Count -gt 0) {
        $explicitArchs = @($archSet.Keys)
        $lines.Add(('  ARCHITECTURE CONSTRAINT: {0} app(s) explicitly constrain to: {1}' -f $explicitArchs.Count, ($explicitArchs -join ', ')))
        $lines.Add('')
    }
    $lines.Add('  Notes:')
    $lines.Add('    - Homebrew Cask, Homebrew formula and Mac App Store installs are all')
    $lines.Add('      architecture-transparent: the same token gets the right build.')
    $lines.Add('    - Only direct downloads (.dmg/.pkg/.zip vendor assets) need an')
    $lines.Add('      architecture-specific URL; the installer picks it from `uname -m`.')
    $lines.Add('    - Windows-app compatibility (wine) is an x86_64 build, so on Apple')
    $lines.Add('      Silicon it runs through Rosetta 2, which is installed automatically.')
    $lines.Add('    - macOS removed the 32-bit runtime in Catalina, so 32-bit-only Windows')
    $lines.Add('      installers cannot run under wine on ANY supported release; those apps')
    $lines.Add('      are reported with CrossOver / a Windows VM as the recommended route.')
    $lines.Add('')

    $lines.Add('----------------------------------------------------------------------------')
    $lines.Add('  MINIMUM macOS VERSION REQUIRED BY INDIVIDUAL APPS')
    $lines.Add('----------------------------------------------------------------------------')
    $lines.Add('')
    if ($minOsSet.Count -gt 0) {
        $lines.Add('  Some applications need a newer macOS than the oldest release above. The')
        $lines.Add('  installer skips those with an explicit reason instead of failing:')
        foreach ($k in ($minOsSet.Keys | Sort-Object { [double]($_ -replace '[^0-9.]', '') } -Descending)) {
            $lines.Add(('    - macOS {0,-6} or newer : {1} app(s)' -f $k, $minOsSet[$k]))
        }
    } else {
        $lines.Add('  No application in the manifest declares a minimum macOS version, so every')
        $lines.Add('  app is attempted on every supported release.  Add "minOS" to an entry''s')
        $lines.Add('  install{} block to have it skipped cleanly on older Macs.')
    }
    $lines.Add('')

    $lines.Add('----------------------------------------------------------------------------')
    $lines.Add('  INSTALL CHANNELS  (ranked, most-used first)')
    $lines.Add('----------------------------------------------------------------------------')
    $lines.Add('')
    foreach ($ch in $channelOrder) {
        $def = $channelDefs[$ch]
        $count = $chCounts[$ch]
        $r = $chReviewCounts[$ch]
        $lines.Add(('  [ {0} ] {1,-22} {2} app(s)' -f $def.Name, $def.Cmd, $count))
        $lines.Add(('    Used for: {0}' -f $def.What))
        if ($r -gt 0) { $lines.Add(('    * {0} app(s) flagged for review on this channel' -f $r)) }
        $lines.Add('')
    }

    $lines.Add('----------------------------------------------------------------------------')
    $lines.Add('  COVERAGE NOTES')
    $lines.Add('----------------------------------------------------------------------------')
    $lines.Add('')
    $lines.Add(('  Of {0:N0} "must-include" applications in the manifest:' -f $totalMustInclude))
    foreach ($ch in $channelOrder) {
        $lines.Add(('    - {0,4} have {1} entries' -f $chCounts[$ch], $channelDefs[$ch].Name))
    }
    $lines.Add('')
    $lines.Add('  Homebrew Cask is the primary channel and the most heavily tested one: a cask')
    $lines.Add('  token works unchanged on every macOS version and on both architectures.')
    $lines.Add('  Mac App Store entries need you to be signed in to the App Store on this Mac.')
    $lines.Add('  MacPorts names are a best-effort fallback for machines that use MacPorts')
    $lines.Add('  instead of Homebrew; when a port name is absent the Homebrew formula name is')
    $lines.Add('  reused.  Entries flagged with ''review: true'' need verification on a real Mac.')
    $lines.Add('')

    # Determine the best-covered channel.
    $sorted = $chCounts.GetEnumerator() | Where-Object { $_.Value -gt 0 } | Sort-Object Value -Descending
    if ($sorted) {
        $bestCh = $sorted | Select-Object -First 1
        $lines.Add(('  Best-covered channel: {0} ({1} app(s)).' -f $channelDefs[$bestCh.Key].Name, $bestCh.Value))
    } else {
        $lines.Add('  No channel has entries in the manifest.  Review documents/B_applications.json')
        $lines.Add('  and add install{} descriptors (caskId / masId / native.brew) to enable them.')
    }
    $lines.Add('')
    $lines.Add('============================================================================')

    # Write with CRLF for readability on Windows (this report is read on the Windows
    # side); BOM-less UTF-8 so it also opens cleanly on macOS.
    $content = ($lines -join "`r`n")
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($OutputPath, $content, $enc)

    Write-Host ('  Channels with entries: {0}' -f (@($chCounts.Keys | Where-Object { $chCounts[$_] -gt 0 }) -join ', ')) -ForegroundColor White
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
$installerDir = Join-Path $scriptDir 'Execute on macOS!'

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
        PassThru          = $true
        ErrorAction       = if ($ContinueOnError) { 'SilentlyContinue' } else { 'Stop' }
    }

    try {
        # IMPORTANT: do NOT use Start-Process -Wait here. On Windows -Wait wraps the
        # child in a job object and blocks until the ENTIRE descendant tree exits, not
        # just the child script. Step 2 (B_detect) invokes docker_discovery.ps1, which
        # starts "Docker Desktop.exe" when the engine is not already running -- a
        # long-lived process that never exits, so -Wait would hang the whole pipeline
        # after the step already printed "Done." We instead wait on the direct process
        # only: caching .Handle keeps .ExitCode readable after it exits.
        $proc = Start-Process @baseArgs
        if ($proc) { $null = $proc.Handle; $proc.WaitForExit() }
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
    Invoke-Step -StepLabel '1/6  Config (Windows settings extraction)' `
                -ScriptPath $scriptConfig `
                -OutputPath $configOutput `
                -ExtraArgs { if ($forwardVerbose) { '-Verbose' } }
    Remove-Item Env:\MIGRATE_XFER_PWD -ErrorAction SilentlyContinue
    Remove-Item Env:\MIGRATE_XFER_PROMPTED -ErrorAction SilentlyContinue

    # -----------------------------------------------------------------------
    # 2. SOFTWARE  - B_detect_installed_windows_software.ps1
    # -----------------------------------------------------------------------
    $softwareOutput = Join-Path $OutputDir 'B_installed_windows_software.csv'
    Invoke-Step -StepLabel '2/6  Software (installed applications detection)' `
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
    Invoke-Step -StepLabel '3/6  Drivers (device driver inventory)' `
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
    Write-Host "  STEP: 4/6  Generator (universal installer set)" -ForegroundColor Yellow
    Write-Host "  Script: $scriptGenerator" -ForegroundColor Gray
    Write-Host "  Target: $installerDir" -ForegroundColor Gray
    Write-Host "$('=' * 70)" -ForegroundColor Cyan
    Write-Host ""

    try {
        $genTokens = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $scriptGenerator, '-OutputDir', $installerDir)
        # Wait on the direct process only (no -Wait job-object tree wait) -- see Invoke-Step.
        $genProc = Start-Process -FilePath $psExe -ArgumentList (Get-ArgLine $genTokens) -NoNewWindow -PassThru
        if ($genProc) { $null = $genProc.Handle; $genProc.WaitForExit() }
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
# 5. SUPPORTED VERSIONS AND ARCHITECTURES  - generate dynamically from manifest
# ---------------------------------------------------------------------------
$supportedVersionsPath = Join-Path $scriptDir 'Supported Versions and Architechtures.txt'

if (-not $DataBackupOnly) {
    Write-Host "`n$('=' * 70)" -ForegroundColor Cyan
    Write-Host "  STEP: 5/6  Supported Versions and Architectures (dynamic from manifest)" -ForegroundColor Yellow
    Write-Host "  Manifest: $manifestPath" -ForegroundColor Gray
    Write-Host "$('=' * 70)" -ForegroundColor Cyan
    Write-Host ""

    try {
        Write-SupportedVersions -ManifestPath $manifestPath -OutputPath $supportedVersionsPath
        Write-Host "  >> Generated: $(Split-Path -Leaf $supportedVersionsPath)" -ForegroundColor Green
    }
    catch {
        Write-Host "  >> Supported Versions and Architectures generation FAILED: $_" -ForegroundColor Red
        if (-not $ContinueOnError) {
            throw
        }
    }
}

# ---------------------------------------------------------------------------
# 6. BACKUP  - E_backup_user&application_data.ps1  (optional; y/n, default y)
# ---------------------------------------------------------------------------
Write-Host "`n$('=' * 70)" -ForegroundColor Cyan
Write-Host "  STEP: 6/6  Back up user & application data (optional)" -ForegroundColor Yellow
Write-Host "  Script: $scriptBackup" -ForegroundColor Gray
Write-Host "$('=' * 70)" -ForegroundColor Cyan
Write-Host ""

if (-not (Test-Path $scriptBackup)) {
    Write-Host "  >> E_backup script not found - skipping the data backup." -ForegroundColor Yellow
} else {
    Write-Host "  This can back up your important user files and application data into a" -ForegroundColor White
    Write-Host "  password-protected archive on your Desktop, ready to carry to your Mac." -ForegroundColor White
    Write-Host "  Note: it may take a long time and will not capture everything." -ForegroundColor DarkYellow

    $doBackup = $true
    if ($DataBackupOnly) {
        Write-Host "  [--data-backup-only] Creating the backup non-interactively (backup-only mode)." -ForegroundColor Gray
    }
    elseif ($DataBackup) {
        Write-Host "  [--data-backup] Auto-confirming the backup (yes, no timeout wait)." -ForegroundColor Gray
    }
    elseif (Get-Command Read-YNTimed -ErrorAction SilentlyContinue) {
        $doBackup = Read-YNTimed -Prompt "  Back up your important user & application data now? (y/n, default y, 15s): " -TimeoutSec 15 -Default $true
    }

    if ($doBackup) {
        try {
            $env:MIGRATE_XFER_PWD = $xferPwd
            $backupTokens = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $scriptBackup, '-ArchiveFormat', $ArchiveFormat)
            if ($DataBackup -or $DataBackupOnly) { $backupTokens += '-AssumeYes' }   # skip the low-space confirmation too
            # Wait on the direct process only (no -Wait job-object tree wait) -- see Invoke-Step.
            $bproc = Start-Process -FilePath $psExe -ArgumentList (Get-ArgLine $backupTokens) -NoNewWindow -PassThru
            if ($bproc) { $null = $bproc.Handle; $bproc.WaitForExit() }
            if ($bproc.ExitCode -ne 0) { Write-Warning "Backup step exited with code $($bproc.ExitCode)." }
            else { Write-Host "  >> Backup step completed." -ForegroundColor Green }
        }
        catch {
            Write-Host "  >> Backup step FAILED: $_" -ForegroundColor Red
            if (-not $ContinueOnError) { throw }
        }
        finally {
            Remove-Item Env:\MIGRATE_XFER_PWD -ErrorAction SilentlyContinue
        }
    } else {
        Write-Host "  >> Skipped the data backup." -ForegroundColor Yellow
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
if ($DataBackupOnly) {
    Write-Host "  Backup-only mode (--data-backup-only): the archive was created on your Desktop." -ForegroundColor White
    Write-Host "================================================================" -ForegroundColor Cyan
    return
}
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
    Write-Host "  Universal installer (one set, runs on every supported macOS version + architecture):" -ForegroundColor White
    Write-Host "    $installerDir\execute_all.sh" -ForegroundColor Gray
    Write-Host "    $installerDir\apply_settings.sh" -ForegroundColor Gray
    Write-Host "    $installerDir\install_must_have_software.sh" -ForegroundColor Gray
    Write-Host "    $installerDir\install_device_drivers.sh" -ForegroundColor Gray
}
Write-Host "  Supported Versions and Architectures:" -ForegroundColor White
Write-Host "    $supportedVersionsPath" -ForegroundColor Gray
Write-Host ""
Write-Host "  Next steps on your Mac:" -ForegroundColor Yellow
Write-Host "    1. Copy the 'Execute on macOS!' folder to your Mac."
Write-Host "    2. cd into 'Execute on macOS!'."
Write-Host "    3. Run:  sudo ./execute_all.sh"
Write-Host "================================================================" -ForegroundColor Cyan
