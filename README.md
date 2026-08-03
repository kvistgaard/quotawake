# quotawake

> [!CAUTION]
> **Early release** It's been used daily but is young so expect rough edges and bugs.

**Claude Code stops when you hit a usage limit. Quotawake starts the work again when the limit is reset – when you are asleep, away from your computer, or there but busy with something else.**

Quatawake reads the reset time out of Claude's own
message, sets an alarm, and exits. Between the limit and the reset there is no
process at all – no CPU, no memory use. Your operating system's
scheduler does the waiting so a resume survives closing the window it started in, computer sleep or reboot.

**Windows only.** Ports to macOS and Linux would be very welcome — earlier
attempts at both are in the git history and are a real head start.

## What happens

1. **Your session stops:** `You've hit your session limit · resets 8pm`
2. **You do nothing.** Close the window and walk away – it is finished either
   way, because nothing outside a running Claude Code session can type into it.
   Leave the machine on, and plugged in, if you want the resume to land on time:
   if it sleeps through the reset, the work starts when you next wake it.
3. **At 8pm the work carries on**, in a *new* session with the full history of
   the old one. (It has to be a new one: the frozen window cannot be revived.)
4. **You are told three ways** – a desktop notification, a `QUOTAWAKE-RESUMED.md`
   note in the project folder, and a new entry in the Claude app, phone included.
5. **You go back into it** and keep typing.

## Install

Windows, PowerShell 7+, and the `claude` CLI on your PATH.

Clone the repository (or download the zip and unpack it)

```powershell
git clone https://github.com/kvistgaard/quotawake quotawake     
cd quotawake
```

Then:

```powershell
.\quotawake.ps1 -Install     # then open a NEW shell
.\quotawake.ps1 -Doctor      # prove it actually works on this machine
```

`-Doctor` registers a real scheduled job, checks the system
can see it, and removes it again. This was added after some silent failures.

`-Install` writes to four places, all of them per-user and none needing admin: a
**Scheduled Task** (the reconciler), your **user PATH**, your **PowerShell
profile** (the `qw` shortcut), and the **Startup folder** (the keep-awake
watcher). `-Uninstall` reverses all four and removes the state files.

## Getting back into the resumed session

```powershell
claude agents
```

Resumed sessions are named after their project and restart time, so yours is
easy to spot:

```
my-project – resumed 20:04
another-project – resumed 03:15
```

Pick it, press Enter, and you are in the conversation with its full history.
Read what it did while you were away, then it is an
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
claude attach 7f3ab210   # open it here ("attach" is Claude Code's word, sorry)
claude logs   7f3ab210   # peek at its output without opening it
claude stop   7f3ab210   # stop it now; nothing is lost, reopen it with attach
```

> [!WARNING]
> **Don't type `resume` into the old frozen window.** It cannot see any of this,
> so it starts a *second* run, where you may ask for something the resumed
> session already did and waste tokens.

### About the ids

Every Claude Code session has one id, a long one, looking like this:
`7f3ab210-0000-…`. Claude Code usually shows just the **first 8 characters**,
`7f3ab210`. Same id, written short. Either form works.

**The resumed session has a different id from the one that stopped**, because it
is a new session. `QUOTAWAKE-RESUMED.md` gives you both, labelled
*Session that stopped* and *Resumed session*.

### Opening the session that stopped, instead

To go back to the original conversation rather than the resumed one, use Claude
Code's own `--resume` flag (nothing to do with quotawake – it reopens any past
conversation by id), from inside the project folder:

```powershell
cd C:\path\to\the\project
claude --resume <id>     # the id on the "Session that stopped" row
```

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
| Why did it decide *that*? | `quotawake.log` – every decision, with reasons |
| You moved the folder | re-run `-Install` there, then end the old watcher (`Get-Process pwsh`) and start the new one with the `wscript` line it prints |
