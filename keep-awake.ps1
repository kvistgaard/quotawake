# Holds the system awake (the display may still sleep) only when BOTH:
#   - the machine is on AC power, AND
#   - a Claude Code CLI session is running (…/node_modules/@anthropic-ai/claude-code/…)
#     OR quotawake has a resume armed (pending-resume.json for a qw-launched
#     task, pending-sessions.json for stranded interactive sessions).
#
# That second condition is the subtle one: quotawake deliberately leaves NO
# process running between a limit and the reset, so there is no claude process
# to detect during the wait. Without watching the state files, the machine would
# sleep straight through the moment the whole tool exists for.
#
# Otherwise it releases the hold so normal power saving — including battery
# sleep timers — applies untouched. It never holds on battery, and never holds
# the display awake, only the system.
#
# Verify a live hold:
#   Windows  powercfg /requests          (a SYSTEM request from this pwsh PID)
#   Linux    systemd-inhibit --list      (a sleep block from quotawake)
#
# Windows and Linux only; on anything else the watcher idles without holding.

$pendingResumeFile   = Join-Path $PSScriptRoot 'pending-resume.json'
$pendingSessionsFile = Join-Path $PSScriptRoot 'pending-sessions.json'
$logPath             = Join-Path $PSScriptRoot 'keep-awake.log'
$pollSeconds         = 30
$held                = $false
$holdProcess         = $null      # Linux: the child that owns the hold

$platform = if ($PSVersionTable.PSVersion.Major -lt 6) { 'Windows' }
            elseif ($IsWindows) { 'Windows' }
            elseif ($IsLinux) { 'Linux' } else { 'Unsupported' }

if ($platform -eq 'Windows') {
  Add-Type -AssemblyName System.Windows.Forms
  Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class PowerHelper {
    [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    public static extern uint SetThreadExecutionState(uint esFlags);
}
"@
  # NB: hex literal 0x80000000 parses as Int32 -2147483648 and the [uint32] cast
  # throws (silently, leaving $null) — use the decimal value.
  $ES_CONTINUOUS      = [uint32]2147483648
  $ES_SYSTEM_REQUIRED = [uint32]1
}

function Write-Log($msg) {
  $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
  "$ts  $msg" | Out-File -FilePath $logPath -Append -Encoding utf8
}

function Test-OnAcPower {
  switch ($platform) {
    'Windows' { return ([System.Windows.Forms.SystemInformation]::PowerStatus.PowerLineStatus -eq 'Online') }
    'Linux' {
      # Mains supplies expose online=1. A desktop or VM has no battery at all,
      # in which case treat it as permanently on AC rather than never holding.
      try {
        $mains = @(Get-ChildItem '/sys/class/power_supply' -ErrorAction Stop |
                   Where-Object { (Get-Content (Join-Path $_.FullName 'type') -ErrorAction SilentlyContinue) -eq 'Mains' })
        if (-not $mains) { return $true }
        foreach ($m in $mains) {
          if ((Get-Content (Join-Path $m.FullName 'online') -ErrorAction SilentlyContinue) -eq '1') { return $true }
        }
        return $false
      } catch { return $true }
    }
  }
  return $true
}

function Test-ClaudeSessionRunning {
  # Match on the CLI's own module path so the Claude desktop app, which can sit
  # open for days, never counts as an active coding session. Both separators are
  # accepted so the same check works on either platform.
  foreach ($p in (Get-Process -Name claude -ErrorAction SilentlyContinue)) {
    try {
      if ($p.Path -and ($p.Path -like '*node_modules*@anthropic-ai*claude-code*')) { return $true }
    } catch { }
  }
  return $false
}

function Start-AwakeHold {
  switch ($platform) {
    'Windows' { [PowerHelper]::SetThreadExecutionState($ES_CONTINUOUS -bor $ES_SYSTEM_REQUIRED) | Out-Null; return $null }
    'Linux' {
      # The inhibit lasts as long as this child lives, so releasing is a kill.
      return (Start-Process systemd-inhibit -PassThru -WindowStyle Hidden -ArgumentList @(
        '--what=sleep', '--who=quotawake', '--why=quotawake is waiting for a usage-limit reset',
        '--mode=block', 'sleep', 'infinity'))
    }
  }
  return $null
}

function Stop-AwakeHold($proc) {
  if ($platform -eq 'Windows') { [PowerHelper]::SetThreadExecutionState($ES_CONTINUOUS) | Out-Null; return }
  if ($proc) { try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch {} }
}

Write-Log "watcher started (PID $PID, platform $platform)"
if ($platform -eq 'Unsupported') { Write-Log "unsupported platform - holds are disabled, watcher will idle" }

while ($true) {
  $onAC           = Test-OnAcPower
  $sessionRunning = Test-ClaudeSessionRunning
  $resumeArmed    = (Test-Path $pendingResumeFile) -or (Test-Path $pendingSessionsFile)
  $shouldHold     = $onAC -and ($sessionRunning -or $resumeArmed)

  # A child-process hold can die on its own (killed, OOM, systemd restart), so
  # treat a dead child as "not held" and re-acquire rather than believing $held.
  if ($held -and $holdProcess -and $holdProcess.HasExited) {
    Write-Log "HOLD lost (helper exited unexpectedly) - will re-acquire"
    $held = $false; $holdProcess = $null
  }

  if ($shouldHold -and -not $held) {
    $holdProcess = Start-AwakeHold
    $held = $true
    Write-Log "HOLD acquired (AC=$onAC, session=$sessionRunning, resumeArmed=$resumeArmed)"
  }
  elseif (-not $shouldHold -and $held) {
    Stop-AwakeHold $holdProcess
    $held = $false; $holdProcess = $null
    Write-Log "HOLD released (AC=$onAC, session=$sessionRunning, resumeArmed=$resumeArmed)"
  }

  Start-Sleep -Seconds $pollSeconds
}
