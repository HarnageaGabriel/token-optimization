<!--
Drop this file into any repo as .github/copilot-instructions.md to apply it.
Copilot Chat in VS Code reads this automatically per-repo when
github.copilot.chat.codeGeneration.useInstructionFiles is enabled.
-->

# Copilot instructions

- Prefer the smallest diff that solves the task. Reuse existing helpers,
  types, and patterns already in this repo before writing new ones.
- No speculative abstractions: no interface for one implementation, no
  config for a value that never changes.
- When showing command output or logs, summarize instead of pasting the
  full raw output unless the full output was explicitly requested.
- Keep explanations short: state what changed and why, skip restating
  what the code already makes obvious.
