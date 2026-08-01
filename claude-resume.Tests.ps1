# Unit tests for claude-resume.ps1 — dot-sources it in -SelfTest mode so no real
# `claude` runs, no scheduled task is registered, and no quota is spent.
# Run:  pwsh -File .\claude-resume.Tests.ps1
$ErrorActionPreference = "Stop"

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("claude-resume-test-" + [guid]::NewGuid().ToString("N").Substring(0,8))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null

# Bring functions + $limitPattern into this scope; skip the entry points.
. (Join-Path $PSScriptRoot "claude-resume.ps1") -SelfTest -Project $tmp
$script:StateFile = Join-Path $tmp "pending-resume.json"   # keep test state out of the real file
$script:logFile   = Join-Path $tmp "claude-resume.log"

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
Check "notice explains why the window is dead"    ($t1 -match 'cannot be resumed in place')
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
# The whole point of --bg over -p: the rescue must be findable from the phone,
# so the notice has to name the agent and say how to reach it.
$n = Get-Content (Join-Path $tmp "CLAUDE-RESUMED.md") -Raw
Check "notice names the background agent"                ($n -match 'abcd1234')
Check "notice says it is visible in the Claude app"      ($n -match '(?i)Claude app')
Check "notice gives the attach/logs commands"            ($n -match 'claude attach abcd1234' -and $n -match 'claude logs abcd1234')
Check "notice carries the agent's own final message"     ($n -match 'the work is finished')
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

Write-Host ""
$col = if ($script:fail -eq 0) { "Green" } else { "Red" }
Write-Host ("RESULT: {0} passed, {1} failed" -f $script:pass, $script:fail) -ForegroundColor $col
Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
exit ([int]($script:fail -gt 0))
