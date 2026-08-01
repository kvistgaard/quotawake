# claude-resume

Auto-resumes **Claude Code** work across usage-limit resets. Claude Code has no
event that fires on "usage limit reached" and no built-in resume when the window
reopens — this fills that gap, on Windows, with no resident process.

Two independent things live here:

- **The wrapper** — you launch a task through it (`crun`), and it re-runs that
  task itself after each reset.
- **Session rescue** — it watches *every* Claude Code session on the machine,
  including ordinary interactive ones you never launched through the wrapper,
  and resumes any that a limit killed. This is the part that matters day to day.

> **The `*.json` files below are transient.** `pending-resume.json` and
> `pending-sessions.json` exist **only while something is actually waiting for a
> reset**, and are deleted the moment it completes. Not seeing them is the normal,
> healthy state — it means nothing is pending, not that anything is broken.

## Timing: why nothing stays running

On a limit the script does **not** sit and wait. It records what to do, registers
a **one-shot Windows Scheduled Task** for the reset time, and exits. Between limit
and reset: zero CPU, zero RAM. Task Scheduler does the waiting.

That is what makes a resume survive the things that killed an in-process wait:

- **Sleep / Modern Standby** — `StartWhenAvailable` fires the task as soon as the
  machine is back; `WakeToRun` may wake it at the exact time (power policy
  permitting).
- **Reboot, logoff, closed window** — the task and the state file persist.
- **A reconciler** (`ClaudeResume-Logon`, created once by `-Install`) runs at logon
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

**What it does.** It arms `ClaudeResume-FireSessions` for reset + 5 min, writes
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
| **`CLAUDE-RESUMED.md`** | Dropped in the rescued project's own folder: agent id, result, the run's final message, and the `attach` / `logs` commands. |
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
.\claude-resume.ps1 -Install
```

That binds the tool to wherever the script currently sits, and is the only step:

- registers the `ClaudeResume-Logon` scheduled task (logon + every 15 min, hidden),
- adds the folder to your **user PATH**, dropping any stale `claude-resume` entry,
- writes the `crun` shortcut into `$PROFILE.CurrentUserAllHosts`,
- writes the keep-awake watcher's autostart stub into your Startup folder.

Open a **new** shell afterwards for PATH and `crun` to take effect, and start the
watcher without waiting for a logon:

```powershell
wscript "$([Environment]::GetFolderPath('Startup'))\keep-awake-claude.vbs"
```

`-Uninstall` reverses all four, plus the state files.

### Moving the folder (or cloning it somewhere new)

Four things bind to an absolute path: the scheduled task, the PATH entry, the
`crun` shortcut, and the watcher's autostart stub. Moving the folder breaks every
one of them **silently** — no reconciler, no rescues, no watcher, and no error
anywhere. Re-running `-Install` from the new location rewrites all four, so:

```powershell
cd <new location>
.\claude-resume.ps1 -Install
```

Then end any watcher still running from the old path (`Get-Process pwsh` — it is
the one whose command line points at the old `keep-awake-claude.ps1`) and start
the new one with the `wscript` line above. State files do not need moving: their
absence just means nothing is pending.

## Usage

The script is on your **User PATH**, and a `crun` function in
`$PROFILE.CurrentUserAllHosts` forwards every argument so you can drop the `.ps1`:

```powershell
# Fire-and-forget; on a limit it arms the resume and exits:
crun -Task "revise my note per the inline comments" -PermissionMode acceptEdits -Project "C:\path\to\workspace"

# Resume the most recent conversation in the current folder:
crun -Continue

# Arm a resume for a time you saw on screen, and exit:
crun -Continue -At "3pm"
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
| `claude-resume.ps1` | The wrapper — all logic. |
| `keep-awake-claude.ps1` | Companion watcher: holds the system awake **on AC only** while a Claude CLI session is running or a resume is armed. Never touches static power settings; never blocks display sleep. |
| `run-hidden.vbs` | Launches the script hidden so tasks never flash a console. |
| `pending-resume.json` | *Transient.* Exists only while a wrapper resume is pending. |
| `pending-sessions.json` | *Transient.* Exists only while stranded sessions await their reset. Also read by the keep-awake watcher. |
| `resumed-sessions.json` | Persistent ledger of handled `(sessionId, limit-time)` pairs, so no stop is resumed twice. Capped. |
| `.session-rescue.lock` | Lock file preventing the 15-min pass and the one-shot task from double-resuming. Empty; safe to leave. |
| `CLAUDE-RESUMED.md` | Written into the **rescued project's** folder, not here. Appended, so rescues stack in reading order. |
| `ClaudeResume-Logon` | The permanent reconciler: logon + every 15 min, hidden, near-zero cost. |
| `ClaudeResume-Fire` | One-shot task for a wrapper resume; exists only while one is pending. |
| `ClaudeResume-FireSessions` | One-shot task for session rescue at reset + 5 min. |
| `claude-resume.log` | Every decision the rescue makes, with reasons. First place to look. |

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
- **On battery, a resume is delayed, never lost.** Wake timers are policy-enabled
  on AC and disabled on battery here — deliberately, to keep battery economic. So
  on battery `WakeToRun` cannot wake the machine; the resume fires the moment you
  next wake it, or at the next reconcile pass.

## Exit codes

`0` done · `2` bad `-At` · `4` hit MaxRounds · `5` limit hit, resume armed ·
otherwise Claude's own non-zero exit code.

## Tests

```powershell
pwsh -File claude-resume.Tests.ps1
```

79 assertions against a mocked `claude` and mocked task registration — no real
runs, no task registered, no quota spent. Covers limit detection, reset-time
parsing (including anchored parsing), `-At` parsing, state round-trips, the full
round logic, stranded-session detection (including the regressions that once made
rescue fail silently), the arming/holding/firing cycle, and the notice and toast.

## Why it works the way it does

Most of the design looks arbitrary until you know which failure produced it —
**[DESIGN-NOTES.md](DESIGN-NOTES.md)** records the reasoning and the gotchas
(including several Claude Code and PowerShell behaviours that cost real debugging
time). Read it before changing detection or dispatch.
