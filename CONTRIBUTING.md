# Contributing

Thanks for looking. quotawake is small, and issues and pull requests are both
welcome.

This tool's defects do not announce themselves. A broken resume and a working one look identical from outside, because the window that hit the limit can never update itself. 

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


## Licence

By contributing you agree that your work is licensed under the
[MIT Licence](LICENSE).
