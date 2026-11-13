# Codex task template

Copy this into a scratchpad `.txt`, fill it, dispatch with:

```
codex-task -Mode execute -Type <type> -Tier auto -Repo <path> -PromptFile <file>
```

`-Tier auto` is the default:

| Resolved tier | Auto selection |
|---|---|
| `fast` (`gpt-reserve`, low effort) | `chore`, `docs`, `format`, `rename`, `search`, `lint`, `run`, `other` |
| `std` | `feature`, `fix`, `refactor`, `test`, or any unknown type |
| `deep` (`gpt-5.6-sol`, high effort) | `debug`, `migration`, `architecture`, `security`, `perf`; all `investigate`/`review` modes |
| `max` (`gpt-6-astra`, high effort) | Explicit `-Tier max`, or escalation from `deep` |

Never paste a long task as inline `-Task` (the shell truncates it). One file per task.
Runs use the exec-lean profile and log tokens to routing.tsv.

---

OBJECTIVE: <one sentence: the outcome, not the steps>

SCOPE:
  TOUCH ONLY: <dirs/files Codex may change>
  DO NOT TOUCH: <dirs/files that must stay byte-identical>

CONTEXT (non-repo only - do not restate what Codex can read):
  <constraints, prior decisions, gotchas>

DELIVERABLES:
  1. <concrete artifact + where it lives>
  2. ...

CONSTRAINTS:
  - match existing style of the surrounding code
  - stdlib-only unless a dep is already in requirements
  - <language/framework version pins>

ACCEPTANCE:
  - <objective, checkable statements>
  - `git status --porcelain` lists only files under <allowed paths>

VERIFY (run these exact commands, quote output verbatim):
  - <test command>
  - <lint/typecheck command>
  - <build command>
  - git status --porcelain

---

## Notes baked into the wrapper (do not repeat in the task)

- python, git, and node are on PATH inside the sandbox. Codex runs the real checks.
- Sandbox is `workspace-write` for execute, `read-only` for investigate/review. No network. No `danger-full-access`.
- git reads work; git writes (commit/push/reset/checkout) do not - Claude does the git.
- execute mode omits the `=== FULL ===` section; investigate/review append it and the wrapper keeps it in `REPORT_FILE` only.
- The wrapper auto-runs `route-log` on completion. Only call `route-log` by hand for a Claude-route sample, a retry, or a takeover.
- Codex quota/rate-limit/exec failure or `STATUS: blocked` writes a 3-hour Claude-fallback marker; success/partial clears it.
