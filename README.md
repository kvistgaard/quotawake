# quotawake

Auto-resumes **Claude Code** work across usage-limit resets. Claude Code has no
event that fires on "usage limit reached" and no built-in resume when the window
reopens — this fills that gap on **Windows, macOS and Linux**, with no resident
process.

Two independent things live here:

- **The wrapper** — you launch a task through it (`qw`), and it re-runs that
  task itself after each reset.
- **Session rescue** — it watches *every* Claude Code session on the machine,
  including ordinary interactive ones you never launched through the wrapper,
  and resumes any that a limit killed. This is the part that matters day to day.

> **The `*.json` files below are transient.** `pending-resume.json` and
> `pending-sessions.json` exist **only while something is actually waiting for a
> reset**, and are deleted the moment it completes. Not seeing them is the normal,
> healthy state — it means nothing is pending, not that anything is broken.

## Platforms

Everything OS-specific sits behind one narrow contract — register a job, remove
it, ask whether it exists — with three backends:

| | Windows | macOS | Linux |
|---|---|---|---|
| Scheduling | Task Scheduler | launchd (`~/Library/LaunchAgents`) | `systemd --user` timers |
| Fires after sleep/off | `StartWhenAvailable` | launchd catch-up on wake | `Persistent=true` |
| Notification | WinRT toast / BurntToast | `osascript` | `notify-send` |
| Keep-awake | `SetThreadExecutionState` | `caffeinate -s` | `systemd-inhibit` |
| AC detection | WinForms `PowerStatus` | `pmset -g batt` | `/sys/class/power_supply` |
| Autostart | Startup-folder shim | LaunchAgent (`KeepAlive`) | user service (`Restart=always`) |

**Verification status — read this before trusting it.**

- **Windows** is fully exercised: unit tests plus repeated live rescues.
- **Linux** unit generation is verified against real `systemd-analyze` (v245):
  the `.timer` and `.service` files are accepted with no complaints, and the
  `OnCalendar` value normalises to the intended instant. The `systemctl` calls
  themselves are not exercised here.
- **macOS is unverified.** It was written against launchd's documented
  behaviour and its plist generation is unit-tested (well-formed XML, correct
  label, calendar fields, `RunAtLoad`), but no Mac was available to run it.

Because of that, every platform ships with a self-check that proves the
integration where it actually runs, including a real register/unregister
round-trip against the live scheduler:

```powershell
./quotawake.ps1 -Doctor
```

Run it first on any new machine. If the scheduler line fails, nothing will ever
fire — and that failure is otherwise silent.

**One deliberate non-goal:** nothing here wakes a sleeping machine. That needs
wake timers on Windows (AC-only under typical laptop policy) and root on
macOS/Linux. A rescue whose moment passes while the machine is asleep runs at
the next wake instead — delayed, never lost.

## Timing: why nothing stays running

On a limit the script does **not** sit and wait. It records what to do, registers
a **one-shot Windows Scheduled Task** for the reset time, and exits. Between limit
and reset: zero CPU, zero RAM. Task Scheduler does the waiting.

That is what makes a resume survive the things that killed an in-process wait:

- **Sleep / Modern Standby** — `StartWhenAvailable` fires the task as soon as the
  machine is back; `WakeToRun` may wake it at the exact time (power policy
  permitting).
- **Reboot, logoff, closed window** — the task and the state file persist.
- **A reconciler** (`QuotaWake-Logon`, created once by `-Install`) runs at logon
  **and every 15 minutes**, re-arming anything whose one-shot task went missing and
  exiting instantly when there is nothing to do. The 15-minute trigger is
  load-bearing, not cosmetic: on a Modern Standby machine the session almost never
  truly logs off, so an AtLogOn-only trigger measured 0 firings in 8 days.

You never type a reset time in — it is read from Claude's own message
(`resets 1:30pm`). If a message has no parseable time, it re-arms for
`+PollMinutes` (default 20) instead, so it keeps going either way.

## Session rescue

Limits are usually hit in ordinary **interactive** sessions that never touch the
wrapper. Those stops are still recorded in the transcript
(`~/.claude/projects/<dir>/<id>.jsonl`) as a line with `"error":"rate_limit"`
carrying the reset time. Every reconcile pass scans transcripts touched in the
last 48 h and resumes the ones nothing else will.

**What counts as stranded.** A stop is considered *cleared* only by an assistant
turn, at or after the announced reset, **that uses a tool**. Anything weaker has
proved wrong in practice: people talk to a limited session without resuming its
work, and a chat reply — even one sent after the reset — is not the agent going
back to what it was doing. An agent genuinely back at work runs tools; that also
preserves the property that an open TUI's own auto-continue (~3 min after the
reset) still wins over a rescue.

**What it does.** It arms `QuotaWake-FireSessions` for reset + 5 min, writes
`pending-sessions.json` (which makes the keep-awake watcher hold the machine awake
on AC), re-checks each session immediately before firing, then dispatches:

```
claude --resume <sessionId> --bg --permission-mode acceptEdits "…continue the pending work…"
```

`--bg`, not `-p`, and that difference is the whole point — see below.

Details that matter:

- The reset is parsed **anchored to the limit's own timestamp**, so a scan running
  after the reset resumes immediately instead of arming for tomorrow.
- Each handled `(sessionId, limit-time)` pair is recorded in
  `resumed-sessions.json` and never fired twice.
- If the dispatched agent hits a **new** limit, its own transcript strands and the
  next pass arms it under its own reset — the chain continues by itself.
- An **unreachable project folder** (an unmounted Google Drive, say) is *deferred
  and retried*, never written off, capped at 8 attempts.
- An arming is **never** discarded because one scan came back empty; it is held
  until its own fire time has passed.

## Where you see what it did

A terminal that hit a limit **can never be resumed in place** — nothing outside a
running Claude Code session can type into it, so that window stays frozen forever.
The rescue therefore reports itself three ways:

| Where | What you get |
|---|---|
| **The Claude app, including mobile** | `--bg` registers a real background session (under a **new** id), so the rescue is listed, watchable and steerable from your phone. A `-p` run registers nothing and is invisible everywhere — which is why a working rescue used to be indistinguishable from a broken one. |
| **`QUOTAWAKE-RESUMED.md`** | Dropped in the rescued project's own folder: agent id, result, the run's final message, and the `attach` / `logs` commands. |
| **A desktop toast** | Fired on completion. Uses BurntToast if installed, otherwise a WinRT toast shelled out to Windows PowerShell 5.1 (pwsh 7 lacks that projection). |

```powershell
claude agents            # lists it, with state
claude attach <agentId>  # open it in this terminal
claude logs  <agentId>   # recent output (raw TUI output — for eyes, not scripts)
```

**Do not type `resume` into the frozen window.** That starts a second run which
redoes finished work; it cost a duplicated pass on 2026-07-31.

## Setup (once)

```powershell
.\quotawake.ps1 -Install
```

That binds the tool to wherever the script currently sits, and is the only step:

- registers the 15-minute reconciler with the platform's scheduler,
- writes the `qw` shortcut into `$PROFILE.CurrentUserAllHosts`,
- installs the keep-awake watcher's autostart,
- **Windows only:** adds the folder to your user PATH, dropping stale entries.

Open a **new** shell afterwards for `qw` to take effect, then confirm the
integration actually works on this machine:

```powershell
./quotawake.ps1 -Doctor
```

`-Uninstall` reverses all of it, plus the state files.

On Linux, user services and timers are torn down at logout unless lingering is
enabled; `-Install` attempts `loginctl enable-linger` but that usually needs
polkit or root. If `-Doctor` still passes after you log out and back in, it took.

### Moving the folder (or cloning it somewhere new)

Four things bind to an absolute path: the scheduled task, the PATH entry, the
`qw` shortcut, and the watcher's autostart stub. Moving the folder breaks every
one of them **silently** — no reconciler, no rescues, no watcher, and no error
anywhere. Re-running `-Install` from the new location rewrites all four, so:

```powershell
cd <new location>
.\quotawake.ps1 -Install
```

Then end any watcher still running from the old path (`Get-Process pwsh` — it is
the one whose command line points at the old `keep-awake.ps1`) and start
the new one with the `wscript` line above. State files do not need moving: their
absence just means nothing is pending.

## Usage

The script is on your **User PATH**, and a `qw` function in
`$PROFILE.CurrentUserAllHosts` forwards every argument so you can drop the `.ps1`:

```powershell
# Fire-and-forget; on a limit it arms the resume and exits:
qw -Task "revise my note per the inline comments" -PermissionMode acceptEdits -Project "C:\path\to\workspace"

# Resume the most recent conversation in the current folder:
qw -Continue

# Arm a resume for a time you saw on screen, and exit:
qw -Continue -At "3pm"
```

Session rescue needs none of this — it runs on its own once `-Install` is done.

## Parameters

| Param | Default | Meaning |
|---|---|---|
| `-Task` | "continue and finish the pending work" | Prompt handed to `claude -p`. |
| `-Continue` | off | Resume the most recent conversation instead of starting fresh. |
| `-Project` | current dir | Folder Claude runs in — its `CLAUDE.md` / `.claude` settings apply, and the log is written there. |
| `-PermissionMode` | "" (prompts) | Pass `acceptEdits` for unattended edits. Without it, headless Claude cannot approve its own edits and will change nothing. |
| `-At` | — | Arm the resume for this time and exit (`"3pm"`, `"15:00"`, a full datetime). Normally unneeded. |
| `-MaxRounds` | 12 | Max chained runs across all resumes. |
| `-BufferSeconds` | 150 | Seconds past the announced reset before firing (wrapper runs). |
| `-PollMinutes` | 20 | Refire interval when a limit has no parseable reset time. |
| `-Install` / `-Uninstall` | — | Create / remove the reconciler task and state. |
| `-Resume` / `-Reconcile` | — | Entry points for the scheduled tasks; not for manual use. |

Session-rescue constants are set at the top of the script: 48 h scan window,
5 min buffer, 8 attempts, 4 min wait for a dispatched agent before writing the
notice anyway.

## Files and tasks

| Piece | What it is |
|---|---|
| `quotawake.ps1` | The wrapper — all logic. |
| `keep-awake.ps1` | Companion watcher: holds the system awake **on AC only** while a Claude CLI session is running or a resume is armed. Never touches static power settings; never blocks display sleep. |
| `run-hidden.vbs` | Launches the script hidden so tasks never flash a console. |
| `pending-resume.json` | *Transient.* Exists only while a wrapper resume is pending. |
| `pending-sessions.json` | *Transient.* Exists only while stranded sessions await their reset. Also read by the keep-awake watcher. |
| `resumed-sessions.json` | Persistent ledger of handled `(sessionId, limit-time)` pairs, so no stop is resumed twice. Capped. |
| `.session-rescue.lock` | Lock file preventing the 15-min pass and the one-shot task from double-resuming. Empty; safe to leave. |
| `QUOTAWAKE-RESUMED.md` | Written into the **rescued project's** folder, not here. Appended, so rescues stack in reading order. |
| `QuotaWake-Logon` | The permanent reconciler: logon + every 15 min, hidden, near-zero cost. |
| `QuotaWake-Fire` | One-shot task for a wrapper resume; exists only while one is pending. |
| `QuotaWake-FireSessions` | One-shot task for session rescue at reset + 5 min. |
| `quotawake.log` | Every decision the rescue makes, with reasons. First place to look. |

## Limitations

- **It cannot take over a live terminal.** It forks the conversation into a new
  background session; the original window stays frozen. See *Where you see what
  it did*.
- **Edits need permission.** Rescue uses `acceptEdits`, so a rescued run edits
  files with nobody to approve it. Review what it wrote.
- **Timezone.** The announced reset is treated as the machine's *local* time —
  correct while your clock matches the zone Claude announces.
- **One pending wrapper resume at a time.** The state file and one-shot task are
  singletons; arming a new resume replaces the previous one. (Session rescue
  handles many sessions per batch.)
- **A sleeping machine delays a resume, never loses it.** Nothing here wakes a
  sleeping machine: Windows needs wake timers (policy-enabled on AC, disabled on
  battery on most laptops — deliberately, to keep battery economic) and
  macOS/Linux need root. The resume fires the moment the machine is next awake,
  or at the following reconcile pass.
- **macOS is untested.** Written to launchd's documented behaviour with its
  plist generation unit-tested, but never run on a Mac. Run `-Doctor` first.

## Exit codes

`0` done · `2` bad `-At` · `4` hit MaxRounds · `5` limit hit, resume armed ·
otherwise Claude's own non-zero exit code.

## Tests

```powershell
pwsh -File quotawake.Tests.ps1
```

100 assertions against a mocked `claude` and mocked task registration — no real
runs, no task registered, no quota spent. Covers limit detection, reset-time
parsing (including anchored parsing), `-At` parsing, state round-trips, the full
round logic, stranded-session detection (including the regressions that once made
rescue fail silently), the arming/holding/firing cycle, the notice and toast, and
the launchd/systemd generators.

The OS-specific backends are written as **pure generators** returning plist and
unit text, so the part most likely to be wrong is testable from any machine. The
generated systemd units are additionally validated by a real `systemd-analyze
verify`. What unit tests cannot reach — the actual `launchctl` and `systemctl`
calls — is what `-Doctor` exists to check on the target machine.

## Why it works the way it does

Most of the design looks arbitrary until you know which failure produced it —
**[DESIGN-NOTES.md](DESIGN-NOTES.md)** records the reasoning and the gotchas
(including several Claude Code and PowerShell behaviours that cost real debugging
time). Read it before changing detection or dispatch.
