<#
.SYNOPSIS
    Shared: the project MEGA-TITLE + the transfer-password prompt.

.DESCRIPTION
    Dot-sourced by run_project.ps1 (the entry point), which shows the mega-title and
    asks for the encryption password FIRST -- before the "STEP n/5" section banners --
    then passes the answer to the detection step via $env:MIGRATE_XFER_PWD.

    C_detect_windows_settings.ps1 also dot-sources this so it can prompt on its own when
    run standalone (i.e. when run_project did not already prompt).

    The password protects every exported secret (WiFi passwords AND SSH private keys /
    the personal-data archive). The prompt is hidden, asks for a confirmation, has a
    15-second IDLE timeout (resets on each keystroke) with a live countdown bar, and a
    timeout / empty answer / non-interactive console all count as SKIPPED.
#>

function Show-MegaTitle {
    Write-Host ''
    Write-Host '  ###########################################################' -ForegroundColor Cyan
    Write-Host '  ##                                                       ##' -ForegroundColor Cyan
    Write-Host '  ##            M I G R A T E   T O   L I N U X             ##' -ForegroundColor Cyan
    Write-Host '  ##        Windows  ->  Linux   Migration  Toolkit         ##' -ForegroundColor Cyan
    Write-Host '  ##                                                       ##' -ForegroundColor Cyan
    Write-Host '  ###########################################################' -ForegroundColor Cyan
    Write-Host ''
}

# Live countdown bar: own line above the prompt, updates each second, resets on every
# keystroke. Twice as big -- 2 '#' per second (two are removed each second).
$Script:ShowTimer = {
    param([int]$secs, [int]$row, [int]$total)
    $cl = [Console]::CursorLeft; $ct = [Console]::CursorTop
    try {
        [Console]::SetCursorPosition(0, $row)
        $w = $total * 2
        $fill = [math]::Max(0, [math]::Min($w, $secs * 2))
        $bar = ('#' * $fill).PadRight($w, '-')
        $col = if ($secs -le 5) { 'Red' } else { 'DarkYellow' }
        Write-Host -NoNewline ("  Time left: {0,2}s  [{1}]   " -f $secs, $bar) -ForegroundColor $col
        [Console]::SetCursorPosition($cl, $ct)
    } catch {}
}
$Script:ClearTimer = {
    param([int]$row)
    $cl = [Console]::CursorLeft; $ct = [Console]::CursorTop
    try {
        [Console]::SetCursorPosition(0, $row)
        Write-Host -NoNewline (' ' * ([Console]::WindowWidth - 1))
        [Console]::SetCursorPosition($cl, $ct)
    } catch {}
}
# Read a masked ('*') line with an IDLE timeout + live countdown. Returns a hashtable
# @{ Value; Status } where Status is 'ok' | 'empty' | 'timeout' | 'noconsole'.
function Read-HostTimed {
    param([string]$Prompt, [int]$TimeoutSec = 15)
    try { $null = [Console]::KeyAvailable } catch {
        Write-Host -NoNewline $Prompt; Write-Host ''
        return @{ Value = ''; Status = 'noconsole' }
    }
    $sb = New-Object System.Text.StringBuilder
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $lastShown = -1
    Write-Host ''                          # this blank line becomes the live countdown
    $timerRow = [Console]::CursorTop - 1
    Write-Host -NoNewline $Prompt
    while ($true) {
        $remaining = [int][math]::Ceiling((($deadline) - (Get-Date)).TotalSeconds)
        if ($remaining -lt 0) { $remaining = 0 }
        if ($remaining -ne $lastShown) { & $Script:ShowTimer $remaining $timerRow $TimeoutSec; $lastShown = $remaining }
        if ($remaining -le 0) {
            & $Script:ClearTimer $timerRow; Write-Host ''
            return @{ Value = ''; Status = 'timeout' }
        }
        if ([Console]::KeyAvailable) {
            $k = [Console]::ReadKey($true)
            $deadline = (Get-Date).AddSeconds($TimeoutSec)   # idle timer resets on each keystroke
            if ($k.Key -eq 'Enter') {
                & $Script:ClearTimer $timerRow; Write-Host ''
                $v = $sb.ToString()
                if ($v -eq '') { return @{ Value = ''; Status = 'empty' } }
                return @{ Value = $v; Status = 'ok' }
            }
            elseif ($k.Key -eq 'Backspace') {
                if ($sb.Length -gt 0) { [void]$sb.Remove($sb.Length - 1, 1); Write-Host -NoNewline "`b `b" }
            }
            elseif ($k.KeyChar) { [void]$sb.Append($k.KeyChar); Write-Host -NoNewline '*' }   # masked
        } else {
            Start-Sleep -Milliseconds 100
        }
    }
}

# Visible (un-masked) y/n prompt with the same idle countdown bar. Returns $true/$false.
# A timeout or non-interactive console returns the default. Reuses the timer visuals above.
function Read-YNTimed {
    param([string]$Prompt, [int]$TimeoutSec = 15, [bool]$Default = $true)
    try { $null = [Console]::KeyAvailable } catch { return $Default }
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $lastShown = -1
    Write-Host ''
    $timerRow = [Console]::CursorTop - 1
    Write-Host -NoNewline $Prompt
    while ($true) {
        $remaining = [int][math]::Ceiling((($deadline) - (Get-Date)).TotalSeconds)
        if ($remaining -lt 0) { $remaining = 0 }
        if ($remaining -ne $lastShown) { & $Script:ShowTimer $remaining $timerRow $TimeoutSec; $lastShown = $remaining }
        if ($remaining -le 0) {
            & $Script:ClearTimer $timerRow; Write-Host ''
            Write-Host ('  (no input within the time limit -> default: ' + $(if ($Default) {'yes'} else {'no'}) + ')')
            return $Default
        }
        if ([Console]::KeyAvailable) {
            $k = [Console]::ReadKey($true)
            $deadline = (Get-Date).AddSeconds($TimeoutSec)
            switch ($k.KeyChar) {
                { $_ -eq 'y' -or $_ -eq 'Y' } { & $Script:ClearTimer $timerRow; Write-Host 'y'; return $true }
                { $_ -eq 'n' -or $_ -eq 'N' } { & $Script:ClearTimer $timerRow; Write-Host 'n'; return $false }
            }
            if ($k.Key -eq 'Enter') { & $Script:ClearTimer $timerRow; Write-Host ''; return $Default }
        } else {
            Start-Sleep -Milliseconds 100
        }
    }
}

# Prompt for the transfer password: HIDDEN entry + a "Confirm password:" re-entry,
# with the idle timeout/countdown. Prints the right Warning! for each skip reason and
# returns '' when skipped (empty / timeout / non-interactive).
function Get-XferPassword {
    param([int]$TimeoutSec = 15)
    $first = Read-HostTimed -Prompt "Enter a password to ENCRYPT exported sensitive data -- Ex: Known WiFi Networks passwords, SSH private keys, etc.`n(Enter to skip; auto-skips after 15s idle): " -TimeoutSec $TimeoutSec
    switch ($first.Status) {
        'empty' {
            Write-Host '  (empty password -> skipped)'
            Write-Host '  Warning! You skipped entering a password. Sensitive data (WiFi, ssh pvt keys, etc) will not be migrated.' -ForegroundColor Yellow
            return '' }
        'timeout' {
            Write-Host '  (no input within the time limit -> treated as empty / skipped)'
            Write-Host '  Warning! Password entry timed out. Sensitive data (WiFi, ssh pvt keys, etc) will not be migrated.' -ForegroundColor Yellow
            return '' }
        'noconsole' {
            Write-Host '  (non-interactive: no password entered -> treated as empty / skipped)'
            Write-Host '  Warning! no password could be entered. Sensitive data (WiFi, ssh pvt keys, etc) will not be migrated.' -ForegroundColor Yellow
            return '' }
    }
    while ($true) {
        $confirm = Read-HostTimed -Prompt "Confirm password: " -TimeoutSec $TimeoutSec
        if ($confirm.Status -eq 'ok' -and $confirm.Value -eq $first.Value) {
            Write-Host ("  password set! " + [char]0x2705) -ForegroundColor Green
            Write-Host ''
            return $first.Value
        }
        switch ($confirm.Status) {
            'timeout' {
                Write-Host '  (no input within the time limit -> treated as empty / skipped)'
                Write-Host '  Warning! Password entry timed out. Sensitive data (WiFi, ssh pvt keys, etc) will not be migrated.' -ForegroundColor Yellow
                return '' }
            'noconsole' { return '' }
            default { Write-Host '  Passwords did not match -- please confirm again.' -ForegroundColor Yellow }
        }
    }
}
