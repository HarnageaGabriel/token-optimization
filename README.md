# ai-agent-bootstrap

One command to bootstrap AI coding agent config on a new machine or repo.

```powershell
.\init.ps1                    # defaults to claude-code
.\init.ps1 -Provider claude-code
.\init.ps1 -Provider copilot
.\init.ps1 -Provider codex-router
```

Idempotent: safe to re-run. Never overwrites a file or settings key that already
exists with a different value — it reports what it skipped and why instead.

## Codex router (plug and play)

The Codex router gives Claude Code one execution party: Codex CLI. Claude makes
product decisions, delegates edits/search/tests/debugging through `codex-task`,
and performs one gated digest review before a push. There are no alternate model
providers or quota fallbacks; when Codex is unavailable, a short-lived marker
re-opens direct Claude work and `[claude-fallback]` subagents.

Quick start:

1. Run `.\init.ps1 -Provider codex-router`.
2. Run `codex login` if the doctor reports that authentication is missing.
3. Open a new Claude Code session so the installed hooks and instructions load.

Delegate a task with a bounded prompt file:

```powershell
~/.claude/codex-router/codex-task.ps1 -Mode execute -Type feature -Tier auto -Repo . -PromptFile .\task.txt
```

`-Tier auto` selects a Codex model and reasoning effort by task type; `-Escalate`
moves one tier higher. `investigate` and `review` use a read-only sandbox, while
`execute` uses workspace-write. Codex is never launched with unrestricted or
danger-full-access permissions and never owns commit/push/reset/clean/deploy.

Before push or PR creation, the hook requests a neutral
`codex-task -Mode review -Tier deep`, followed by Claude's review of
`pr-review-digest.ps1` and its flagged hunks. Claude owns the final go/no-go.

Uninstall only recorded installer-owned files and hook entries:

```powershell
.\init.ps1 -Provider codex-router -Uninstall
```

### Model mapping configuration

The tier-to-model mapping lives in `~/.claude/codex-router/model-catalog.json`. The
installed defaults are:

| Tier | Model | Effort |
|------|-------|--------|
| fast | gpt-reserve | low |
| std | gpt-5.6-sol | medium |
| deep | gpt-5.6-sol | high |
| max | gpt-6-astra | high |

These defaults reflect the author's Codex catalog; your catalog may differ. Edit
the JSON to use models available in your account. To list available Codex models,
run `codex models` (or check the Codex CLI documentation for the current command).
Missing tiers fall back to the defaults above.

### Requirements

- Windows
- PowerShell 7 (`pwsh`) or Windows PowerShell 5.1 (`powershell`). Both hosts
  pass the router test suite.

Troubleshooting:

- Hooks require PowerShell 7 (`pwsh`). The doctor prints an exact install hint.
- RTK is optional. If it exists in the Codex runtime cache but is not resolvable,
  re-run with `-FixRtk`; otherwise install Rust Token Killer and re-run.
- Install Codex CLI with `npm i -g @openai/codex`, then authenticate with
  `codex login`. The installer never reads or writes credentials.
- Claude desktop's model selector and claude.ai connectors must be changed in
  the app UI; this repository does not configure either surface.

## What `claude-code` sets up

- RTK hook wiring in `~/.claude/settings.json` (only if `rtk` is on PATH — this
  script never installs binaries silently). RTK compresses verbose shell
  output (git, docker, terraform, kubectl...) before it enters context.
  Validated on real repos: 57–83% saved on `git diff`/`git log`. Does **not**
  cover `az` — az output goes in raw, no hook rewrites it today.
- Graphify, registered **as a user-scope MCP server** so the agent queries the
  graph on its own — no `/graphify` to type. Graphify parses the repo locally
  with tree-sitter into a queryable knowledge graph, so the agent navigates the
  graph instead of re-reading files. Complementary to RTK, not overlapping: RTK
  compresses *command output*, Graphify compresses *codebase exploration*.
  Payoff scales with repo size — on a few dozen files it buys close to nothing,
  the vendor's headline numbers are measured on 500+ file codebases.
  Only wired if `graphify` is on PATH — same policy as RTK, the script never
  installs the Python package for you:
  ```
  uv tool install "graphifyy[mcp]"
  ```
  The script also runs `graphify install` (skill file + `~/.claude/CLAUDE.md`
  pointer) so `/graphify .` still works for building the graph in the first
  place. See the MCP wiring notes below — three details there are not what the
  upstream docs suggest.
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

### Wiring Graphify as an MCP server: what the docs get wrong

Read off the upstream source (`graphify/__main__.py`, `graphify/serve.py`,
`pyproject.toml` at v0.1.14), not off the README:

- **There is no `graphify --mcp` command.** The CLI's `main()` dispatches only
  `install`, `vscode`, `claude`, `hook` and `benchmark`; anything else prints
  `unknown command` and exits 1. The `--mcp` you see in the docs is a flag the
  *skill* passes, not a CLI verb. The stdio server is `graphify/serve.py`, so
  the real command is `<python> -m graphify.serve`.
- **`mcp` is an optional extra**, not a dependency — `pip install graphifyy`
  gives you a server that raises `ImportError` the moment it starts. You need
  `graphifyy[mcp]`. The script checks `import mcp` separately and warns with
  the exact fix rather than registering a server that can't boot.
- **Which python matters.** `uv tool install` isolates the package in its own
  venv, so `python -m graphify.serve` against the interpreter on PATH fails to
  import. The script probes candidates (uv tool venv → the dir next to the
  `graphify` shim → PATH python) and keeps the first that can actually
  `import graphify.serve`, then registers *that* absolute path.

One consequence worth knowing before you turn this on: `serve()` loads
**`graphify-out/graph.json` as a relative path** and `sys.exit(1)`s if it's
missing. The server inherits the session's working directory, so it resolves
per-repo — which is what makes a single user-scope registration workable — but
it also means the server shows up as **failed in every repo where you have not
run `/graphify .` at least once**. That's noise, not breakage.

Registration goes through `claude mcp add --scope user`, deliberately *not* by
editing `~/.claude.json` directly: that file holds your oauth account and the
full per-project history, and a PowerShell 5.1 `ConvertFrom-Json` →
`ConvertTo-Json -Depth 10` round-trip would quietly flatten the deep structures
it doesn't fit. If the `claude` CLI isn't on PATH the script prints the exact
command instead of touching the file.

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
5. For Graphify, in a repo where you've run `/graphify .` once:
   `claude mcp list` must show `graphify` as connected, and the session must
   expose its tools (`query_graph`, `god_nodes`, `graph_stats`...). A server
   that registers but never connects saves nothing. Then ask an architecture
   question and confirm the agent hits those tools instead of reading files —
   that's the whole point, and it's the only thing that proves the tokens are
   actually going down.

## Adding another provider

Create `providers/<name>/install.ps1` following the same shape as
`providers/claude-code/install.ps1`: check what's already there before writing,
merge instead of overwrite, print `[add]`/`[ok]`/`[warn]` per change. Add the
name to the `-Provider` `ValidateSet` in `init.ps1`.
