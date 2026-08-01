# Design notes

Why this tool is shaped the way it is. Most of these decisions look arbitrary
until you know which failure produced them — every section below exists because
something silently did not work.

## No resident process

The obvious design is to hit a limit, sleep until the reset, and carry on. That
was the first version, and it lost work constantly: a waiting process dies with a
closed window, a logoff, a reboot, or a laptop entering Modern Standby.

So the wait was handed to Windows Task Scheduler instead. On a limit the script
records what to do, registers a one-shot task for the reset, and exits. Nothing is
running in between — which means there is nothing left to kill.

- `StartWhenAvailable` makes a task that was missed (machine asleep or off) fire
  as soon as the machine is back, instead of being skipped.
- `WakeToRun` can wake the machine at the exact moment, where power policy allows.

## The 15-minute reconciler trigger

The reconciler task was originally `AtLogOn` only. It never fired once — on a
Modern Standby machine the session suspends and resumes rather than logging off,
so "logon" can go unobserved for days. One measurement: 8 days of uptime, 484
Modern Standby resumes, **0** logon events, and a `LastRunTime` still showing the
never-ran sentinel.

It now has `AtLogOn` **plus** a 15-minute repeating trigger. The periodic trigger
is what actually provides coverage; the logon trigger is a bonus for real reboots.
An `AtStartup` trigger would be the natural third option but registering one
requires elevation, which would break the "install needs no admin" property.

## Why session rescue exists at all

The wrapper can only resume runs it launched. But limits are hit in ordinary
interactive sessions, which never pass through it. For weeks the infrastructure
was verified healthy — reconciler firing, tasks registered, tests green — while
nothing was ever resumed, because nothing had ever *armed*. The tool was working
perfectly on an empty set.

Hence session rescue: scan the transcripts Claude Code already writes
(`~/.claude/projects/<dir>/<id>.jsonl`), find sessions a limit killed, and resume
those. Two observations fixed the behaviour:

- A TUI **left open** on an awake machine continues by itself ~3 min after the
  reset. Rescue must not fight it.
- A TUI **closed** after the limit stays dead forever. Nothing else will ever
  revive it.

## What "stranded" means — three wrong answers first

This one definition caused every remaining failure. In order:

1. **"The rate-limit line is the last line."** Wrong, because transcripts keep
   accreting bookkeeping (mode, permission-mode, title, last-prompt,
   queue-operation, file-history, attachments) long after the conversation stops,
   and merely opening the resume picker adds more. Worse, the check read a fixed
   40-line tail: measured across every transcript that had ever hit a limit, the
   stop sat 52 / 335 / 670 / 1707 lines from the end. All invisible.
2. **"Any user/assistant event after the stop means it recovered."** Wrong,
   because people talk to a limited session without resuming its work. A single
   question — *"What's this session ID?"*, asked in order to report the bug —
   cancelled a pending rescue while the interrupted work stayed unfinished.
3. **"Any event at or after the announced reset means it recovered."** Wrong for
   the same case, because that question happened to be asked 81 seconds after the
   reset.

The rule that holds: a stop is cleared **only by an assistant turn, at or after
the announced reset, that uses a tool**. An agent genuinely back at work runs
tools; a chat reply does not. It also preserves the open-TUI-wins property, since
a real auto-continue does tool work.

The scan runs backwards from the end of the file, so the verdict cannot depend on
how much noise trails the stop.

**Bias deliberately toward resuming.** A needless resume costs a forked run that
reads the transcript and replies DONE. A missed resume abandons hours of work with
no signal. These are not comparable, so ties go to resuming.

## An arming is never discarded on a single empty scan

The reconciler re-derives state every 15 minutes from files a live session may be
writing to. Treating one empty scan as proof of recovery meant a transient miss
could `Unregister-ScheduledTask` a rescue that had not fired yet — and that is
unrecoverable. An arming is now held until its own fire time has passed; only then
is "nothing stranded" conclusive.

## Why `--bg` and not `-p`

A `-p` (print/headless) run registers no session at all. It never appears in
`claude agents`, so the Claude app — and any phone — cannot show it. Remote
Control does not help: it is documented as *"start an **interactive** session with
Remote Control enabled"*, so it never applies to a headless run.

Combined with the fact that **a terminal that hit a limit can never be resumed in
place** (nothing outside a running Claude Code session can type into it), a `-p`
rescue is invisible *everywhere*. It can complete the work perfectly and be
indistinguishable from having done nothing. That is not a cosmetic problem: it led
to a session being manually resumed 11 minutes after the automatic rescue had
already finished it, duplicating the work.

`claude --resume <id> --bg …` returns immediately, registers a real background
session under a **new** id, and is visible and steerable from the app. Rescues also
write `QUOTAWAKE-RESUMED.md` into the rescued project and raise a desktop toast, so
there are three independent signals rather than none.

Consequences worth knowing:

- The dispatch exits 0 long before the agent knows whether the window reopened, so
  a re-limit cannot be read from exit text. It is detected by running the same
  stranded-session detector over the *agent's own* transcript.
- `claude logs <id>` replays raw TUI output, escape codes and all. It is for
  humans, not parsing — read the transcript instead.

## Platform gotchas that cost real debugging time

- **`claude --resume <id>` only finds sessions belonging to the current
  directory's project.** Run it elsewhere and you get "No conversation found",
  even though the transcript exists. Take the `cwd` from the transcript.
- **`ConvertFrom-Json` returns timestamps as `[datetime]` with `Kind=Utc`**, and
  PowerShell prints them as UTC. A stop displayed as "13:01" was really 15:01
  local. Normalise before comparing against a parsed reset time, or the comparison
  is silently wrong by your UTC offset.
- **`[uint32]0x80000000` throws in PowerShell** — the hex literal parses as
  `Int32`. Win32 flag constants must be written in decimal.
- **Wake timers are commonly policy-enabled on AC and disabled on battery.** On
  battery, `WakeToRun` cannot wake the machine; `StartWhenAvailable` still fires
  the rescue at the next wake. Delayed, never lost.
- **pwsh 7 lacks the WinRT toast projection** that Windows PowerShell 5.1 carries,
  so toasts shell out to 5.1 when BurntToast is not installed.

## The keep-awake watcher

A rescue is useless if the machine sleeps through the reset. `keep-awake.ps1`
holds `ES_SYSTEM_REQUIRED` only when on AC **and** either a Claude Code CLI process
is running or a resume is armed. It deliberately:

- never changes static power settings,
- never holds the **display** awake, only the system,
- never holds anything on battery, so battery behaviour stays economic.

It watches the state files as well as processes, because by design no process
exists during a wait.
