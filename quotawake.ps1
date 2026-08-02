<#
.SYNOPSIS
  Run a Claude Code task headlessly and auto-resume across usage-limit resets.

.WHY
  Claude Code has no hook that fires on "usage limit reached" and no built-in
  auto-resume when the usage window resets. This wrapper fills the gap: it runs
  `claude` in print/headless mode, and when it stops on a usage limit it reads
  the reset time from Claude's own message and arms a resume for that moment.

.HOW THE RESUME WORKS (no resident process)
  On a limit, the script does NOT sit and wait — a waiting process dies with a
  closed window, a logoff, a reboot, or Modern Standby, which is why in-process
  waiting proved unreliable. Instead it:
    1. saves the pending work to pending-resume.json (next to this script),
    2. registers a one-shot Windows Scheduled Task at reset time (+buffer),
    3. exits (code 5).
  Between limit and reset nothing runs: zero CPU, zero RAM. The task fires at
  the reset (StartWhenAvailable = it still fires after the machine was asleep
  or off; WakeToRun = it may wake the machine, policy permitting) and re-runs
  this script with -Resume, which picks the state up and continues the chain.
  A logon task (created once by -Install) reconciles pending state at every
  login as a belt-and-braces fallback.

.SESSION RESCUE (interactive sessions)
  Interactive TUI sessions never pass through this wrapper, but their limit
  stops are recorded in the transcript (~/.claude/projects/<dir>/<id>.jsonl) as
  a line with top-level "error":"rate_limit" whose text carries the reset time.
  An open TUI on an awake machine auto-continues ~3 min after the reset — but a
  closed or abandoned session stays dead forever. So every -Reconcile pass also
  scans recent transcripts for sessions *stranded* on a rate-limit stop, arms a
  one-shot task (QuotaWake-FireSessions) for reset+buffer, and then resumes
  each stranded conversation headlessly: `claude --resume <sessionId> -p ...`
  run in the session's own project folder. State: pending-sessions.json (also
  watched by keep-awake.ps1); handled stops: resumed-sessions.json.

.NOTES
  - Headless only (`claude -p`); it cannot type into a live interactive TUI.
    (Session rescue forks a stranded conversation into a new headless run; the
    TUI window that hit the limit stays as it was.)
  - For unattended edits pass -PermissionMode acceptEdits, or set an allowlist
    in .claude/settings.json; headless claude cannot approve its own actions.
  - Exit codes: 0 done · 2 bad -At · 4 hit MaxRounds · 5 resume armed ·
    otherwise claude's own non-zero exit code.
  - -SelfTest defines the functions and returns, for quotawake.Tests.ps1.

.EXAMPLES
  # One-time setup: create the logon reconciler ("startup service"):
  .\quotawake.ps1 -Install

  # Fire-and-forget a task; on a limit it arms the scheduled resume and exits:
  .\quotawake.ps1 -Task "revise the note per my inline comments" -PermissionMode acceptEdits

  # Resume the most recent conversation (arms itself the same way if limited):
  .\quotawake.ps1 -Continue

  # Pre-schedule: arm the resume for a time you saw on screen, and exit:
  .\quotawake.ps1 -Continue -At "3pm"
#>

param(
  [Parameter(Position = 0)]
  [string]$Task = "continue and finish the pending work",

  # Optional: arm the resume for this time ("3pm", "15:00", "2026-07-04 20:00")
  # and exit immediately. Normally unneeded — the reset time is read from
  # Claude's own limit message.
  [string]$At,

  # Resume the most recent conversation instead of starting a fresh one.
  [switch]$Continue,

  # Directory to run in (defaults to the current directory).
  [string]$Project = (Get-Location).Path,

  # Passed to `claude --permission-mode`. Leave empty to prompt (safe default).
  [string]$PermissionMode = "",

  # Max chained claude runs across all resumes (tracked in the state file).
  [int]$MaxRounds = 12,

  # Extra seconds past the announced reset before firing, so a not-quite-open
  # window isn't re-hit.
  [int]$BufferSeconds = 150,

  # Fallback: if a limit message has no parseable reset time, refire after
  # this many minutes.
  [int]$PollMinutes = 20,

  # Entry point used by the one-shot scheduled task: load pending-resume.json
  # and run the next round.
  [switch]$Resume,

  # Entry point used by the logon task: if pending state exists, run it (if
  # overdue) or re-arm the one-shot task (if still in the future). Silent and
  # instant when there is nothing pending.
  [switch]$Reconcile,

  # One-time setup: register the logon reconciler task.
  [switch]$Install,

  # Remove the logon task, any armed one-shot task, and the state file.
  [switch]$Uninstall,

  # Check that this machine's platform integration actually works, and exit.
  # This exists because the Linux backend cannot be exercised from a Windows
  # development box: rather than asking anyone to trust untested code, -Doctor
  # proves or disproves each piece where it actually runs.
  [switch]$Doctor,

  # Show what has been resumed and how to get back into it. The one command a
  # user needs after a rescue: which project, which session, still running?
  [switch]$List,

  # Define the functions and return without running — for the test harness.
  [switch]$SelfTest
)

$ErrorActionPreference = "Stop"
# claude's non-zero exit on a limit must NOT throw (PS 7.3+ would otherwise turn
# a native non-zero exit into a terminating error under -ErrorAction Stop).
$PSNativeCommandUseErrorActionPreference = $false
# Read claude's UTF-8 output correctly (avoids "·" -> "┬╖" mojibake in the log).
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$script:StateFile = Join-Path $ScriptDir "pending-resume.json"
$FireTaskName  = "QuotaWake-Fire"
$LogonTaskName = "QuotaWake-Logon"
$HiddenLauncher = Join-Path $ScriptDir "run-hidden.vbs"
$script:logFile = Join-Path $Project "quotawake.log"

# --- interactive-session rescue (see the region of the same name below) ---
$SessionsFireTaskName         = "QuotaWake-FireSessions"
$script:SessionsStateFile     = Join-Path $ScriptDir "pending-sessions.json"
$script:ProcessedSessionsFile = Join-Path $ScriptDir "resumed-sessions.json"
$script:RescueLockFile        = Join-Path $ScriptDir ".session-rescue.lock"
$script:ProjectsRoot          = Join-Path $env:USERPROFILE ".claude\projects"
$SessionScanWindowHours = 48    # only transcripts touched this recently are scanned
$SessionBufferSeconds   = 300   # an open TUI auto-continues ~3 min after reset; it must win
$SessionMaxAttempts     = 8     # re-arm cap while the window stays shut
$SessionResumeTask      = "You were interrupted by a usage-limit reset. Continue the pending work from where it left off. If it was already complete, reply DONE."
$SessionPermissionMode  = "acceptEdits"
# Dropped in the rescued project's OWN folder, not next to this script: the
# terminal that hit the limit can never update itself, so the only way the user
# learns the work is finished is to find the evidence where they are already
# looking. An invisible success reads exactly like a failure — that is what made
# this tool look broken for weeks, and cost a duplicated run on 2026-07-31.
$SessionNoticeFile      = "QUOTAWAKE-RESUMED.md"
# How long a reconcile pass waits for a dispatched agent before writing the
# notice anyway. Timing out is not a failure — the agent keeps running and stays
# visible in `claude agents`; only the notice's "Result" line gets vaguer.
$SessionAgentWaitSeconds = 240

function Log([string]$msg) {
  $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $msg
  Write-Host $line
  Add-Content -Path $script:logFile -Value $line -Encoding UTF8
}

function Resolve-ClockTime([int]$hr, [string]$minStr, [string]$apStr, [datetime]$anchor = (Get-Date)) {
  # Turn hour/minute/am-pm into the next occurrence of that clock time after
  # $anchor (defaults to now; session rescue anchors to the limit's timestamp
  # so an already-elapsed reset isn't pushed a day into the future).
  $mn = if ($minStr) { [int]$minStr } else { 0 }
  $ap = if ($apStr) { $apStr.ToLower() } else { "" }
  if ($ap -eq "pm" -and $hr -lt 12) { $hr += 12 }
  if ($ap -eq "am" -and $hr -eq 12) { $hr = 0 }
  $candidate = $anchor.Date.AddHours($hr).AddMinutes($mn)
  if ($candidate -le $anchor) { $candidate = $candidate.AddDays(1) }
  return $candidate
}

function Parse-ResetTime([string]$text, [datetime]$anchor = (Get-Date)) {
  # Scrape a reset time out of claude's output. Returns [datetime] or $null.
  if ([string]::IsNullOrWhiteSpace($text)) { return $null }

  # 1) Full timestamp: 2026-07-04T20:00 or 2026-07-04 20:00
  $m = [regex]::Match($text, '(\d{4}-\d{2}-\d{2}[ T]\d{1,2}:\d{2}(:\d{2})?)')
  if ($m.Success) { try { return [datetime]::Parse($m.Groups[1].Value) } catch {} }

  # 2) "resets in 2h 15m" / "reset in 45m"
  $m = [regex]::Match($text, '(?i)reset[s]?\s+in\s+(?:(\d+)\s*h)?\s*(?:(\d+)\s*m)?')
  if ($m.Success -and ($m.Groups[1].Value -or $m.Groups[2].Value)) {
    $h = 0; $min = 0
    if ($m.Groups[1].Value) { $h = [int]$m.Groups[1].Value }
    if ($m.Groups[2].Value) { $min = [int]$m.Groups[2].Value }
    if ($h -or $min) { return $anchor.AddHours($h).AddMinutes($min) }
  }

  # 3) "resets 1:30pm" / "resets at 3pm" / "reset at 15:00" (the "at" is optional)
  $m = [regex]::Match($text, '(?i)reset[s]?\s+(?:at\s+)?(\d{1,2})(?::(\d{2}))?\s*([ap]m)?')
  if ($m.Success) {
    return (Resolve-ClockTime ([int]$m.Groups[1].Value) $m.Groups[2].Value $m.Groups[3].Value $anchor)
  }

  return $null
}

function Parse-AtTime([string]$text) {
  # Parse a user-supplied -At value: "3pm", "3:30 pm", "15:00", or a full date.
  if ([string]::IsNullOrWhiteSpace($text)) { return $null }
  # A bare clock time first, so a non-US locale (fr-FR etc.) can't choke on "3pm".
  $m = [regex]::Match($text, '(?i)^\s*(\d{1,2})(?::(\d{2}))?\s*([ap]m)?\s*$')
  if ($m.Success -and [int]$m.Groups[1].Value -le 23) {
    return (Resolve-ClockTime ([int]$m.Groups[1].Value) $m.Groups[2].Value $m.Groups[3].Value)
  }
  # Otherwise a full date/time, parsed culture-independently.
  try { return [datetime]::Parse($text, [Globalization.CultureInfo]::InvariantCulture) } catch {}
  try { return [datetime]::Parse($text) } catch {}
  return $null
}

# A usage/quota stop (not an ordinary completion). Anchored on the phrases claude
# actually prints. Matching is only trusted together with a non-zero exit.
$limitPattern = '(?i)(hit your (session|usage|weekly|5-hour) limit|(usage|rate|session|weekly) limit|limit reached|limit will reset|reset[s]?\s+(?:at\s+)?\d|try again (later|at)|\d+-hour limit)'

function Invoke-Claude([bool]$continueRun) {
  $claudeArgs = @()
  if ($continueRun) { $claudeArgs += "--continue" }
  if ($PermissionMode) { $claudeArgs += @("--permission-mode", $PermissionMode) }
  $claudeArgs += @("-p", $Task)
  Log ("claude " + ($claudeArgs -join " "))
  # Pipe empty stdin so `claude -p` doesn't wait 3s for piped input it will never get.
  $out = ($null | & claude @claudeArgs 2>&1 | Out-String)
  $code = $LASTEXITCODE
  Add-Content -Path $script:logFile -Value $out -Encoding UTF8
  return @{ Text = $out; Code = $code }
}

# ---------- pending-resume state ----------
function Save-PendingState([datetime]$fireAt, [int]$roundsUsed, [bool]$continueNext) {
  @{
    project        = $Project
    task           = $Task
    permissionMode = $PermissionMode
    continue       = $continueNext
    fireAt         = $fireAt.ToString("o")
    roundsUsed     = $roundsUsed
    maxRounds      = $MaxRounds
    bufferSeconds  = $BufferSeconds
    pollMinutes    = $PollMinutes
    saved          = (Get-Date).ToString("o")
  } | ConvertTo-Json | Set-Content -Path $script:StateFile -Encoding UTF8
}

function Load-PendingState {
  if (Test-Path $script:StateFile) {
    try { return (Get-Content $script:StateFile -Raw | ConvertFrom-Json) } catch { return $null }
  }
  return $null
}

function Get-StateFireAt($st) {
  # ConvertFrom-Json may hand back fireAt as a [datetime] already (pwsh parses
  # ISO strings), possibly in UTC — normalise to a local [datetime] either way.
  $v = $st.fireAt
  if ($v -is [datetime]) {
    if ($v.Kind -eq [System.DateTimeKind]::Utc) { return $v.ToLocalTime() }
    return $v
  }
  return [datetime]::Parse([string]$v, $null, [System.Globalization.DateTimeStyles]::RoundtripKind)
}

function Clear-PendingState {
  Remove-Item $script:StateFile -Force -ErrorAction SilentlyContinue
  Unregister-ScheduledJob $FireTaskName
}

# ---------- platform layer ----------
# Everything OS-specific lives between here and the end of this section:
# scheduling, desktop notifications, autostart and the shell shortcut. The rest
# of the script is ordinary PowerShell and runs unchanged on all three systems.
#
# The scheduling contract is deliberately narrow:
#   Register-ScheduledJob -Name <n> -Arguments <string> [-FireAt <dt>] [-IntervalMinutes <n>]
#   Unregister-ScheduledJob -Name <n>
#   Test-ScheduledJob -Name <n>   -> [bool]
#
# A backend must provide two guarantees, both load-bearing:
#   1. a job whose moment passed while the machine was asleep or off still runs
#      once the machine is back  (Windows StartWhenAvailable / systemd
#      Persistent=true);
#   2. the registration survives reboot and logoff.
# Waking a *sleeping* machine is explicitly NOT required: on Windows it needs
# wake timers (AC-only on typical laptop policy) and on Linux it needs root. So
# a rescue is delayed to the next wake, never lost — the same behaviour Windows
# already has on battery.
#
# Supported: Windows and Linux. A launchd backend for macOS was written and then
# removed at ac11ea2 because there was no Mac to test it on, and an untested
# backend that silently registers nothing is worse than none at all — this tool
# has already been broken four times by failures that looked like successes.
# `git show ac11ea2 -- quotawake.ps1` has it if a Mac ever becomes available.

function Get-Platform {
  if ($PSVersionTable.PSVersion.Major -lt 6) { return 'Windows' }  # 5.1 has no $IsWindows
  if ($IsWindows) { return 'Windows' }
  if ($IsMacOS)   { return 'macOS' }   # detected only so it can be refused by name
  if ($IsLinux)   { return 'Linux' }
  return 'Unknown'
}
$script:Platform = Get-Platform

function Assert-SupportedPlatform {
  # Every backend below switches on $script:Platform, and a switch with no
  # matching branch does nothing at all — quietly. On an unsupported OS that
  # would mean -Install reporting success while registering no job whatsoever.
  # Fail loudly instead, at the one place all entry points pass through.
  if ($script:Platform -in @('Windows', 'Linux')) { return }
  $extra = if ($script:Platform -eq 'macOS') {
    "The launchd backend was removed at ac11ea2 because it could not be tested."
  } else { "" }
  throw ("quotawake supports Windows and Linux; this is '{0}'. {1}" -f $script:Platform, $extra).Trim()
}

function Get-JobSlug([string]$name) {
  # 'QuotaWake-FireSessions' -> 'firesessions'; used for systemd unit names,
  # which are lowercase-by-convention and must be stable.
  return (($name -replace '^QuotaWake-', '') -replace '[^A-Za-z0-9]', '').ToLowerInvariant()
}

function Get-SelfArgv([string]$arguments) {
  # argv that re-runs this script with $arguments, without a console window.
  # Windows keeps the .vbs shim (Task Scheduler would otherwise flash a
  # console); systemd already runs detached, so it calls pwsh.
  if ($script:Platform -eq 'Windows') {
    return @('wscript.exe', ('"{0}" {1}' -f $HiddenLauncher, $arguments))
  }
  $pwsh = try { (Get-Process -Id $PID).Path } catch { $null }
  if (-not $pwsh) { $pwsh = 'pwsh' }
  $argv = @($pwsh, '-NoProfile', '-NonInteractive', '-File', (Join-Path $ScriptDir 'quotawake.ps1'))
  foreach ($a in ($arguments -split '\s+' | Where-Object { $_ })) { $argv += $a }
  return $argv
}

# --- Linux: systemd --user ---
function Get-SystemdUnitDir { Join-Path $HOME '.config/systemd/user' }
function Get-SystemdUnitName([string]$name) { 'quotawake-' + (Get-JobSlug $name) }
function New-SystemdUnits([string]$name, [string]$arguments, $fireAt, [int]$intervalMinutes) {
  # Returns @{ Service = <text>; Timer = <text> }. Pure, so it is unit-testable
  # off Linux and can be handed to `systemd-analyze verify`.
  # Persistent=true is the systemd spelling of StartWhenAvailable: a timer whose
  # moment passed while the machine was off fires once it is back.
  $exec = ($(Get-SelfArgv $arguments) | ForEach-Object {
    if ($_ -match '\s') { '"{0}"' -f $_ } else { $_ }
  }) -join ' '
  $slug = Get-JobSlug $name
  $service = @"
[Unit]
Description=quotawake $slug

[Service]
Type=oneshot
WorkingDirectory=$ScriptDir
ExecStart=$exec
"@
  $timerBody = if ($null -ne $fireAt) {
    "OnCalendar=$($fireAt.ToString('yyyy-MM-dd HH:mm:ss'))`nAccuracySec=1s"
  } else {
    "OnBootSec=1min`nOnUnitActiveSec=${intervalMinutes}min`nAccuracySec=30s"
  }
  $timer = @"
[Unit]
Description=quotawake $slug timer

[Timer]
$timerBody
Persistent=true

[Install]
WantedBy=timers.target
"@
  return @{ Service = $service; Timer = $timer }
}

function Invoke-Systemctl([string[]]$systemctlArgs) {
  try { & systemctl --user @systemctlArgs 2>&1 | Out-Null; return ($LASTEXITCODE -eq 0) } catch { return $false }
}

# --- the contract ---
function Register-ScheduledJob {
  param([string]$Name, [string]$Arguments, [datetime]$FireAt, [int]$IntervalMinutes)
  $once = $PSBoundParameters.ContainsKey('FireAt')
  switch ($script:Platform) {
    'Windows' {
      $argv    = Get-SelfArgv $Arguments
      $action  = New-ScheduledTaskAction -Execute $argv[0] -Argument $argv[1] -WorkingDirectory $ScriptDir
      if ($once) {
        $trigger  = New-ScheduledTaskTrigger -Once -At $FireAt
        $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -WakeToRun `
                    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                    -ExecutionTimeLimit ([TimeSpan]::Zero)
        Register-ScheduledTask -TaskName $Name -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null
      } else {
        # AtLogOn alone was measured firing 0 times in 8 days on a Modern
        # Standby machine (484 resumes, 0 real logons): the session suspends
        # rather than logging off. The periodic trigger is the real coverage;
        # AtLogOn is kept for genuine reboots. No -RepetitionDuration, because
        # omitting it repeats indefinitely while [TimeSpan]::MaxValue overflows
        # the task XML. -AtStartup would need elevation, breaking "no admin".
        $atLogon  = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
        $periodic = New-ScheduledTaskTrigger -Once -At (Get-Date) `
                    -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes)
        $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable `
                    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                    -ExecutionTimeLimit (New-TimeSpan -Hours 12)
        Register-ScheduledTask -TaskName $Name -Action $action -Trigger @($atLogon, $periodic) `
          -Settings $settings -Force | Out-Null
      }
    }
    'Linux' {
      $dir = Get-SystemdUnitDir
      New-Item -ItemType Directory -Force -Path $dir | Out-Null
      $unit  = Get-SystemdUnitName $Name
      $units = if ($once) { New-SystemdUnits $Name $Arguments $FireAt 0 }
               else       { New-SystemdUnits $Name $Arguments $null $IntervalMinutes }
      Set-Content -LiteralPath (Join-Path $dir "$unit.service") -Value $units.Service -Encoding UTF8
      Set-Content -LiteralPath (Join-Path $dir "$unit.timer")   -Value $units.Timer   -Encoding UTF8
      [void](Invoke-Systemctl @('daemon-reload'))
      [void](Invoke-Systemctl @('enable', '--now', "$unit.timer"))
    }
  }
}

function Unregister-ScheduledJob([string]$Name) {
  switch ($script:Platform) {
    'Windows' { Unregister-ScheduledTask -TaskName $Name -Confirm:$false -ErrorAction SilentlyContinue }
    'Linux' {
      $unit = Get-SystemdUnitName $Name
      [void](Invoke-Systemctl @('disable', '--now', "$unit.timer"))
      Remove-Item -LiteralPath (Join-Path (Get-SystemdUnitDir) "$unit.service"), `
                               (Join-Path (Get-SystemdUnitDir) "$unit.timer") -Force -ErrorAction SilentlyContinue
      [void](Invoke-Systemctl @('daemon-reload'))
    }
  }
}

function Test-ScheduledJob([string]$Name) {
  switch ($script:Platform) {
    'Windows' { return [bool](Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue) }
    'Linux'   { return (Test-Path -LiteralPath (Join-Path (Get-SystemdUnitDir) ((Get-SystemdUnitName $Name) + '.timer'))) }
  }
  return $false
}

# ---------- scheduled tasks (thin wrappers over the contract) ----------
function Register-FireTask([datetime]$fireAt) {
  Register-ScheduledJob -Name $FireTaskName -Arguments '-Resume' -FireAt $fireAt
}

function Register-LogonTask {
  Register-ScheduledJob -Name $LogonTaskName -Arguments '-Reconcile' -IntervalMinutes 15
}

# ---------- interactive-session rescue ----------
# Interactive TUI sessions record a usage-limit stop as a transcript line with
# top-level "error":"rate_limit" — a synthetic assistant message whose text
# carries the reset time ("You've hit your session limit · resets 9:50pm ...").
# A session whose LAST real event is such a line is stranded: nothing anywhere
# will ever resume it. The reconciler finds those and resumes them headlessly.

function ConvertTo-IsoUtcString($v) {
  # Normalise a transcript/state timestamp to one canonical UTC ISO form.
  # ConvertFrom-Json silently turns ISO strings into [datetime] (and a plain
  # [string] cast of those is invariant-culture, which a dd/MM machine culture
  # then misparses) — so every timestamp that gets stored or compared MUST go
  # through here, or (sessionId, limitTs) pairs stop matching across restarts.
  if ($v -is [datetime]) { return $v.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ") }
  $s = [string]$v
  try {
    return ([datetime]::Parse($s, [Globalization.CultureInfo]::InvariantCulture,
      [Globalization.DateTimeStyles]::RoundtripKind)).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
  } catch { return $s }
}

function ConvertTo-LocalDateTime($v) {
  # Same normalisation as above, handed back as a local [datetime] for
  # comparison against a parsed reset time. Returns $null if unreadable.
  try {
    return ([datetime]::Parse((ConvertTo-IsoUtcString $v), [Globalization.CultureInfo]::InvariantCulture,
      [Globalization.DateTimeStyles]::RoundtripKind)).ToLocalTime()
  } catch { return $null }
}

function Find-StrandedSession([string]$jsonlPath) {
  # Returns @{SessionId;Cwd;LimitTs;LimitText;Transcript} if the transcript's
  # last real event is a rate-limit stop; $null if it completed or moved on.
  #
  # Scans BACKWARDS and stops at the first genuine conversation event. Only
  # user/assistant lines count; a transcript keeps accreting bookkeeping lines
  # (system, mode, permission-mode, ai-title, custom-title, last-prompt,
  # queue-operation, file-history-*, attachment, bridge-session, agent-name)
  # long after the conversation itself has stopped, and merely opening the
  # /resume picker adds more.
  #
  # This used to read a fixed 40-line tail forwards, which was the bug that
  # made session rescue never once fire: bookkeeping pushes the rate-limit line
  # out of a short window within minutes, after which a dead session looks
  # perfectly healthy. Measured 2026-07-25 across the four transcripts here
  # that had ever hit a limit, the stop sat 52 / 335 / 670 / 1707 lines from
  # the end — every one of them invisible at 40. Scanning backwards makes the
  # verdict independent of trailing volume, so a wider window can only help.
  #
  # Lines are JSON-parsed before being trusted: a transcript can *quote* a
  # rate-limit line inside tool output (this project's own transcripts do), so
  # a substring match alone would false-fire.
  #
  # A stop counts as CLEARED only when the session is demonstrably back at
  # work: an assistant turn, at or after the announced reset, that actually
  # uses a tool. Anything weaker has repeatedly proved wrong here, because
  # people talk to a limited session without resuming its work:
  #   - "any later event = recovered" lost the 15:00 rescue on 2026-07-31.
  #     Work was cut off mid-tool-use at 12:19 local; the lone question
  #     "What's this session ID?" answered at 15:01:21 — 81 seconds past the
  #     reset — stood the rescue down while v0.4 stayed unwritten.
  #   - "any event after the reset = recovered" fails the same case, since that
  #     question happened to be asked just after 15:00.
  # An agent that has genuinely picked the work back up runs tools; a one-line
  # chat reply does not. That is the discriminator, and it keeps the property
  # that matters: an open TUI auto-continues ~3 min past the reset and resumes
  # real tool work, so it still wins over a headless fork.
  #
  # The asymmetry is deliberate. A needless resume costs a fork that reads the
  # transcript and replies DONE; a missed resume silently abandons the user's
  # work for hours. When in doubt, resume.
  foreach ($window in @(500, 5000, 0)) {
    $lines = @()
    try {
      $lines = if ($window -gt 0) { @(Get-Content -Path $jsonlPath -Tail $window -Encoding UTF8 -ErrorAction Stop) }
               else                { @(Get-Content -Path $jsonlPath -Encoding UTF8 -ErrorAction Stop) }
    } catch { return $null }

    # Newest genuine rate-limit stop in the window. Only candidate lines are
    # parsed, so healthy transcripts cost a regex sweep and nothing more.
    $limIdx = -1; $limEv = $null
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
      if ($lines[$i] -notmatch '"error"\s*:\s*"rate_limit"') { continue }
      $ev = $null
      try { $ev = $lines[$i] | ConvertFrom-Json } catch { continue }
      # Parsed, not substring-matched: a transcript can quote a rate-limit line
      # inside tool output (this project's own transcripts do).
      if ($ev.type -in @('user', 'assistant') -and $ev.error -eq 'rate_limit' -and $ev.sessionId) {
        $limIdx = $i; $limEv = $ev; break
      }
    }
    if ($limIdx -lt 0) {
      # No stop here. Widen only when the window held no conversation at all
      # (pure bookkeeping), so healthy transcripts are never re-read in full.
      if ($lines | Where-Object { $_ -match '"type"\s*:\s*"(user|assistant)"' } | Select-Object -First 1) { return $null }
      if ($lines.Count -lt $window) { return $null }
      continue
    }

    $text = ''
    try { $text = @($limEv.message.content | Where-Object { $_.type -eq 'text' } | ForEach-Object { $_.text }) -join ' ' } catch {}
    $hit = @{
      SessionId  = [string]$limEv.sessionId
      Cwd        = [string]$limEv.cwd
      LimitTs    = ConvertTo-IsoUtcString $limEv.timestamp
      LimitText  = $text
      Transcript = $jsonlPath
    }

    $anchor = ConvertTo-LocalDateTime $hit.LimitTs
    if ($null -eq $anchor) { return $hit }
    $reset = Parse-ResetTime $hit.LimitText $anchor
    if ($null -eq $reset) { return $hit }   # unreadable reset: assume stranded

    for ($j = $limIdx + 1; $j -lt $lines.Count; $j++) {
      if ($lines[$j] -notmatch '"type"\s*:\s*"assistant"') { continue }
      $e2 = $null
      try { $e2 = $lines[$j] | ConvertFrom-Json } catch { continue }
      if ($e2.type -ne 'assistant' -or $e2.isApiErrorMessage) { continue }
      $ts = ConvertTo-LocalDateTime $e2.timestamp
      if ($null -eq $ts -or $ts -lt $reset) { continue }
      $usedTool = $false
      try { $usedTool = [bool]@($e2.message.content | Where-Object { $_.type -eq 'tool_use' }).Count } catch {}
      if ($usedTool) { return $null }       # genuinely back at work
    }
    return $hit
  }
  return $null
}

# A handled (sessionId, limitTs) pair is never resumed twice; a resumed fork
# that hits a NEW limit strands its own new transcript, so the chain continues
# under a fresh pair. The list is capped so the file can't grow unbounded.
function Get-ProcessedSessions {
  if (Test-Path $script:ProcessedSessionsFile) {
    try { return @(Get-Content $script:ProcessedSessionsFile -Raw | ConvertFrom-Json) } catch {}
  }
  return @()
}

function Add-ProcessedSession([string]$sessionId, [string]$limitTs, [string]$cwd = '', [string]$resumedAs = '', [string]$label = '') {
  # This file is not only a duplicate-suppression ledger — it is the map the
  # user opens to answer "which of these ids is mine?". A row of two UUIDs and
  # a timestamp cannot answer that, so every row also carries the project it
  # belongs to, the name shown in `claude agents`, and the id of the session
  # that took over. Extra fields are optional: older rows stay readable.
  $all = @(Get-ProcessedSessions | Where-Object { -not ($_.sessionId -eq $sessionId -and $_.limitTs -eq $limitTs) })
  $row = [ordered]@{
    project      = $(if ($cwd) { try { Split-Path -Leaf $cwd } catch { '' } } else { '' })
    name         = $label
    resumedAs    = $resumedAs
    stoppedId    = $sessionId
    projectPath  = $cwd
    limitTs      = $limitTs
    handled      = (Get-Date).ToString("o")
    # Kept under the original key as well: Test-ProcessedSession matches on it,
    # and so do the rows written before this file grew the friendlier fields.
    sessionId    = $sessionId
  }
  $all += [pscustomobject]$row
  ConvertTo-Json -InputObject @($all | Select-Object -Last 200) -Depth 5 |
    Set-Content -Path $script:ProcessedSessionsFile -Encoding UTF8
}

function Test-ProcessedSession($processed, [string]$sessionId, [string]$limitTs) {
  foreach ($p in $processed) {
    if ($p.sessionId -eq $sessionId -and (ConvertTo-IsoUtcString $p.limitTs) -eq $limitTs) { return $true }
  }
  return $false
}

function Save-SessionsState([datetime]$fireAt, $sessions, [int]$attempt) {
  $payload = @{
    fireAt   = $fireAt.ToString("o")
    attempt  = $attempt
    saved    = (Get-Date).ToString("o")
    sessions = @($sessions | ForEach-Object {
      @{ sessionId = $_.SessionId; cwd = $_.Cwd; limitTs = $_.LimitTs; transcript = $_.Transcript }
    })
  }
  ConvertTo-Json -InputObject $payload -Depth 5 | Set-Content -Path $script:SessionsStateFile -Encoding UTF8
}

function Load-SessionsState {
  if (Test-Path $script:SessionsStateFile) {
    try { return (Get-Content $script:SessionsStateFile -Raw | ConvertFrom-Json) } catch { return $null }
  }
  return $null
}

function Clear-SessionsState {
  Remove-Item $script:SessionsStateFile -Force -ErrorAction SilentlyContinue
  Unregister-ScheduledJob $SessionsFireTaskName
}

function Get-AgentList {
  # `claude agents --json --all` lists interactive AND background sessions —
  # the same set the Claude app shows. Best-effort; never throws.
  try {
    $json = (& claude agents --json --all 2>$null | Out-String)
    if ([string]::IsNullOrWhiteSpace($json)) { return @() }
    return @($json | ConvertFrom-Json)
  } catch { return @() }
}

function Get-LiveSessionIds {
  # Session ids currently held by a running process. A stop line in a transcript
  # says the session hit a limit; it does NOT say the session is gone. Three
  # kinds of live session must never be rescued:
  #
  #   * the user's own open terminal — Claude Code's TUI continues by itself
  #     after a reset, so dispatching a background copy duplicates the work in a
  #     window the user cannot see;
  #   * a background agent this tool dispatched earlier — rescuing it forks the
  #     rescue, and since each fork's transcript is scanned in turn the result is
  #     a chain that spawns one agent per tick forever;
  #   * anything merely blocked (waiting on a permission prompt) — that is a
  #     stalled session needing a human, not a stranded one needing a resume.
  #
  # On 2026-08-01 the absence of this check forked a live interactive session
  # three deep (one live window -> its rescue -> its rescue) in half an hour.
  # An empty result means "could not tell" and is deliberately non-blocking: the
  # processed ledger and the fire-time buffer still bound the damage.
  $live = @{}
  foreach ($a in (Get-AgentList)) {
    $sid = [string]$a.sessionId
    if (-not $sid) { continue }
    # A pid is the strongest signal: something is attached to it right now.
    $alive = [bool]$a.pid
    # Terminal states are the only ones safe to treat as finished.
    $state = ([string]$a.state).ToLowerInvariant()
    if ($state -and $state -notin @('done', 'failed', 'stopped', 'killed')) { $alive = $true }
    if ($alive) { $live[$sid] = $true }
  }
  return $live
}

function Scan-StrandedSessions {
  # Every *.jsonl directly under a project dir (subagent transcripts live in
  # subdirectories and are skipped), touched within the scan window — plus any
  # transcript already armed in the state file whose mtime has aged out of the
  # window (a weekly-limit wait can outlive it).
  $cutoff = (Get-Date).AddHours(-$SessionScanWindowHours)
  $files = @()
  if (Test-Path $script:ProjectsRoot) {
    $files = @(Get-ChildItem $script:ProjectsRoot -Directory -ErrorAction SilentlyContinue |
      ForEach-Object { Get-ChildItem $_.FullName -Filter *.jsonl -File -ErrorAction SilentlyContinue } |
      Where-Object { $_.LastWriteTime -gt $cutoff })
  }
  $st = Load-SessionsState
  if ($st) {
    $known = @($files | ForEach-Object { $_.FullName })
    foreach ($s in @($st.sessions)) {
      if ($s.transcript -and ($known -notcontains $s.transcript) -and (Test-Path $s.transcript)) {
        $files += Get-Item $s.transcript
      }
    }
  }
  $processed = Get-ProcessedSessions
  $live      = Get-LiveSessionIds
  $found = @()
  foreach ($f in $files) {
    $hit = Find-StrandedSession $f.FullName
    if ($null -eq $hit) { continue }
    if (Test-ProcessedSession $processed $hit.SessionId $hit.LimitTs) { continue }
    if ($live.ContainsKey($hit.SessionId)) {
      # Not processed and not stranded — just busy. Skipped silently rather than
      # recorded, so it stays eligible once the process really does go away.
      Log ("session-rescue: {0} is still live; not a rescue target." -f $hit.SessionId)
      continue
    }
    $found += $hit
  }
  return $found
}

function Register-SessionsFireTask([datetime]$fireAt) {
  # Same shape as Register-FireTask, but re-enters via -Reconcile so a single
  # code path serves both the punctual one-shot and the 15-min safety net.
  Register-ScheduledJob -Name $SessionsFireTaskName -Arguments '-Reconcile' -FireAt $fireAt
}

function Get-BackgroundAgentState([string]$bgId) {
  try {
    foreach ($a in (Get-AgentList)) {
      if ($a.id -eq $bgId -or ([string]$a.sessionId).StartsWith($bgId)) {
        if ($a.state)  { return [string]$a.state }
        if ($a.status) { return [string]$a.status }
      }
    }
  } catch {}
  return $null
}

function Get-AgentTranscript([string]$bgId) {
  # A dispatched agent gets a fresh session id; its transcript is named after it.
  try {
    return @(Get-ChildItem $script:ProjectsRoot -Directory -ErrorAction SilentlyContinue |
      ForEach-Object { Get-ChildItem $_.FullName -Filter "$bgId*.jsonl" -File -ErrorAction SilentlyContinue })[0]
  } catch { return $null }
}

function Get-LastAssistantText([string]$path) {
  # The run's final visible message, for the notice. `claude logs` is useless
  # here — it replays raw TUI output, escape codes and all.
  try {
    $lines = @(Get-Content -Path $path -Tail 200 -Encoding UTF8 -ErrorAction Stop)
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
      if ($lines[$i] -notmatch '"type"\s*:\s*"assistant"') { continue }
      $e = $null
      try { $e = $lines[$i] | ConvertFrom-Json } catch { continue }
      if ($e.type -ne 'assistant' -or $e.isApiErrorMessage) { continue }
      $t = (@($e.message.content | Where-Object { $_.type -eq 'text' } | ForEach-Object { $_.text }) -join "`n").Trim()
      if ($t) { return $t }
    }
  } catch {}
  return ''
}

function Get-SessionLabel($hit) {
  # The name a human will scan for in `claude agents`: project folder, then the
  # time it was resumed. Kept short — the picker truncates — and free of the
  # word "session", which every row already is.
  $leaf = try { Split-Path -Leaf $hit.Cwd } catch { '' }
  if (-not $leaf) { $leaf = 'unknown project' }
  return ("{0} — resumed {1}" -f $leaf, (Get-Date -Format 'HH:mm'))
}

function Invoke-SessionResume($hit) {
  # Dispatched with --bg, NOT -p. A -p run registers no session at all: it never
  # appears in `claude agents`, so the Claude app — and therefore the user's
  # phone — cannot show it. Since the terminal that hit the limit can never
  # update itself, a -p rescue is invisible everywhere, which is exactly what
  # made a working rescue indistinguishable from a broken one. --bg returns
  # immediately, registers a real background session under a fresh id, and is
  # watchable and steerable from mobile.
  # --name is what makes the result findable. Without it Claude Code names a
  # background session after its prompt, so every resumed session was called
  # "You were interrupted by a usage-limit reset…" — identical for all of them,
  # in a list where the id is 8 random hex characters. Naming it after the
  # project folder and the time means the list answers "which one is mine?"
  # on sight, which is the whole job of that list.
  $label = Get-SessionLabel $hit
  $resumeArgs = @("--resume", $hit.SessionId, "--bg", "--name", $label,
                  "--permission-mode", $SessionPermissionMode, $SessionResumeTask)
  Log ("session-rescue: claude " + ($resumeArgs -join " ") + "   [in $($hit.Cwd)]")
  # -LiteralPath: project folder names can start with a dot or contain spaces
  # and brackets; wildcard interpretation of a project path is never wanted.
  Push-Location -LiteralPath $hit.Cwd
  try {
    $out = ($null | & claude @resumeArgs 2>&1 | Out-String)
    $code = $LASTEXITCODE
  } finally { Pop-Location }
  Add-Content -Path $script:logFile -Value $out -Encoding UTF8

  # "backgrounded · 8ea1c866" — the separator is a non-ASCII bullet, so match on
  # the id shape rather than the punctuation between.
  $bgId = ''
  $m = [regex]::Match($out, '(?i)backgrounded\D{0,4}([0-9a-f]{8})')
  if ($m.Success) { $bgId = $m.Groups[1].Value }
  if (-not $bgId) { return @{ Text = $out; Code = $code; BgId = ''; State = 'unknown'; Summary = '' } }

  $state = 'running'
  $deadline = (Get-Date).AddSeconds($SessionAgentWaitSeconds)
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 10
    $s = Get-BackgroundAgentState $bgId
    if ($s) { $state = $s }
    if ($state -in @('done', 'failed', 'stopped', 'completed', 'error')) { break }
  }
  $summary = ''
  $tr = Get-AgentTranscript $bgId
  if ($tr) { $summary = Get-LastAssistantText $tr.FullName }
  return @{ Text = $out; Code = $code; BgId = $bgId; State = $state; Summary = $summary }
}

function Show-RescueToast([string]$title, [string]$body) {
  # Best-effort desktop notification. Returns $true only if a notifier was
  # actually invoked. EVERY path is swallowed: the rescue has already succeeded
  # by the time this runs, and a missing module, a headless box or a locked-down
  # session must never turn a completed rescue into a failed one. When this
  # returns $false the notice file says so, and becomes the only signal.
  if ($script:Platform -eq 'Linux') {
    try {
      if (Get-Command notify-send -ErrorAction SilentlyContinue) {
        & notify-send -a quotawake -- $title $body 2>$null | Out-Null
        return ($LASTEXITCODE -eq 0)
      }
    } catch {}
    return $false   # headless boxes have no notifier at all; expected, not an error
  }
  try {
    if (Get-Module -ListAvailable -Name BurntToast -ErrorAction SilentlyContinue) {
      Import-Module BurntToast -ErrorAction Stop
      # Out-Null matters: any object this emits would join the function's output
      # and turn the [bool] return into an array at the call site.
      New-BurntToastNotification -Text $title, $body -ErrorAction Stop | Out-Null
      return $true
    }
  } catch {}
  try {
    # Windows PowerShell 5.1 carries the WinRT toast projection that pwsh 7
    # lacks, so shell out to it. Hidden and fire-and-forget.
    $ps51 = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
    if (Test-Path -LiteralPath $ps51) {
      $t = ($title -replace "['<>&]", " ")
      $b = ($body  -replace "['<>&]", " ")
      $inner = @'
[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
$x = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02)
$n = $x.GetElementsByTagName('text')
$n.Item(0).AppendChild($x.CreateTextNode('__T__')) | Out-Null
$n.Item(1).AppendChild($x.CreateTextNode('__B__')) | Out-Null
$toast = [Windows.UI.Notifications.ToastNotification]::new($x)
[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('quotawake').Show($toast)
'@
      $inner = $inner.Replace('__T__', $t).Replace('__B__', $b)
      $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($inner))
      Start-Process -FilePath $ps51 -WindowStyle Hidden -ErrorAction Stop `
        -ArgumentList @("-NoProfile", "-NonInteractive", "-EncodedCommand", $enc)
      return $true
    }
  } catch {}
  return $false
}

# Kept out of the function so tests can assert the exact wording the user sees.
$script:RescueNoticeTemplate = @'

---

## Resumed automatically — {0}

Your session stopped at a usage limit and has been resumed. The window it
stopped in **cannot be revived** — nothing outside a running Claude Code session
can type into it — so the conversation was reopened in a **new session**, which
is why the two ids below differ. It runs in the background, so it also shows up
in the Claude app, phone included.

| | |
|---|---|
| Session that stopped | `{1}` |
| Resumed session | `{8}` |
| Limit hit (UTC) | {2} |
| Reset announced | {3} |
| Resumed at | {0} |
| Result | {4} |
| Desktop notification | {5} |

**This work is already running or done — do not re-run it by hand.** Typing
`resume` into the old frozen window starts a second run that redoes finished
work; that cost a duplicated pass on 2026-07-31.

## To go back into the resumed session

    claude agents

It is named after this project and the time it restarted, so it is easy to spot
in the list. Pick it, press Enter. `qw -List` shows the same thing for
quotawake's resumes only. Or go straight in, if you have the id:

    claude attach {8}      # open it in this terminal
    claude logs {8}        # see recent output without opening it
    claude stop {8}        # stop it early; the conversation is kept

If the list shows it as `blocked / waiting for permission prompt`, it is not out
of quota — it is asking for approval and nobody is there. Open it and answer.

## To reopen the session that stopped, instead

    cd "{6}"
    claude --resume {1}

Both of these must be true or you get `No conversation found`: the old window is
closed (`--resume` skips a session something still has open), and you are
standing in the project folder (`--resume` only lists that folder's sessions).

Edits were made under `acceptEdits`, with nobody available to approve them.
Review them before trusting them.

### What the resumed session reported

{7}
'@

function Write-RescueNotice($hit, [string]$outText, $resetAt, [string]$result, [bool]$toastShown, [string]$bgId) {
  # Writes the visible sibling for a terminal that can never update itself.
  # Appended, so several rescues in one project stack up in reading order.
  if (-not (Test-Path -LiteralPath $hit.Cwd)) { return $null }
  $summary = ""
  try {
    $keep = @($outText -split "`r?`n" | Where-Object { $_.Trim().Length -gt 0 })
    $summary = ($keep | Select-Object -Last 15) -join "`n"
  } catch {}
  if (-not $summary) { $summary = "(the run produced no text output)" }
  # Built as an explicit array rather than a line-continued -f list: the
  # continuation form is easy to get subtly wrong and this file is edited rarely
  # and under pressure. ($fields, not $args — $args is automatic in functions.)
  $fields = @(
    (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    [string]$hit.SessionId
    [string]$hit.LimitTs
    $(if ($resetAt) { [string]$resetAt } else { "not parsed" })
    $result
    $(if ($toastShown) { "shown" } else { "unavailable — this file is the only signal" })
    [string]$hit.Cwd
    $summary
    $(if ($bgId) { $bgId } else { "(not dispatched)" })
  )
  $entry = $script:RescueNoticeTemplate -f $fields
  $path = Join-Path $hit.Cwd $SessionNoticeFile
  try { Add-Content -LiteralPath $path -Value $entry -Encoding UTF8; return $path } catch { return $null }
}

function Invoke-SessionReconcile {
  $stranded = @(Scan-StrandedSessions)
  if ($stranded.Count -eq 0) {
    if (Test-Path $script:SessionsStateFile) {
      # An arming is NOT thrown away just because one pass saw nothing. This
      # pass runs every 15 minutes against files a live TUI is still appending
      # to, so an empty result can mean "scan raced the writer" as easily as
      # "session recovered" — and disarming on it is unrecoverable. That is
      # precisely how the 19:20 reset died on 2026-07-25: armed correctly at
      # 18:07, then one empty scan at 19:25 unregistered the task instead of
      # letting it fire. The one-shot costs nothing to keep and re-checks each
      # session immediately before resuming it, so hold it until its own fire
      # time has actually passed; only then is "nothing stranded" conclusive.
      $st = Load-SessionsState
      $fire = $null
      if ($st) { try { $fire = Get-StateFireAt $st } catch {} }
      if ($null -ne $fire -and $fire -gt (Get-Date)) {
        if (-not (Test-ScheduledJob $SessionsFireTaskName)) {
          Register-SessionsFireTask $fire
          Log ("session-rescue: nothing stranded in this pass; arming for {0} kept, missing task re-registered." -f $fire)
        }
        return
      }
      Log "session-rescue: nothing stranded and the armed time has passed - clearing state."
      Clear-SessionsState
    }
    return
  }

  $st = Load-SessionsState
  $attempt = 0
  if ($st -and $st.attempt) { $attempt = [int]$st.attempt }
  if ($attempt -ge $SessionMaxAttempts) {
    Log "session-rescue: still limited after $attempt attempts - giving up on this batch."
    foreach ($h in $stranded) { Add-ProcessedSession $h.SessionId $h.LimitTs $h.Cwd '' 'gave up after 8 attempts' }
    Clear-SessionsState
    return
  }

  # The limit is account-wide, so every stranded session shares one reset.
  # Each message is parsed anchored to its own limit timestamp so "resets
  # 9:50pm" lands on the day the limit was hit, not on today.
  $due = @(); $latestFire = $null
  foreach ($h in $stranded) {
    $anchor = Get-Date
    if ($h.LimitTs) {
      try {
        $anchor = ([datetime]::Parse($h.LimitTs, [Globalization.CultureInfo]::InvariantCulture,
          [System.Globalization.DateTimeStyles]::RoundtripKind)).ToLocalTime()
      } catch {}
    }
    $reset = Parse-ResetTime $h.LimitText $anchor
    $fireAt = if ($null -ne $reset) { $reset.AddSeconds($SessionBufferSeconds) } else { (Get-Date).AddMinutes($PollMinutes) }
    if ($fireAt -le (Get-Date)) { $due += $h }
    if ($null -eq $latestFire -or $fireAt -gt $latestFire) { $latestFire = $fireAt }
  }

  if ($due.Count -eq 0) {
    # Window still shut for all of them: keep the state fresh so the watcher
    # holds the machine awake (on AC), make sure the punctual one-shot exists,
    # and stay quiet otherwise — this path runs every 15 minutes.
    $prevFire = $null
    if ($st) { try { $prevFire = Get-StateFireAt $st } catch {} }
    Save-SessionsState $latestFire $stranded $attempt
    $existing = Test-ScheduledJob $SessionsFireTaskName
    if (-not $existing -or $null -eq $prevFire -or [math]::Abs(($latestFire - $prevFire).TotalSeconds) -gt 60) {
      Register-SessionsFireTask $latestFire
      Log ("session-rescue: {0} stranded session(s); '{1}' fires at {2}." -f $stranded.Count, $SessionsFireTaskName, $latestFire)
    }
    return
  }

  Log ("session-rescue: reset reached - resuming {0} session(s)." -f $due.Count)
  $deferred = 0
  foreach ($h in ($due | Sort-Object { $_.LimitTs })) {
    # Re-check right before firing: a TUI left open auto-continues ~3 minutes
    # after the reset, and that must win over a headless fork.
    $fresh = Find-StrandedSession $h.Transcript
    if ($null -eq $fresh -or $fresh.LimitTs -ne $h.LimitTs) {
      Log ("session-rescue: {0} already moved on by itself - skipping." -f $h.SessionId)
      Add-ProcessedSession $h.SessionId $h.LimitTs $h.Cwd '' 'continued on its own'
      continue
    }
    if (-not (Test-Path -LiteralPath $h.Cwd)) {
      # Do NOT write the session off here. A project can live under a
      # cloud-sync or network mount, where an unreachable folder usually means
      # the drive is unmounted or still coming up — a temporary condition, not
      # a deleted project. Marking it processed would
      # forfeit the rescue permanently over a transient mount, so defer and let
      # the attempt counter below bound the retries.
      Log ("session-rescue: {0}: project folder '{1}' not reachable right now - deferring." -f $h.SessionId, $h.Cwd)
      $deferred++
      continue
    }
    $r = Invoke-SessionResume $h
    Add-ProcessedSession $h.SessionId $h.LimitTs $h.Cwd $r.BgId (Get-SessionLabel $h)
    if ($r.Code -ne 0 -or -not $r.BgId) {
      Log ("session-rescue: {0} dispatch failed (exit {1}) - see output above; not retrying." -f $h.SessionId, $r.Code)
      $result = "dispatch failed (exit $($r.Code)) — see quotawake.log"
    } else {
      # An agent that re-limits immediately strands its own transcript. Ask the
      # same detector rather than scraping text — with --bg the dispatch exits 0
      # long before the agent knows whether the window reopened, so the old
      # "non-zero exit + limit marker" test can no longer see a re-limit. The
      # next 15-minute pass arms the new transcript under its own reset.
      $reStranded = $null
      $tr = Get-AgentTranscript $r.BgId
      if ($tr) { $reStranded = Find-StrandedSession $tr.FullName }
      if ($reStranded) {
        $result = "hit the limit again — agent $($r.BgId) is stranded; the next pass re-arms it"
        Log ("session-rescue: dispatched agent {0} hit the limit again; the next scan will arm it." -f $r.BgId)
      } elseif ($r.State -in @('done', 'completed')) {
        $result = "finished cleanly (agent $($r.BgId))"
        Log ("session-rescue: {0} resumed as background agent {1}; finished cleanly." -f $h.SessionId, $r.BgId)
      } elseif ($r.State -in @('failed', 'error', 'stopped')) {
        $result = "agent $($r.BgId) ended '$($r.State)' — check with: claude logs $($r.BgId)"
        Log ("session-rescue: {0} resumed as background agent {1}; ended '{2}'." -f $h.SessionId, $r.BgId, $r.State)
      } else {
        $result = "still running as agent $($r.BgId) — watch it in the Claude app"
        Log ("session-rescue: {0} resumed as background agent {1}; still running." -f $h.SessionId, $r.BgId)
      }
    }

    # Surface it. Everything above this point can succeed perfectly and still
    # look like nothing happened, because the window the user is staring at is
    # a stale view that no longer receives anything.
    $toast = Show-RescueToast "Claude session resumed" (
      "{0} — {1}. Do not re-run by hand." -f (Split-Path $h.Cwd -Leaf), $result)
    $noticeReset = $null
    try { $noticeReset = Parse-ResetTime $h.LimitText (ConvertTo-LocalDateTime $h.LimitTs) } catch {}
    $noticeBody = if ($r.Summary) { $r.Summary } else { $r.Text }
    $notice = Write-RescueNotice $h $noticeBody $noticeReset $result $toast $r.BgId
    if ($notice) { Log ("session-rescue: notice written to {0} (toast: {1})." -f $notice, $(if ($toast) { "shown" } else { "unavailable" })) }
    else { Log ("session-rescue: could not write the notice file into {0}." -f $h.Cwd) }
  }
  if ($deferred -gt 0) {
    $retryAt = (Get-Date).AddMinutes($PollMinutes)
    Save-SessionsState $retryAt $stranded ($attempt + 1)
    Register-SessionsFireTask $retryAt
    Log ("session-rescue: {0} session(s) deferred on an unreachable folder; retrying at {1} (attempt {2} of {3})." -f $deferred, $retryAt, ($attempt + 1), $SessionMaxAttempts)
    return
  }
  if (@(Scan-StrandedSessions).Count -eq 0) { Clear-SessionsState }
}

# ---------- one round of the chain ----------
function Invoke-Round([bool]$continueRun, [int]$round) {
  Log "--- round $round of $MaxRounds ---"
  $r = Invoke-Claude $continueRun
  # A limit is a non-zero exit whose output carries a limit/reset marker. Gating
  # on the exit code stops a stray "reset" in ordinary output from false-firing.
  $hitLimit = ($r.Code -ne 0) -and ($r.Text -match $limitPattern)

  if ($r.Code -eq 0 -and -not $hitLimit) {
    Log "Task completed cleanly. Done."
    Clear-PendingState
    return 0
  }
  if (-not $hitLimit) {
    Log ("claude exited $($r.Code) with no usage-limit marker — treating as a real error, not a reset. Stopping. See $script:logFile.")
    Clear-PendingState
    return $r.Code
  }
  if ($round -ge $MaxRounds) {
    Log "Usage limit hit but MaxRounds ($MaxRounds) reached. Stopping."
    Clear-PendingState
    return 4
  }

  $reset = Parse-ResetTime $r.Text
  if ($null -eq $reset) {
    $reset = (Get-Date).AddMinutes($PollMinutes)
    Log ("Usage limit hit, but no reset time was in the output; will poll at {0}." -f $reset)
  } else {
    Log "Usage limit hit; Claude's announced reset time parsed as $reset."
  }
  $fireAt = $reset.AddSeconds($BufferSeconds)
  # If this run already continued a conversation, the next one continues it too.
  # If this was a fresh run that got limited, refire fresh — a --continue after
  # a failed fresh start could resume the wrong (older) conversation.
  Save-PendingState $fireAt $round $continueRun
  Register-FireTask $fireAt
  Log "Resume armed: scheduled task '$FireTaskName' fires at $fireAt (survives sleep/reboot via StartWhenAvailable; WakeToRun set). No process stays behind. Exit 5."
  return 5
}

# ---------- machine bindings (PATH, qw shortcut, watcher autostart) ----------
# Four things bind this tool to an absolute folder: the scheduled task, the user
# PATH entry, the qw shortcut in the profile, and the watcher's startup stub.
# Move the folder and every one of them breaks — silently, which is the worst
# way for this particular tool to fail: no reconciler means no rescues, and
# nothing anywhere says so. They are all derived from $ScriptDir and rewritten
# idempotently, so re-running -Install from a new location IS the migration.

$AliasBegin     = '# >>> quotawake (qw) >>>'
$AliasEnd       = '# <<< quotawake (qw) <<<'
$StartupVbsName = 'quotawake-keepawake.vbs'

# Names used before this tool was renamed from claude-resume. -Install clears
# them, because a scheduled task left pointing at a script that no longer exists
# is this project's signature failure: it stays registered, fires on time, does
# nothing at all, and reports nothing. A rename is exactly when that gets
# created, so the installer has to be the thing that prevents it.
$LegacyTaskNames  = @('ClaudeResume-Fire', 'ClaudeResume-Logon', 'ClaudeResume-FireSessions')
$LegacyAliasBegin = '# >>> claude-resume (crun) >>>'
$LegacyAliasEnd   = '# <<< claude-resume (crun) <<<'
$LegacyVbsName    = 'keep-awake-claude.vbs'

function Remove-LegacyInstall {
  # Returns what it actually cleaned, so -Install can say so rather than leaving
  # the user to wonder whether the old install is still lurking. Windows-only:
  # the tool was Windows-only under its old name, so no other platform can have
  # a pre-rename install to clean up.
  $done = @()
  if ($script:Platform -ne 'Windows') { return $done }
  foreach ($t in $LegacyTaskNames) {
    if (Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue) {
      Unregister-ScheduledTask -TaskName $t -Confirm:$false -ErrorAction SilentlyContinue
      $done += "unregistered stale task '$t'"
    }
  }
  $legacyVbs = Join-Path ([Environment]::GetFolderPath('Startup')) $LegacyVbsName
  if (Test-Path -LiteralPath $legacyVbs) {
    Remove-Item -LiteralPath $legacyVbs -Force -ErrorAction SilentlyContinue
    $done += "removed stale autostart '$LegacyVbsName'"
  }
  return $done
}

function Get-StartupVbsPath { Join-Path ([Environment]::GetFolderPath('Startup')) $StartupVbsName }

# The watcher's autostart, per platform: a Startup-folder shim on Windows, a
# systemd --user service on Linux. Unlike the scheduled jobs this one is
# long-running, so Linux gets Restart=always.
$WatcherUnit  = 'quotawake-keepawake'

function Get-WatcherAutostartPath {
  switch ($script:Platform) {
    'Windows' { return (Get-StartupVbsPath) }
    'Linux'   { return (Join-Path (Get-SystemdUnitDir) "$WatcherUnit.service") }
  }
  return $null
}

function Get-WatcherArgv {
  $pwsh = try { (Get-Process -Id $PID).Path } catch { $null }
  if (-not $pwsh) { $pwsh = 'pwsh' }
  return @($pwsh, '-NoProfile', '-NonInteractive', '-File', (Join-Path $ScriptDir 'keep-awake.ps1'))
}

function New-WatcherSystemdUnit {
  $exec = (Get-WatcherArgv | ForEach-Object { if ($_ -match '\s') { '"{0}"' -f $_ } else { $_ } }) -join ' '
  return @"
[Unit]
Description=quotawake keep-awake watcher

[Service]
ExecStart=$exec
Restart=always
RestartSec=30

[Install]
WantedBy=default.target
"@
}

function Set-UserPathEntry([switch]$Remove) {
  # Windows only. Linux has no per-user persistent PATH a script can safely edit
  # — it lives in whichever shell rc the user happens to use, and rewriting
  # someone's .bashrc uninvited is not this tool's business. Linux relies on the
  # `qw` function written into the PowerShell profile, which works from any
  # directory regardless of PATH.
  if ($script:Platform -ne 'Windows') { return $false }
  # Also drops any quotawake folder that no longer exists — exactly what a
  # move leaves behind, and a stale PATH entry is pure confusion later.
  $cur  = @(([Environment]::GetEnvironmentVariable('PATH', 'User') -split ';') | Where-Object { $_ })
  $kept = @($cur | Where-Object {
    -not (
      # this folder, so it can be re-added cleanly at the end
      $_.TrimEnd('\') -eq $ScriptDir.TrimEnd('\') -or
      # a quotawake folder that no longer exists: what a move leaves behind
      ($_ -like '*quotawake*' -and -not (Test-Path -LiteralPath $_)) -or
      # an older copy still on disk: after a copy-then-install the old entry
      # would otherwise survive AND could shadow this one on PATH lookup
      (Test-Path -LiteralPath (Join-Path $_ 'quotawake.ps1'))
    )
  })
  $new = if ($Remove) { $kept } else { $kept + $ScriptDir }
  if (($new -join ';') -ne ($cur -join ';')) {
    [Environment]::SetEnvironmentVariable('PATH', ($new -join ';'), 'User')
    return $true
  }
  return $false
}

function Set-AliasShortcut([switch]$Remove) {
  # Rewrites only the marked block, so anything else in the profile survives.
  $profilePath = $PROFILE.CurrentUserAllHosts
  $dir = Split-Path -Parent $profilePath
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  $lines = @()
  if (Test-Path -LiteralPath $profilePath) { $lines = @(Get-Content -LiteralPath $profilePath) }
  # Strips the pre-rename block as well, or the profile would end up defining
  # both `crun` and `qw`, with crun still pointing at a script that is gone.
  $out = @(); $inBlock = $false
  foreach ($l in $lines) {
    $t = $l.Trim()
    if ($t -eq $AliasBegin -or $t -eq $LegacyAliasBegin) { $inBlock = $true; continue }
    if ($t -eq $AliasEnd   -or $t -eq $LegacyAliasEnd)   { $inBlock = $false; continue }
    if (-not $inBlock) { $out += $l }
  }
  if (-not $Remove) {
    $out += $AliasBegin
    $out += '# One-word shortcut to run quotawake from any directory; forwards all args.'
    $out += ('function qw {{ & "{0}" @args }}' -f (Join-Path $ScriptDir 'quotawake.ps1'))
    $out += $AliasEnd
  }
  Set-Content -LiteralPath $profilePath -Value $out -Encoding UTF8
}

function Set-WatcherAutostart([switch]$Remove) {
  $target = Get-WatcherAutostartPath
  switch ($script:Platform) {
    'Windows' {
      if ($Remove) { Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue; return }
      $ps1 = Join-Path $ScriptDir 'keep-awake.ps1'
      Set-Content -LiteralPath $target -Encoding ASCII -Value @(
        "' Autostarts the quotawake keep-awake watcher, hidden (no console flash).",
        "' Generated by quotawake.ps1 -Install - edit that, not this file.",
        'Dim objShell',
        'Set objShell = CreateObject("WScript.Shell")',
        ('objShell.Run "pwsh -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File ""{0}""", 0, False' -f $ps1)
      )
    }
    'Linux' {
      if ($Remove) {
        [void](Invoke-Systemctl @('disable', '--now', "$WatcherUnit.service"))
        Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
        [void](Invoke-Systemctl @('daemon-reload'))
        return
      }
      New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
      Set-Content -LiteralPath $target -Value (New-WatcherSystemdUnit) -Encoding UTF8
      [void](Invoke-Systemctl @('daemon-reload'))
      [void](Invoke-Systemctl @('enable', '--now', "$WatcherUnit.service"))
      # Without lingering, user units are torn down at logout and every timer
      # dies with the session — which would silently disable the whole tool on
      # a machine you SSH into. Best-effort: it usually needs polkit or root.
      try { & loginctl enable-linger $env:USER 2>$null | Out-Null } catch {}
    }
  }
}

# --- when dot-sourced for testing, stop here: functions + $limitPattern defined ---
if ($SelfTest) { return }

# ---------- entry points ----------
# Every path below ends in a backend call, so refuse an unsupported OS here
# rather than letting each switch fall through to a silent no-op. -Doctor is
# exempt: reporting *why* the platform is unsupported is exactly its job, and
# -List only reads a file.
if (-not $Doctor -and -not $List) { Assert-SupportedPlatform }

if ($List) {
  # Answers the only question a user has after a rescue: which of these is
  # mine, and is it still going? The ledger supplies project and name; the
  # live agent list supplies state. Neither alone is enough — the ledger does
  # not know what is running, and `claude agents` does not know which project a
  # row came from once several are in flight.
  $rows = @(Get-ProcessedSessions | Where-Object { $_.resumedAs })
  if (-not $rows.Count) {
    Write-Host "Nothing has been resumed yet."
    Write-Host "Once a session is resumed it is listed here, and in ``claude agents``."
    exit 0
  }
  $liveState = @{}
  foreach ($a in (Get-AgentList)) {
    $sid = [string]$a.sessionId
    $short = if ($sid.Length -ge 8) { $sid.Substring(0, 8) } else { $sid }
    $liveState[$short] = $(if ($a.state) { [string]$a.state } elseif ($a.status) { [string]$a.status } else { '' })
  }
  Write-Host ""
  Write-Host ("  {0,-16}  {1,-22}  {2,-10}  {3}" -f 'Resumed at', 'Project', 'Session', 'State')
  Write-Host ("  {0,-16}  {1,-22}  {2,-10}  {3}" -f ('-'*16), ('-'*22), ('-'*10), ('-'*10))
  foreach ($r in ($rows | Select-Object -Last 15)) {
    # Not a bare [datetime] cast: ConvertFrom-Json hands back Kind=Utc for a
    # "…Z" timestamp, which would print two hours early here and be silently
    # wrong on any machine not at UTC. ConvertTo-LocalDateTime is the one
    # normaliser every timestamp in this script goes through.
    $wd = ConvertTo-LocalDateTime $r.handled
    $when = if ($wd) { $wd.ToString('yyyy-MM-dd HH:mm') } else { [string]$r.handled }
    $proj = [string]$r.project; if (-not $proj) { $proj = '(unknown)' }
    if ($proj.Length -gt 22) { $proj = $proj.Substring(0, 21) + '…' }
    $short = [string]$r.resumedAs
    $state = $liveState[$short]
    if (-not $state) { $state = 'not running' }
    Write-Host ("  {0,-16}  {1,-22}  {2,-10}  {3}" -f $when, $proj, $short, $state)
  }
  Write-Host ""
  Write-Host "  Go back into one:   claude attach <session>"
  Write-Host "  Or pick from a list: claude agents"
  Write-Host ""
  exit 0
}

$script:DoctorFailures = 0
function Test-Doctor([string]$label, [bool]$pass, [string]$detail = '', [switch]$Warn) {
  $tag = if ($pass) { 'OK  ' } elseif ($Warn) { 'WARN' } else { 'FAIL' }
  if (-not $pass -and -not $Warn) { $script:DoctorFailures++ }
  Write-Host ("  [{0}] {1}{2}" -f $tag, $label.PadRight(38), $(if ($detail) { "  $detail" } else { '' }))
}

if ($Doctor) {
  Write-Host "quotawake doctor — $($script:Platform), pwsh $($PSVersionTable.PSVersion), $ScriptDir`n"

  Test-Doctor "platform supported" ($script:Platform -in @('Windows','Linux')) `
    $(if ($script:Platform -eq 'macOS') { "macOS - no tested backend (see ac11ea2)" } else { $script:Platform })
  Test-Doctor "pwsh 7+" ($PSVersionTable.PSVersion.Major -ge 7) $PSVersionTable.PSVersion.ToString()
  $claude = Get-Command claude -ErrorAction SilentlyContinue
  Test-Doctor "claude CLI on PATH" ([bool]$claude) $(if ($claude) { $claude.Source } else { 'not found - rescue cannot run' })
  Test-Doctor "transcripts folder" (Test-Path -LiteralPath $script:ProjectsRoot) $script:ProjectsRoot

  # The scheduler is the one piece that cannot be faked: without it nothing ever
  # fires, and that failure is silent, so prove it by actually registering.
  $backend = switch ($script:Platform) {
    'Windows' { if (Get-Command Register-ScheduledTask -ErrorAction SilentlyContinue) { 'Task Scheduler' } else { $null } }
    'Linux'   { if ((Get-Command systemctl -ErrorAction SilentlyContinue) -and (Invoke-Systemctl @('show', '--property=Version'))) { 'systemd --user' } else { $null } }
  }
  Test-Doctor "scheduler backend" ([bool]$backend) $(if ($backend) { $backend } else { 'unavailable - nothing will ever fire' })

  if ($backend) {
    $probe = 'QuotaWake-DoctorProbe'
    try {
      Register-ScheduledJob -Name $probe -Arguments '-Reconcile' -FireAt ((Get-Date).AddMinutes(5))
      $made = Test-ScheduledJob $probe
      Test-Doctor "register a one-shot job" $made $(if ($made) { 'registered and visible' } else { 'registration did not take' })
      Unregister-ScheduledJob $probe
      Test-Doctor "unregister it again" (-not (Test-ScheduledJob $probe))
    } catch {
      Test-Doctor "register a one-shot job" $false $_.Exception.Message
    }
  }

  # A missing notifier is survivable — the notice file carries the result — so
  # this is a warning, not a failure. Headless Linux legitimately has none.
  $toast = Show-RescueToast "quotawake doctor" "If you can see this, notifications work."
  Test-Doctor "desktop notification" $toast $(if ($toast) { 'sent - check your screen' } else { 'none available; CLAUDE/QUOTAWAKE-RESUMED.md is the only signal' }) -Warn:(-not $toast)

  $awake = switch ($script:Platform) {
    'Windows' { 'SetThreadExecutionState (built in)' }
    'Linux'   { if (Get-Command systemd-inhibit -ErrorAction SilentlyContinue) { 'systemd-inhibit' } else { $null } }
  }
  Test-Doctor "keep-awake mechanism" ([bool]$awake) $(if ($awake) { $awake } else { 'missing - machine may sleep through a reset' }) -Warn:(-not $awake)

  Test-Doctor "reconciler installed" (Test-ScheduledJob $LogonTaskName) $LogonTaskName
  $autostart = Get-WatcherAutostartPath
  Test-Doctor "watcher autostart" ($autostart -and (Test-Path -LiteralPath $autostart)) $autostart -Warn
  $prof = $PROFILE.CurrentUserAllHosts
  $hasAlias = (Test-Path -LiteralPath $prof) -and (Select-String -LiteralPath $prof -Pattern 'function qw ' -Quiet)
  Test-Doctor "qw shortcut in profile" $hasAlias $prof -Warn:(-not $hasAlias)

  Write-Host ""
  if ($script:DoctorFailures -eq 0) { Write-Host "No blocking problems found." }
  else { Write-Host "$script:DoctorFailures blocking problem(s) — rescue will not work until fixed." }
  exit ([int]($script:DoctorFailures -gt 0))
}

if ($Uninstall) {
  Clear-PendingState
  Clear-SessionsState
  Remove-Item $script:ProcessedSessionsFile, $script:RescueLockFile -Force -ErrorAction SilentlyContinue
  Unregister-ScheduledJob $LogonTaskName
  Set-AliasShortcut -Remove
  Set-WatcherAutostart -Remove
  [void](Set-UserPathEntry -Remove)
  [void](Remove-LegacyInstall)
  Write-Host "Removed: state files, scheduled jobs, PATH entry, qw shortcut, watcher autostart."
  Write-Host "A watcher already running stays up until you end it or log off."
  exit 0
}

if ($Install) {
  $cleaned = @(Remove-LegacyInstall)
  Register-LogonTask
  $pathChanged = Set-UserPathEntry
  Set-AliasShortcut
  Set-WatcherAutostart
  $backendName = switch ($script:Platform) {
    'Windows' { "scheduled task '$LogonTaskName'" }
    'Linux'   { "systemd --user timer '$(Get-SystemdUnitName $LogonTaskName).timer'" }
    default   { "reconciler '$LogonTaskName'" }
  }
  Write-Host "quotawake installed from: $ScriptDir   ($($script:Platform))"
  foreach ($c in $cleaned) { Write-Host "  migrated           $c" }
  Write-Host "  reconciler         $backendName (every 15 min)"
  if ($script:Platform -eq 'Windows') {
    Write-Host ("  user PATH          {0}" -f $(if ($pathChanged) { "updated" } else { "already correct" }))
  }
  Write-Host ("  qw shortcut        {0}" -f $PROFILE.CurrentUserAllHosts)
  Write-Host ("  watcher autostart  {0}" -f (Get-WatcherAutostartPath))
  Write-Host ""
  Write-Host "Open a NEW shell for the qw shortcut to take effect, then verify this"
  Write-Host "machine's integration end to end:"
  Write-Host "  ./quotawake.ps1 -Doctor"
  Write-Host ""
  Write-Host "If you just moved the folder, end any watcher still running from the old"
  Write-Host "path first. To start the new one without waiting for a logon:"
  switch ($script:Platform) {
    'Windows' { Write-Host ("  wscript `"{0}`"" -f (Get-WatcherAutostartPath)) }
    'Linux'   { Write-Host "  systemctl --user restart $WatcherUnit.service" }
  }
  exit 0
}

if ($Resume -or $Reconcile) {
  if ($Reconcile) {
    # Interactive-session rescue runs on every reconcile pass, independent of
    # any qw-launched pending state. The exclusive file lock keeps the 15-min
    # pass and the one-shot fire task from double-resuming when they collide;
    # the loser skips silently (the next pass covers it). The OS releases the
    # handle even if the process is killed mid-resume.
    $rescueLock = $null
    try {
      $rescueLock = [System.IO.File]::Open($script:RescueLockFile,
        [System.IO.FileMode]::Create, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    } catch {}
    if ($rescueLock) {
      try { Invoke-SessionReconcile }
      catch { Log ("session-rescue: ERROR - " + $_.Exception.Message) }
      finally { $rescueLock.Dispose() }
    }
  }
  $st = Load-PendingState
  if ($null -eq $st) { exit 0 }   # nothing pending: exit silently (logon path)
  # Restore the saved context.
  $Project        = $st.project
  $Task           = $st.task
  $PermissionMode = $st.permissionMode
  $MaxRounds      = [int]$st.maxRounds
  $BufferSeconds  = [int]$st.bufferSeconds
  $PollMinutes    = [int]$st.pollMinutes
  $script:logFile = Join-Path $Project "quotawake.log"
  $fireAt = Get-StateFireAt $st

  if ($Reconcile -and $fireAt -gt (Get-Date)) {
    # Still in the future: make sure the one-shot task exists, then leave.
    $existing = Test-ScheduledJob $FireTaskName
    if (-not $existing) {
      Register-FireTask $fireAt
      Log "Reconcile: re-armed missing '$FireTaskName' for $fireAt."
    }
    exit 0
  }

  Set-Location $Project
  Log "=== quotawake resuming in $Project (round $([int]$st.roundsUsed + 1)) ==="
  exit (Invoke-Round ([bool]$st.continue) ([int]$st.roundsUsed + 1))
}

# --- fresh start ---
Set-Location $Project
$script:logFile = Join-Path $Project "quotawake.log"

if ($At) {
  $when = Parse-AtTime $At
  if ($null -eq $when) {
    Log "Could not parse -At '$At'. Expected e.g. '3pm', '15:00', '2026-07-04 20:00'. Aborting."
    exit 2
  }
  Save-PendingState $when 0 $true
  Register-FireTask $when
  Log "Resume armed for $when via scheduled task '$FireTaskName'. Nothing stays running. Exit 5."
  exit 5
}

Log "=== quotawake starting in $Project ==="
if (-not $PermissionMode) {
  Log "WARNING: no -PermissionMode given — headless claude cannot approve its own actions, so file edits and most commands will be auto-denied. Pass -PermissionMode acceptEdits for unattended work."
}
exit (Invoke-Round $Continue.IsPresent 1)
