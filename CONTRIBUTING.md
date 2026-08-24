# Contributing

This repository bootstraps AI coding-agent configuration on a machine or a repo.
A broken change here costs someone their working setup, which is why the rules
below are stricter than the size of the code would suggest.

## Ground rules

Every script has to be safe to re-run. If a file or a settings key already exists
with a different value, leave it alone and report what was skipped and why.

Don't download or install binaries on the user's behalf. Detect what is missing,
say so, and let them decide.

Keep secrets out of the repository. That includes API keys, tokens, tenant ids
and internal hostnames, and it also includes placeholders that look real enough
to be copied by mistake.

## Making a change

1. Fork the repository and branch off `main`.
2. Keep the change scoped to one problem. Two unrelated fixes are two pull requests.
3. Run the script you touched on a clean machine or a throwaway profile, then run
   it again to check that the second run is a no-op.
4. Update `README.md` if behaviour or usage changed.
5. Open a pull request and fill in the template, including what you ran.

## PowerShell style

- `Set-StrictMode -Version Latest` and `$ErrorActionPreference = 'Stop'` at the top
- approved verbs for function names (`Get-`, `Set-`, `Test-`, `Install-`)
- full parameter names in scripts, no positional arguments and no aliases
- `Test-Path` guards for conditions you expect, `try`/`catch` for the ones you don't
- PSScriptAnalyzer runs on every pull request; warnings and errors block the merge

`PSAvoidUsingWriteHost` is switched off in `PSScriptAnalyzerSettings.psd1`. These
scripts are an installer and a statusline renderer, so what they print to the
console is the point.

## Adding a provider

Providers live under `providers/<name>/` and ship their own `install.ps1`. Follow
the layout of one that already exists, keep it re-runnable, and make it selectable
through `.\init.ps1 -Provider <name>`.
