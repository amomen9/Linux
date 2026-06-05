<#
.SYNOPSIS
    Inventories all real installed software on Windows and rates how each app can be
    used on Linux: availability flags, the best alternative, an estimated performance
    competency, the Linux pricing model, and whether it is worth installing on Linux.

.DESCRIPTION
    The script produces installed_windows_software.csv with 9 columns:

      MACHINE-DERIVED (read live from this PC, never hand-authored):
        Name                       human-friendly product name
        Version                    installed version
        Publisher                  vendor
        Source                     Win32 (registry) or Store (UWP/Appx)

      KNOWLEDGE-DERIVED (curated in the $LinuxKB table below / derived in code):
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
        Must be included on Linux  yes/no — DERIVED by the script: "yes" for the most
                                   competent installable option per product (native or
                                   alternative) whose competency >= -MustIncludeThreshold

    How the data is sourced (honouring "fill the judgement columns by tweaking, not by
    pretending the PC reported them"): the four curated columns come from the $LinuxKB
    knowledge base (researched from the web, June 2026) — the single place to tweak —
    while "Must be included on Linux" is computed from the competency figures. The
    machine columns are always read fresh from the registry / Appx and are never edited.

    Noise removed before rating: Windows updates / hotfixes / KBs, and (unless
    -IncludeSystemComponents) redistributables, runtimes, drivers and SDK fragments.

.PARAMETER OutputPath
    CSV path. Default: installed_windows_software.csv beside this script.
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
    .\detect_installed_windows_software.ps1
    .\detect_installed_windows_software.ps1 -Online -MustIncludeThreshold 80
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

# Resolve the output path robustly: prefer the script's own folder, then the folder
# of the running command, then the current directory.
if (-not $OutputPath) {
    $scriptDir = $PSScriptRoot
    if (-not $scriptDir -and $PSCommandPath)            { $scriptDir = Split-Path -Parent $PSCommandPath }
    if (-not $scriptDir -and $MyInvocation.MyCommand.Path) { $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
    if (-not $scriptDir)                               { $scriptDir = (Get-Location).Path }
    $OutputPath = Join-Path $scriptDir 'installed_windows_software.csv'
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
# 4. KNOWLEDGE BASE  -- availability (S), best alternative (A),
#    competency % (C) and Linux pricing model (Pr).
#    First matching pattern wins, so list specific entries before generic ones.
# ---------------------------------------------------------------------------
$LinuxKB = @(
    # --- Browsers ---
    @{P='Google Chrome';                 S='Available on Linux';                                 A=''; C=100; Pr='Free'}
    @{P='Microsoft Edge';                S='Available on Linux';                                 A=''; C=98;  Pr='Free'}
    @{P='Mozilla Firefox|Firefox';       S='Available on Linux';                                 A=''; C=100; Pr='Free (FOSS)'}

    # --- Communication / meetings ---
    @{P='Discord';                       S='Available on Linux';                                 A=''; C=100; Pr='Free'}
    @{P='Zoom';                          S='Available on Linux';                                 A=''; C=98;  Pr='Freemium'}
    @{P='Cisco Jabber';                  S='Not Available; Available as WebApp';                 A='Cisco Webex (native Linux) or Jami / Linphone (FOSS SIP)'; C=85; Pr='Freemium'}
    @{P='Teams';                         S='Available as WebApp; Native Alternative';            A='Teams PWA via Edge/Chrome (Microsoft-recommended); or the unofficial "teams-for-linux" app'; C=85; Pr='Freemium'}

    # --- Cloud storage / sync ---
    @{P='Dropbox';                       S='Available on Linux';                                 A=''; C=100; Pr='Freemium'}
    @{P='Google Drive';                  S='Native Alternative; Available as WebApp';            A='Insync (paid GUI) or rclone (free CLI); GNOME Online Accounts for basic mounting'; C=85; Pr='Free (FOSS)'}
    @{P='OneDrive';                      S='Native Alternative; Available as WebApp';            A='abraunegg "onedrive" client (free, full sync) or Insync / rclone'; C=88; Pr='Free (FOSS)'}
    @{P='Quick Share';                   S='Native Alternative';                                 A='LocalSend, or "Packet" / RQuickShare (brings Google Quick Share to Linux)'; C=105; Pr='Free (FOSS)'}

    # --- Developer tools ---
    @{P='Visual Studio Code';            S='Available on Linux';                                 A=''; C=100; Pr='Free'}
    @{P='Visual Studio Build Tools';     S='Native Alternative';                                 A='.NET SDK (`dotnet` CLI), MSBuild via Mono, or build with gcc/clang + make/CMake'; C=95; Pr='Free'}
    @{P='Visual Studio Community|Visual Studio \d|Visual Studio 20'; S='Not Available; Native Alternative'; A='VS Code or JetBrains Rider + .NET SDK CLI (all native on Linux)'; C=85; Pr='Freemium'}
    @{P='GitHub Desktop';                S='Not Available; Native Alternative';                  A='GitKraken, or the "github-desktop-plus" community fork; gitg / Git Cola for FOSS'; C=85; Pr='Freemium'}
    @{P='^Git\b|^Git$|^Git ';            S='Available on Linux';                                 A=''; C=100; Pr='Free (FOSS)'}
    @{P='Docker Desktop';                S='Available on Linux';                                 A='Docker Desktop for Linux, or native Docker Engine / Podman (no VM needed)'; C=120; Pr='Free (FOSS)'}
    @{P='DBeaver';                       S='Available on Linux';                                 A=''; C=100; Pr='Freemium'}
    @{P='pgAdmin';                       S='Available on Linux';                                 A=''; C=100; Pr='Free (FOSS)'}
    @{P='pgNow';                         S='Native Alternative';                                 A='pgAdmin 4, DBeaver, or the psql CLI'; C=95; Pr='Free (FOSS)'}
    @{P='SQL Server Management Studio';  S='Not Available; Native Alternative; Linux Docker';    A='DBeaver or VS Code "mssql" extension as the client; run SQL Server itself via Docker (mcr.microsoft.com/mssql/server)'; C=80; Pr='Free (FOSS)'}
    @{P='CMake';                         S='Available on Linux';                                 A=''; C=100; Pr='Free (FOSS)'}
    @{P='^ninja';                        S='Available on Linux';                                 A=''; C=100; Pr='Free (FOSS)'}
    @{P='Node\.js';                      S='Available on Linux';                                 A=''; C=100; Pr='Free (FOSS)'}
    @{P='Anaconda';                      S='Available on Linux';                                 A=''; C=100; Pr='Freemium'}
    @{P='^Python';                       S='Available on Linux';                                 A='python3 is pre-installed; manage versions with pyenv'; C=105; Pr='Free (FOSS)'}
    @{P='^R for Windows|^R \d|^R$';      S='Available on Linux';                                 A=''; C=100; Pr='Free (FOSS)'}
    @{P='RStudio';                       S='Available on Linux';                                 A=''; C=100; Pr='Free (FOSS)'}
    @{P='PowerShell 7';                  S='Available on Linux';                                 A=''; C=100; Pr='Free (FOSS)'}
    @{P='OpenSSH';                       S='Available on Linux';                                 A='OpenSSH client/server is standard on Linux'; C=100; Pr='Free (FOSS)'}
    @{P='OpenSSL';                       S='Available on Linux';                                 A='OpenSSL is pre-installed'; C=100; Pr='Free (FOSS)'}
    @{P='OpenVPN';                       S='Available on Linux';                                 A=''; C=100; Pr='Free (FOSS)'}
    @{P='Strawberry Perl|Perl';          S='Available on Linux';                                 A='Perl is pre-installed; add modules with cpanminus'; C=100; Pr='Free (FOSS)'}
    @{P='MiKTeX';                        S='Available on Linux; Native Alternative';             A='MiKTeX has a Linux build, or use TeX Live (the Linux standard)'; C=100; Pr='Free (FOSS)'}
    @{P='Pandoc';                        S='Available on Linux';                                 A=''; C=100; Pr='Free (FOSS)'}
    @{P='wkhtmltox|wkhtmltopdf';         S='Available on Linux';                                 A=''; C=100; Pr='Free (FOSS)'}
    @{P='Gurobi';                        S='Available on Linux';                                 A='Gurobi runs natively on Linux (commercial; free academic license)'; C=100; Pr='Paid'; F='HiGHS, SCIP, Google OR-Tools or GLPK'}
    @{P='Java \d|Java\(TM\)|^JDK|^JRE';  S='Available on Linux; Native Alternative';             A='OpenJDK (e.g. Eclipse Temurin / "openjdk-*-jdk" packages)'; C=100; Pr='Free (FOSS)'}
    @{P='\.NET SDK';                     S='Available on Linux';                                 A=''; C=100; Pr='Free (FOSS)'}
    @{P='GnuWin32: Grep|^Grep';          S='Available on Linux';                                 A='GNU grep is pre-installed'; C=100; Pr='Free (FOSS)'}
    @{P='MobaXterm';                     S='Native Alternative; Windows Emulator (Wine/Proton)'; A='Built-in terminal + OpenSSH; Remmina (RDP/VNC/SSH), Tabby, or Termius'; C=90; Pr='Free (FOSS)'}
    @{P='PuTTY';                         S='Available on Linux';                                 A='PuTTY is packaged for Linux, though native `ssh` is the norm'; C=100; Pr='Free (FOSS)'}
    @{P='Bitvise SSH';                   S='Not Available; Native Alternative';                  A='OpenSSH (ssh/sftp/scp), Termius, or FileZilla for SFTP'; C=95; Pr='Free (FOSS)'}
    @{P='Proxifier';                     S='Not Available; Native Alternative';                  A='proxychains-ng or redsocks'; C=75; Pr='Free (FOSS)'}
    @{P='RealVNC|VNC Viewer';            S='Available on Linux';                                 A=''; C=95; Pr='Freemium'}
    @{P='AnyDesk';                       S='Available on Linux';                                 A=''; C=97; Pr='Freemium'}
    @{P='Parsec';                        S='Available on Linux';                                 A=''; C=95; Pr='Freemium'}
    @{P='VMware Workstation';            S='Available on Linux';                                 A='VMware Workstation Pro for Linux (now free) — or KVM/virt-manager, VirtualBox'; C=100; Pr='Free'}

    # --- Media / utilities ---
    @{P='calibre';                       S='Available on Linux';                                 A=''; C=100; Pr='Free (FOSS)'}
    @{P='Anki';                          S='Available on Linux';                                 A=''; C=100; Pr='Free (FOSS)'}
    @{P='KMPlayer';                      S='Not Available; Native Alternative';                  A='VLC or mpv'; C=150; Pr='Free (FOSS)'}
    @{P='K-Lite|Codec Pack';             S='Not Available';                                      A='Not needed on Linux — VLC/mpv + GStreamer/ffmpeg cover all codecs'; C=100; Pr='Free (FOSS)'}
    @{P='oCam';                          S='Not Available; Native Alternative';                  A='OBS Studio or SimpleScreenRecorder (record); Flameshot (stills)'; C=110; Pr='Free (FOSS)'}
    @{P='Camtasia';                      S='Not Available; Native Alternative';                  A='OBS Studio (capture) + Kdenlive / Shotcut (edit); or ScreenPal (web)'; C=85; Pr='Free (FOSS)'}
    @{P='Lightshot';                     S='Not Available; Native Alternative';                  A='Flameshot (or Spectacle / Ksnip)'; C=115; Pr='Free (FOSS)'}
    @{P='WinRAR';                        S='Not Available; Native Alternative';                  A='p7zip / PeaZip / Ark (GUI); `rar`/`unrar` CLI also available'; C=95; Pr='Free (FOSS)'}
    @{P='Torrent';                       S='Not Available; Native Alternative';                  A='qBittorrent (or Transmission / Deluge)'; C=130; Pr='Free (FOSS)'}
    @{P='Internet Download Manager';     S='Not Available; Native Alternative';                  A='uGet (closest match) or Free Download Manager / JDownloader 2 / XDM; aria2 for CLI'; C=85; Pr='Free (FOSS)'}
    @{P='Notepad\+\+';                   S='Native Alternative; Windows Emulator (Wine/Proton)'; A='Notepadqq, Geany, Kate or VS Code; Notepad++ also runs well under Wine'; C=95; Pr='Free (FOSS)'}

    # --- Office / productivity / writing ---
    @{P='Microsoft 365|Microsoft Office|Office \d|^Office'; S='Available as WebApp; Native Alternative; Windows Emulator (Wine/Proton)'; A='Office for the web (office.com); or LibreOffice / OnlyOffice / WPS Office (native)'; C=78; Pr='Free (FOSS)'}
    @{P='OneNote';                       S='Available as WebApp; Native Alternative';            A='OneNote for the web; or Obsidian / Joplin / Xournal++'; C=85; Pr='Free (FOSS)'}
    @{P='Grammarly';                     S='Not Available; Available as WebApp; Native Alternative'; A='LanguageTool (FOSS desktop + browser); or Grammarly browser extension / web'; C=80; Pr='Freemium'}
    @{P='Reverso';                       S='Available as WebApp; Native Alternative';            A='reverso.net (web); GoldenDict for offline dictionary/translation'; C=80; Pr='Freemium'}
    @{P='Longman Dictionary';            S='Not Available; Native Alternative';                  A='GoldenDict / GoldenDict-ng (can load the Longman dictionary files)'; C=85; Pr='Free (FOSS)'}
    @{P='Babylon';                       S='Not Available; Native Alternative';                  A='GoldenDict (reads Babylon .BGL dictionaries)'; C=90; Pr='Free (FOSS)'}
    @{P='AlterEgo|Lexique';              S='Not Available; Native Alternative; Windows Emulator (Wine/Proton)'; A='GoldenDict with the relevant dictionary files; or run under Wine'; C=65; Pr='Free (FOSS)'}
    @{P='QUICKfind';                     S='Not Available; Windows Emulator (Wine/Proton)';      A='GoldenDict / a StarDict reader; QUICKfind may run under Wine'; C=50; Pr='Free (FOSS)'}
    @{P='Copilot';                       S='Available as WebApp';                                A='copilot.microsoft.com (web/PWA); local LLMs via Ollama'; C=95; Pr='Freemium'}

    # --- VPN / DRM / e-learning ---
    @{P='SpotPlayer|Spot Player';        S='Available on Linux';                                 A='SpotPlayer has an Ubuntu/Linux build at spotplayer.ir'; C=95; Pr='Free'}
    @{P='Hotspot Shield';                S='Available on Linux; Native Alternative';             A='Hotspot Shield has an Ubuntu/Debian client; stronger FOSS option: Proton VPN (or Mullvad)'; C=105; Pr='Freemium'}
    @{P='Adobe AIR';                     S='Not Available';                                      A='Deprecated runtime (HARMAN AIR SDK only); most AIR apps have native/web replacements'; C=20; Pr='Free'}
    @{P='Adobe Connect';                 S='Available as WebApp';                                A='Adobe Connect in-browser; or Jitsi / BigBlueButton for FOSS web meetings'; C=85; Pr='Paid'}
    @{P='Adobe Digital Editions';        S='Not Available; Native Alternative';                  A='Thorium Reader (reads LCP DRM) or calibre + DeDRM; Foliate for DRM-free EPUB'; C=90; Pr='Free (FOSS)'}

    # --- Hardware / vendor utilities ---
    @{P='Lenovo Vantage|Lenovo Companion'; S='Not Available; Native Alternative';               A='No vendor app; use fwupd (firmware) and LenovoLegionLinux for Legion hardware'; C=40; Pr='Free (FOSS)'}
    @{P='Lenovo Go Central|Lenovo Professional Wireless'; S='Not Available';                     A='Vendor utility — usually no Linux app needed; Solaar for Logitech-style combos'; C=20; Pr='Free (FOSS)'}
    @{P='Legion Arena';                  S='Not Available; Native Alternative';                  A='Steam / Lutris / Heroic for games; LenovoLegionLinux for hardware control'; C=60; Pr='Free'}
    @{P='Samsung Magician';              S='Not Available; Native Alternative';                  A='smartmontools (SMART), nvme-cli, fwupd; Samsung Magician DC (bootable) for firmware'; C=55; Pr='Free (FOSS)'}
    @{P='Samsung Account';               S='Not Available; Available as WebApp';                 A='account.samsung.com (web)'; C=70; Pr='Free'}
    @{P='PaperCut';                      S='Available on Linux';                                 A='PaperCut ships a native Linux client'; C=95; Pr='Paid'; F='CUPS (built-in Linux printing) for basic needs'}
    @{P='Psiphon';                       S='Native Alternative';                                 A='Proton VPN, or Tor Browser / obfs4 bridges'; C=90; Pr='Freemium'}

    # --- More communication / accounts ---
    @{P='WhatsApp|Whats App';            S='Available as WebApp; Native Alternative';            A='web.whatsapp.com (PWA); native clients ZapZap or Whatsie'; C=90; Pr='Free'}
    @{P='Outlook';                       S='Available as WebApp; Native Alternative';            A='Thunderbird or Evolution (native); outlook.com (web)'; C=88; Pr='Free (FOSS)'}
    @{P='Claude';                        S='Available as WebApp';                                A='claude.ai (web/PWA); local LLMs via Ollama / Jan'; C=95; Pr='Freemium'}
    @{P='Nearby Share';                  S='Native Alternative';                                 A='LocalSend, or "Packet" / RQuickShare (Quick Share for Linux)'; C=105; Pr='Free (FOSS)'}

    # --- Store first-party small apps ---
    @{P='Rufus';                         S='Not Available; Native Alternative';                  A='GNOME Disks, balenaEtcher, Ventoy, Fedora Media Writer, or `dd`'; C=90; Pr='Free (FOSS)'}
    @{P='Windows Calculator';            S='Available on Linux';                                 A='GNOME Calculator / KCalc (pre-installed)'; C=100; Pr='Free (FOSS)'}
    @{P='Sticky Notes';                  S='Native Alternative';                                 A='Sticky (GNOME), KNotes, or Joplin'; C=95; Pr='Free (FOSS)'}
    @{P='Microsoft To Do';               S='Available as WebApp; Native Alternative';            A='to-do.microsoft.com (web); or Tasks.org / Planify / Super Productivity'; C=90; Pr='Free (FOSS)'}
    @{P='Windows Terminal';              S='Native Alternative';                                 A='GNOME Console/Terminal, Konsole, Tabby, or Ghostty (built-in on Linux)'; C=110; Pr='Free (FOSS)'}
    @{P='Sound Recorder';                S='Native Alternative';                                 A='GNOME Sound Recorder or Audacity'; C=100; Pr='Free (FOSS)'}
    @{P='Windows Camera';                S='Native Alternative';                                 A='Cheese, GNOME Snapshot, or Kamoso'; C=95; Pr='Free (FOSS)'}
    @{P='Windows Notepad';               S='Native Alternative';                                 A='GNOME Text Editor / gedit / Kate (pre-installed)'; C=110; Pr='Free (FOSS)'}
    @{P='^Paint$|Microsoft Paint';       S='Native Alternative';                                 A='GIMP, Krita, Pinta, or Drawing'; C=200; Pr='Free (FOSS)'}
    @{P='^Photos$|Windows Photos';       S='Native Alternative';                                 A='Shotwell, gThumb, GNOME Loupe, or digiKam'; C=100; Pr='Free (FOSS)'}
    @{P='Zune Music|Groove|Media Player';S='Native Alternative';                                 A='Rhythmbox, Lollypop, Elisa, or VLC'; C=110; Pr='Free (FOSS)'}
    @{P='Alarms';                        S='Native Alternative';                                 A='GNOME Clocks (or KDE Clock widget)'; C=100; Pr='Free (FOSS)'}
    @{P='PowerToys';                     S='Not Available; Native Alternative';                  A='Text Extractor: Frog (tenderowl.com/frog - shortcut-triggered OCR, select->extract, FOSS). Keyboard accents: ibus-typing-booster or Compose key (built-in). Color Picker: gpick / KColorChooser (shortcut->click to pick hex). File Locksmith: fuser / lsof (CLI) or GNOME File Locksmith. Find My Mouse: GNOME "Show Pointer Location" or KDE "Track Mouse". Image Resizer: right-click in Nautilus + nautilus-image-converter, or ImageMagick `convert`. Mouse Without Borders: Barrier / Input Leap (software KVM, FOSS). ZoomIt: KMag / Zoom (GNOME) or screen-recorder. Shortcut Guide: GNOME Super key overlay or KDE shortcuts cheat sheet'; C=95; Pr='Free (FOSS)'}
    @{P='Power ?Shell';                  S='Available on Linux';                                 A=''; C=100; Pr='Free (FOSS)'}
    @{P='Windows Store|Microsoft Store';  S='Native Alternative';                                A="Your distro's software center (GNOME Software / KDE Discover) + Flathub"; C=100; Pr='Free (FOSS)'}
    @{P='Bing';                          S='Available as WebApp';                                A='bing.com in any browser (or DuckDuckGo / Google)'; C=95; Pr='Free'}
    @{P='Weather';                       S='Available as WebApp; Native Alternative';            A='GNOME Weather / KWeather (native); or any weather website'; C=100; Pr='Free (FOSS)'}
    @{P='Power Automate';                S='Native Alternative';                                 A='No Linux client; use cron / systemd timers, n8n, or AutoKey for desktop macros'; C=65; Pr='Free (FOSS)'}
    @{P='Ubuntu \(WSL\)';                S='Available on Linux';                                 A='You are already on Linux — WSL is not needed'; C=100; Pr='Free (FOSS)'}

    # --- Hard-coded inclusions (always migrate these) ---
    @{P='Adobe Acrobat|Adobe Acrobat Pro|Acrobat DC|Adobe Acrobat DC'; S='Not Available; Native Alternative; Linux Docker'; A='Stirling PDF (FOSS, Docker or local JAR — full PDF toolkit: merge, split, OCR, sign, compress, convert) + PDF Arranger (native APT: merge/reorder/split) + LibreOffice Draw (edit). Free alternative to Acrobat Pro.'; C=90; Pr='Free (FOSS)'}
    @{P='Advanced IP Scanner';           S='Not Available; Native Alternative';                  A='Angry IP Scanner (java-based, official .deb at angryip.org — scans IPs + ports with GUI) or nmap + Zenmap / RustScan (CLI)'; C=105; Pr='Free (FOSS)'}
    @{P='Advanced Port Scanner';         S='Not Available; Native Alternative';                  A='RustScan (blazing-fast Rust port scanner, CLI) or Zenmap (nmap GUI) or Angry IP Scanner (covers both IP + port scanning)'; C=110; Pr='Free (FOSS)'}
    @{P='Telegram';                      S='Available on Linux';                                 A='telegram-desktop (APT/Flatpak/Snap — official client)'; C=100; Pr='Free (FOSS)'}
    @{P='Terminator';                    S='Available on Linux';                                 A='terminator (APT — feature-rich terminal emulator with tiling/grouping/broadcasting)'; C=100; Pr='Free (FOSS)'}
    @{P='WindTerm';                      S='Available on Linux';                                 A='WindTerm has a native Linux build (.deb/tarball from github.com/kingToolfish/WindTerm) — fast SSH/Telnet/Serial client with file manager'; C=98; Pr='Free'}
    @{P='WinDirStat';                    S='Native Alternative';                                 A='QDirStat (APT — Qt-based disk usage analyzer + cleanup, closest match to WinDirStat) or GNOME Disk Usage Analyzer / baobab (pre-installed on GNOME)'; C=95; Pr='Free (FOSS)'}
)

# Canonical flag order so the Linux Availability column is consistent on every row.
$FlagOrder = @(
    'Available on Linux', 'Not Available', 'Native Alternative',
    'Available as WebApp', 'Linux Docker', 'Windows Emulator (Wine/Proton)',
    'Needs Review'
)
function Format-Flags {
    param([string] $Status)
    $parts = $Status -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    $ordered = $parts | Sort-Object {
        $i = $FlagOrder.IndexOf($_)
        if ($i -lt 0) { 99 } else { $i }
    }
    return ($ordered -join '; ')
}

function Resolve-Linux {
    param([string] $Name)
    foreach ($entry in $LinuxKB) {
        if ($Name -match $entry.P) {
            return [pscustomobject]@{
                Status = $entry.S; Alt = $entry.A; Competency = $entry.C; Pricing = $entry.Pr; Free = $entry.F
            }
        }
    }
    return $null
}

# ---------------------------------------------------------------------------
# 4b. OPTIONAL ONLINE LOOKUP  -- repology.org for apps not in the KB
# ---------------------------------------------------------------------------
$repoCachePath = [System.IO.Path]::ChangeExtension($OutputPath, '.repology-cache.json')
$repoCache = @{}
if ($Online -and (Test-Path $repoCachePath)) {
    try { (Get-Content $repoCachePath -Raw | ConvertFrom-Json).PSObject.Properties |
            ForEach-Object { $repoCache[$_.Name] = $_.Value } } catch {}
}

function Resolve-LinuxOnline {
    param([string] $Name)
    $slug = ($Name.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
    $slug = ($slug -replace '-(x64|x86|64|32|bit|version|for|windows).*$', '')
    if (-not $slug) { return $null }
    if ($repoCache.ContainsKey($slug)) { return $repoCache[$slug] }

    $result = $null
    try {
        $headers = @{ 'User-Agent' = 'detect-installed-windows-software/3.0 (personal Linux migration audit)' }
        $resp = Invoke-RestMethod -Uri "https://repology.org/api/v1/project/$slug" -Headers $headers -TimeoutSec 15
        if ($resp -and $resp.Count -gt 0) {
            $repos = ($resp | ForEach-Object { $_.repo } | Sort-Object -Unique)
            $result = [pscustomobject]@{
                Status     = 'Available on Linux'
                Alt        = "Packaged on Linux (Repology: $($repos.Count) repos, e.g. $(( $repos | Select-Object -First 3) -join ', '))"
                Competency = 100
                Pricing    = 'Free (FOSS)'
                Free       = ''
            }
        } else {
            $result = [pscustomobject]@{ Status = 'Needs Review'; Alt = 'Not found on repology.org — check AlternativeTo'; Competency = $null; Pricing = ''; Free = '' }
        }
    } catch {
        $result = [pscustomobject]@{ Status = 'Needs Review'; Alt = "Online lookup failed: $($_.Exception.Message)"; Competency = $null; Pricing = '' }
    }
    $repoCache[$slug] = $result
    Start-Sleep -Milliseconds 700
    return $result
}

# ---------------------------------------------------------------------------
# 5. ENRICH
# ---------------------------------------------------------------------------
$enriched = foreach ($app in $deduped) {
    $hit = Resolve-Linux $app.Name
    if (-not $hit -and $Online) { $hit = Resolve-LinuxOnline $app.Name }

    $comp = $null
    if ($hit -and $null -ne $hit.Competency -and "$($hit.Competency)" -ne '') { $comp = [int]$hit.Competency }

    [pscustomobject]@{
        Name      = $app.Name
        Version   = $app.Version
        Publisher = $app.Publisher
        Source    = $app.Source
        Status    = Format-Flags $(if ($hit) { $hit.Status } else { 'Needs Review' })
        Alt       = if ($hit) { $hit.Alt }     else { '' }
        Comp      = $comp
        Pricing   = if ($hit) { $hit.Pricing } else { '' }
        Free      = if ($hit) { $hit.Free }    else { '' }
        Must      = 'no'
    }
}

# ---------------------------------------------------------------------------
# 5b. DERIVE "Must be included on Linux"
#     yes = the single most-competent INSTALLABLE option per product (native or
#     alternative) whose competency reaches the threshold. Web-only / not-available
#     rows are never "yes" (nothing to install); duplicate builds of one product
#     (e.g. three Python versions) yield a single "yes".
# ---------------------------------------------------------------------------
$claimed = @{}
foreach ($r in ($enriched |
        Sort-Object @{E={ if ($null -ne $_.Comp) { $_.Comp } else { -1 } }; Descending=$true},
                    @{E={ $_.Source -ne 'Win32' }})) {
    $installable = ($r.Status -match 'Available on Linux' -or $r.Status -match 'Native Alternative')
    $id = Get-IdentityKey $r.Name
    if ($installable -and $null -ne $r.Comp -and $r.Comp -ge $MustIncludeThreshold -and -not $claimed.ContainsKey($id)) {
        $r.Must = 'yes'
        $claimed[$id] = $true
    }
}

# ---------------------------------------------------------------------------
# 6. EXPORT  (fixed column order, including the user-named headings)
# ---------------------------------------------------------------------------
$rows = $enriched | Sort-Object Name | ForEach-Object {
    [pscustomobject]([ordered]@{
        'Name'                      = $_.Name
        'Version'                   = $_.Version
        'Publisher'                 = $_.Publisher
        'Source'                    = $_.Source
        'Linux Availability'        = $_.Status
        'Best Linux Alternative'    = $(
            # Task 1: if the recommended Linux option is paid, append the best free option.
            $a = $_.Alt
            if ($_.Pricing -eq 'Paid' -and $_.Free) {
                if ($a) { "$a; free alternative: $($_.Free)" } else { "Free alternative: $($_.Free)" }
            } else { $a }
        )
        'Alternative Competency'    = if ($null -ne $_.Comp) { "$($_.Comp)%" } else { '' }
        'Pricing model'             = $_.Pricing
        'Must be included on Linux' = $_.Must
    })
}

if ($Online) {
    try { $repoCache | ConvertTo-Json -Depth 5 | Set-Content -Path $repoCachePath -Encoding UTF8 } catch {}
}

$rows | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "Inventory written to: $OutputPath" -ForegroundColor Green
Write-Host ("Total apps listed : {0}" -f $rows.Count)
Write-Host ("Excluded as noise : {0} (updates/hotfixes" -f ($combined.Count - $filtered.Count)) -NoNewline
Write-Host $(if ($IncludeSystemComponents) { ')' } else { ' + system components)' })
Write-Host ("Must install (yes): {0}  (competency >= {1}%)" -f ($rows | Where-Object 'Must be included on Linux' -eq 'yes').Count, $MustIncludeThreshold)
Write-Host ""
$enriched | Group-Object {
        if ($_.Status -match '^Available on Linux') { 'Native on Linux' }
        elseif ($_.Status -match 'Native Alternative') { 'Has Linux alternative' }
        elseif ($_.Status -match 'WebApp')             { 'Web app only' }
        elseif ($_.Status -match 'Not Available')      { 'Not available' }
        else { 'Needs review' }
    } | Sort-Object Count -Descending |
    ForEach-Object { Write-Host ("  {0,-22} {1}" -f $_.Name, $_.Count) }
Write-Host ""
if (($enriched | Where-Object Status -eq 'Needs Review').Count -gt 0 -and -not $Online) {
    Write-Host "Tip: re-run with -Online to auto-classify the 'Needs Review' apps via repology.org" -ForegroundColor Yellow
}
