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

Write-Host "== who typed: a person, or Claude Code itself =="
# Only a person typing after the reset hands a window back to its user. Claude
# Code writes many user lines by itself, and none of them may count.
Check "a typed prompt is a person"                 (Test-HumanPrompt ([pscustomobject]@{ type = 'user'; message = @{ content = 'continue with the plan' } }))
Check "a typed text block is a person"             (Test-HumanPrompt ([pscustomobject]@{ type = 'user'; message = @{ content = @(@{ type = 'text'; text = 'go on' }) } }))
Check "a tool result is not"                       (-not (Test-HumanPrompt ([pscustomobject]@{ type = 'user'; message = @{ content = @(@{ type = 'tool_result'; content = 'x' }) } })))
Check "a task notification is not"                 (-not (Test-HumanPrompt ([pscustomobject]@{ type = 'user'; message = @{ content = '<task-notification><task-id>b2x</task-id>' } })))
Check "a meta line is not"                         (-not (Test-HumanPrompt ([pscustomobject]@{ type = 'user'; isMeta = $true; message = @{ content = 'Caveat' } })))
Check "quotawake's own continue prompt is not"     (-not (Test-HumanPrompt ([pscustomobject]@{ type = 'user'; message = @{ content = $SessionResumeTask } })))
$typedAfter = '{"type":"user","timestamp":"2026-07-18T20:30:00.000Z","message":{"role":"user","content":"keep going"},"sessionId":"aaaa-1111","cwd":"C:\\proj"}'
$hit = Find-StrandedSession (NewFixture @($userLine, $limitLine, $typedAfter))
Check "typing after the reset is recorded"         ($null -ne $hit -and $hit.HumanAfterReset)
$hit = Find-StrandedSession (NewFixture @($userLine, $limitLine, $beforeReset))
Check "typing before the reset is not"             ($null -ne $hit -and -not $hit.HumanAfterReset)

Write-Host "== a copy is recognised by its id =="
# Since Claude Code 2.1.257 `--resume <id> --bg` keeps the session's id; a new
# id means it copied the session because something still holds it.
Check "same id -> the session itself"              (-not (Test-CopyDispatch '1c886230-a8f4-49af-b46b-ec4c118a06c4' '1c886230'))
Check "a different id -> a copy"                   (Test-CopyDispatch '8eed15d7-2e3b-429b-9f40-774af154614d' '1c886230')
Check "no id printed -> not called a copy"         (-not (Test-CopyDispatch '8eed15d7-2e3b' ''))

Write-Host "== rescue notice (the only signal a frozen terminal ever gets) =="
$fakeHit = @{ SessionId = "zzzz0000-1111"; Cwd = $tmp; LimitTs = "2026-07-18T16:06:14.641Z"
              LimitText = "resets 9:50pm"; Transcript = "x" }
$p1 = Write-RescueNotice $fakeHit "line one`nline two" ([datetime]"2026-07-18 21:50") "The session is continuing in the background." $false
Check "notice file created in the project folder" ($null -ne $p1 -and (Test-Path $p1))
$t1 = Get-Content $p1 -Raw
Check "notice leads with what happened"           ($t1 -match '(?s)## Resumed automatically[^\n]*\n\nThe session is continuing')
Check "notice says there is nothing to do"        ($t1 -match 'Nothing to do')
Check "notice gives the one command to open it"   ($t1 -match 'qw -Open' -and $t1 -match 'claude attach zzzz0000')
Check "notice says it is the same session"        ($t1 -match 'the same session as before')
Check "notice no longer claims two ids differ"    ($t1 -notmatch 'ids below differ')
Check "notice carries the run's own output"       ($t1 -like "*line two*")
Check "notice flags a missing toast"              ($t1 -match 'only signal')
$p2 = Write-RescueNotice $fakeHit "second run" ([datetime]"2026-07-18 21:50") "Done." $true
$t2 = Get-Content $p2 -Raw
Check "a second rescue appends, never overwrites" (([regex]::Matches($t2, 'Resumed automatically')).Count -eq 2)
Check "notice records that a toast was shown"     ($t2 -match 'Desktop notification \| shown')
Remove-Item $p1 -Force -ErrorAction SilentlyContinue
$p3 = Write-RescueNotice $fakeHit "" $null "quotawake could not resume this session (exit 1)." $false $false
Check "a failed resume says how to do it by hand" ((Get-Content $p3 -Raw) -match 'claude --resume zzzz0000-1111')
Remove-Item $p3 -Force -ErrorAction SilentlyContinue
Check "unreachable project folder -> no notice"   ($null -eq (Write-RescueNotice `
  @{ SessionId = "q"; Cwd = (Join-Path $tmp "no-such-dir"); LimitTs = "x" } "t" $null "r" $false))
Check "an empty project path -> no notice, no throw" ($null -eq (Write-RescueNotice @{ SessionId = "q"; Cwd = ''; LimitTs = "x" } "t" $null "r" $false))
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
# Mirrors the real --bg return shape: the dispatch exits 0 at once and prints
# the session's 8-character id – its own id, since resumes keep it. A test
# that sets $script:copyNext stands for a CLI that copied the session instead.
$script:copyNext = $false
function Invoke-SessionResume($hit) {
  $script:resumed += $hit.SessionId
  if ($script:copyNext) { return @{ Text = "note: started a copy as c0c0c0c0"; Code = 0; BgId = "c0c0c0c0"; State = 'removed'; Summary = ''; Copy = $true } }
  $bg = $hit.SessionId.Substring(0, [math]::Min(8, $hit.SessionId.Length))
  return @{ Text = "backgrounded `u{00B7} $bg"; Code = 0; BgId = $bg; State = "done"; Summary = "the work is finished"; Copy = $false }
}
$script:toasts = @()
function Show-RescueToast([string]$title, [string]$body) { $script:toasts += $body; return $false }
# Ending a holder means killing a process or stopping a session: mocked, so no
# test touches anything running on this machine.
$script:stopped = @(); $script:stopWorks = $true
function Stop-SessionHolder($info) { $script:stopped += $info; return $script:stopWorks }
# Nothing here may shell out to the real `claude agents`: it would be slow, and
# it would make the suite's verdict depend on whatever the machine happens to be
# running. Individual cases below override this to describe a live session.
$script:agents = @()
# $script:agents = $null stands for a probe that could not be taken at all,
# which the real function reports the same way. The rest goes back as an array
# even when empty – `return @()` unrolls to $null and would make every case
# below look like a failed probe.
function Get-AgentList {
  if ($null -eq $script:agents) { return $null }
  return ,@($script:agents)
}

function NewLimitLine([string]$sid, [datetime]$ts, [string]$resetText, [string]$cwd) {
  ([ordered]@{
    type      = "assistant"
    timestamp = $ts.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
    message   = @{ role = "assistant"; content = @(@{ type = "text"; text = $resetText }) }
    error     = "rate_limit"; isApiErrorMessage = $true; sessionId = $sid; cwd = $cwd
  } | ConvertTo-Json -Depth 8 -Compress)
}
$tr = Join-Path $projDir "sess.jsonl"
function WriteStop([datetime]$ts, [datetime]$reset, [string]$sid, [string]$cwd, [string[]]$after = @()) {
  Set-Content -Path $tr -Encoding UTF8 -Value ((@($userLine,
    (NewLimitLine $sid $ts ("You've hit your session limit - resets " + $reset.ToString("h:mmtt").ToLower()) $cwd)) + $after) -join "`n")
  # A stranded transcript's last write is its own stop line, hours ago. Say so
  # on disk: the dispatch checks the file's mtime to see whether a process is
  # writing it, and a fixture created a millisecond ago reads as very much alive.
  try { (Get-Item -LiteralPath $tr).LastWriteTime = $ts } catch {}
}

$soon = (Get-Date).AddHours(1)
WriteStop (Get-Date) $soon "ffff-9999" $tmp
$script:sessArmed = @()
Invoke-SessionReconcile
Check "arms a one-shot for the announced reset" ($script:sessArmed.Count -eq 1)
Check "arming lands at reset + 5 min"            ([math]::Abs(($script:sessArmed[0] - $soon.AddSeconds(300)).TotalMinutes) -lt 1.5)
Check "pending-sessions state written"           (Test-Path $script:SessionsStateFile)

# The exact 2026-07-25 failure: one pass sees nothing, and used to respond by
# unregistering the armed task – throwing away a rescue that had not fired yet.
Rename-Item $tr ($tr + ".hidden")
$script:sessArmed = @(); $script:fakeTask = $null
Invoke-SessionReconcile
Check "an empty scan does NOT delete a live arming"  (Test-Path $script:SessionsStateFile)
Check "an empty scan re-registers a missing task"    ($script:sessArmed.Count -eq 1)

Save-SessionsState ((Get-Date).AddMinutes(-5)) @()
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
Check "the toast says how to look in"                    ($script:toasts[0] -match 'qw -Open')
$n = Get-Content $autoNotice -Raw
Check "notice names the session"                         ($n -match 'ffff-9999')
Check "notice gives the one command to open it"          ($n -match 'qw -Open')
Check "notice carries the resumed session's last words"  ($n -match 'the work is finished')
# The transcript keeps the stop that was just handled: a resume keeps the id.
# That old stop must not be reported as a new one (9 of 11 resumes did).
Check "the handled stop is not reported as a new limit"  ($n -notmatch 'another usage limit')
Remove-Item $autoNotice -Force -ErrorAction SilentlyContinue

# A project on an unmounted Google Drive must be retried, never written off.
WriteStop $past $past.AddMinutes(30) "gggg-8888" (Join-Path $tmp "no-such-drive")
Remove-Item $script:ProcessedSessionsFile, $script:SessionsStateFile -Force -ErrorAction SilentlyContinue
$script:resumed = @(); $script:sessArmed = @()
Invoke-SessionReconcile
Check "unreachable project folder -> not resumed"        ($script:resumed.Count -eq 0)
Check "unreachable project folder -> NOT written off"    (-not (Test-ProcessedSession (Get-ProcessedSessions) "gggg-8888" (ConvertTo-IsoUtcString $past)))
Check "unreachable project folder -> retry re-armed"     ($script:sessArmed.Count -eq 1)
# Retried for as long as it takes, but not forever: a day after its reset the
# stop is written off, with a note. Measured per session from its own reset.
$old = (Get-Date).AddHours(-30)
WriteStop $old $old.AddMinutes(30) "gggg-8888" (Join-Path $tmp "no-such-drive")
Remove-Item $script:ProcessedSessionsFile, $script:SessionsStateFile -Force -ErrorAction SilentlyContinue
$script:resumed = @(); $script:sessArmed = @(); $script:toasts = @()
Invoke-SessionReconcile
Check "a day past its reset it is given up"              (Test-ProcessedSession (Get-ProcessedSessions) "gggg-8888" (ConvertTo-IsoUtcString $old))
Check "giving up is announced"                           ($script:toasts.Count -eq 1 -and $script:toasts[0] -match 'gave up')

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
Remove-Item $script:ProcessedSessionsFile -Force -ErrorAction SilentlyContinue
Add-ProcessedSession "7f3ab210-1111" "2026-08-02T10:00:00Z" "C:\_GitHub\my-project" "7f3ab210" "my-project – resumed 20:04"
$led = @(Get-ProcessedSessions)
Check "ledger row records the project"                   ($led[0].project -eq 'my-project')
Check "ledger row records the resumed session id"        ($led[0].resumedAs -eq '7f3ab210')
Check "ledger row records the full project path"         ($led[0].projectPath -eq 'C:\_GitHub\my-project')
# Duplicate suppression must keep working across the added fields, or a resumed
# session gets resumed a second time.
Check "ledger still suppresses a handled pair"           (Test-ProcessedSession $led "7f3ab210-1111" (ConvertTo-IsoUtcString "2026-08-02T10:00:00Z"))
Remove-Item $script:ProcessedSessionsFile -Force -ErrorAction SilentlyContinue

# `qw -Open` picks the session for the folder it is run in.
$rowsOpen = @(
  [pscustomobject]@{ resumedAs = 'a1b2c3d4'; projectPath = 'C:\_GitHub\another-project' },
  [pscustomobject]@{ resumedAs = '7f3ab210'; projectPath = 'C:\_GitHub\my-project' },
  [pscustomobject]@{ resumedAs = '';         projectPath = 'C:\_GitHub\my-project' },
  [pscustomobject]@{ resumedAs = 'e5f6a7b8'; projectPath = 'C:\_GitHub\third-project' })
Check "-Open picks this folder's resume"                 ((Select-ResumedRow $rowsOpen 'C:\_GitHub\my-project').resumedAs -eq '7f3ab210')
Check "-Open works from a subfolder"                     ((Select-ResumedRow $rowsOpen 'C:\_GitHub\my-project\src').resumedAs -eq '7f3ab210')
Check "-Open does not match a name prefix"               ((Select-ResumedRow $rowsOpen 'C:\_GitHub\my-project-two').resumedAs -eq 'e5f6a7b8')
Check "-Open elsewhere -> the newest resume"             ((Select-ResumedRow $rowsOpen 'C:\Users').resumedAs -eq 'e5f6a7b8')
Check "-Open with no resumes -> nothing"                 ($null -eq (Select-ResumedRow @() 'C:\'))

# A stop line records that a session HIT a limit, not that it is gone. A held
# session is never resumed outright: `--resume --bg` would copy it, and the copy
# works beside the holder. That is what happened on 2026-09-28: a copy did the
# night's work and the open window started the same work again at 08:19.
function ScanOnly([string]$sid, $agents, [switch]$KeepLedger, [string[]]$after = @()) {
  $script:agents = $agents
  WriteStop $past $past.AddMinutes(30) $sid $tmp $after
  if (-not $KeepLedger) { Remove-Item $script:ProcessedSessionsFile -Force -ErrorAction SilentlyContinue }
  Remove-Item $script:SessionsStateFile -Force -ErrorAction SilentlyContinue
  $script:resumed = @(); $script:stopped = @(); $script:sessArmed = @(); $script:toasts = @()
  Invoke-SessionReconcile
}

# The user's own open window, 90 minutes past its reset and still stopped.
$liveWindow = @([pscustomobject]@{ sessionId = "live-0001"; pid = 4242; kind = "interactive"; status = "idle" })
ScanOnly "live-0001" $liveWindow
Check "a stopped open window is taken over"              ($script:stopped.Count -eq 1 -and $script:stopped[0].Pid -eq 4242)
Check "its holder is ended BEFORE the session resumes"   ($script:resumed -contains "live-0001")
Check "the take-over closes the pair"                    (Test-ProcessedSession (Get-ProcessedSessions) "live-0001" (ConvertTo-IsoUtcString $past))
$cn = Get-Content (Join-Path $tmp $SessionNoticeFile) -Raw
Check "the notice says the window was closed"            ($cn -match 'quotawake closed it')
Check "the notice says nothing runs twice"               ($cn -match 'Nothing runs twice')
Remove-Item (Join-Path $tmp $SessionNoticeFile) -Force -ErrorAction SilentlyContinue

# A holder that cannot be ended is never resumed past: the resume would copy.
$script:stopWorks = $false
ScanOnly "live-0001" $liveWindow
Check "a holder that will not end -> no resume"          ($script:resumed.Count -eq 0)
Check "... and the session stays eligible"               (-not (Test-ProcessedSession (Get-ProcessedSessions) "live-0001" (ConvertTo-IsoUtcString $past)))
Check "... and a retry is armed"                         ($script:sessArmed.Count -eq 1)
$script:stopWorks = $true

# Someone typed into the window after the reset: they are there. Hands off.
$typedNow = '{"type":"user","timestamp":"' + (Get-Date).AddMinutes(-20).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ") + '","message":{"role":"user","content":"what happened?"},"sessionId":"live-0001","cwd":"C:\\proj"}'
ScanOnly "live-0001" $liveWindow -after @($typedNow)
Check "typed after the reset -> not taken over"          ($script:stopped.Count -eq 0 -and $script:resumed.Count -eq 0)
Check "typed after the reset -> left to the user"        (Test-ProcessedSession (Get-ProcessedSessions) "live-0001" (ConvertTo-IsoUtcString $past))
Check "the note says it was left to them"                ((Get-Content (Join-Path $tmp $SessionNoticeFile) -Raw) -match 'Left to you')
Remove-Item (Join-Path $tmp $SessionNoticeFile) -Force -ErrorAction SilentlyContinue

# The decision itself, without the pass around it.
$fakeLive = @{ SessionId = 'live-0001'; LimitTs = (ConvertTo-IsoUtcString $past); LimitText = "resets " + $past.AddMinutes(30).ToString("h:mmtt").ToLower(); Cwd = $tmp }
$justReset = $past.AddMinutes(30).AddSeconds(60)
$win = @{ Kind = 'interactive'; Pid = 4242; Status = 'idle'; Id = '' }
Check "inside the grace -> defer (it may continue itself)"  ((Resolve-LiveStrandedAction $fakeLive $win $justReset).Action -eq 'defer')
Check "the grace defer asks for a look when it ends"        ($null -ne (Resolve-LiveStrandedAction $fakeLive $win $justReset).RetryAt)
Check "past the grace -> take over"                         ((Resolve-LiveStrandedAction $fakeLive $win $justReset.AddSeconds($SessionLiveGraceSeconds)).Action -eq 'takeover')
$busy = @{ Kind = 'interactive'; Pid = 4242; Status = 'busy'; Id = '' }
Check "busy, inside the busy grace -> defer"                ((Resolve-LiveStrandedAction $fakeLive $busy $justReset.AddSeconds($SessionLiveGraceSeconds)).Action -eq 'defer')
Check "busy past the busy grace -> take over anyway"        ((Resolve-LiveStrandedAction $fakeLive $busy $justReset.AddSeconds($SessionBusyGraceSeconds)).Action -eq 'takeover')
Check "an unknown kind of holder is never ended"            ((Resolve-LiveStrandedAction $fakeLive @{ Kind = 'unknown'; Pid = 1; Status = '' } (Get-Date)).Action -eq 'defer')
$fakeTyped = $fakeLive.Clone(); $fakeTyped.HumanAfterReset = $true
Check "typed after the reset -> leave"                      ((Resolve-LiveStrandedAction $fakeTyped $win (Get-Date)).Action -eq 'leave')
$isoX = ConvertTo-IsoUtcString '2026-01-01T00:00:00Z'
Check "a resume row closes the pair"                     (Test-ProcessedSession @([pscustomobject]@{ sessionId = 'x'; limitTs = $isoX; action = 'resumed' }) 'x' $isoX)
Check "a row from before the action field counts as a resume" (Test-ProcessedSession @([pscustomobject]@{ sessionId = 'x'; limitTs = $isoX }) 'x' $isoX)
Check "an old nudge row does not close the pair"         (-not (Test-ProcessedSession @([pscustomobject]@{ sessionId = 'x'; limitTs = $isoX; action = 'nudged' }) 'x' $isoX))
Check "a removed copy is never rescued, by its id prefix" (Test-ProcessedSession @([pscustomobject]@{ sessionId = 'c0c0c0c0'; limitTs = $isoX; action = 'discarded copy' }) 'c0c0c0c0-9999-aaaa' (ConvertTo-IsoUtcString '2026-02-02T00:00:00Z'))

# A background session stopped at a new limit – this tool's own rescue, say –
# is stopped through the CLI and continued under the same id. No copy, so no
# chain: the ids never multiply (the 2026-08-01 chain came from copies).
ScanOnly "bgrn-0003" @([pscustomobject]@{ sessionId = "bgrn-0003"; id = "bgrn0003"; kind = "background"; state = "blocked" })
Check "a stopped background session is taken over"      ($script:stopped.Count -eq 1 -and $script:stopped[0].Id -eq 'bgrn0003')
Check "... and continued under its own id"              ($script:resumed -contains "bgrn-0003")
Remove-Item (Join-Path $tmp $SessionNoticeFile) -Force -ErrorAction SilentlyContinue

# A finished agent holds no process, so it is resumed without any take-over.
ScanOnly "done-0004" @([pscustomobject]@{ sessionId = "done-0004"; id = "done"; kind = "background"; state = "done" })
Check "a finished agent is resumed directly"             ($script:resumed -contains "done-0004" -and $script:stopped.Count -eq 0)

# An empty list is an answer: the CLI ran and nothing holds the session.
ScanOnly "gone-0005" @()
Check "an empty agent list still allows rescue"          ($script:resumed -contains "gone-0005")

# A probe that could not be taken used to defer every resume (all seven on
# 2026-09-13). It resumes now: if anything still holds the session, the CLI
# copies it instead, says so by the id it prints, and the copy is removed.
ScanOnly "blnd-0006" $null
Check "a blind agent probe still resumes"                ($script:resumed -contains "blnd-0006")
$script:copyNext = $true
ScanOnly "blnd-0006" $null
$script:copyNext = $false
Check "a copy is not counted as a resume"                (-not (Test-ProcessedSession (Get-ProcessedSessions) "blnd-0006" (ConvertTo-IsoUtcString $past)))
Check "the removed copy is recorded so it is never rescued" (Test-ProcessedSession (Get-ProcessedSessions) "c0c0c0c0-0000-0000" (ConvertTo-IsoUtcString $past))
Check "a copy defers the session for another look"       ($script:sessArmed.Count -eq 1)
Check "a removed copy raises no 'resumed' toast"         ($script:toasts.Count -eq 0)
$script:agents = @()

# The transcript itself answers the same question without the CLI: a file being
# written right now has a process on it, whoever that is.
WriteStop $past $past.AddMinutes(30) "warm-0007" $tmp
(Get-Item -LiteralPath $tr).LastWriteTime = (Get-Date)
Remove-Item $script:ProcessedSessionsFile, $script:SessionsStateFile -Force -ErrorAction SilentlyContinue
$script:resumed = @(); $script:sessArmed = @()
Invoke-SessionReconcile
Check "a transcript written just now is not resumed"     ($script:resumed.Count -eq 0)
Check "a warm transcript leaves the session eligible"    (-not (Test-ProcessedSession (Get-ProcessedSessions) "warm-0007" (ConvertTo-IsoUtcString $past)))
# Deferrals no longer spend a shared budget. Many passes in a row write nothing off.
for ($i = 0; $i -lt 10; $i++) { (Get-Item -LiteralPath $tr).LastWriteTime = (Get-Date); Invoke-SessionReconcile }
Check "ten deferrals in a row write nothing off"         (-not (Test-ProcessedSession (Get-ProcessedSessions) "warm-0007" (ConvertTo-IsoUtcString $past)))
Remove-Item (Join-Path $tmp $SessionNoticeFile) -Force -ErrorAction SilentlyContinue

Write-Host "== platform =="
# Windows only. Backends for macOS (launchd) and Linux (systemd --user) were both
# written and both removed: neither could be tested on the machine shipping them,
# and a scheduler backend fails by registering NOTHING, silently. The rule that
# replaced them is that an unsupported OS must fail loudly - without it, -Install
# would report success having registered no job at all, which is exactly the
# silent-success failure this tool has already shipped four times.
$realPlatform = $script:Platform
Check "platform detected"                    ($realPlatform -eq 'Windows')
$ok = $true; try { Assert-SupportedPlatform } catch { $ok = $false }
Check "Windows is accepted"                  $ok

$script:Platform = 'macOS'
$threw = $false; $msg = ''
try { Assert-SupportedPlatform } catch { $threw = $true; $msg = $_.Exception.Message }
Check "macOS is refused, not half-supported" $threw
Check "the refusal names the platform"       ($msg -match 'macOS')
Check "the refusal says where the code went" ($msg -match 'ac11ea2')

$script:Platform = 'Linux'
$threw = $false; $msg = ''
try { Assert-SupportedPlatform } catch { $threw = $true; $msg = $_.Exception.Message }
Check "Linux is refused too"                 $threw
Check "and points at the planned port"       ($msg -match '(?i)python')

$script:Platform = 'Unknown'
$threw = $false; try { Assert-SupportedPlatform } catch { $threw = $true }
Check "an unknown platform is refused too"   $threw

$script:Platform = $realPlatform
Check "platform restored"                    ($script:Platform -eq 'Windows')
# The .vbs shim is what stops Task Scheduler flashing a console on every pass.
$argv = Get-SelfArgv '-Reconcile'
Check "self-argv goes through the vbs shim"  ($argv[0] -eq 'wscript.exe' -and $argv[1] -match 'run-hidden\.vbs' -and $argv[1] -match '\-Reconcile')

Write-Host ""
$col = if ($script:fail -eq 0) { "Green" } else { "Red" }
Write-Host ("RESULT: {0} passed, {1} failed" -f $script:pass, $script:fail) -ForegroundColor $col
Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
exit ([int]($script:fail -gt 0))
