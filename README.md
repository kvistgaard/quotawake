# quotawake

**Claude Code stops when you hit a usage limit. quotawake starts it again the
moment the limit resets — while you are asleep, in a meeting, or away from the
machine.**

It works like an alarm clock. It reads the reset time out of Claude's own
message, sets an alarm, and goes away. Nothing runs in between. When the alarm
goes off, your work carries on and you get told it happened.

## What this looks like

You are working in Claude Code and it stops mid-task:

```
You've hit your session limit · resets 8pm
```

Normally that window is done for. Nothing outside a running Claude Code session
can type into it, so the work sits there until you come back and restart it
yourself — which, if the reset lands at 3am, means losing the night.

With quotawake installed, at 8pm the work continues on its own. You find out in
three places:

- a **desktop notification** when it finishes,
- a **`QUOTAWAKE-RESUMED.md`** note dropped in the project folder, saying what
  was done,
- a new session in the **Claude app, including on your phone**, which you can
  read, steer or stop.

You do not have to do anything to get this. No special command, no flag, no
particular way of starting Claude. Install it once and it looks after every
Claude Code session on the machine.

## Setup

Windows or Linux, PowerShell 7+, and the `claude` CLI on your PATH.

```powershell
.\quotawake.ps1 -Install
```

Then open a **new** shell and confirm it actually works on this machine:

```powershell
.\quotawake.ps1 -Doctor
```

`-Doctor` is not decoration. It registers a real scheduled job, checks the
system can see it, and removes it again. If that line fails, nothing will ever
fire — and that failure is otherwise completely silent, which is how this tool
spent weeks looking installed while doing nothing.

`-Install` is the only step. It:

- registers a reconciler that runs at logon and every 15 minutes,
- writes a `qw` shortcut into `$PROFILE.CurrentUserAllHosts`,
- installs the keep-awake watcher's autostart,
- **Windows only:** adds the folder to your user PATH, dropping stale entries.

`-Uninstall` reverses all of it, including the state files.

On Linux, user services and timers are torn down at logout unless lingering is
enabled. `-Install` attempts `loginctl enable-linger`, but that usually needs
polkit or root. If `-Doctor` still passes after you log out and back in, it
took.

### If you move the folder

Four things bind to an absolute path: the scheduled job, the PATH entry, the
`qw` shortcut, and the watcher's autostart stub. Moving the folder breaks all
four **silently** — no reconciler, no rescues, no watcher, and no error
anywhere. Re-running `-Install` from the new location rewrites them:

```powershell
cd <new location>
.\quotawake.ps1 -Install
```

Then end any watcher still running from the old path (`Get-Process pwsh` — it is
the one whose command line points at the old `keep-awake.ps1`) and start the new
one with the `wscript` line `-Install` prints. State files do not need moving;
their absence just means nothing is pending.

## What you get when it fires

A terminal that hit a limit **can never be resumed in place** — nothing outside
a running Claude Code session can type into it, so that window stays frozen
forever. The work is therefore continued in a *new* background session, and
reported three ways:

| Where | What you get |
|---|---|
| **The Claude app, including mobile** | The rescue is dispatched with `--bg`, which registers a real background session under a **new** id. It is listed, watchable and steerable from your phone. (A `-p` run registers nothing and is invisible everywhere — which is why a working rescue used to be indistinguishable from a broken one.) |
| **`QUOTAWAKE-RESUMED.md`** | Dropped in the rescued project's own folder: agent id, result, the run's final message, and the commands to reach it. |
| **A desktop toast** | Fired on completion. Uses BurntToast if installed, otherwise a WinRT toast shelled out to Windows PowerShell 5.1 (pwsh 7 lacks that projection); `notify-send` on Linux. |

To reach the resumed work:

```powershell
claude agents            # lists it, with state
claude attach <agentId>  # open it in this terminal
claude logs  <agentId>   # recent output (raw TUI output — for eyes, not scripts)
```

**`claude attach`, not `claude --resume`.** `--resume` refuses a session that is
still running, and only lists sessions belonging to the folder you are standing
in — so it answers `No conversation found` in exactly the situation you are most
likely to try it.

**Do not type `resume` into the frozen window.** That starts a second run which
redoes finished work; it cost a duplicated pass on 2026-07-31.

## The other way to use it: launching a task yourself

Everything above happens on its own. There is also a wrapper, for when you want
to hand over a job and walk away — it runs the task, and re-runs it itself after
each reset until the work is done.

The script is on your PATH, and the `qw` function forwards every argument, so
you can drop the `.ps1`:

```powershell
# Fire-and-forget; on a limit it arms the resume and exits:
qw -Task "revise my note per the inline comments" -PermissionMode acceptEdits -Project "C:\path\to\workspace"

# Resume the most recent conversation in the current folder:
qw -Continue

# Arm a resume for a time you saw on screen, and exit:
qw -Continue -At "3pm"
```

The automatic rescue needs none of this.

## How it survives sleep, reboots and closed windows

On a limit the script does **not** sit and wait. It records what to do,
registers a **one-shot scheduled job** for the reset time, and exits. Between
limit and reset: zero CPU, zero RAM. The operating system's scheduler does the
waiting.

That is what makes a resume survive the things that kill an in-process wait:

- **Sleep / Modern Standby** — `StartWhenAvailable` fires the job as soon as the
  machine is back; `WakeToRun` may wake it at the exact time (power policy
  permitting).
- **Reboot, logoff, closed window** — the job and the state file persist.
- **A reconciler** (`QuotaWake-Logon`, created once by `-Install`) runs at logon
  **and every 15 minutes**, re-arming anything whose one-shot job went missing
  and exiting instantly when there is nothing to do. The 15-minute trigger is
  load-bearing, not cosmetic: on a Modern Standby machine the session almost
  never truly logs off, so an AtLogOn-only trigger measured 0 firings in 8 days.

You never type a reset time in — it is read from Claude's own message
(`resets 1:30pm`). If a message has no parseable time, it re-arms for
`+PollMinutes` (default 20) instead, so it keeps going either way.

**One deliberate non-goal:** nothing here wakes a sleeping machine. That needs
wake timers on Windows (AC-only under typical laptop policy) and root on Linux.
A rescue whose moment passes while the machine is asleep runs at the next wake
instead — delayed, never lost.

## How a stranded session is found

Limits are usually hit in ordinary **interactive** sessions. Those stops are
recorded in the transcript (`~/.claude/projects/<dir>/<id>.jsonl`) as a line
with `"error":"rate_limit"` carrying the reset time. Every reconcile pass scans
transcripts touched in the last 48 h and resumes the ones nothing else will.

**What counts as stranded.** A stop is considered *cleared* only by an assistant
turn, at or after the announced reset, **that uses a tool**. Anything weaker has
proved wrong in practice: people talk to a limited session without resuming its
work, and a chat reply — even one sent after the reset — is not the agent going
back to what it was doing. An agent genuinely back at work runs tools. That also
preserves the property that an open window's own auto-continue (~3 min after the
reset) still wins over a rescue.

**A session that is still running is never touched.** A limit line records that
a session *hit* a limit, not that it stopped. Live sessions — your open
terminal, a running background agent, anything blocked on a permission prompt —
are skipped, because `--resume --bg` forks a session rather than continuing it.
Without this rule the tool resumed a live window, then resumed its own rescue,
and chained one agent per pass.

**What it does.** It arms `QuotaWake-FireSessions` for reset + 5 min, writes
`pending-sessions.json` (which makes the keep-awake watcher hold the machine
awake on AC), re-checks each session immediately before firing, then dispatches:

```
claude --resume <sessionId> --bg --permission-mode acceptEdits "…continue the pending work…"
```

Details that matter:

- The reset is parsed **anchored to the limit's own timestamp**, so a scan
  running after the reset resumes immediately instead of arming for tomorrow.
- Each handled `(sessionId, limit-time)` pair is recorded in
  `resumed-sessions.json` and never fired twice.
- An **unreachable project folder** (an unmounted Google Drive, say) is
  *deferred and retried*, never written off, capped at 8 attempts.
- An arming is **never** discarded because one scan came back empty; it is held
  until its own fire time has passed.

> **The `*.json` files are transient.** `pending-resume.json` and
> `pending-sessions.json` exist **only while something is actually waiting for a
> reset**, and are deleted the moment it completes. Not seeing them is the
> normal, healthy state — it means nothing is pending, not that anything is
> broken.

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
| `-Install` / `-Uninstall` | — | Create / remove the reconciler job and state. |
| `-Doctor` | — | Prove the platform integration on this machine. |
| `-Resume` / `-Reconcile` | — | Entry points for the scheduled jobs; not for manual use. |

Session-rescue constants are set at the top of the script: 48 h scan window,
5 min buffer, 8 attempts, 4 min wait for a dispatched agent before writing the
notice anyway.

## Files and jobs

| Piece | What it is |
|---|---|
| `quotawake.ps1` | All the logic. |
| `keep-awake.ps1` | Companion watcher: holds the system awake **on AC only** while a Claude CLI session is running or a resume is armed. Never touches static power settings; never blocks display sleep. |
| `run-hidden.vbs` | Launches the script hidden so jobs never flash a console. |
| `pending-resume.json` | *Transient.* Exists only while a wrapper resume is pending. |
| `pending-sessions.json` | *Transient.* Exists only while stranded sessions await their reset. Also read by the keep-awake watcher. |
| `resumed-sessions.json` | Persistent ledger of handled `(sessionId, limit-time)` pairs, so no stop is resumed twice. Capped. |
| `.session-rescue.lock` | Lock file preventing the 15-min pass and the one-shot job from double-resuming. Empty; safe to leave. |
| `QUOTAWAKE-RESUMED.md` | Written into the **rescued project's** folder, not here. Appended, so rescues stack in reading order. |
| `QuotaWake-Logon` | The permanent reconciler: logon + every 15 min, hidden, near-zero cost. |
| `QuotaWake-Fire` | One-shot job for a wrapper resume; exists only while one is pending. |
| `QuotaWake-FireSessions` | One-shot job for session rescue at reset + 5 min. |
| `quotawake.log` | Every decision the rescue makes, with reasons. First place to look. |

## Limitations

- **It cannot take over a live terminal.** It continues the conversation in a new
  background session; the original window stays frozen. See *What you get when
  it fires*.
- **Edits need permission.** Rescue uses `acceptEdits`, so a rescued run edits
  files with nobody to approve it. Review what it wrote.
- **Timezone.** The announced reset is treated as the machine's *local* time —
  correct while your clock matches the zone Claude announces.
- **One pending wrapper resume at a time.** The state file and one-shot job are
  singletons; arming a new resume replaces the previous one. (Session rescue
  handles many sessions per batch.)
- **A sleeping machine delays a resume, never loses it.** Windows needs wake
  timers (policy-enabled on AC, disabled on battery on most laptops —
  deliberately, to keep battery economic) and Linux needs root. The resume fires
  the moment the machine is next awake, or at the following reconcile pass.
- **Your own open terminal is left alone.** It continues by itself after a
  reset; that is Claude Code's behaviour, not this tool's.
- **macOS is not supported.** See *Platform internals*.

## Exit codes

`0` done · `2` bad `-At` · `4` hit MaxRounds · `5` limit hit, resume armed ·
otherwise Claude's own non-zero exit code.

## Platform internals

Everything OS-specific sits behind one narrow contract — register a job, remove
it, ask whether it exists — with two backends:

| | Windows | Linux |
|---|---|---|
| Scheduling | Task Scheduler | `systemd --user` timers |
| Fires after sleep/off | `StartWhenAvailable` | `Persistent=true` |
| Notification | WinRT toast / BurntToast | `notify-send` |
| Keep-awake | `SetThreadExecutionState` | `systemd-inhibit` |
| AC detection | WinForms `PowerStatus` | `/sys/class/power_supply` |
| Autostart | Startup-folder shim | user service (`Restart=always`) |

**Verification status — read this before trusting it.**

- **Windows** is fully exercised: unit tests plus repeated live rescues.
- **Linux** unit generation is verified against real `systemd-analyze` (v245):
  the `.timer` and `.service` files are accepted with no complaints, and the
  `OnCalendar` value normalises to the intended instant. The `systemctl` calls
  themselves are not exercised here.
- **macOS is not supported.** A launchd backend was written and then removed,
  because there was no Mac to run it on. Every earlier failure in this project
  looked like a success from the outside, so an untested scheduler backend —
  which fails by registering nothing, silently — was not worth shipping.
  quotawake refuses to run on macOS by name rather than half-working. The
  implementation is in git if a Mac turns up: `git show ac11ea2 -- quotawake.ps1`.

## Tests

```powershell
pwsh -File quotawake.Tests.ps1
```

102 assertions against a mocked `claude` and mocked job registration — no real
runs, no job registered, no quota spent. Covers limit detection, reset-time
parsing (including anchored parsing), `-At` parsing, state round-trips, the full
round logic, stranded-session detection (including the regressions that once made
rescue fail silently, and the live-session rule that stopped it forking running
sessions), the arming/holding/firing cycle, the notice and toast, the systemd
generators, and the refusal to run on an unsupported OS.

The OS-specific backend is written as a **pure generator** returning unit text,
so the part most likely to be wrong is testable from any machine. The generated
systemd units are additionally validated by a real `systemd-analyze verify`.
What unit tests cannot reach — the actual `systemctl` calls — is what `-Doctor`
exists to check on the target machine.

## Why it works the way it does

Most of the design looks arbitrary until you know which failure produced it —
**[DESIGN-NOTES.md](DESIGN-NOTES.md)** records the reasoning and the gotchas
(including several Claude Code and PowerShell behaviours that cost real debugging
time). Read it before changing detection or dispatch.
