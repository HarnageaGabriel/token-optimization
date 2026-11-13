# PreToolUse guard: Codex allowance has priority over Claude subagents.
# Allow a Claude fallback only after the caller has a concrete Codex failure and
# marks the task description with [claude-fallback].

$ErrorActionPreference = 'Stop'

function Get-UserHome {
    if ($HOME) { return $HOME }
    $profilePath = [Environment]::GetFolderPath('UserProfile')
    if ($profilePath) { return $profilePath }
    throw 'Cannot determine user home directory ($HOME or UserProfile).'
}

function Get-ClaudeHome {
    $configDir = ([string]$env:CLAUDE_CONFIG_DIR).Trim()
    if (-not [string]::IsNullOrWhiteSpace($configDir)) { return [IO.Path]::GetFullPath($configDir) }
    $installedIn = Split-Path -Parent $PSScriptRoot
    if ($installedIn) { return $installedIn }
    return Join-Path (Get-UserHome) '.claude'
}

try {
    $data = [Console]::In.ReadToEnd() | ConvertFrom-Json
} catch {
    exit 0
}

if ([string]$data.tool_name -notin @('Agent', 'mcp__ccd_session__spawn_task')) {
    exit 0
}

# $input is PowerShell's reserved pipeline enumerator.  Assigning to it
# silently loses the tool payload, which previously made this guard a no-op.
$toolInput = $data.tool_input
$description = "{0} {1} {2}" -f [string]$toolInput.description, [string]$toolInput.prompt, [string]$toolInput.task
# Creative linkedin roles deliberately stay on Claude (writing quality); a few
# harness-only agent types have no Codex equivalent.
$creative = @('linkedin-writer', 'linkedin-hook-specialist', 'linkedin-blog-writer', 'claude-code-guide', 'statusline-setup')
if ([string]$toolInput.subagent_type -in $creative) {
    exit 0
}

# [claude-fallback] is honoured only after a real Codex failure: codex-task.ps1
# writes this marker on quota/rate-limit, exec failure, or STATUS: blocked.
if ($description -match '(?i)\[claude-fallback\]') {
    $marker = Join-Path (Get-ClaudeHome) '.codex-drift\codex-unavailable'
    $ts = [DateTimeOffset]::MinValue
    if ((Test-Path -LiteralPath $marker) -and
        [DateTimeOffset]::TryParse([string](Get-Content -LiteralPath $marker -TotalCount 1), [ref]$ts) -and
        $ts.ToUniversalTime() -gt [DateTimeOffset]::UtcNow.AddHours(-3)) {
        exit 0
    }
    [Console]::Error.WriteLine('[codex-priority] [claude-fallback] needs a real Codex failure first: no quota/failure marker in the last 3h. Run codex-task; if it fails (quota/rate-limit/capability) the wrapper writes the marker and fallback opens.')
    exit 2
}

[Console]::Error.WriteLine('[codex-priority] Codex allowance has priority. Do not start a Claude task/subagent. Write a bounded task prompt and run codex-task first. Use Claude only after Codex returns a quota/rate-limit or concrete capability failure; then include [claude-fallback] in its description.')
exit 2
