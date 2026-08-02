# quotawake

**Claude Code stops when you hit a usage limit. quotawake starts the work again
the moment the limit resets — while you are asleep, in a meeting, or away from
the machine.**

Windows today; a native Linux port is planned.

It works like an alarm clock. It reads the reset time out of Claude's own
message, sets an alarm, and exits.

**Between the limit and the reset there is no process at all — no CPU, no
memory, nothing polling in the background.** The operating system's own
scheduler does the waiting, which is also why a resume survives sleep, a
reboot, or closing the window it started in.

---

## The whole thing in one page

1. You are working in Claude Code. Your session stops:
   `You've hit your session limit · resets 8pm`
2. You do nothing. Close the window if you like — it is finished either way.
3. At 8pm your session resumes, **in a new session window**, not the old one.
4. You get a desktop notification, a note in the project folder, and the resumed
   session appears in the Claude app.
5. To go back into it, run **`claude agents`** and pick the one named after your
   project (`my-project — resumed 20:04`), or run **`qw -List`** to see just
   what quotawake restarted.
6. You are in the conversation with its full history. Read what it did, then
   keep typing. It is an ordinary session from here on.

The rest of this page explains each step, and then the internals.

---

## Install

**Windows**, PowerShell 7+, and the `claude` CLI on your PATH.

> **Linux is not usable yet.** The scheduling backend for `systemd --user` is
> written and validated, but the tool itself is a PowerShell script, so today it
> would require every Linux user to install PowerShell first — which is not a
> reasonable thing to ask. A native Linux port is planned; until it lands, treat
> this as Windows-only. See *Platform internals*.

```powershell
.\quotawake.ps1 -Install
```

Open a **new** shell, then check it actually works on this machine:

```powershell
.\quotawake.ps1 -Doctor
```

`-Doctor` is not decoration. It registers a real scheduled job, checks the
system can see it, and removes it again. If that line fails, nothing will ever
fire — and that failure is otherwise completely silent, which is how this tool
once spent weeks looking installed while doing nothing.

That is the whole setup. There is no flag to remember and no special way to
start Claude; from now on every Claude Code session on the machine is covered.

<details>
<summary>What <code>-Install</code> changes</summary>

- registers a reconciler that runs at logon and every 15 minutes,
- writes a `qw` shortcut into your PowerShell profile,
- installs the keep-awake watcher's autostart,
- adds the folder to your user PATH, dropping stale entries.

`-Uninstall` reverses all of it, including the state files.
</details>

---

# The workflow

## Step 1 — You hit a limit

```
You've hit your session limit · resets 8pm
```

**Do nothing.** You can close the terminal, shut the laptop, or walk away.

That window is already finished. Nothing outside a running Claude Code session
can type into it, so it will sit there frozen no matter what you or quotawake
do. This is the single fact the rest of the design follows from.

## Step 2 — The wait

Nothing runs. quotawake wrote down what to do, set an alarm with your operating
system, and exited.

The machine may sleep. If it is asleep at 8pm, the work starts at the next wake
instead — delayed, never lost.

## Step 3 — The reset

At 8pm your session resumes. Because the old window cannot be revived, the
conversation is reopened in a **new session** — same history, same project,
carrying on from where it stopped.

So there are now two sessions: the one that stopped, and the one that resumed
it. They have different ids. That is the only genuinely confusing part of this,
and *About session ids* below deals with it.

The resumed session runs in the background, which is what makes it show up in
the Claude app and on your phone instead of running where nobody can see it.

## Step 4 — You find out

Three places, so you cannot miss it:

| Where | What you get |
|---|---|
| **Desktop notification** | Fires when the resumed session finishes. |
| **`QUOTAWAKE-RESUMED.md`** | Written into the project's own folder. Says what was done, and gives the id of both sessions. Appended, so repeated resumes stack in reading order. |
| **The Claude app, including mobile** | The resumed session appears in your session list — readable and steerable from your phone. |

## Step 5 — Go back into the resumed session

**This is the step you actually care about.** Run:

```powershell
claude agents
```

That lists your sessions. Each resumed one is named after its project and the
time it restarted, so you can recognise yours on sight:

```
my-project — resumed 20:04
another-project — resumed 03:15
```

Pick yours, press Enter, and you are in it — full history, exactly as if you had
been there all along.

**Read what it did while you were away, then carry on typing.** There is nothing
else to learn: from here it is an ordinary Claude Code session.

`Ctrl+Z` puts you back in your shell, and the session keeps running.

### Or see just what quotawake resumed

`claude agents` shows every session on the machine. To see only the ones
quotawake restarted, and whether they are still going:

```powershell
qw -List
```

> Parameter names ignore case, so `qw -list` is the same thing.

```
  Resumed at        Project                 Session     State
  ----------------  ----------------------  ----------  ----------
  2026-08-02 20:04  my-project              7f3ab210    running
  2026-08-02 03:15  another-project         a1b2c3d4    done

  Go back into one:   claude attach <session>
  Or pick from a list: claude agents
```

That `Session` column is the id, and it is all you need:

```powershell
claude attach 7f3ab210
```

`attach` is just Claude Code's word for "open this session in my terminal" — you
never have to type it if you use the list.

```powershell
claude logs 7f3ab210   # see its recent output without opening it
claude stop 7f3ab210   # stop it early; the conversation is kept
```

> **Do not type `resume` into the old frozen window.** It cannot see any of
> this, so that starts a *second* run which redoes work that is already done.
> That cost a duplicated pass on 2026-07-31.

## Step 6 — If you want the session that stopped, instead

Sometimes you want the original conversation as it was, rather than the resumed
one. Two things must both be true or it will not open:

```powershell
cd C:\path\to\the\project          # 1. stand in the project's own folder
claude --resume 1a2b3c4d-0000-0000-0000-000000000000
```

1. **You must be in the project folder.** `--resume` only lists conversations
   belonging to the directory you are standing in.
2. **Nothing else can have it open.** `--resume` skips any session something is
   already using — including the resumed session from step 5, and including a
   terminal you left open.

Its id is in `QUOTAWAKE-RESUMED.md`, on the row labelled **Session that
stopped**.

---

## About session ids

Only one kind of id exists here, and this is the whole of it.

**Every Claude Code session has an id** — a long one:

```
7f3ab210-0000-0000-0000-000000000000
```

Claude Code usually shows you just the **first 8 characters**:

```
7f3ab210
```

Same id, written short. Anywhere a command asks for one, either form works.

**The session that resumed has a different id from the session that stopped.**
That is unavoidable: the old window cannot be revived, so the conversation is
reopened in a new session, and a new session gets a new id.
`QUOTAWAKE-RESUMED.md` gives you both, labelled:

| Row in the note | Which one | How to open it |
|---|---|---|
| **Session that stopped** | the one you were working in | step 6 |
| **Resumed session** | the one carrying on the work | step 5 |

### Why `claude --resume` says "No conversation found"

Almost always one of two things, and the message is the same unhelpful line
either way:

- **The session is already in use.** `--resume` only picks up conversations
  nobody has open. For the resumed session, use `claude agents` (step 5).
- **You are in the wrong folder.** `--resume` only sees the current directory's
  conversations. `cd` to the project first.

**Rule of thumb:** to get back into the session that resumed, use
`claude agents`. To reopen an older conversation nobody is using, `cd` to its
project and use `claude --resume`.

---

## The other way to use it: hand over a job and walk away

Everything above happens on its own. There is also a wrapper for when you want
to give Claude a task and leave — it runs the task and re-runs it itself after
each reset until the work is finished.

```powershell
# Fire-and-forget; on a limit it arms the resume and exits:
qw -Task "revise my note per the inline comments" -PermissionMode acceptEdits -Project "C:\path\to\workspace"

# Resume the most recent conversation in the current folder:
qw -Continue

# Arm a resume for a time you saw on screen, and exit:
qw -Continue -At "3pm"
```

The automatic resume needs none of this.

## Running the commands

`-Install` puts the folder on your PATH and writes a `qw` shortcut into your
PowerShell profile, so from any directory:

```powershell
qw -List
qw -Doctor
```

**Capitalisation does not matter.** Parameter names are conventionally written
`-List`, `-Install`, `-Doctor`, but PowerShell ignores case — `qw -list` and
`qw -LIST` do the same thing.

---

# How it works

## Why nothing stays running

On a limit the script records what to do, registers a **one-shot scheduled job**
for the reset time, and exits. Nothing of it remains in memory.

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

## How a stopped session is found

Limits are usually hit in ordinary sessions you started yourself. Claude Code
records the stop in the session's own transcript
(`~/.claude/projects/<dir>/<id>.jsonl`) as a line with `"error":"rate_limit"`
carrying the reset time. Every reconcile pass reads transcripts touched in the
last 48 h and resumes the sessions nothing else will.

**When a stop counts as already dealt with.** Only a reply from Claude, at or
after the announced reset, **that uses a tool**. Anything weaker has proved
wrong in practice: people talk to a stopped session without restarting its work,
and a chat reply — even one sent after the reset — is not Claude going back to
what it was doing. Claude genuinely back at work uses tools. This also means an
open window that revives itself (~3 min after the reset) wins over a resume.

**A session that is still running is never touched.** A limit line records that
a session *hit* a limit, not that it stopped. Sessions still in use — your open
terminal, one already running in the background, one waiting on a permission
prompt — are skipped, because resuming a live session copies it rather than
continuing it. Without this rule the tool resumed a live window, then resumed
its own resume, and made a new session every pass.

**What it does.** It arms `QuotaWake-FireSessions` for reset + 5 min, writes
`pending-sessions.json` (which makes the keep-awake watcher hold the machine
awake on AC), re-checks each session immediately before firing, then runs:

```
claude --resume <sessionId> --bg --permission-mode acceptEdits "…continue the pending work…"
```

`--bg` is what makes the resumed session visible in `claude agents` and in the
Claude app. The `-p` flag used previously registered no session at all, so a
working resume was invisible everywhere — indistinguishable from a broken one.

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

---

# Reference

## If it did not work

| Symptom | Look at |
|---|---|
| Nothing ever fires | `.\quotawake.ps1 -Doctor` — especially the scheduler line. |
| Want to know what it decided and why | `quotawake.log` — every decision, with reasons. |
| `No conversation found` | *Understanding the ids* above. |
| It fired but you cannot find the session | `qw -List` — project, id and state in one table. |
| Which of these ids is mine? | `qw -List`, or look for your project's name in `claude agents`. |
| You moved the folder | Re-run `-Install` from the new location; see below. |

### If you move the folder

Four things bind to an absolute path: the scheduled job, the PATH entry, the
`qw` shortcut, and the watcher's autostart stub. Moving the folder breaks all
four **silently**. Re-running `-Install` from the new location rewrites them:

```powershell
cd <new location>
.\quotawake.ps1 -Install
```

Then end any watcher still running from the old path (`Get-Process pwsh` — it is
the one whose command line points at the old `keep-awake.ps1`) and start the new
one with the `wscript` line `-Install` prints. State files do not need moving;
their absence just means nothing is pending.

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
| `-List` | — | Show what has been resumed: project, session id, and whether it is still running. |
| `-Doctor` | — | Prove the platform integration on this machine. |
| `-Resume` / `-Reconcile` | — | Entry points for the scheduled jobs; not for manual use. |

Session-rescue constants are set at the top of the script: 48 h scan window,
5 min buffer, 8 attempts, 4 min wait for the resumed session to report back
before writing the note anyway.

## Files and jobs

| Piece | What it is |
|---|---|
| `quotawake.ps1` | All the logic. |
| `keep-awake.ps1` | Companion watcher: holds the system awake **on AC only** while a Claude CLI session is running or a resume is armed. Never touches static power settings; never blocks display sleep. |
| `run-hidden.vbs` | Launches the script hidden so jobs never flash a console. |
| `pending-resume.json` | *Transient.* Exists only while a wrapper resume is pending. |
| `pending-sessions.json` | *Transient.* Exists only while stopped sessions are waiting for their reset. Also read by the keep-awake watcher. |
| `resumed-sessions.json` | The map of what was resumed: project, session that stopped, session that took over, and when. Also stops anything being resumed twice. `qw -List` prints it. Capped. |
| `.session-rescue.lock` | Lock file preventing the 15-min pass and the one-shot job from double-resuming. Empty; safe to leave. |
| `QUOTAWAKE-RESUMED.md` | Written into the **rescued project's** folder, not here. |
| `QuotaWake-Logon` | The permanent reconciler: logon + every 15 min, hidden, near-zero cost. |
| `QuotaWake-Fire` | One-shot job for a wrapper resume; exists only while one is pending. |
| `QuotaWake-FireSessions` | One-shot job for session rescue at reset + 5 min. |
| `quotawake.log` | Every decision the rescue makes, with reasons. First place to look. |

## Limitations

- **It cannot take over a live terminal.** It continues the conversation in a
  new session; the original window stays frozen. See step 3.
- **Edits need permission.** Rescue uses `acceptEdits`, so a rescued run edits
  files with nobody to approve it. Review what it wrote.
- **Timezone.** The announced reset is treated as the machine's *local* time —
  correct while your clock matches the zone Claude announces.
- **One pending wrapper resume at a time.** The state file and one-shot job are
  singletons; arming a new resume replaces the previous one. (Session rescue
  handles many sessions per batch.)
- **A sleeping machine delays a resume, never loses it.** Windows needs wake
  timers (policy-enabled on AC, disabled on battery on most laptops —
  deliberately, to keep battery economic) and Linux needs root.
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

- **Windows** is fully exercised: unit tests plus repeated live rescues. This is
  the supported platform.
- **Linux is not usable yet, by design.** The `systemd --user` unit generation
  is verified against real `systemd-analyze` (v245) — the `.timer` and
  `.service` files are accepted with no complaints and `OnCalendar` normalises
  to the intended instant — but that only means the *scheduling* is right. The
  tool is a PowerShell script, so running it on Linux requires PowerShell 7,
  and expecting Linux users to install PowerShell to get a resume is not a
  serious offer. **A native Linux port is planned**; the systemd work above is
  kept because the port will reuse the same unit design.
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
round logic, stopped-session detection (including the regressions that once made
rescue fail silently, and the live-session rule that stopped it forking running
sessions), the arming/holding/firing cycle, the notice and toast, the systemd
generators, and the refusal to run on an unsupported OS.

The OS-specific backend is written as a **pure generator** returning unit text,
so the part most likely to be wrong is testable from any machine. What unit
tests cannot reach — the actual `systemctl` calls — is what `-Doctor` exists to
check on the target machine.

## Why it works the way it does

Most of the design looks arbitrary until you know which failure produced it —
**[DESIGN-NOTES.md](DESIGN-NOTES.md)** records the reasoning and the gotchas
(including several Claude Code and PowerShell behaviours that cost real
debugging time). Read it before changing how stops are detected or resumed.
