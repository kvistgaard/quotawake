# Contributing

Thanks for looking. quotawake is small, and issues and pull requests are both
welcome.

One thing shapes everything below: **this tool's defects do not announce
themselves.** A broken resume and a working one look identical from outside,
because the window that hit the limit can never update itself. It once spent
weeks appearing installed while doing nothing. Most of the rules here exist to
make failure loud.

## Reporting a bug

Open an [issue](../../issues) with:

- what you expected, and what happened instead
- the output of `.\quotawake.ps1 -Doctor`
- the relevant lines from `quotawake.log`, which records every decision and why

`quotawake.log` can contain file contents and prompts from whatever you were
working on, and `-Doctor` prints local paths — read both before pasting, and
redact anything private.

## Proposing a change

1. Fork, and branch off `main`.
2. Make the change, **and add an assertion for it** in `quotawake.Tests.ps1`.
3. Run the suite — everything must pass:
   ```powershell
   pwsh -File quotawake.Tests.ps1
   ```
   It runs against a mocked `claude` and mocked job registration, so it starts
   no sessions and spends no quota.
4. Run `.\quotawake.ps1 -Doctor` on your own machine.
5. Open a pull request saying **which failure the change prevents**, not just
   what it does.

## Two rules that are not negotiable

- **If it can fail silently, it needs a check.** Anything unit tests cannot
  reach must be provable by `-Doctor`, which registers a real scheduled job,
  confirms the system can see it, and removes it again.
- **Do not add a platform you cannot test.** Windows only today. macOS
  (`launchd`) and Linux (`systemd --user`) backends were both written and both
  removed, because neither could be exercised on the machine shipping them and a
  scheduler backend fails by registering *nothing*. Both are in the git history
  and are a real head start if you have the hardware — a port is very welcome,
  provided `-Doctor` can prove it where it runs.

## Licence

By contributing you agree that your work is licensed under the
[MIT Licence](LICENSE).
