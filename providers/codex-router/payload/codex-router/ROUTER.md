# Codex router (short)

Delegate: write a scratchpad `.txt` (template `codex-router/TASK_TEMPLATE.md`: objective, scope, constraints, acceptance, verify), then
`codex-task -Mode execute|investigate|review -Type <feature|fix|refactor|test|debug|...> -Repo <path> -PromptFile <file>`
Always `-PromptFile`. `-Tier auto` unless escalating. Never danger-full-access. Git writes stay with Claude.

Review: after `execute`, run a neutral Codex review with `codex-task -Mode review -Tier deep`. Claude then performs one gated pre-push digest review and owns the final decision.

Pre-push gate: Codex review ran; read only `pr-review-digest.ps1` output plus flagged hunks; full diff only for auth/security/migrations/data loss/public API/secrets. Clean = push; otherwise delegate the fix and re-run the digest.

Retry once with `-Escalate`, one defect plus correction; then narrow, investigate, or ask. On Codex quota/rate-limit/exec failure, the wrapper writes `codex-unavailable`, which permits direct Claude edits or a subagent marked `[claude-fallback]`. `ROUTING_REVIEW_DUE` -> `route-stats`.

Hooks enforce: `codex-gate` (4th direct edit blocked), `codex-priority-guard` (no Claude subagents unless codex unavailable; then description `[claude-fallback]`).

Report block: STATUS, CHANGED, SUMMARY, CHECKS, RISKS, NEEDS_CLAUDE, NEXT; full detail in `REPORT_FILE`.
