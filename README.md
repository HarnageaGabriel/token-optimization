# ai-agent-bootstrap

One command to bootstrap AI coding agent config on a new machine or repo.

```powershell
.\init.ps1                    # defaults to claude-code
.\init.ps1 -Provider claude-code
.\init.ps1 -Provider copilot
```

Idempotent: safe to re-run. Never overwrites a file or settings key that already
exists with a different value — it reports what it skipped and why instead.

## What `claude-code` sets up

- RTK hook wiring in `~/.claude/settings.json` (only if `rtk` is on PATH — this
  script never installs binaries silently)
- `model: opusplan` default (Opus plans, Sonnet executes)
- `permissions.defaultMode: auto` (auto-proceed on safe/local actions, gate on
  anything touching prod/cloud/shared state — this is the built-in Claude Code
  auto-mode classifier, not a custom rule)
- Three subagents in `~/.claude/agents/`:
  - `dev` (Sonnet) — writes/edits code
  - `searcher` (Haiku, read-only) — locates code, no Bash/Edit/Write
  - `runner` (Haiku, Bash-only) — runs tests/verification commands

Generic on purpose — no project- or company-specific rules baked in. Add those
to your own project's `CLAUDE.md`, not here.

## What `copilot` sets up

Scope is smaller on purpose: Copilot Chat's instructions file
(`.github/copilot-instructions.md`) is per-repo, not global like `~/.claude`,
so this provider doesn't write into any project on your behalf.

- Checks the GitHub Copilot Chat extension is installed (reports, never
  auto-downloads on a corporate machine; sign-in can't be automated either)
- Sets the global VS Code setting
  `github.copilot.chat.codeGeneration.useInstructionFiles: true`, so Copilot
  picks up a repo's instructions file when present
- Ships `providers/copilot/copilot-instructions.md` as a template — copy it
  to `<project>\.github\copilot-instructions.md` in whichever repos you want
  it active

## Adding another provider

Create `providers/<name>/install.ps1` following the same shape as
`providers/claude-code/install.ps1`: check what's already there before writing,
merge instead of overwrite, print `[add]`/`[ok]`/`[warn]` per change. Add the
name to the `-Provider` `ValidateSet` in `init.ps1`.
