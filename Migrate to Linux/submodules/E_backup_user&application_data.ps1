<#
.SYNOPSIS
    Step 6 (Windows side): back up the user's important user-data and application
    data into ONE password-protected archive on the Desktop, ready to be carried to
    Linux and restored by "Execute on Linux!/submodules/restore_user_and_application_data.sh".

.DESCRIPTION
    Driven by documents/D_data_migration.json:
      * userProfile.inclusions  -> the static, default-important parts of C:\Users\<name>
      * applications.<key>.{userdir,system} -> the dynamic, app-specific data

    Files are collected verbatim (NEVER altered on Windows -- any path rewriting happens
    on the Linux side, reversibly), staged into a neat tree, then archived as
        tar  --(gzip -6, medium)-->  .tar.gz  --(openssl AES-256-CBC/PBKDF2)-->  .tar.gz.enc
    using the SAME transfer password as the rest of the toolkit. If no password was
    provided, an UNENCRYPTED .tar.gz is produced instead (the user chose this trade-off).

    Archive layout (so the restore script can classify every file):
        user/<relative path>           -> always restored verbatim into ~/
        apps/<slug>/userdir/<tree>     -> governed by userdir_safe_* for that app
        apps/<slug>/system/<tree>      -> governed by safe_* for that app

    ~/.ssh and Contacts are intentionally NOT included here -- C_detect already exports
    them inside the encrypted migrated_user_data archive. They are still listed in the
    report so the user sees the full picture.

.PARAMETER DataMigrationJson
    Path to documents/D_data_migration.json. Default: resolved relative to this script.

.PARAMETER OutputDir
    Where to drop the archive. Default: the current user's Desktop.

.PARAMETER EncPwd / -enc_pwd
    Transfer password. Normally inherited from $env:MIGRATE_XFER_PWD (set by run_project.ps1);
    this parameter lets the script run standalone.

.PARAMETER AssumeYes
    Skip the storage-space confirmation prompt (answer yes). Used for non-interactive runs.
#>
[CmdletBinding()]
param(
    [string] $DataMigrationJson,
    [string] $OutputDir,
    [Alias('enc_pwd')]
    [string] $EncPwd,
    [switch] $AssumeYes,
    # Archive format (accepts --archive-format[=]VALUE):
    #   'zip'    (DEFAULT) single-stage compress + AES-256 encrypt via 7-Zip -> .zip
    #   '7z'     single-stage compress + AES-256 encrypt (encrypted headers) via 7-Zip -> .7z
    #   'enctar' tar + gzip + OpenSSL AES-256-CBC/PBKDF2 -> .tar.gz(.enc)
    [ValidateSet('zip', '7z', 'enctar')]
    [string] $ArchiveFormat = 'zip',
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]] $ExtraArgs
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Resolve paths + inputs
# ---------------------------------------------------------------------------
$scriptDir = $PSScriptRoot
if (-not $scriptDir) { $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
$projRoot  = Split-Path -Parent $scriptDir

# Reuse the shared timed y/n prompt (Read-YNTimed) so confirmations here match the
# password prompt: 15s idle countdown, default answer on timeout / no console.
$xferShared = Join-Path $scriptDir '_xfer_password.ps1'
if (Test-Path $xferShared) { . $xferShared }
if (-not $DataMigrationJson) { $DataMigrationJson = Join-Path $projRoot 'documents\D_data_migration.json' }
if (-not $OutputDir)         { $OutputDir = [Environment]::GetFolderPath('Desktop') }

# Password: explicit param > env (from run_project) > literal --enc_pwd in ExtraArgs.
if (-not $EncPwd) { $EncPwd = $env:MIGRATE_XFER_PWD }
if ($ExtraArgs) {
    for ($i = 0; $i -lt $ExtraArgs.Count; $i++) {
        $a = [string]$ExtraArgs[$i]
        if (-not $EncPwd -and $a -like '--enc_pwd=*') { $EncPwd = $a.Substring(10) }
        elseif (-not $EncPwd -and $a -eq '--enc_pwd' -and ($i + 1) -lt $ExtraArgs.Count) { $EncPwd = [string]$ExtraArgs[$i + 1]; $i++ }
        elseif ($a -like '--archive-format=*') { $ArchiveFormat = $a.Substring(17) }
        elseif ($a -eq '--archive-format' -and ($i + 1) -lt $ExtraArgs.Count) { $ArchiveFormat = [string]$ExtraArgs[$i + 1]; $i++ }
    }
}
if ($ArchiveFormat -notin @('zip', '7z', 'enctar')) { $ArchiveFormat = 'zip' }

function Write-Info  { param($m) Write-Host "       $m" }
function Write-OkLine { param($m) Write-Host "       $m" -ForegroundColor Green }
function Write-WarnY { param($m) Write-Host "       $m" -ForegroundColor Yellow }
function Write-ErrR  { param($m) Write-Host "       $m" -ForegroundColor Red }

# Box-drawing needs a UTF-8 console; guarded so redirected output never throws.
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

# Render a polished two-column table (Windows source -> Linux destination). Column
# widths auto-fit the terminal; over-long cells are middle-ellipsised so both the start
# and the end of a path stay readable. Colours: cyan header, dark-gray borders.
function Write-ReportTable {
    param([object[]] $Rows, [string] $LeftLabel = 'Windows source', [string] $RightLabel = 'Linux destination', [string] $Indent = '  ')
    if (-not $Rows -or $Rows.Count -eq 0) { return }
    $cw = 120; try { if ([Console]::WindowWidth -gt 20) { $cw = [Console]::WindowWidth } } catch {}
    $budget = $cw - $Indent.Length - 8            # borders "| " + " | " + " |" + safety
    if ($budget -lt 24) { $budget = 24 }
    $lw = [Math]::Max($LeftLabel.Length,  [int]($Rows | ForEach-Object { ([string]$_.Source).Length } | Measure-Object -Maximum).Maximum)
    $rw = [Math]::Max($RightLabel.Length, [int]($Rows | ForEach-Object { ([string]$_.Target).Length } | Measure-Object -Maximum).Maximum)
    while (($lw + $rw) -gt $budget) {
        if ($lw -ge $rw -and $lw -gt 10) { $lw-- } elseif ($rw -gt 10) { $rw-- } else { break }
    }
    $fit = {
        param([string]$s, [int]$w)
        if ($null -eq $s) { $s = '' }
        if ($s.Length -le $w) { return $s.PadRight($w) }
        if ($w -le 3) { return $s.Substring(0, $w) }
        $keep = $w - 3; $head = [int][Math]::Ceiling($keep / 2); $tail = $keep - $head
        return ($s.Substring(0, $head) + '...' + $s.Substring($s.Length - $tail))
    }
    $bd = 'DarkGray'
    $h = [string]([char]0x2500); $v = [char]0x2502
    $top = $Indent + [char]0x250C + ($h * ($lw + 2)) + [char]0x252C + ($h * ($rw + 2)) + [char]0x2510
    $sep = $Indent + [char]0x251C + ($h * ($lw + 2)) + [char]0x253C + ($h * ($rw + 2)) + [char]0x2524
    $bot = $Indent + [char]0x2514 + ($h * ($lw + 2)) + [char]0x2534 + ($h * ($rw + 2)) + [char]0x2518
    Write-Host $top -ForegroundColor $bd
    Write-Host -NoNewline ($Indent + "$v ") -ForegroundColor $bd
    Write-Host -NoNewline (& $fit $LeftLabel $lw) -ForegroundColor Cyan
    Write-Host -NoNewline (" $v ") -ForegroundColor $bd
    Write-Host -NoNewline (& $fit $RightLabel $rw) -ForegroundColor Cyan
    Write-Host (" $v") -ForegroundColor $bd
    Write-Host $sep -ForegroundColor $bd
    foreach ($r in $Rows) {
        Write-Host -NoNewline ($Indent + "$v ") -ForegroundColor $bd
        Write-Host -NoNewline (& $fit ([string]$r.Source) $lw) -ForegroundColor White
        Write-Host -NoNewline (" $v ") -ForegroundColor $bd
        Write-Host -NoNewline (& $fit ([string]$r.Target) $rw) -ForegroundColor Gray
        Write-Host (" $v") -ForegroundColor $bd
    }
    Write-Host $bot -ForegroundColor $bd
}

Write-Host ""
Write-Host "==> Backing up your important user & application data" -ForegroundColor Cyan

if (-not (Test-Path $DataMigrationJson)) {
    Write-ErrR "Data-migration manifest not found: $DataMigrationJson  -- nothing to back up."
    exit 0
}
$plan = Get-Content -Raw -Path $DataMigrationJson -Encoding UTF8 | ConvertFrom-Json

# Fail fast: make sure the tool the chosen --archive-format needs is available (installing it
# automatically if possible) BEFORE any collection/staging work. Exits with a clear message here
# if it cannot be obtained.
Initialize-BackupTools

# Human-readable size, max 2 decimals.
function Format-Size {
    param([double] $Bytes)
    $u = @('B','KB','MB','GB','TB','PB'); $i = 0
    while ($Bytes -ge 1024 -and $i -lt $u.Count - 1) { $Bytes /= 1024; $i++ }
    return ('{0:0.##} {1}' -f $Bytes, $u[$i])
}

# Remove every temp leftover this tool can create -- staging trees, intermediate .tar.gz
# archives, and the throwaway encrypt .cmd -- from THIS run and any previous/aborted run by
# anyone. The only artifacts a run ever leaves are the final .enc/.tar.gz + .log on the Desktop.
function Clear-Leftovers {
    $tmp = [System.IO.Path]::GetTempPath()
    foreach ($pat in @('mtl_backup_*', 'mtl_*.tar.gz', 'mtl_*.cmd')) {
        Get-ChildItem -LiteralPath $tmp -Filter $pat -Force -ErrorAction SilentlyContinue |
            ForEach-Object { try { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction Stop } catch {} }
    }
}

# Run a shell command line (its own stderr redirect included) via a tiny generated .cmd,
# launched with [Diagnostics.Process]::Start so the exit code is ALWAYS reliable (unlike
# Start-Process -PassThru, whose .ExitCode can come back $null without -Wait). Polls
# $WatchFile's growing size to drive a progress bar. Returns the real integer exit code
# (or 1 if the process could not even be started).
function Invoke-CmdWithProgress {
    param([string] $CmdText, [string] $WatchFile, [double] $Denom, [string] $Activity)
    $cmdFile = Join-Path ([System.IO.Path]::GetTempPath()) ('mtl_run_' + [System.Guid]::NewGuid().ToString('N').Substring(0, 8) + '.cmd')
    Set-Content -LiteralPath $cmdFile -Value $CmdText
    $rc = 1
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $env:ComSpec
        $psi.Arguments = '/c "' + $cmdFile + '"'
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $p = [System.Diagnostics.Process]::Start($psi)
        while (-not $p.HasExited) {
            $cur = 0; try { $cur = (Get-Item -LiteralPath $WatchFile -ErrorAction SilentlyContinue).Length } catch {}
            $pct = [Math]::Min(99, [int](($cur / $Denom) * 100))
            Write-Progress -Activity $Activity -Status ("{0} / ~{1}" -f (Format-Size $cur), (Format-Size $Denom)) -PercentComplete $pct
            Start-Sleep -Milliseconds 250
        }
        $p.WaitForExit()
        $rc = $p.ExitCode
    } catch {
        $rc = 1
    } finally {
        Write-Progress -Activity $Activity -Completed
        Remove-Item -LiteralPath $cmdFile -Force -ErrorAction SilentlyContinue
    }
    return $rc
}

# --------------------------- external-tool acquisition -----------------------
function Resolve-Tool {
    param([string] $Name, [string[]] $Fallbacks)
    $c = Get-Command $Name -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    foreach ($p in $Fallbacks) { if ($p -and (Test-Path $p)) { return $p } }
    return $null
}
# Read a PE header's machine type: '64' (x64/arm64), '32' (x86), or '' on error.
function Get-PEBitness {
    param([string] $Path)
    try {
        $fs = [IO.File]::OpenRead($Path); $br = New-Object IO.BinaryReader($fs)
        $fs.Position = 0x3C; $peOff = $br.ReadInt32(); $fs.Position = $peOff + 4
        $m = $br.ReadUInt16(); $br.Close(); $fs.Close()
        switch ($m) { 0x8664 { '64' } 0xAA64 { '64' } 0x14c { '32' } default { '' } }
    } catch { '' }
}
# Try to install a package via whatever package manager exists (winget, then Chocolatey).
# $Probe returns $true once the tool is present. Returns $true on success.
function Install-ViaManagers {
    param([string[]] $WingetIds, [string[]] $ChocoIds, [scriptblock] $Probe)
    if (& $Probe) { return $true }
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        foreach ($id in $WingetIds) {
            try { Write-Info "Installing $id via winget ..."; winget install --id $id -e --accept-source-agreements --accept-package-agreements --silent 2>$null | Out-Null } catch {}
            if (& $Probe) { return $true }
        }
    }
    if (Get-Command choco -ErrorAction SilentlyContinue) {
        foreach ($id in $ChocoIds) {
            try { Write-Info "Installing $id via Chocolatey ..."; choco install $id -y --no-progress 2>$null | Out-Null } catch {}
            if (& $Probe) { return $true }
        }
    }
    return $false
}
# Find OpenSSL (64-bit preferred), installing on demand. Returns @{Exe;Bits} or $null.
function Resolve-OpenSSL {
    $cands = {
        @("$env:ProgramFiles\Git\usr\bin\openssl.exe", "$env:ProgramFiles\Git\mingw64\bin\openssl.exe",
          'C:\OpenSSL-Win64\bin\openssl.exe', (Get-Command openssl -ErrorAction SilentlyContinue).Source,
          "${env:ProgramFiles(x86)}\Git\usr\bin\openssl.exe", 'C:\OpenSSL-Win32\bin\openssl.exe'
        ) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique
    }
    # existing -> winget/choco (OpenSSL builds, or Git which bundles a 64-bit openssl)
    Install-ViaManagers -WingetIds @('ShiningLight.OpenSSL.Light', 'FireDaemon.OpenSSL', 'Git.Git') -ChocoIds @('openssl', 'git') -Probe { [bool]((& $cands) | Select-Object -First 1) } | Out-Null
    $list = & $cands
    $exe = $null; $bits = ''
    foreach ($x in $list) { if ((Get-PEBitness $x) -eq '64') { $exe = $x; $bits = '64'; break } }
    if (-not $exe -and $list.Count -gt 0) { $exe = $list[0]; $bits = (Get-PEBitness $exe) }
    if ($exe) { return @{ Exe = $exe; Bits = $bits } }
    return $null
}
# Find a 7-Zip that can create AES zip/7z, installing on demand. Returns the exe path or $null.
# Order: existing -> winget -> choco -> standalone 7za bootstrap (no admin / no package manager:
# 7zr.exe from a stable URL extracts 7za.exe from the versioned "extra" package on GitHub).
function Resolve-7Zip {
    $find = {
        @((Get-Command 7z -ErrorAction SilentlyContinue).Source, "$env:ProgramFiles\7-Zip\7z.exe",
          "${env:ProgramFiles(x86)}\7-Zip\7z.exe", (Get-Command 7za -ErrorAction SilentlyContinue).Source,
          (Join-Path ([System.IO.Path]::GetTempPath()) 'mtl_7z\7za.exe')
        ) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
    }
    $p = & $find; if ($p) { return $p }
    Install-ViaManagers -WingetIds @('7zip.7zip') -ChocoIds @('7zip') -Probe { [bool](& $find) } | Out-Null
    $p = & $find; if ($p) { return $p }
    try {
        Write-Info "No package manager available - fetching the standalone 7-Zip (7za) directly ..."
        $bin = Join-Path ([System.IO.Path]::GetTempPath()) 'mtl_7z'
        New-Item -ItemType Directory -Path $bin -Force | Out-Null
        $7zr = Join-Path $bin '7zr.exe'
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest 'https://www.7-zip.org/a/7zr.exe' -OutFile $7zr -UseBasicParsing -TimeoutSec 60
        $rel = Invoke-RestMethod 'https://api.github.com/repos/ip7z/7zip/releases/latest' -UseBasicParsing -TimeoutSec 60 -Headers @{ 'User-Agent' = 'mtl' }
        $asset = $rel.assets | Where-Object { $_.name -match 'extra\.7z$' } | Select-Object -First 1
        if ($asset) {
            $extra = Join-Path $bin 'extra.7z'
            Invoke-WebRequest $asset.browser_download_url -OutFile $extra -UseBasicParsing -TimeoutSec 300 -Headers @{ 'User-Agent' = 'mtl' }
            foreach ($member in @('7za.exe', 'x64\7za.exe')) {
                & $7zr e $extra -o"$bin" $member -y 2>$null | Out-Null
                $7za = Join-Path $bin '7za.exe'
                if (Test-Path $7za) { return $7za }
            }
        }
    } catch {}
    return $null
}

# Find an already-installed 7-Zip / OpenSSL WITHOUT trying to install (so we can tell whether an
# internet-dependent install is actually needed). Return the path, or $null.
function Find-7Zip {
    @((Get-Command 7z -ErrorAction SilentlyContinue).Source, "$env:ProgramFiles\7-Zip\7z.exe",
      "${env:ProgramFiles(x86)}\7-Zip\7z.exe", (Get-Command 7za -ErrorAction SilentlyContinue).Source,
      (Join-Path ([System.IO.Path]::GetTempPath()) 'mtl_7z\7za.exe')
    ) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
}
function Find-OpenSSL {
    @("$env:ProgramFiles\Git\usr\bin\openssl.exe", "$env:ProgramFiles\Git\mingw64\bin\openssl.exe",
      'C:\OpenSSL-Win64\bin\openssl.exe', (Get-Command openssl -ErrorAction SilentlyContinue).Source,
      "${env:ProgramFiles(x86)}\Git\usr\bin\openssl.exe", 'C:\OpenSSL-Win32\bin\openssl.exe'
    ) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
}
# Quick internet check (a couple of short TCP connects); automatic installs need it.
function Test-Internet {
    foreach ($hp in @(@('github.com', 443), @('www.7-zip.org', 443), @('8.8.8.8', 53))) {
        try {
            $c = New-Object System.Net.Sockets.TcpClient
            $iar = $c.BeginConnect($hp[0], $hp[1], $null, $null)
            if ($iar.AsyncWaitHandle.WaitOne(2500)) { $c.EndConnect($iar); $c.Close(); return $true }
            $c.Close()
        } catch {}
    }
    return $false
}

# Resolve every external tool the CHOSEN format+encryption needs, installing on demand. If the
# required tool truly cannot be obtained automatically -- because there is no internet, or no
# install method works -- print the exact reason and EXIT here, at the very beginning, before any
# staging/compression work is done. Sets script-scoped vars.
function Initialize-BackupTools {
    $script:tarExe       = Resolve-Tool 'tar' @()
    $script:encrypt      = [bool]$EncPwd
    $script:sevenZip     = $null
    $script:opensslExe   = $null
    $script:opensslBits  = ''
    $script:useZipFallback = $false
    if (-not $EncPwd) { Write-WarnY "No transfer password was set -- the archive will be created UNENCRYPTED (your choice)." }

    # For a REQUIRED tool that is not already installed: if there is no internet we cannot install
    # it automatically -- say so and exit. $NoInstallHint is the extra "or ..." guidance.
    function _need_tool {
        param([string] $Kind, [scriptblock] $Find, [scriptblock] $Resolve, [string] $Missing, [string] $NoInstallHint)
        $p = & $Find
        if ($p) { return $p }
        if (-not (Test-Internet)) {
            Write-ErrR ("$Missing (there is no internet connection to install it automatically). Connect to the internet and re-run, install $Kind manually, $NoInstallHint")
            exit 1
        }
        $p = & $Resolve
        if (-not $p) { Write-ErrR ("$Missing. Install $Kind manually and re-run, $NoInstallHint"); exit 1 }
        return $p
    }

    switch ($ArchiveFormat) {
        '7z' {
            $script:sevenZip = _need_tool '7-Zip' { Find-7Zip } { Resolve-7Zip } `
                "--archive-format 7z is selected but 7-Zip cannot be installed automatically" `
                "or choose 'zip'/'enctar' for --archive-format, or simply do not provide a password to imply that you do not require encryption of your data that is being backed up to be transferred."
        }
        'zip' {
            if ($script:encrypt) {
                $script:sevenZip = _need_tool '7-Zip' { Find-7Zip } { Resolve-7Zip } `
                    "--archive-format zip is selected but 7-Zip cannot be installed automatically" `
                    "or choose 'enctar' for --archive-format, or simply do not provide a password to imply that you do not require encryption of your data that is being backed up to be transferred."
            } else {
                # Unencrypted zip needs no external tool: use 7-Zip if already here, else a plain .NET zip.
                $p = Find-7Zip
                if ($p) { $script:sevenZip = $p } else { $script:useZipFallback = $true }
            }
        }
        'enctar' {
            if (-not $script:tarExe) { Write-ErrR "tar.exe not found (it ships with Windows 10/11). Cannot create the archive."; exit 1 }
            if ($script:encrypt) {
                $osslPath = _need_tool 'OpenSSL' { Find-OpenSSL } { $o = Resolve-OpenSSL; if ($o) { $o.Exe } else { $null } } `
                    "OpenSSL cannot be installed automatically" `
                    "or choose 'zip'/'7z' for --archive-format, or simply do not provide a password to imply that you do not require encryption of your data that is being backed up."
                $script:opensslExe = $osslPath
                $script:opensslBits = if ($osslPath) { Get-PEBitness $osslPath } else { '' }
            }
        }
    }
}

# Slug shared with the bash side (_common.sh slugify): lowercase, non [a-z0-9-_] stripped.
function Get-Slug {
    param([string] $Name)
    $s = $Name.ToLowerInvariant() -replace ' ', '-'
    return ($s -replace '[^a-z0-9\-_]', '')
}

# Expand %ENV% references then return the path (may or may not exist).
function Expand-Src { param([string] $Raw) [Environment]::ExpandEnvironmentVariables($Raw) }

# Match a file's archive-relative path (forward slashes) against an inclusion/exclusion
# regex list. Exclusions override inclusions.
function Test-Included {
    param([string] $RelPath, [string[]] $Incl, [string[]] $Excl)
    $inc = $false
    if (-not $Incl -or $Incl.Count -eq 0) { $inc = $true }       # no inclusions => include all
    else { foreach ($r in $Incl) { if ($RelPath -match $r) { $inc = $true; break } } }
    if (-not $inc) { return $false }
    if ($Excl) { foreach ($r in $Excl) { if ($RelPath -match $r) { return $false } } }
    return $true
}

# ---------------------------------------------------------------------------
# Cloud-storage + browser exclusion. Per policy, data that a service restores on its
# own is NEVER backed up -- whether it is online-only OR fully downloaded locally:
#   * cloud-sync roots (OneDrive, Dropbox, Google Drive, iCloud, Box, ...)
#   * files carrying the online-only / cloud-recall attributes
#   * browser profile data (Chrome/Edge/Brave/Firefox/Opera/...)
# ---------------------------------------------------------------------------
function Get-CloudRoots {
    $roots = New-Object System.Collections.Generic.List[string]
    $add = { param($p) if ($p) { $roots.Add([string]$p) } }
    foreach ($v in 'OneDrive','OneDriveConsumer','OneDriveCommercial') { & $add ([Environment]::GetEnvironmentVariable($v)) }
    # OneDrive accounts (registry) -> UserFolder
    try { Get-ChildItem 'HKCU:\Software\Microsoft\OneDrive\Accounts' -ErrorAction SilentlyContinue | ForEach-Object {
        & $add ((Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).UserFolder) } } catch {}
    # Dropbox info.json (personal + business)
    foreach ($ij in @("$env:APPDATA\Dropbox\info.json","$env:LOCALAPPDATA\Dropbox\info.json")) {
        if (Test-Path $ij) { try { (Get-Content -Raw $ij | ConvertFrom-Json).PSObject.Properties |
            ForEach-Object { & $add $_.Value.path } } catch {} }
    }
    # Common local mount points under the profile
    foreach ($rel in 'Dropbox','OneDrive','My Drive','Google Drive','iCloudDrive','iCloud Drive','Box','Box Sync') {
        $p = Join-Path $env:USERPROFILE $rel; if (Test-Path $p) { & $add $p }
    }
    # Google DriveFS local cache
    if ($env:LOCALAPPDATA) { $p = "$env:LOCALAPPDATA\Google\DriveFS"; if (Test-Path $p) { & $add $p } }
    # Windows Cloud Files sync roots -- the generic registry that EVERY Cloud Filter API
    # provider (OneDrive/Dropbox/Google Drive/iCloud) registers its root(s) under.
    try { Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\SyncRootManager' -ErrorAction SilentlyContinue |
        ForEach-Object { Get-ChildItem "$($_.PSPath)\UserSyncRoots" -ErrorAction SilentlyContinue |
            ForEach-Object { (Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).PSObject.Properties |
                Where-Object { $_.Name -notmatch '^PS' } | ForEach-Object { & $add $_.Value } } } } catch {}
    return ($roots | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\').ToLowerInvariant() } | Sort-Object -Unique)
}
$script:CloudRoots = @(Get-CloudRoots)
# Browser profile data (restorable from the browser account / sync).
$script:BrowserFrags = @(
    '\google\chrome\user data', '\google\chrome sxs\user data', '\google\chrome beta\user data',
    '\microsoft\edge\user data', '\bravesoftware\brave-browser\user data', '\chromium\user data',
    '\vivaldi\user data', '\opera software\', '\mozilla\firefox', '\yandex\yandexbrowser\user data'
) | ForEach-Object { $_.ToLowerInvariant() }

# True when a path is cloud-synced, browser data, or (for files) online-only / recall.
function Test-ExcludedPath {
    param([string] $Full, [int] $Attrs = 0)
    $lp = $Full.ToLowerInvariant().TrimEnd('\')
    foreach ($r in $script:CloudRoots)   { if ($lp -eq $r -or $lp.StartsWith($r + '\')) { return $true } }
    foreach ($b in $script:BrowserFrags) { if ($lp.Contains($b)) { return $true } }
    if ($Attrs -band 0x1000)   { return $true }   # FILE_ATTRIBUTE_OFFLINE (online-only)
    if ($Attrs -band 0x40000)  { return $true }   # FILE_ATTRIBUTE_RECALL_ON_OPEN
    if ($Attrs -band 0x400000) { return $true }   # FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS
    return $false
}

# ---------------------------------------------------------------------------
# Collect: returns a list of @{ Src; Rel; Size } and builds the report rows.
# ---------------------------------------------------------------------------
$items = New-Object System.Collections.Generic.List[object]   # files to stage
$report = New-Object System.Collections.Generic.List[object]  # @{ Source; Target } collapsed parents
$totalBytes = [double]0
$script:excludedCount = 0
$script:excludedBytes = [double]0

function Add-Tree {
    # Walk one source root, keep matching files, stage them under $archPrefix/<rel>.
    param([string] $SrcRoot, [string] $ArchPrefix, [string[]] $Incl, [string[]] $Excl)
    if (-not (Test-Path $SrcRoot)) { return $false }
    # Whole root is cloud-synced / browser data -> skip the entire subtree (never enumerate it).
    if (Test-ExcludedPath $SrcRoot) { return $false }
    $any = $false
    if (Test-Path $SrcRoot -PathType Leaf) {
        $fi = Get-Item -LiteralPath $SrcRoot
        $rel = $fi.Name
        if (Test-ExcludedPath $fi.FullName ([int]$fi.Attributes)) { $script:excludedCount++; $script:excludedBytes += $fi.Length; return $false }
        if (Test-Included ($rel -replace '\\','/') $Incl $Excl) {
            $items.Add(@{ Src = $fi.FullName; Rel = "$ArchPrefix/$rel"; Size = $fi.Length })
            $script:totalBytes += $fi.Length; $any = $true
        }
        return $any
    }
    $base = (Get-Item -LiteralPath $SrcRoot).FullName.TrimEnd('\')
    foreach ($f in (Get-ChildItem -LiteralPath $SrcRoot -Recurse -File -Force -ErrorAction SilentlyContinue)) {
        # Cloud-synced / online-only / browser data -> excluded, whatever its inclusion match.
        if (Test-ExcludedPath $f.FullName ([int]$f.Attributes)) { $script:excludedCount++; $script:excludedBytes += $f.Length; continue }
        $rel = $f.FullName.Substring($base.Length + 1) -replace '\\','/'
        if (-not (Test-Included $rel $Incl $Excl)) { continue }
        $items.Add(@{ Src = $f.FullName; Rel = "$ArchPrefix/$rel"; Size = $f.Length })
        $script:totalBytes += $f.Length; $any = $true
    }
    return $any
}

# Sweep any leftover junk from this or previous/aborted runs up front, so the disk is
# reclaimed before staging and the free-space estimate is accurate.
Clear-Leftovers

# ---- 1. Static user-profile data ----
$userDir = $env:USERPROFILE
foreach ($inc in $plan.userProfile.inclusions) {
    $src = Join-Path $userDir $inc.path
    $excl = @(); if ($inc.exclude) { $excl = @($inc.exclude) }
    $prefix = 'user/' + ($inc.path -replace '\\','/')
    if (Add-Tree -SrcRoot $src -ArchPrefix $prefix -Incl @() -Excl $excl) {
        $report.Add(@{ Source = $src; Target = $inc.linuxTarget })
    }
}

# ---- 2. Application data (per scope) ----
$appsObj = $plan.applications
if ($appsObj) {
    foreach ($p in $appsObj.PSObject.Properties) {
        $appKey = $p.Name; $app = $p.Value
        $slug = Get-Slug $appKey
        foreach ($scopeName in @('userdir','system')) {
            $scope = $app.$scopeName
            if (-not $scope) { continue }
            $incl = @(); if ($scope.DataTransferInclusions) { $incl = @($scope.DataTransferInclusions) }
            $excl = @(); if ($scope.DataTransferExclusions) { $excl = @($scope.DataTransferExclusions) }
            foreach ($s in @($scope.sources)) {
                $sp = Expand-Src $s
                if (Add-Tree -SrcRoot $sp -ArchPrefix "apps/$slug/$scopeName" -Incl $incl -Excl $excl) {
                    $report.Add(@{ Source = $sp; Target = "[$appKey/$scopeName] $($scope.linuxTarget)" })
                }
            }
        }
    }
}

# .ssh / Contacts are handled by C_detect -- listed for the user, NOT re-archived here.
$report.Add(@{ Source = (Join-Path $userDir '.ssh');     Target = '~/.ssh  (already handled by the encrypted settings archive)' })
$report.Add(@{ Source = (Join-Path $userDir 'Contacts'); Target = '~/Contacts  (already handled by the encrypted settings archive)' })

if ($items.Count -eq 0) {
    Write-WarnY "None of the important data locations exist on this machine -- nothing to back up."
    exit 0
}

# ---------------------------------------------------------------------------
# Report (<= 30 rows; otherwise log-only). Collapse to earliest common parents:
# de-dupe identical source roots; they already are the earliest parents we walked.
# ---------------------------------------------------------------------------
$logPath = Join-Path $OutputDir 'MigrateToLinux_backup_report.log'
$reportSorted = $report | Sort-Object { $_.Source }
Write-Host ""
Write-Info "The backup will include these locations (verbatim) and where each is meant to land on Linux:"
Write-Host ""
if ($reportSorted.Count -le 30) {
    Write-ReportTable -Rows $reportSorted
} else {
    Write-WarnY ("There are {0} locations -- too many to list here. The full list is written to:" -f $reportSorted.Count)
    Write-Info  ("    $logPath")
}
# Always write the full list to the log.
$logLines = @('Migrate to Linux -- backup report (' + (Get-Date) + ')','')
foreach ($r in $reportSorted) { $logLines += ('{0}  -->  {1}' -f $r.Source, $r.Target) }
[System.IO.File]::WriteAllText($logPath, ($logLines -join "`r`n"), (New-Object System.Text.UTF8Encoding($false)))

if ($script:excludedCount -gt 0) {
    Write-Host ""
    Write-Info ("Skipped {0} file(s) (~{1}) that a service restores on its own: cloud storage (OneDrive/Dropbox/Google Drive/iCloud/...) and browser data -- excluded whether online-only or downloaded." -f $script:excludedCount, (Format-Size $script:excludedBytes))
    if ($script:CloudRoots.Count -gt 0) { Write-Info ("Cloud roots detected: {0}" -f (($script:CloudRoots) -join '; ')) }
}

Write-Host ""
Write-WarnY "WARNING: depending on how much data you have, this can take a long time."
Write-WarnY "WARNING: this backup will probably NOT include everything you might want. Review the list above; continue only if you accept that risk."

# ---------------------------------------------------------------------------
# Size estimate + storage-space precheck
# ---------------------------------------------------------------------------
$estArchive = [double]($totalBytes * 0.6)     # rough only; incompressible media can be ~1:1
# Worst case the archive is nearly as large as the source (incompressible media), and the
# staging tree briefly coexists with the .tar.gz (and later the .tar.gz with the .enc) on the
# same drive. Staging is freed BEFORE encryption, so the guaranteed peak is ~2x the source.
$peakNeeded = [double]($totalBytes * 2)
$drive = (Split-Path -Qualifier $OutputDir)
$free = $null
try { $free = (Get-PSDrive ($drive.TrimEnd(':')) -ErrorAction SilentlyContinue).Free } catch {}
Write-Host ""
Write-Info ("Data to back up (uncompressed) : {0}" -f (Format-Size $totalBytes))
Write-Info ("Estimated archive size         : ~{0} (rough; can be much larger for media)" -f (Format-Size $estArchive))
Write-Info ("Peak temp space needed         : ~{0}" -f (Format-Size $peakNeeded))
Write-Info ("Estimated size needed on Linux : ~{0}" -f (Format-Size $totalBytes))
if ($null -ne $free) { Write-Info ("Free space on {0} (Desktop)     : {1}" -f $drive, (Format-Size $free)) }

$needConfirm = $false; $why = New-Object System.Collections.Generic.List[string]
# Need room for the staging tree AND the archive to coexist briefly (~2x the source size).
if (($null -ne $free) -and ($free -lt $peakNeeded)) { $needConfirm = $true; $why.Add('free space may be insufficient - the staged copy and the archive briefly coexist (~2x the data size)') }
if ($totalBytes -gt 50GB) { $needConfirm = $true; $why.Add('the backup exceeds 50 GB') }

if ($needConfirm -and -not $AssumeYes) {
    Write-Host ""
    Write-WarnY ("You are being asked to confirm because " + ($why -join ' and ') + ".")
    $cont = $true
    if (Get-Command Read-YNTimed -ErrorAction SilentlyContinue) {
        $cont = Read-YNTimed -Prompt "  Continue with the backup anyway? (y/n, default y, 15s): " -TimeoutSec 15 -Default $true
    } else {
        $ans = Read-Host "  Continue with the backup anyway? (y/n, default y)"
        $cont = ($ans -notmatch '^\s*[nN]')     # default y: only an explicit 'n' cancels
    }
    if (-not $cont) { Write-Info "Backup cancelled."; exit 0 }
}

# ---------------------------------------------------------------------------
# Stage -> archive (tools were resolved / validated by Initialize-BackupTools)
# ---------------------------------------------------------------------------
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$staging = Join-Path ([System.IO.Path]::GetTempPath()) ("mtl_backup_" + $stamp)
New-Item -ItemType Directory -Path $staging -Force | Out-Null

Write-Host ""
Write-Info ("Staging {0} file(s) ..." -f $items.Count)
$done = 0; $lastPct = -1
foreach ($it in $items) {
    $dest = Join-Path $staging ($it.Rel -replace '/','\')
    $dd = Split-Path -Parent $dest
    if (-not (Test-Path $dd)) { New-Item -ItemType Directory -Path $dd -Force | Out-Null }
    try { Copy-Item -LiteralPath $it.Src -Destination $dest -Force -ErrorAction Stop } catch {}
    $done++
    $pct = [int](($done / $items.Count) * 100)
    if ($pct -ne $lastPct) { Write-Progress -Activity "Staging files" -Status "$done / $($items.Count)" -PercentComplete $pct; $lastPct = $pct }
}
Write-Progress -Activity "Staging files" -Completed

$denom = [Math]::Max([double]1, $estArchive)

if ($ArchiveFormat -eq 'enctar') {
    # ---- enctar: tar + gzip (medium) -> OpenSSL AES-256-CBC/PBKDF2 ----
    $tarGz = [System.IO.Path]::GetFullPath((Join-Path $staging "..\mtl_$stamp.tar.gz"))
    Write-Info "Compressing (tar + gzip, medium) ..."
    $env:GZIP = '-6'   # default gzip level is 6 (medium); documents intent (bsdtar ignores it)
    $tarErr = [System.IO.Path]::GetTempFileName()
    $tarCmdText = '@"' + $tarExe + '" -czf "' + $tarGz + '" -C "' + $staging + '" . 2> "' + $tarErr + '"'
    $tarRc = Invoke-CmdWithProgress -CmdText $tarCmdText -WatchFile $tarGz -Denom $denom -Activity "Compressing (tar + gzip, medium)"
    Remove-Item Env:\GZIP -ErrorAction SilentlyContinue
    $tarErrText = (Get-Content -LiteralPath $tarErr -Raw -ErrorAction SilentlyContinue)
    Remove-Item -LiteralPath $tarErr -Force -ErrorAction SilentlyContinue
    $tarGzSize = if (Test-Path $tarGz) { (Get-Item $tarGz).Length } else { 0 }
    # bsdtar exit codes: 0 = ok, 1 = WARNING (files skipped, archive still valid), >=2 = fatal.
    if ($tarGzSize -eq 0 -or $tarRc -ge 2) {
        Write-ErrR ("Compression FAILED (tar exit {0}, output {1}). Archive not created." -f $tarRc, (Format-Size $tarGzSize))
        if ($tarErrText) { Write-ErrR ("tar said: " + ($tarErrText.Trim() -split "`n" | Select-Object -First 3 | Out-String).Trim()) }
        Remove-Item -LiteralPath $tarGz -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
        Write-Info "The staged/temporary files have been deleted."
        exit 1
    }
    if ($tarRc -ne 0) {
        Write-WarnY "tar reported warnings (some files may have been skipped); continuing with the archive."
        if ($tarErrText) { Write-WarnY ("tar said: " + ($tarErrText.Trim() -split "`n" | Select-Object -First 2 | Out-String).Trim()) }
    }
    $finalName = if ($encrypt) { "MigrateToLinux_UserData_$stamp.tar.gz.enc" } else { "MigrateToLinux_UserData_$stamp.tar.gz" }
    $finalPath = Join-Path $OutputDir $finalName
    # Free staging BEFORE encryption so staging + .tar.gz + .enc don't all pile up on one drive.
    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
    if ($encrypt) {
        $freeNow = $null
        try { $freeNow = (Get-PSDrive ($drive.TrimEnd(':')) -ErrorAction SilentlyContinue).Free } catch {}
        if (($null -ne $freeNow) -and ($freeNow -lt ($tarGzSize * 1.02))) {
            Write-ErrR ("Backup FAILED - NOT ENOUGH DISK SPACE to write the encrypted archive on {0}: need ~{1}, only {2} free. Free up space and re-run." -f $drive, (Format-Size $tarGzSize), (Format-Size $freeNow))
            Remove-Item -LiteralPath $tarGz -Force -ErrorAction SilentlyContinue
            Write-Info "The staged/temporary files have been deleted."
            exit 1
        }
        if ($opensslBits -ne '64') {
            Write-Info ("OpenSSL is {0}; the archive is streamed to it via stdin, so large files ({1}) work on a 32-bit build too." -f ($(if($opensslBits){"$opensslBits-bit"}else{'of unknown bitness'}), (Format-Size $tarGzSize)))
        }
        Write-Info "Encrypting (OpenSSL AES-256-CBC / PBKDF2) ..."
        $encDenom = [Math]::Max([int64]1, $tarGzSize)
        $env:MTL_ENCPW = $EncPwd
        $encErr = [System.IO.Path]::GetTempFileName()
        # Archive fed to OpenSSL on STDIN (cmd opens the big file) so a 32-bit OpenSSL works too;
        # password stays in the env var (never in the .cmd); stderr captured (2> ...).
        $encCmdText = '@"' + $opensslExe + '" enc -aes-256-cbc -pbkdf2 -salt -pass env:MTL_ENCPW -out "' + $finalPath + '" < "' + $tarGz + '" 2> "' + $encErr + '"'
        $encRc = Invoke-CmdWithProgress -CmdText $encCmdText -WatchFile $finalPath -Denom $encDenom -Activity "Encrypting (OpenSSL AES-256-CBC / PBKDF2)"
        Remove-Item Env:\MTL_ENCPW -ErrorAction SilentlyContinue
        $encErrText = (Get-Content -LiteralPath $encErr -Raw -ErrorAction SilentlyContinue)
        Remove-Item -LiteralPath $encErr -Force -ErrorAction SilentlyContinue
        $encSize = if (Test-Path $finalPath) { (Get-Item $finalPath).Length } else { 0 }
        if ($encRc -ne 0 -or $encSize -lt $tarGzSize) {
            $freeAtFail = $null; try { $freeAtFail = (Get-PSDrive ($drive.TrimEnd(':')) -ErrorAction SilentlyContinue).Free } catch {}
            if (($encErrText -match '(?i)writ|space|disk') -or ($encSize -lt $tarGzSize)) {
                $fm = if ($null -ne $freeAtFail) { (Format-Size $freeAtFail) } else { 'unknown' }
                Write-ErrR ("Backup FAILED - NOT ENOUGH DISK SPACE on {0} to write the encrypted archive: needed ~{1}, only {2} free. Free up space and re-run." -f $drive, (Format-Size $tarGzSize), $fm)
            } else {
                Write-ErrR ("Encryption FAILED (openssl exit {0}; output {1}, expected >= {2})." -f $encRc, (Format-Size $encSize), (Format-Size $tarGzSize))
            }
            if ($encErrText) { Write-ErrR ("openssl said: " + ($encErrText.Trim() -split "`n" | Select-Object -First 3 | Out-String).Trim()) }
            Remove-Item -LiteralPath $finalPath -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $tarGz -Force -ErrorAction SilentlyContinue
            Write-Info "The staged/temporary files have been deleted."
            exit 1
        }
        Remove-Item -LiteralPath $tarGz -Force -ErrorAction SilentlyContinue
    } else {
        Move-Item -LiteralPath $tarGz -Destination $finalPath -Force
    }
} else {
    # ---- zip / 7z: single-stage compress (+AES-256 encrypt) via 7-Zip ----
    # Tools were already resolved/validated by Initialize-BackupTools: $sevenZip is set, unless
    # this is an UNENCRYPTED zip on a machine with no 7-Zip ($useZipFallback -> plain .NET zip).
    $finalName = if ($ArchiveFormat -eq 'zip') { "MigrateToLinux_UserData_$stamp.zip" } else { "MigrateToLinux_UserData_$stamp.7z" }
    $finalPath = Join-Path $OutputDir $finalName
    if ($useZipFallback) {
        Write-Info "Creating ZIP archive (no encryption; 7-Zip is not available) ..."
        try {
            Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
            [System.IO.Compression.ZipFile]::CreateFromDirectory($staging, $finalPath, [System.IO.Compression.CompressionLevel]::Optimal, $false)
        } catch {
            Write-ErrR ("ZIP creation FAILED: {0}" -f $_.Exception.Message)
            Remove-Item -LiteralPath $finalPath -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
            Write-Info "The staged/temporary files have been deleted."
            exit 1
        }
        Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
    } else {
        if ($ArchiveFormat -eq 'zip') {
            $typeOpt = '-tzip'
            $encOpt = if ($encrypt) { ' -mem=AES256 -p"' + $EncPwd + '"' } else { '' }   # AES-256 ZIP (filenames NOT encrypted - zip format limit)
        } else {
            $typeOpt = '-t7z'
            $encOpt = if ($encrypt) { ' -mhe=on -p"' + $EncPwd + '"' } else { '' }        # AES-256 7z with encrypted headers
        }
        Write-Info ("Creating {0} archive (compress + {1} in one pass) ..." -f $ArchiveFormat.ToUpper(), $(if($encrypt){'AES-256 encrypt'}else{'no encryption'}))
        if ($encrypt) { Write-Info "  (7-Zip takes the password on its command line, so the running 7z process briefly shows it; the temp launcher is deleted immediately.)" }
        $zErr = [System.IO.Path]::GetTempFileName()
        # cd into staging so entries are stored as user\... / apps\... (not the temp path).
        $zCmdText = '@cd /d "' + $staging + '"' + "`r`n" + '@"' + $sevenZip + '" a ' + $typeOpt + ' -mx=5 -bsp0' + $encOpt + ' "' + $finalPath + '" * > "' + $zErr + '" 2>&1'
        $zRc = Invoke-CmdWithProgress -CmdText $zCmdText -WatchFile $finalPath -Denom $denom -Activity ("Creating {0} archive (compress + encrypt)" -f $ArchiveFormat.ToUpper())
        $zErrText = (Get-Content -LiteralPath $zErr -Raw -ErrorAction SilentlyContinue)
        Remove-Item -LiteralPath $zErr -Force -ErrorAction SilentlyContinue
        $zSize = if (Test-Path $finalPath) { (Get-Item $finalPath).Length } else { 0 }
        # 7-Zip exit codes: 0 = ok, 1 = WARNING (non-fatal), >=2 = fatal.
        if ($zSize -eq 0 -or $zRc -ge 2) {
            $freeAtFail = $null; try { $freeAtFail = (Get-PSDrive ($drive.TrimEnd(':')) -ErrorAction SilentlyContinue).Free } catch {}
            if (($zErrText -match '(?i)space|disk|writ|not enough') -or ($zRc -ge 2 -and $zSize -gt 0)) {
                $fm = if ($null -ne $freeAtFail) { (Format-Size $freeAtFail) } else { 'unknown' }
                Write-ErrR ("Backup FAILED - possibly NOT ENOUGH DISK SPACE on {0} (free ~{1}) to write the archive. 7-Zip exit {2}. Free up space and re-run." -f $drive, $fm, $zRc)
            } else {
                Write-ErrR ("{0} archive creation FAILED (7-Zip exit {1}, output {2})." -f $ArchiveFormat.ToUpper(), $zRc, (Format-Size $zSize))
            }
            if ($zErrText) { Write-ErrR ("7-Zip said: " + ($zErrText.Trim() -split "`n" | Select-Object -First 3 | Out-String).Trim()) }
            Remove-Item -LiteralPath $finalPath -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
            Write-Info "The staged/temporary files have been deleted."
            exit 1
        }
        if ($zRc -ne 0) { Write-WarnY "7-Zip reported warnings (some files may have been skipped); continuing with the archive." }
        Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
    }
}
if (-not (Test-Path $finalPath)) {
    Write-ErrR "Archive creation failed."
    Write-Info "The staged/temporary files have been deleted."
    Write-Host ""
    exit 1
}
$archSize = (Get-Item $finalPath).Length
Write-Host ""
Write-OkLine "Backup complete."
Write-OkLine ("  Archive            : $finalPath")
Write-OkLine ("  Archive size       : {0}" -f (Format-Size $archSize))
Write-OkLine ("  Est. size on Linux : ~{0} (uncompressed)" -f (Format-Size $totalBytes))
if ($encrypt) {
    Write-Info  "  Encrypted with your transfer password. Carry it to Linux and give its path to the installer when asked."
} else {
    Write-WarnY "  UNENCRYPTED. Keep it private and delete it after restoring."
}
Write-OkLine ("  Log (full file list): $logPath")
Write-Info "The staged/temporary files have been deleted."
Write-Host ""
exit 0
