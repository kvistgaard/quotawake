# Keeps Windows system awake (display may still sleep) only when BOTH:
#   - the laptop is on AC power, AND
#   - a Claude Code CLI session is running (node_modules\@anthropic-ai\claude-code\bin\claude.exe)
#     OR claude-resume.ps1 has a resume armed (pending-resume.json for a
#     crun-launched task, pending-sessions.json for stranded interactive
#     sessions) — it exits between a limit hit and the reset by design, so
#     there is no claude.exe process during that wait; without this, wake
#     timers are the only thing that could resume it, and those are
#     policy-disabled on battery.
# Otherwise releases the lock so normal power-saving (incl. battery sleep timers) applies.
# Verify with: powercfg /requests   (look for a SYSTEM request from this script's pwsh PID)

# Beside this script, wherever it lives — claude-resume.ps1 writes them there too.
# These were absolute paths once, which silently broke the watcher's whole reason
# for existing if the folder was ever moved or copied to another machine: both
# Test-Path checks would just return false and the awake-lock would never be held
# during a wait.
$pendingResumeFile   = Join-Path $PSScriptRoot 'pending-resume.json'
$pendingSessionsFile = Join-Path $PSScriptRoot 'pending-sessions.json'

Add-Type -AssemblyName System.Windows.Forms

Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class PowerHelper {
    [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    public static extern uint SetThreadExecutionState(uint esFlags);
}
"@

# NB: hex literal 0x80000000 parses as Int32 -2147483648 in PowerShell and the
# [uint32] cast throws (silently here, leaving $null) — use the decimal value.
$ES_CONTINUOUS      = [uint32]2147483648
$ES_SYSTEM_REQUIRED = [uint32]1

$logPath     = Join-Path $PSScriptRoot 'keep-awake-claude.log'
$pollSeconds = 30
$held        = $false

function Write-Log($msg) {
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    "$ts  $msg" | Out-File -FilePath $logPath -Append -Encoding utf8
}

Write-Log "watcher started (PID $PID)"

while ($true) {
    $onAC = ([System.Windows.Forms.SystemInformation]::PowerStatus.PowerLineStatus -eq 'Online')

    $sessionRunning = $false
    foreach ($p in (Get-Process -Name claude -ErrorAction SilentlyContinue)) {
        try {
            if ($p.Path -and $p.Path -like '*node_modules\@anthropic-ai\claude-code*') {
                $sessionRunning = $true
                break
            }
        } catch { }
    }

    $resumeArmed = (Test-Path $pendingResumeFile) -or (Test-Path $pendingSessionsFile)
    $shouldHold = $onAC -and ($sessionRunning -or $resumeArmed)

    if ($shouldHold -and -not $held) {
        [PowerHelper]::SetThreadExecutionState($ES_CONTINUOUS -bor $ES_SYSTEM_REQUIRED) | Out-Null
        $held = $true
        Write-Log "HOLD acquired (AC=$onAC, session=$sessionRunning, resumeArmed=$resumeArmed)"
    }
    elseif (-not $shouldHold -and $held) {
        [PowerHelper]::SetThreadExecutionState($ES_CONTINUOUS) | Out-Null
        $held = $false
        Write-Log "HOLD released (AC=$onAC, session=$sessionRunning, resumeArmed=$resumeArmed)"
    }

    Start-Sleep -Seconds $pollSeconds
}
