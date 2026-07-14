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
  script never installs binaries silently). RTK compresses verbose shell
  output (git, docker, terraform, kubectl...) before it enters context.
  Validated on real repos: 57–83% saved on `git diff`/`git log`. Does **not**
  cover `az` — az output goes in raw, no hook rewrites it today.
- `model: opusplan` default (Opus plans, Sonnet executes) — the model-routing
  part of the setup; applies to the main thread, not just subagents.
- `permissions.defaultMode: auto` (auto-proceed on safe/local actions, gate on
  anything touching prod/cloud/shared state — this is the built-in Claude Code
  auto-mode classifier, not a custom rule). Confirmed: destructive commands
  (`terraform destroy`, `az group delete`, etc.) stay gated regardless of
  which subagent invokes them — the classifier evaluates the command, not
  the caller.
- Three subagents in `~/.claude/agents/`:
  - `dev` (Sonnet) — writes/edits code
  - `searcher` (Haiku, read-only) — locates code, no Bash/Edit/Write
  - `runner` (Haiku, Bash-only) — runs tests/verification commands
- `ponytail@ponytail` plugin (anti-overengineering ladder: reuse before
  writing, stdlib before dependency, shortest diff that works) registered
  and installed, forced to **ultra** intensity.
- `caveman@caveman` plugin (ultra-compressed responses) forced to **ultra**
  intensity, same mechanism as ponytail below.

Generic on purpose — no project- or company-specific rules baked in. Add those
to your own project's `CLAUDE.md`, not here.

### The ponytail/caveman "ultra" mode: a real Windows path bug

Both plugins resolve their default intensity in this order: `PONYTAIL_DEFAULT_MODE` /
`CAVEMAN_DEFAULT_MODE` env var → `config.json` → hardcoded default (`full`).
The config file lives at **`%APPDATA%\<tool>\config.json` on Windows** —
`~/.config/<tool>/` is a Mac/Linux-only fallback. An earlier version of this
script wrote to `~/.config/`, so on Windows neither plugin ever saw the
override and silently stayed at `full` despite the file existing. Confirmed
via a fresh session showing the literal startup reminder text (`level: ultra`
vs `level: full`) before and after the fix — not assumed from the config
file alone. The script now sets **both** the user env var (highest priority,
survives even if the path logic is wrong again) and the config file at the
correct path, idempotently, and warns instead of overwriting if you've set a
different mode yourself.

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

## Verifying it actually took effect

Config files being correct isn't the same as behavior being correct — see the
path bug above. Env vars and some hook-driven state (model, permission mode)
are only read at process start, so anything changed by this script won't be
live in the session you ran it from. To verify for real:

1. Open a **new** Claude Code session (new window/terminal, not the one that
   ran the script).
2. Check the SessionStart reminders verbatim: ponytail and caveman both print
   their active level on boot (`... MODE ACTIVE — level: X`) — confirm it
   says `ultra`, not `full`.
3. Run a verbose command from your real stack (`git diff`, `git log --stat`)
   in a real repo, then run `rtk gain` and confirm that specific command
   shows up with a nonzero saved percentage — don't trust the aggregate
   number alone, it can be dominated by unrelated commands.
4. `claude plugin list` should show both `ponytail@ponytail` and
   `caveman@caveman` as enabled.

## Adding another provider

Create `providers/<name>/install.ps1` following the same shape as
`providers/claude-code/install.ps1`: check what's already there before writing,
merge instead of overwrite, print `[add]`/`[ok]`/`[warn]` per change. Add the
name to the `-Provider` `ValidateSet` in `init.ps1`.
