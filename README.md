# quotawake

**Claude Code stops when you hit a usage limit. Quotawake starts the work again when the limit is reset – when you are asleep, away from your computer, or there but busy with something else.**

Quatawake reads the reset time out of Claude's own message, sets an alarm, and exits. Between the limit and the reset there is no process at all – no CPU, no memory use. Your operating system's scheduler does the waiting so a resume survives closing the window it started in, computer sleep or reboot.

**Windows only.** Ports to macOS and Linux would be very welcome.

## What happens

1. **Your session stops:** `You've hit your session limit · resets 8pm`
2. **You do nothing.** Close the window and walk away, or leave it open. Leave the machine on, and plugged in, if you want the resume to be
   on time. If your machine sleeps through the reset, the work starts when you next wake it.
3. **At reset time the work is resumed.** What happens depends on the window:
   - **Window closed:** quotawake continues the session in the background.
   - **Window open:** Claude Code usually continues it by itself, through its
     "Continue automatically at usage limit" setting, added in
     [2.1.234](https://github.com/anthropics/claude-code/releases/tag/v2.1.234). If it is still stopped ten minutes after the reset, quotawake closes the window and continues the session in the background.
   - **You typed into the window in those ten minutes:** quotawake leaves the
     session to you.

   Only one process ever works on a session.

4. **You are told twice** – a desktop notification and a
   `QUOTAWAKE-RESUMED.md` note in the project folder.
5. **You go back into it** with `qw -Open` in the project folder, and keep
   typing.

## Doesn't Claude Code do this itself?

Only in an open window, and only since 2.1.234, released on 17 August 2026.
Before that release, Claude Code did not continue a stopped session by itself.
You had to come back and type, or use a tool like quotawake.

Claude Code now [waits in the open window and continues the task after the
reset](https://code.claude.com/docs/en/interactive-mode#wait-for-a-usage-limit-to-reset).
It does not continue the task when:
- you closed the window, or Claude Code exited
- the computer slept through the reset for more than about 30 minutes
- the session runs in the background
- the continued task keeps hitting the limit
quotawake resumes the session in these cases. In an open window it waits ten
minutes after the reset, so that Claude Code can continue the task first.

## Install

Windows, PowerShell 7+, and Claude Code 2.1.285 or later on your PATH.

Clone the repository, or download the zip and unpack it:

```powershell
git clone https://github.com/kvistgaard/quotawake
cd quotawake
.\quotawake.ps1 -Install     # then open a new shell
.\quotawake.ps1 -Doctor      # prove it works on this machine
```

`-Install` needs no admin rights. It adds a scheduled task, the `qw` shortcut
to your PowerShell profile, this folder to your user PATH, and a keep-awake
watcher to your Startup folder. 
`-Uninstall` removes all four, and the state files.


## Getting back into the session

In the project folder:

```powershell
qw -Open
```

To see everything quotawake resumed, and whether each one is still running:

```powershell
qw -List
```

```
  Resumed at        Project                 Session     State
  ----------------  ----------------------  ----------  ----------
  2026-08-02 20:04  my-project              7f3ab210    running
  2026-08-02 03:15  another-project         a1b2c3d4    done
```

The `Session` column works with Claude Code's own commands, from any folder:

```powershell
claude attach 7f3ab210   # open it here
claude logs   7f3ab210   # peek at its output without opening it
claude stop   7f3ab210   # stop it now; nothing is lost
```

Resumed sessions are also listed in `claude agents`, named after their project
and restart time, such as `my-project – resumed 20:04`.

## If something looks wrong

| Symptom                                        | What to do                                                                                                                     |
| ---------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| Nothing ever fires                             | `qw -Doctor`, especially the scheduler line                                                                                    |
| You cannot find the resumed session            | `qw -Open` in the project folder, or `qw -List`                                                                                |
| `claude --resume` says `No conversation found` | `cd` to the project folder first, or use `qw -Open`                                                                            |
| `-Doctor` says Claude Code is too old          | `claude update`                                                                                                                |
| Why did it decide *that*?                      | `quotawake.log` – every decision, with reasons                                                                                 |
| You moved the folder                           | re-run `-Install` there, then end the old watcher (`Get-Process pwsh`) and start the new one with the `wscript` line it prints |

