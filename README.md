# quotawake

> ⚠️ **Under active development.** It works and is in daily use on Windows, but
> it is young and has a history of failing *silently* — run `-Doctor` after
> installing, and check `quotawake.log` before assuming it did nothing. Windows
> only today; a native Linux port is planned.

**Claude Code stops when you hit a usage limit. quotawake starts the work again
the moment the limit resets — while you are asleep, in a meeting, or away from
the machine.**

It works like an alarm clock: it reads the reset time out of Claude's own
message, sets an alarm, and exits. **Between the limit and the reset there is no
process at all** — no CPU, no memory, nothing polling. Your operating system's
scheduler does the waiting, which is why a resume survives sleep, a reboot, or
closing the window it started in.

## What happens

1. **Your session stops:** `You've hit your session limit · resets 8pm`
2. **You do nothing.** Close the window, shut the laptop, walk away. That window
   is finished either way — nothing outside a running Claude Code session can
   type into it.
3. **At 8pm the work carries on**, in a *new* session with the full history of
   the old one. (It has to be a new one: the frozen window cannot be revived.)
4. **You are told three ways** — a desktop notification, a `QUOTAWAKE-RESUMED.md`
   note in the project folder, and a new entry in the Claude app, phone included.
5. **You go back into it** and keep typing. That is the next section.

## Install

Windows, PowerShell 7+, and the `claude` CLI on your PATH.

```powershell
.\quotawake.ps1 -Install     # then open a NEW shell
.\quotawake.ps1 -Doctor      # prove it actually works on this machine
```

`-Doctor` is not decoration: it registers a real scheduled job, checks the system
can see it, and removes it again. If that fails, nothing will ever fire — and
that failure is otherwise silent, which is how this tool once spent weeks looking
installed while doing nothing.

That is the whole setup. No flag to remember, no special way to start Claude —
every Claude Code session on the machine is covered from here on.

## Getting back into the resumed session

```powershell
claude agents
```

Resumed sessions are named after their project and restart time, so yours is
easy to spot:

```
my-project — resumed 20:04
another-project — resumed 03:15
```

Pick it, press Enter, and you are in the conversation with its full history.
Read what it did while you were away, then **just keep typing** — it is an
ordinary session from here. `Ctrl+Z` returns you to your shell; the session keeps
running.

To see only what quotawake resumed, and whether it is still going:

```powershell
qw -List
```

```
  Resumed at        Project                 Session     State
  ----------------  ----------------------  ----------  ----------
  2026-08-02 20:04  my-project              7f3ab210    running
  2026-08-02 03:15  another-project         a1b2c3d4    done
```

That `Session` column is all you need:

```powershell
claude attach 7f3ab210   # open it here ("attach" is Claude Code's word for it)
claude logs   7f3ab210   # peek at its output without opening it
claude stop   7f3ab210   # stop it early; the conversation is kept
```

> **Don't type `resume` into the old frozen window.** It cannot see any of this,
> so it starts a *second* run that redoes finished work.

### About the ids

Every Claude Code session has one id, a long one — `7f3ab210-0000-…` — and
Claude Code usually shows just the **first 8 characters**, `7f3ab210`. Same id,
written short; anywhere a command wants one, either form works.

**The resumed session has a different id from the one that stopped**, because it
genuinely is a new session. `QUOTAWAKE-RESUMED.md` gives you both, labelled
*Session that stopped* and *Resumed session*.

### When `claude --resume` says "No conversation found"

Almost always one of two things:

- **The session is already in use.** `--resume` only picks up conversations
  nobody has open. For a resumed session use `claude agents` or `claude attach`.
- **You are in the wrong folder.** `--resume` only sees the current directory's
  conversations, so `cd` to the project first.

**Rule of thumb:** resumed sessions → `claude agents`. Older conversations
nobody is using → `cd` to the project, then `claude --resume <id>`.

## If something looks wrong

| Symptom | Look at |
|---|---|
| Nothing ever fires | `qw -Doctor`, especially the scheduler line |
| Which id is mine? | `qw -List`, or your project's name in `claude agents` |
| It fired but you cannot find the session | `qw -List` |
| `No conversation found` | the section above |
| Why did it decide *that*? | `quotawake.log` — every decision, with reasons |
| You moved the folder | re-run `-Install` there; it rebinds all four bindings |

---

<details>
<summary><b>Hand over a job and walk away</b> — the optional wrapper</summary>

Everything above is automatic. There is also a wrapper for when you want to give
Claude a task and leave: it runs the task and re-runs it after each reset until
the work is done.

```powershell
# Fire-and-forget; on a limit it arms the resume and exits:
qw -Task "revise my note per the inline comments" -PermissionMode acceptEdits -Project "C:\path\to\workspace"

qw -Continue              # resume the most recent conversation here
qw -Continue -At "3pm"    # arm a resume for a time you saw on screen, and exit
```

The automatic resume needs none of this.
</details>

<details>
<summary><b>Parameters</b></summary>

`qw` is a shortcut for `quotawake.ps1`, written into your PowerShell profile by
`-Install`. Parameter names ignore case — `-list` and `-List` are the same.

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
| `-List` | — | What has been resumed: project, session id, still running or not. |
| `-Doctor` | — | Prove the platform integration on this machine. |
| `-Resume` / `-Reconcile` | — | Entry points for the scheduled jobs; not for manual use. |

Session-resume constants are at the top of the script: 48 h scan window, 5 min
buffer, 8 attempts, 4 min wait for the resumed session to report back.
</details>

<details>
<summary><b>Files and jobs</b></summary>

| Piece | What it is |
|---|---|
| `quotawake.ps1` | All the logic. |
| `keep-awake.ps1` | Companion watcher: holds the system awake **on AC only** while a Claude CLI session is running or a resume is armed. Never touches static power settings; never blocks display sleep. |
| `run-hidden.vbs` | Launches the script hidden so jobs never flash a console. |
| `pending-resume.json` | *Transient.* Only while a wrapper resume is pending. |
| `pending-sessions.json` | *Transient.* Only while stopped sessions await their reset. Also read by the keep-awake watcher. |
| `resumed-sessions.json` | The map of what was resumed: project, both session ids, when. Also stops anything being resumed twice. `qw -List` prints it. |
| `.session-rescue.lock` | Stops the 15-min pass and the one-shot job double-resuming. Empty; safe to leave. |
| `QUOTAWAKE-RESUMED.md` | Written into the **resumed project's** folder, not here. |
| `QuotaWake-Logon` | The permanent reconciler: logon + every 15 min, hidden, near-zero cost. |
| `QuotaWake-Fire` / `QuotaWake-FireSessions` | One-shot jobs, existing only while a resume is pending. |
| `quotawake.log` | Every decision, with reasons. First place to look. |

**The `*.json` files are transient.** `pending-resume.json` and
`pending-sessions.json` exist *only while something is waiting for a reset*.
Not seeing them is the healthy state — it means nothing is pending.

Moving the folder breaks four absolute-path bindings **silently** — the
scheduled job, the PATH entry, the `qw` shortcut, and the watcher's autostart.
Re-running `-Install` from the new location rewrites all four. Then end any
watcher still running from the old path and start the new one with the `wscript`
line `-Install` prints.
</details>

<details>
<summary><b>How it works</b></summary>

**Why nothing stays running.** On a limit the script records what to do,
registers a one-shot scheduled job for the reset time, and exits. That is what
makes a resume survive what kills an in-process wait:

- **Sleep / Modern Standby** — `StartWhenAvailable` fires the job as soon as the
  machine is back; `WakeToRun` may wake it at the exact time (policy permitting).
- **Reboot, logoff, closed window** — the job and the state file persist.
- **A reconciler** (`QuotaWake-Logon`) runs at logon **and every 15 minutes**,
  re-arming anything whose one-shot job went missing. That 15-minute trigger is
  load-bearing: on a Modern Standby machine the session almost never truly logs
  off, so an AtLogOn-only trigger measured 0 firings in 8 days.

You never type a reset time — it is read from Claude's message (`resets 1:30pm`),
anchored to the limit's own timestamp so a late scan resumes now rather than
arming for tomorrow. No parseable time means re-arm in `-PollMinutes`.

**How a stopped session is found.** Claude Code records the stop in the
session's transcript (`~/.claude/projects/<dir>/<id>.jsonl`) as a line with
`"error":"rate_limit"` carrying the reset time. Every reconcile pass reads
transcripts touched in the last 48 h.

- **A stop counts as dealt with** only when Claude replies at or after the reset
  **using a tool**. Weaker tests failed in practice: people talk to a stopped
  session without restarting its work, and a chat reply is not Claude going back
  to work. It also means an open window reviving itself beats a resume.
- **A session still running is never touched.** A limit line says a session *hit*
  a limit, not that it stopped. Resuming a live session copies it rather than
  continuing it — without this rule the tool resumed a live window, then its own
  resume, making a new session every pass.
- **An unreachable project folder** (unmounted network drive) is deferred and
  retried, never written off, capped at 8 attempts.
- **An arming is never dropped** because one scan came back empty.

It then arms a one-shot job for reset + 5 min and runs:

```
claude --resume <id> --bg --name "<project> — resumed HH:mm" --permission-mode acceptEdits "…continue…"
```

`--bg` is what makes the result visible in `claude agents` and the Claude app;
`--name` is what makes it recognisable. An earlier `-p` version registered no
session at all, so a working resume was invisible — indistinguishable from a
broken one.

**One deliberate non-goal:** nothing here wakes a sleeping machine. That needs
wake timers on Windows (AC-only under typical laptop policy). A resume whose
moment passes while asleep runs at the next wake — delayed, never lost.
</details>

<details>
<summary><b>Limitations, platforms and tests</b></summary>

- **It cannot take over a live terminal.** The original window stays frozen.
- **Edits happen under `acceptEdits`**, with nobody to approve them. Review them.
- **Timezone.** The announced reset is read as machine-local time.
- **One pending wrapper resume at a time** (session resume handles many).
- **A sleeping machine delays a resume, never loses it.** Wake timers are
  disabled on battery on most laptops — deliberately, to keep battery economic.
- **Your own open terminal is left alone**; it revives itself after a reset.

**Exit codes:** `0` done · `2` bad `-At` · `4` hit MaxRounds · `5` limit hit,
resume armed · otherwise Claude's own exit code.

**Platforms.** Everything OS-specific sits behind one contract — register a job,
remove it, ask whether it exists.

| | Windows | Linux |
|---|---|---|
| Scheduling | Task Scheduler | `systemd --user` timers |
| Fires after sleep/off | `StartWhenAvailable` | `Persistent=true` |
| Notification | WinRT toast / BurntToast | `notify-send` |
| Keep-awake | `SetThreadExecutionState` | `systemd-inhibit` |
| AC detection | WinForms `PowerStatus` | `/sys/class/power_supply` |

- **Windows** is the supported platform: unit tests plus repeated live resumes.
- **Linux is not usable yet, by design.** The systemd units are verified against
  real `systemd-analyze` (v245), but the tool is a PowerShell script — and asking
  Linux users to install PowerShell first is not a serious offer. A native port
  is planned; the systemd work is kept because that port will reuse it.
- **macOS is not supported.** A launchd backend was written and removed for lack
  of a Mac to test it on: a scheduler backend fails by registering nothing,
  silently. Retrievable via `git show ac11ea2 -- quotawake.ps1`.

**Tests:** `pwsh -File quotawake.Tests.ps1` — 111 assertions against a mocked
`claude` and mocked job registration. No real runs, no quota spent. The
OS-specific backend is a pure generator returning unit text, so the part most
likely to be wrong is testable anywhere; `-Doctor` covers what unit tests cannot.
</details>

## Why it works the way it does

Most of the design looks arbitrary until you know which failure produced it.
**[DESIGN-NOTES.md](DESIGN-NOTES.md)** records the reasoning and the gotchas,
including several Claude Code and PowerShell behaviours that cost real debugging
time. Read it before changing how stops are detected or resumed.
