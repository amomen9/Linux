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
if (-not $DataMigrationJson) { $DataMigrationJson = Join-Path $projRoot 'documents\D_data_migration.json' }
if (-not $OutputDir)         { $OutputDir = [Environment]::GetFolderPath('Desktop') }

# Password: explicit param > env (from run_project) > literal --enc_pwd in ExtraArgs.
if (-not $EncPwd) { $EncPwd = $env:MIGRATE_XFER_PWD }
if (-not $EncPwd -and $ExtraArgs) {
    for ($i = 0; $i -lt $ExtraArgs.Count; $i++) {
        $a = [string]$ExtraArgs[$i]
        if ($a -like '--enc_pwd=*') { $EncPwd = $a.Substring(10) }
        elseif ($a -eq '--enc_pwd' -and ($i + 1) -lt $ExtraArgs.Count) { $EncPwd = [string]$ExtraArgs[$i + 1]; $i++ }
    }
}

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

# Human-readable size, max 2 decimals.
function Format-Size {
    param([double] $Bytes)
    $u = @('B','KB','MB','GB','TB','PB'); $i = 0
    while ($Bytes -ge 1024 -and $i -lt $u.Count - 1) { $Bytes /= 1024; $i++ }
    return ('{0:0.##} {1}' -f $Bytes, $u[$i])
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
# Collect: returns a list of @{ Src; Rel; Size } and builds the report rows.
# ---------------------------------------------------------------------------
$items = New-Object System.Collections.Generic.List[object]   # files to stage
$report = New-Object System.Collections.Generic.List[object]  # @{ Source; Target } collapsed parents
$totalBytes = [double]0

function Add-Tree {
    # Walk one source root, keep matching files, stage them under $archPrefix/<rel>.
    param([string] $SrcRoot, [string] $ArchPrefix, [string[]] $Incl, [string[]] $Excl)
    if (-not (Test-Path $SrcRoot)) { return $false }
    $any = $false
    if (Test-Path $SrcRoot -PathType Leaf) {
        $fi = Get-Item -LiteralPath $SrcRoot
        $rel = $fi.Name
        if (Test-Included ($rel -replace '\\','/') $Incl $Excl) {
            $items.Add(@{ Src = $fi.FullName; Rel = "$ArchPrefix/$rel"; Size = $fi.Length })
            $script:totalBytes += $fi.Length; $any = $true
        }
        return $any
    }
    $base = (Get-Item -LiteralPath $SrcRoot).FullName.TrimEnd('\')
    foreach ($f in (Get-ChildItem -LiteralPath $SrcRoot -Recurse -File -Force -ErrorAction SilentlyContinue)) {
        $rel = $f.FullName.Substring($base.Length + 1) -replace '\\','/'
        if (-not (Test-Included $rel $Incl $Excl)) { continue }
        $items.Add(@{ Src = $f.FullName; Rel = "$ArchPrefix/$rel"; Size = $f.Length })
        $script:totalBytes += $f.Length; $any = $true
    }
    return $any
}

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
            $stagedHere = $false
            foreach ($s in @($scope.sources)) {
                $sp = Expand-Src $s
                if (Add-Tree -SrcRoot $sp -ArchPrefix "apps/$slug/$scopeName" -Incl $incl -Excl $excl) {
                    $report.Add(@{ Source = $sp; Target = "[$appKey/$scopeName] $($scope.linuxTarget)" })
                    $stagedHere = $true
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

Write-Host ""
Write-WarnY "WARNING: depending on how much data you have, this can take a long time."
Write-WarnY "WARNING: this backup will probably NOT include everything you might want. Review the list above; continue only if you accept that risk."

# ---------------------------------------------------------------------------
# Size estimate + storage-space precheck
# ---------------------------------------------------------------------------
$estArchive = [double]($totalBytes * 0.6)     # rough: medium gzip on mixed data
$drive = (Split-Path -Qualifier $OutputDir)
$free = $null
try { $free = (Get-PSDrive ($drive.TrimEnd(':')) -ErrorAction SilentlyContinue).Free } catch {}
Write-Host ""
Write-Info ("Data to back up (uncompressed) : {0}" -f (Format-Size $totalBytes))
Write-Info ("Estimated archive size         : ~{0}" -f (Format-Size $estArchive))
Write-Info ("Estimated size needed on Linux : ~{0}" -f (Format-Size $totalBytes))
if ($free -ne $null) { Write-Info ("Free space on {0} (Desktop)     : {1}" -f $drive, (Format-Size $free)) }

$needConfirm = $false; $why = New-Object System.Collections.Generic.List[string]
# The archive is built via a temp .tar.gz next to the output, so we need ~estArchive*2 transiently.
if ($free -ne $null -and $free -lt ($estArchive * 2)) { $needConfirm = $true; $why.Add('predicted free space on the Desktop drive may be insufficient') }
if ($totalBytes -gt 50GB -or $estArchive -gt 50GB)   { $needConfirm = $true; $why.Add('the backup exceeds 50 GB') }

if ($needConfirm -and -not $AssumeYes) {
    Write-Host ""
    Write-WarnY ("You are being asked to confirm because " + ($why -join ' and ') + ".")
    $ans = Read-Host "  Continue with the backup anyway? (y/n)"
    if ($ans -notmatch '^(?i)y') { Write-Info "Backup cancelled."; exit 0 }
}

# ---------------------------------------------------------------------------
# Stage -> tar.gz -> (openssl) -> Desktop
# ---------------------------------------------------------------------------
function Resolve-Tool {
    param([string] $Name, [string[]] $Fallbacks)
    $c = Get-Command $Name -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    foreach ($p in $Fallbacks) { if ($p -and (Test-Path $p)) { return $p } }
    return $null
}
$tarExe = Resolve-Tool 'tar' @()
$opensslExe = Resolve-Tool 'openssl' @(
    "$env:ProgramFiles\Git\usr\bin\openssl.exe",
    "$env:ProgramFiles\Git\mingw64\bin\openssl.exe",
    "${env:ProgramFiles(x86)}\Git\usr\bin\openssl.exe")

if (-not $tarExe) {
    Write-ErrR "tar.exe not found (ships with Windows 10/11). Cannot create the archive."
    exit 1
}
$encrypt = [bool]$EncPwd
if ($encrypt -and -not $opensslExe) {
    Write-WarnY "A password was provided but OpenSSL was not found -- the archive will be created UNENCRYPTED."
    $encrypt = $false
}
if (-not $EncPwd) {
    Write-WarnY "No transfer password was set -- the archive will be created UNENCRYPTED (your choice)."
}

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

$tarGz = Join-Path $staging "..\mtl_$stamp.tar.gz"
$tarGz = [System.IO.Path]::GetFullPath($tarGz)
Write-Info "Compressing (tar + gzip, medium) ..."
# bsdtar honours GZIP=-6 for medium compression of the gzip filter.
$env:GZIP = '-6'
# Windows ships bsdtar (no GNU --checkpoint), so we can't read progress FROM tar. Instead
# run it asynchronously and drive a progress bar from the OUTPUT archive's growing size,
# measured against the estimate (approximate but a real, moving indicator).
$tarErr = [System.IO.Path]::GetTempFileName()
$tarArgLine = (@('-czf', $tarGz, '-C', $staging, '.') | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '
$denom = [Math]::Max(1, $estArchive)
try {
    $tp = Start-Process -FilePath $tarExe -ArgumentList $tarArgLine -NoNewWindow -PassThru -RedirectStandardError $tarErr
    while (-not $tp.HasExited) {
        $cur = 0; try { $cur = (Get-Item -LiteralPath $tarGz -ErrorAction SilentlyContinue).Length } catch {}
        $pct = [Math]::Min(99, [int](($cur / $denom) * 100))
        Write-Progress -Activity "Compressing (tar + gzip, medium)" -Status ("{0} / ~{1}" -f (Format-Size $cur), (Format-Size $estArchive)) -PercentComplete $pct
        Start-Sleep -Milliseconds 250
    }
    $tp.WaitForExit()
} catch {
    # Fallback: synchronous compression with no progress bar.
    & $tarExe -czf $tarGz -C $staging . 2>$null
} finally {
    Write-Progress -Activity "Compressing (tar + gzip, medium)" -Completed
    Remove-Item Env:\GZIP -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $tarErr -Force -ErrorAction SilentlyContinue
}
if (-not (Test-Path $tarGz) -or (Get-Item $tarGz).Length -eq 0) {
    Write-ErrR "Compression failed -- archive not created."
    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
    exit 1
}

$finalName = if ($encrypt) { "MigrateToLinux_UserData_$stamp.tar.gz.enc" } else { "MigrateToLinux_UserData_$stamp.tar.gz" }
$finalPath = Join-Path $OutputDir $finalName
if ($encrypt) {
    Write-Info "Encrypting (OpenSSL AES-256-CBC / PBKDF2) ..."
    # Progress driven by the encrypted OUTPUT size vs the (known) input size. The password
    # is passed via an env var (-pass env:) so it never appears on the visible command line.
    $encDenom = [Math]::Max(1, (Get-Item $tarGz).Length)
    $env:MTL_ENCPW = $EncPwd
    $encErr = [System.IO.Path]::GetTempFileName()
    $encArgLine = (@('enc','-aes-256-cbc','-pbkdf2','-salt','-pass','env:MTL_ENCPW','-in',$tarGz,'-out',$finalPath) |
                   ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '
    try {
        $ep = Start-Process -FilePath $opensslExe -ArgumentList $encArgLine -NoNewWindow -PassThru -RedirectStandardError $encErr
        while (-not $ep.HasExited) {
            $cur = 0; try { $cur = (Get-Item -LiteralPath $finalPath -ErrorAction SilentlyContinue).Length } catch {}
            $pct = [Math]::Min(99, [int](($cur / $encDenom) * 100))
            Write-Progress -Activity "Encrypting (OpenSSL AES-256-CBC / PBKDF2)" -Status ("{0} / ~{1}" -f (Format-Size $cur), (Format-Size $encDenom)) -PercentComplete $pct
            Start-Sleep -Milliseconds 250
        }
        $ep.WaitForExit()
    } catch {
        # Fallback: synchronous encryption with no progress bar.
        & $opensslExe enc -aes-256-cbc -pbkdf2 -salt -pass env:MTL_ENCPW -in $tarGz -out $finalPath 2>$null
    } finally {
        Write-Progress -Activity "Encrypting (OpenSSL AES-256-CBC / PBKDF2)" -Completed
        Remove-Item Env:\MTL_ENCPW -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $encErr -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $tarGz -Force -ErrorAction SilentlyContinue
} else {
    Move-Item -LiteralPath $tarGz -Destination $finalPath -Force
}
# Clean the clear-text staging tree (data now lives only inside the archive).
Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue

if (-not (Test-Path $finalPath)) {
    Write-ErrR "Archive creation failed."
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
Write-Info ("  Full file list     : $logPath")
exit 0
