# Unit tests for quotawake.ps1 — dot-sources it in -SelfTest mode so no real
# `claude` runs, no scheduled task is registered, and no quota is spent.
# Run:  pwsh -File .\quotawake.Tests.ps1
$ErrorActionPreference = "Stop"

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("quotawake-test-" + [guid]::NewGuid().ToString("N").Substring(0,8))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null

# Bring functions + $limitPattern into this scope; skip the entry points.
. (Join-Path $PSScriptRoot "quotawake.ps1") -SelfTest -Project $tmp
$script:StateFile = Join-Path $tmp "pending-resume.json"   # keep test state out of the real file
$script:logFile   = Join-Path $tmp "quotawake.log"

$script:pass = 0; $script:fail = 0
function Check([string]$name, [bool]$cond) {
  if ($cond) { Write-Host ("  PASS  " + $name); $script:pass++ }
  else       { Write-Host ("  FAIL  " + $name) -ForegroundColor Red; $script:fail++ }
}

Write-Host "== limit detection (must match) =="
$limitMsgs = @(
  "You've hit your session limit `u{00B7} resets 1:30pm (Europe/Paris)",
  "Claude usage limit reached. Your limit will reset at 3pm.",
  "You've hit your usage limit `u{00B7} resets in 2h 15m",
  "5-hour limit reached - try again later"
)
foreach ($m in $limitMsgs) { Check ("detects: " + $m.Substring(0,[math]::Min(38,$m.Length))) ([bool]($m -match $limitPattern)) }

Write-Host "== ordinary output (must NOT match) =="
$okMsgs = @(
  "Task done. I ran git reset --hard and committed.",
  "I reset the camera view in the figure.",
  "Wrote 3 files; no errors."
)
foreach ($m in $okMsgs) { Check ("ignores: " + $m.Substring(0,[math]::Min(38,$m.Length))) (-not ([bool]($m -match $limitPattern))) }

Write-Host "== reset-time parsing (claude output) =="
Check "resets 1:30pm -> 13:30" ((Parse-ResetTime "you hit your limit, resets 1:30pm").Hour -eq 13 -and (Parse-ResetTime "resets 1:30pm").Minute -eq 30)
Check "resets at 15:00 -> 15"  ((Parse-ResetTime "resets at 15:00").Hour -eq 15)
Check "resets in 2h 15m ~135m" ([math]::Abs(((Parse-ResetTime "resets in 2h 15m") - (Get-Date)).TotalMinutes - 135) -lt 2)
Check "ISO absolute -> 20"     ((Parse-ResetTime "limit will reset 2026-07-04 20:00").Hour -eq 20)
Check "junk -> null"           ($null -eq (Parse-ResetTime "nothing to see here"))

Write-Host "== -At parsing (user supplied) =="
Check "'3pm' -> 15"        ((Parse-AtTime "3pm").Hour -eq 15)
Check "'15:00' -> 15"      ((Parse-AtTime "15:00").Hour -eq 15)
Check "'3:30 pm' -> 15:30" ((Parse-AtTime "3:30 pm").Hour -eq 15 -and (Parse-AtTime "3:30 pm").Minute -eq 30)
Check "full datetime -> 20"((Parse-AtTime "2026-07-04 20:00").Hour -eq 20)
Check "garbage -> null"    ($null -eq (Parse-AtTime "not a time"))

Write-Host "== state save / load roundtrip =="
$Project = $tmp; $Task = "test task"; $PermissionMode = "acceptEdits"
$when = (Get-Date).AddHours(2)
Save-PendingState $when 3 $true
$st = Load-PendingState
Check "state saved and loads"      ($null -ne $st)
Check "fireAt roundtrips"          ([math]::Abs(((Get-StateFireAt $st) - $when).TotalSeconds) -lt 1)
Check "roundsUsed = 3"             ([int]$st.roundsUsed -eq 3)
Check "continue = true"            ([bool]$st.continue)
Check "task / project preserved"   ($st.task -eq "test task" -and $st.project -eq $tmp)
Remove-Item $script:StateFile -Force

Write-Host "== round logic (mocked claude + mocked task registration) =="
$script:armed = @()
function Register-FireTask([datetime]$fireAt) { $script:armed += $fireAt }   # mock: no real task
function Unregister-ScheduledTask { param($TaskName, $Confirm) }             # mock: swallow cleanup
$script:responses = @(); $script:calls = New-Object System.Collections.ArrayList
function Invoke-Claude([bool]$continueRun) {
  [void]$script:calls.Add(@{ continue = $continueRun })
  return $script:responses[$script:calls.Count - 1]
}
function RunRound($resp, [bool]$cont, [int]$round) {
  $script:calls = New-Object System.Collections.ArrayList
  $script:armed = @()
  $script:responses = @($resp)
  return (Invoke-Round $cont $round)
}

$rc = RunRound @{ Text = "all done"; Code = 0 } $false 1
Check "A clean run -> 0, nothing armed"      ($rc -eq 0 -and $script:armed.Count -eq 0)

$rc = RunRound @{ Text = "Error: boom"; Code = 2 } $false 1
Check "B real error -> exit 2, nothing armed" ($rc -eq 2 -and $script:armed.Count -eq 0)

$rc = RunRound @{ Text = "You've hit your session limit, resets 1:30pm"; Code = 1 } $false 1
$st = Load-PendingState
Check "C limit -> 5 (armed, no waiting)"     ($rc -eq 5 -and $script:armed.Count -eq 1)
Check "C armed at 13:30 + buffer"            ($script:armed[0].Hour -eq 13 -and $script:armed[0].Minute -eq 32)
Check "C state saved for the fire task"      ($null -ne $st -and [int]$st.roundsUsed -eq 1)
Check "C fresh run refires fresh"            (-not [bool]$st.continue)
Remove-Item $script:StateFile -Force -ErrorAction SilentlyContinue

$rc = RunRound @{ Text = "You've hit your session limit, resets 1:30pm"; Code = 1 } $true 4
$st = Load-PendingState
Check "D continued run re-arms as continue"  ($rc -eq 5 -and [bool]$st.continue -and [int]$st.roundsUsed -eq 4)
Remove-Item $script:StateFile -Force -ErrorAction SilentlyContinue

$rc = RunRound @{ Text = "You've hit your session limit (no time given)"; Code = 1 } $true 2
$st = Load-PendingState
Check "E no reset time -> polls (+20m arm)"  ($rc -eq 5 -and [math]::Abs(($script:armed[0] - (Get-Date)).TotalMinutes - 22.5) -lt 2)
Remove-Item $script:StateFile -Force -ErrorAction SilentlyContinue

$rc = RunRound @{ Text = "You've hit your session limit, resets 1:30pm"; Code = 1 } $true 12
Check "F limit at MaxRounds -> 4, no re-arm" ($rc -eq 4 -and $script:armed.Count -eq 0)

Write-Host "== anchored reset parsing (session rescue) =="
$anchor = (Get-Date).Date.AddDays(-1).AddHours(18)   # a limit hit yesterday 6pm
$r = Parse-ResetTime "You've hit your session limit - resets 9:50pm (Europe/Paris)" $anchor
Check "anchored: lands on the limit's own day" ($r -eq $anchor.Date.AddHours(21).AddMinutes(50))
$anchor2 = (Get-Date).Date.AddDays(-1).AddHours(23)  # hit at 11pm -> reset is past midnight
$r2 = Parse-ResetTime "resets 9:50pm" $anchor2
Check "anchored: rolls past midnight"          ($r2 -eq $anchor2.Date.AddDays(1).AddHours(21).AddMinutes(50))

Write-Host "== stranded-session detection (transcript fixtures) =="
function NewFixture([string[]]$jsonLines) {
  $f = Join-Path $tmp ([guid]::NewGuid().ToString("N").Substring(0, 8) + ".jsonl")
  Set-Content -Path $f -Value ($jsonLines -join "`n") -Encoding UTF8
  return $f
}
$limitLine  = '{"type":"assistant","timestamp":"2026-07-18T16:06:14.641Z","message":{"role":"assistant","content":[{"type":"text","text":"You''ve hit your session limit - resets 9:50pm (Europe/Paris)"}]},"error":"rate_limit","isApiErrorMessage":true,"apiErrorStatus":429,"sessionId":"aaaa-1111","cwd":"C:\\proj"}'
$userLine   = '{"type":"user","timestamp":"2026-07-18T15:00:00.000Z","message":{"role":"user","content":"go on"},"sessionId":"aaaa-1111","cwd":"C:\\proj"}'
$asstLine   = '{"type":"assistant","timestamp":"2026-07-18T15:00:05.000Z","message":{"role":"assistant","content":[{"type":"text","text":"ok"}]},"sessionId":"aaaa-1111","cwd":"C:\\proj"}'
$metaLine   = '{"type":"queue-operation","operation":"enqueue"}'
$quotedLine = '{"type":"user","timestamp":"2026-07-18T19:00:00.000Z","message":{"role":"user","content":[{"type":"tool_result","content":"grep hit: \"error\":\"rate_limit\" inside quoted tool output"}]},"sessionId":"bbbb-2222","cwd":"C:\\proj"}'
# $limitLine stops at 16:06:14Z (18:06 Paris) announcing "resets 9:50pm" -> the
# window reopens 19:50Z. Talk before that cannot have resumed anything; talk
# after it means the session genuinely picked itself up.
$beforeReset = '{"type":"user","timestamp":"2026-07-18T18:00:00.000Z","message":{"role":"user","content":"what is this session id?"},"sessionId":"aaaa-1111","cwd":"C:\\proj"}'
# Chat after the reset is NOT recovery — this is the 2026-07-31 shape exactly:
# a plain answer to an unrelated question, 81s past the reset, work untouched.
$afterChat   = '{"type":"assistant","timestamp":"2026-07-18T20:30:00.000Z","message":{"role":"assistant","content":[{"type":"text","text":"`session_0EXAMPLE0000000000000000`"}]},"sessionId":"aaaa-1111","cwd":"C:\\proj"}'
# Tool use after the reset IS recovery — the agent is executing again.
$afterWork   = '{"type":"assistant","timestamp":"2026-07-18T20:30:00.000Z","message":{"role":"assistant","content":[{"type":"tool_use","name":"Edit","input":{}}]},"sessionId":"aaaa-1111","cwd":"C:\\proj"}'

$hit = Find-StrandedSession (NewFixture @($userLine, $limitLine))
Check "limit as last event -> stranded"          ($null -ne $hit -and $hit.SessionId -eq "aaaa-1111" -and $hit.Cwd -eq "C:\proj")
Check "stranded hit carries the reset text"      ($null -ne $hit -and $hit.LimitText -like "*resets 9:50pm*")
# ConvertFrom-Json turns the ISO timestamp into [datetime]; it must come back
# out in the exact canonical UTC form or (sessionId, limitTs) matching breaks.
Check "LimitTs normalised to canonical UTC ISO"  ($null -ne $hit -and $hit.LimitTs -eq "2026-07-18T16:06:14.641Z")
$hit = Find-StrandedSession (NewFixture @($userLine, $limitLine, $metaLine, $metaLine))
Check "meta lines after limit -> still stranded" ($null -ne $hit)
$hit = Find-StrandedSession (NewFixture @($userLine, $limitLine, $afterWork))
Check "tool work after the reset -> not stranded"   ($null -eq $hit)
# The 2026-07-31 failure, both halves of it: talk while the window is still
# shut is obviously not recovery, and neither is a chat reply just after the
# reset. Only tool use clears a stop.
$hit = Find-StrandedSession (NewFixture @($userLine, $limitLine, $beforeReset))
Check "talk before the reset -> STILL stranded"     ($null -ne $hit -and $hit.SessionId -eq "aaaa-1111")
$hit = Find-StrandedSession (NewFixture @($userLine, $limitLine, $afterChat))
Check "chat after the reset -> STILL stranded"      ($null -ne $hit -and $hit.SessionId -eq "aaaa-1111")
$hit = Find-StrandedSession (NewFixture @($userLine, $limitLine, $beforeReset, $afterChat, $afterWork))
Check "chat then real tool work -> clear"           ($null -eq $hit)
$hit = Find-StrandedSession (NewFixture @($userLine, $asstLine))
Check "no limit at all -> not stranded"          ($null -eq $hit)
$hit = Find-StrandedSession (NewFixture @($asstLine, $quotedLine))
Check "quoted rate_limit in tool output ignored" ($null -eq $hit)

Write-Host "== detection survives trailing bookkeeping (2026-07-25 regression) =="
# The detector used to read a fixed 40-line tail forwards. A stopped session
# keeps accreting bookkeeping (mode/permission/title snapshots, /resume
# browsing, queue ops), so within minutes the stop scrolled out of that window
# and a dead session looked healthy. Measured on the real transcripts here, the
# stop sat 52/335/670/1707 lines from the end. Verdicts must not depend on how
# much noise trails the stop, so this walks a range that straddles the old 40.
foreach ($n in @(0, 39, 60, 500, 3000)) {
  $doc = @($userLine, $limitLine)
  if ($n -gt 0) { $doc += (1..$n | ForEach-Object { $metaLine }) }
  $hit = Find-StrandedSession (NewFixture $doc)
  Check "stranded through $n trailing bookkeeping lines" ($null -ne $hit -and $hit.SessionId -eq "aaaa-1111")
}
$doc = @($userLine, $limitLine) + (1..200 | ForEach-Object { $metaLine }) + @($afterWork)
Check "tool work after reset still wins under deep noise" ($null -eq (Find-StrandedSession (NewFixture $doc)))
$doc = @($userLine, $limitLine) + (1..200 | ForEach-Object { $metaLine }) + @($beforeReset, $afterChat)
Check "chat-only under deep noise -> still stranded"      ($null -ne (Find-StrandedSession (NewFixture $doc)))

Write-Host "== rescue notice (the only signal a frozen terminal ever gets) =="
$fakeHit = @{ SessionId = "zzzz-0000"; Cwd = $tmp; LimitTs = "2026-07-18T16:06:14.641Z"
              LimitText = "resets 9:50pm"; Transcript = "x" }
$p1 = Write-RescueNotice $fakeHit "line one`nline two" ([datetime]"2026-07-18 21:50") "finished cleanly" $false
Check "notice file created in the project folder" ($null -ne $p1 -and (Test-Path $p1))
$t1 = Get-Content $p1 -Raw
Check "notice explains why the window is dead"    ($t1 -match 'cannot be revived')
Check "notice carries the run's own output"       ($t1 -like "*line two*")
Check "notice tells you not to re-run it"         ($t1 -match 'do not re-run it by hand')
Check "notice shows how to reopen the session"    ($t1 -match 'claude --resume zzzz-0000')
Check "notice flags a missing toast"              ($t1 -match 'only signal')
$p2 = Write-RescueNotice $fakeHit "second run" ([datetime]"2026-07-18 21:50") "finished cleanly" $true
$t2 = Get-Content $p2 -Raw
Check "a second rescue appends, never overwrites" (([regex]::Matches($t2, 'Resumed automatically')).Count -eq 2)
Check "notice records that a toast was shown"     ($t2 -match 'Desktop notification \| shown')
Check "unreachable project folder -> no notice"   ($null -eq (Write-RescueNotice `
  @{ SessionId = "q"; Cwd = (Join-Path $tmp "no-such-dir"); LimitTs = "x" } "t" $null "r" $false))
Remove-Item $p1 -Force -ErrorAction SilentlyContinue
# The toast is best-effort by design: a rescue that already succeeded must not
# be reported as failed just because no notifier is reachable.
if (-not (Get-Module -ListAvailable -Name BurntToast -ErrorAction SilentlyContinue)) {
  $savedRoot = $env:SystemRoot
  try {
    $env:SystemRoot = Join-Path $tmp "no-such-windows"
    Check "toast degrades to false, never throws" ((Show-RescueToast "t" "b") -eq $false)
  } finally { $env:SystemRoot = $savedRoot }
} else {
  Write-Host "  SKIP  toast degradation (BurntToast installed; would fire a real toast)"
}

Write-Host "== reconcile: arming, holding, resuming (mocked tasks + resume) =="
$projRoot = Join-Path $tmp "projects"
$projDir  = Join-Path $projRoot "C--proj"
New-Item -ItemType Directory -Path $projDir -Force | Out-Null
$script:ProjectsRoot          = $projRoot
$script:SessionsStateFile     = Join-Path $tmp "pending-sessions.json"
$script:ProcessedSessionsFile = Join-Path $tmp "resumed-sessions.json"

$script:sessArmed = @(); $script:resumed = @(); $script:fakeTask = $null
function Register-SessionsFireTask([datetime]$fireAt) { $script:sessArmed += $fireAt }
function Get-ScheduledTask { param($TaskName, $ErrorAction) return $script:fakeTask }
# Mirrors the real --bg return shape: the dispatch exits 0 immediately and hands
# back the background agent's id, which is what the Claude app (and the phone)
# lists. A -p run returned none of this and was invisible everywhere.
function Invoke-SessionResume($hit) {
  $script:resumed += $hit.SessionId
  return @{ Text = "backgrounded `u{00B7} abcd1234"; Code = 0; BgId = "abcd1234"; State = "done"; Summary = "the work is finished" }
}
$script:toasts = @()
function Show-RescueToast([string]$title, [string]$body) { $script:toasts += $body; return $false }
# Nothing here may shell out to the real `claude agents`: it would be slow, and
# it would make the suite's verdict depend on whatever the machine happens to be
# running. Individual cases below override this to describe a live session.
$script:agents = @()
function Get-AgentList { return $script:agents }

function NewLimitLine([string]$sid, [datetime]$ts, [string]$resetText, [string]$cwd) {
  ([ordered]@{
    type      = "assistant"
    timestamp = $ts.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
    message   = @{ role = "assistant"; content = @(@{ type = "text"; text = $resetText }) }
    error     = "rate_limit"; isApiErrorMessage = $true; sessionId = $sid; cwd = $cwd
  } | ConvertTo-Json -Depth 8 -Compress)
}
$tr = Join-Path $projDir "sess.jsonl"
function WriteStop([datetime]$ts, [datetime]$reset, [string]$sid, [string]$cwd) {
  Set-Content -Path $tr -Encoding UTF8 -Value (@($userLine,
    (NewLimitLine $sid $ts ("You've hit your session limit - resets " + $reset.ToString("h:mmtt").ToLower()) $cwd)) -join "`n")
}

$soon = (Get-Date).AddHours(1)
WriteStop (Get-Date) $soon "ffff-9999" $tmp
$script:sessArmed = @()
Invoke-SessionReconcile
Check "arms a one-shot for the announced reset" ($script:sessArmed.Count -eq 1)
Check "arming lands at reset + 5 min"            ([math]::Abs(($script:sessArmed[0] - $soon.AddSeconds(300)).TotalMinutes) -lt 1.5)
Check "pending-sessions state written"           (Test-Path $script:SessionsStateFile)

# The exact 2026-07-25 failure: one pass sees nothing, and used to respond by
# unregistering the armed task — throwing away a rescue that had not fired yet.
Rename-Item $tr ($tr + ".hidden")
$script:sessArmed = @(); $script:fakeTask = $null
Invoke-SessionReconcile
Check "an empty scan does NOT delete a live arming"  (Test-Path $script:SessionsStateFile)
Check "an empty scan re-registers a missing task"    ($script:sessArmed.Count -eq 1)

Save-SessionsState ((Get-Date).AddMinutes(-5)) @() 0
Invoke-SessionReconcile
Check "clears only once the armed time has passed"   (-not (Test-Path $script:SessionsStateFile))

$past = (Get-Date).AddHours(-2)
Remove-Item ($tr + ".hidden") -Force -ErrorAction SilentlyContinue
WriteStop $past $past.AddMinutes(30) "ffff-9999" $tmp
Remove-Item $script:ProcessedSessionsFile, $script:SessionsStateFile -Force -ErrorAction SilentlyContinue
$script:resumed = @()
Invoke-SessionReconcile
Check "a reset already past -> session actually resumed" ($script:resumed -contains "ffff-9999")
Check "resumed session recorded as handled"              (Test-ProcessedSession (Get-ProcessedSessions) "ffff-9999" (ConvertTo-IsoUtcString $past))
# The rescue is worthless if the user cannot tell it happened.
$autoNotice = Join-Path $tmp $SessionNoticeFile
Check "a real rescue attempts a desktop toast"           ($script:toasts.Count -eq 1)
Check "the toast says not to re-run by hand"             ($script:toasts[0] -match 'do not re-run')
# The whole point of --bg over -p: the resumed session must be findable from the
# phone, so the notice has to give its id and say how to get back into it.
$n = Get-Content (Join-Path $tmp "QUOTAWAKE-RESUMED.md") -Raw
Check "notice gives the resumed session's id"            ($n -match 'abcd1234')
Check "notice says it is visible in the Claude app"      ($n -match '(?i)Claude app')
# The user must never be sent to `--resume` for the session that is running -
# that answers "No conversation found" and reads as a broken rescue.
Check "notice leads with the claude agents list"         ($n -match 'claude agents')
Check "notice labels the two ids in plain words"         ($n -match 'Session that stopped' -and $n -match 'Resumed session')
Check "notice gives the attach/logs commands"            ($n -match 'claude attach abcd1234' -and $n -match 'claude logs abcd1234')
Check "notice carries the resumed session's last words"  ($n -match 'the work is finished')
Check "a real rescue leaves a notice in the project"     (Test-Path $autoNotice)
Check "that notice names the rescued session"            ((Get-Content $autoNotice -Raw) -like "*ffff-9999*")
Remove-Item $autoNotice -Force -ErrorAction SilentlyContinue

# A project on an unmounted Google Drive must be retried, never written off.
WriteStop $past $past.AddMinutes(30) "gggg-8888" (Join-Path $tmp "no-such-drive")
Remove-Item $script:ProcessedSessionsFile, $script:SessionsStateFile -Force -ErrorAction SilentlyContinue
$script:resumed = @(); $script:sessArmed = @()
Invoke-SessionReconcile
Check "unreachable project folder -> not resumed"        ($script:resumed.Count -eq 0)
Check "unreachable project folder -> NOT written off"    (-not (Test-ProcessedSession (Get-ProcessedSessions) "gggg-8888" (ConvertTo-IsoUtcString $past)))
Check "unreachable project folder -> retry re-armed"     ($script:sessArmed.Count -eq 1)

# An 8-character hex id tells the user nothing about which session it is. The
# name is the only thing in `claude agents` that can, and Claude Code derives it
# from the prompt unless --name is given - which made every resumed session
# read "You were interrupted by a usage-limit reset...", identical for all of
# them. The label must name the project.
$lbl = Get-SessionLabel ([pscustomobject]@{ Cwd = 'C:\_GitHub\my-project' })
Check "session label names the project folder"           ($lbl -match '^my-project')
Check "session label says when it was resumed"           ($lbl -match 'resumed \d{2}:\d{2}$')
Check "session label survives a pathless hit"            ((Get-SessionLabel ([pscustomobject]@{ Cwd = '' })) -match 'unknown project')

# The ledger doubles as the map the user opens to answer "which id is mine?".
# Two UUIDs and a timestamp cannot answer that; project and resumed-id can.
Remove-Item $script:ProcessedSessionsFile -Force -ErrorAction SilentlyContinue
Add-ProcessedSession "old-1111" "2026-08-02T10:00:00Z" "C:\_GitHub\my-project" "7f3ab210" "my-project — resumed 20:04"
$led = @(Get-ProcessedSessions)
Check "ledger row records the project"                   ($led[0].project -eq 'my-project')
Check "ledger row records the resumed session id"        ($led[0].resumedAs -eq '7f3ab210')
Check "ledger row records the full project path"         ($led[0].projectPath -eq 'C:\_GitHub\my-project')
# Duplicate suppression must keep working across the added fields, or a resumed
# session gets resumed a second time.
Check "ledger still suppresses a handled pair"           (Test-ProcessedSession $led "old-1111" (ConvertTo-IsoUtcString "2026-08-02T10:00:00Z"))
Remove-Item $script:ProcessedSessionsFile -Force -ErrorAction SilentlyContinue

# A stop line records that a session HIT a limit. It does not record that the
# session is gone — and a session that is still running must never be resumed,
# because `--resume --bg` forks it rather than continuing it. Missing this turned
# one live interactive window into a three-deep chain of background agents in
# half an hour on 2026-08-01: the tool rescued the user's own terminal, then
# rescued its own rescue, twice.
function ScanOnly([string]$sid, $agents) {
  $script:agents = $agents
  WriteStop $past $past.AddMinutes(30) $sid $tmp
  Remove-Item $script:ProcessedSessionsFile, $script:SessionsStateFile -Force -ErrorAction SilentlyContinue
  $script:resumed = @(); $script:sessArmed = @()
  Invoke-SessionReconcile
  Remove-Item (Join-Path $tmp $SessionNoticeFile) -Force -ErrorAction SilentlyContinue
}

# The user's own open window. Its TUI continues by itself after a reset.
ScanOnly "live-0001" @([pscustomobject]@{ sessionId = "live-0001"; pid = 4242; kind = "interactive"; status = "idle" })
Check "a live interactive session is never rescued"      ($script:resumed.Count -eq 0)
Check "a live session is NOT written off as handled"     (-not (Test-ProcessedSession (Get-ProcessedSessions) "live-0001" (ConvertTo-IsoUtcString $past)))

# An agent waiting on a permission prompt needs a human, not a second copy.
ScanOnly "blkd-0002" @([pscustomobject]@{ sessionId = "blkd-0002"; id = "blkd"; kind = "background"; state = "blocked"; status = "waiting" })
Check "an agent blocked on a prompt is left alone"       ($script:resumed.Count -eq 0)

# A previously dispatched rescue, still running: resuming it is what chained.
ScanOnly "bgrn-0003" @([pscustomobject]@{ sessionId = "bgrn-0003"; id = "bgrn"; kind = "background"; state = "running" })
Check "a running background agent is not re-rescued"     ($script:resumed.Count -eq 0)

# But a finished agent holds no process, so it stays eligible.
ScanOnly "done-0004" @([pscustomobject]@{ sessionId = "done-0004"; id = "done"; kind = "background"; state = "done" })
Check "a finished agent is still a valid target"         ($script:resumed -contains "done-0004")

# Losing the agent list must not disable rescue altogether.
ScanOnly "gone-0005" @()
Check "an unreadable agent list still allows rescue"     ($script:resumed -contains "gone-0005")
$script:agents = @()

Write-Host "== platform layer =="
# The systemd backend cannot run on a Windows box, so everything OS-specific is
# written as a PURE GENERATOR returning text. That makes the part most likely to
# be wrong — the exact unit content — testable everywhere, and leaves only the
# `systemctl` calls unverified. -Doctor covers those where they actually run.
# (A launchd backend existed until ac11ea2 and was removed for lack of a Mac to
# test on; macOS is now refused by name rather than half-supported.)
$realPlatform = $script:Platform
Check "platform detected"                 ($realPlatform -eq 'Windows')
Check "job slug strips prefix and case"   ((Get-JobSlug 'QuotaWake-FireSessions') -eq 'firesessions')
Check "job slug stable for Fire"          ((Get-JobSlug 'QuotaWake-Fire') -eq 'fire')

$fire = [datetime]'2026-08-01 15:05:00'

# An unsupported OS must fail loudly. Every backend switch below would otherwise
# match no branch and do nothing, so -Install would report success having
# registered no job at all — the exact silent-success failure mode this tool has
# already shipped four times.
$script:Platform = 'macOS'
$threw = $false
try { Assert-SupportedPlatform } catch { $threw = $true; $msg = $_.Exception.Message }
Check "macOS is refused, not half-supported" $threw
Check "the refusal names the platform"       ($msg -match 'macOS')
$script:Platform = 'Unknown'
$threw = $false; try { Assert-SupportedPlatform } catch { $threw = $true }
Check "an unknown platform is refused too"   $threw

$script:Platform = 'Linux'
$argv = Get-SelfArgv '-Reconcile'
Check "unix argv invokes pwsh -File"      ($argv[0] -match 'pwsh' -and ($argv -contains '-File') -and ($argv -contains '-Reconcile'))
$u = New-SystemdUnits 'QuotaWake-FireSessions' '-Reconcile' $fire 0
Check "systemd service is oneshot"        ($u.Service -match '(?m)^Type=oneshot$')
Check "systemd ExecStart runs the script" ($u.Service -match 'quotawake\.ps1' -and $u.Service -match '\-Reconcile')
Check "systemd timer: exact moment"       ($u.Timer -match '(?m)^OnCalendar=2026-08-01 15:05:00$')
# Persistent=true is the systemd spelling of StartWhenAvailable. Without it a
# timer whose moment passed while the machine was off never runs at all, which
# is the whole guarantee this tool rests on.
Check "systemd timer is Persistent"       ($u.Timer -match '(?m)^Persistent=true$')
Check "systemd timer installs correctly"  ($u.Timer -match '(?m)^WantedBy=timers\.target$')
$ur = New-SystemdUnits 'QuotaWake-Logon' '-Reconcile' $null 15
Check "systemd recurring: 15min interval" ($ur.Timer -match '(?m)^OnUnitActiveSec=15min$')
Check "systemd recurring: fires at boot"  ($ur.Timer -match '(?m)^OnBootSec=')
Check "watcher unit restarts on failure"  ((New-WatcherSystemdUnit) -match '(?m)^Restart=always$')
Check "watcher unit runs keep-awake"      ((New-WatcherSystemdUnit) -match 'keep-awake\.ps1')

$script:Platform = $realPlatform
Check "platform restored"                 ($script:Platform -eq 'Windows')

Write-Host ""
$col = if ($script:fail -eq 0) { "Green" } else { "Red" }
Write-Host ("RESULT: {0} passed, {1} failed" -f $script:pass, $script:fail) -ForegroundColor $col
Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
exit ([int]($script:fail -gt 0))
