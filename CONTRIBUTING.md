# Contributing

Thanks for taking the time. This repository bootstraps AI coding-agent
configuration on a machine or a repo, so a broken change costs someone their
working setup. That shapes the rules below.

## Ground rules

- **Idempotence is the contract.** Every script must be safe to re-run. Never
  overwrite an existing file or an existing settings key that holds a different
  value — skip it and report what was skipped and why.
- **No silent installs.** Do not download or install binaries on the user's
  behalf. Detect, report, and let the user decide.
- **No secrets.** No API keys, tokens, tenant ids, or internal hostnames, not
  even as placeholders that look real.

## Making a change

1. Fork the repository and branch off `main`.
2. Keep the change scoped to one problem. Two unrelated fixes are two pull requests.
3. Run the script you touched on a clean machine or a throwaway profile, then run
   it a second time to prove it is idempotent.
4. Update `README.md` when behaviour or usage changes.
5. Open a pull request and fill in the template, including what you actually ran.

## PowerShell style

- `Set-StrictMode -Version Latest` and `$ErrorActionPreference = 'Stop'` at the top
- Approved verbs for function names (`Get-`, `Set-`, `Test-`, `Install-`)
- Full parameter names in scripts — no positional guessing, no aliases
- Prefer `Test-Path` guards over `try`/`catch` for expected conditions
- The pull-request CI runs PSScriptAnalyzer; warnings and errors block the merge

## Adding a provider

Providers live under `providers/<name>/` and each ships its own `install.ps1`.
A new provider should follow the layout of an existing one, stay idempotent, and
be selectable through `.\init.ps1 -Provider <name>`.
