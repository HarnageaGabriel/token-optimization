# UserPromptSubmit hook: per-turn reminder to delegate real work to Codex CLI
# and keep Claude as a thin orchestrator, to conserve Claude tokens.
# Always exits 0 (never blocks); its stdout is appended to the turn's context.

$ErrorActionPreference = 'Stop'
try {
    $data   = [Console]::In.ReadToEnd() | ConvertFrom-Json
    $prompt = [string]$data.prompt
} catch {
    exit 0
}

# Skip the reminder for trivial / non-work prompts to avoid noise.
$p = $prompt.Trim()
if ($p.Length -lt 15) { exit 0 }
if ($p -match '^\s*!') { exit 0 }

Write-Output "[router] Delegate code edits, multi-file search, tests, and debugging to codex-task. Claude decides and performs one gated review before push; see codex-router/ROUTER.md."
exit 0
