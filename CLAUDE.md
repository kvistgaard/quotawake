# Working on quotawake

Read `DESIGN-NOTES.md` before changing behaviour. Nearly every decision here was
made in response to a specific silent failure, and the obvious simplification is
usually the thing that was already tried and broke.

## The failure mode to design against

This tool's defects do not announce themselves. A broken rescue and a working one
look identical from the outside, because the terminal that hit the limit can never
update itself. Assume any change you make could fail silently for weeks.

Concretely:

- **Never widen "the session recovered".** A stop is cleared only by an assistant
  turn, at or after the announced reset, that uses a tool. Three looser
  definitions each shipped, each looked right, and each silently cancelled real
  rescues. See DESIGN-NOTES.
- **Never discard an arming on one empty scan.** Unregistering a task that has not
  fired yet is unrecoverable.
- **Bias toward resuming.** A needless resume costs a run that replies DONE; a
  missed one abandons hours of work with no signal.

## Verifying

`pwsh -File quotawake.Tests.ps1` — all assertions must pass. They mock
`claude` and task registration, so they spend no quota and register nothing.

Unit tests are necessary but have twice been insufficient here: they passed while
the tool did nothing useful, because the fixtures were tidier than real
transcripts. For any change to detection or dispatch, also run it against the real
transcripts in `~/.claude/projects/`, and prove an end-to-end rescue by planting a
stranded stop behind ~60 trailing bookkeeping lines and letting the scheduled task
fire on its own.

## House rules

- **OS-specific code must be a pure generator plus a thin call.** Return the
  unit/command as text from a function that touches nothing, then execute it
  separately. That is what makes the Linux backend testable from a machine that
  is not Linux. Never inline OS-specific text into the code that runs it.
- **Anything you cannot test here must be checkable by `-Doctor`.** If you add a
  platform capability, add the corresponding check.
- **Do not add a platform you cannot test.** Windows and Linux are supported;
  macOS is refused by name in `Assert-SupportedPlatform`. A launchd backend was
  written and removed at `ac11ea2` for exactly this reason — a scheduler backend
  fails by registering nothing, silently, which is how this tool was already
  broken four times. If you delete a platform, delete the code too and keep the
  explicit refusal; a half-supported OS with no warning is the worst outcome.
- **Never resume a session that is still running.** A limit line means the
  session *hit* a limit, not that it stopped. `--resume --bg` on a live session
  forks it — and since each fork's transcript is then scanned in turn, that
  chains. `Get-LiveSessionIds` is the guard; it is not optional.
- No absolute paths. Use `$PSScriptRoot`; a hardcoded path once disabled the
  keep-awake watcher entirely.
- Timestamps from `ConvertFrom-Json` are `Kind=Utc` and print as UTC. Normalise
  before comparing with a parsed reset time.
- Nothing that runs after a successful rescue may throw. Notices and toasts are
  best-effort and must never turn a completed rescue into a failed one.
- Do not commit logs or state files — the log accumulates Claude's stdout, which
  means whatever the user was working on.
