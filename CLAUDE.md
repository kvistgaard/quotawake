# Working on claude-resume

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

`pwsh -File claude-resume.Tests.ps1` — all assertions must pass. They mock
`claude` and task registration, so they spend no quota and register nothing.

Unit tests are necessary but have twice been insufficient here: they passed while
the tool did nothing useful, because the fixtures were tidier than real
transcripts. For any change to detection or dispatch, also run it against the real
transcripts in `~/.claude/projects/`, and prove an end-to-end rescue by planting a
stranded stop behind ~60 trailing bookkeeping lines and letting the scheduled task
fire on its own.

## House rules

- No absolute paths. Use `$PSScriptRoot`; a hardcoded path once disabled the
  keep-awake watcher entirely.
- Timestamps from `ConvertFrom-Json` are `Kind=Utc` and print as UTC. Normalise
  before comparing with a parsed reset time.
- Nothing that runs after a successful rescue may throw. Notices and toasts are
  best-effort and must never turn a completed rescue into a failed one.
- Do not commit logs or state files — the log accumulates Claude's stdout, which
  means whatever the user was working on.
