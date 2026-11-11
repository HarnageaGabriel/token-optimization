$ErrorActionPreference = 'Stop'

function Test-PushMention {
    param([string]$Raw)
    return ($Raw -match '(?i)git\s+push' -or $Raw -match '(?i)gh\s+pr\s+create')
}

function Exit-FailClosed {
    param([string]$Raw, [switch]$Always)
    if ($Always -or (Test-PushMention -Raw $Raw)) {
        [Console]::Error.WriteLine('push-review-gate: could not verify push command, blocked (fail-closed)')
        exit 2
    }
    exit 0
}

$raw = $null
try {
    $raw = [Console]::In.ReadToEnd()
    $data = $raw | ConvertFrom-Json
    if ([string]$data.tool_name -notin @('Bash', 'PowerShell')) { exit 0 }

    $toolInput = $data.tool_input
    if ($null -eq $toolInput) { Exit-FailClosed -Raw $raw }

    $command = $toolInput.command
    if (-not ($command -is [string]) -or [string]::IsNullOrWhiteSpace($command)) { Exit-FailClosed -Raw $raw }

    # Remove heredoc bodies: from a line containing <<'TAG' / <<"TAG" / <<TAG / <<-TAG
    # up to the line equal to TAG.
    # PowerShell here-strings (@'...'@ / @"..."@) are dropped first.
    $command = [regex]::Replace($command, '(?s)@([''"])\r?\n.*?\r?\n\1@', '@$1$1@')
    $lines = $command -split '\r?\n'
    $kept = New-Object System.Collections.Generic.List[string]
    $i = 0
    while ($i -lt $lines.Count) {
        if ($lines[$i] -match "<<\s*-?\s*(['`"]?)([A-Za-z_][A-Za-z0-9_]*)\1") {
            $tag = $Matches[2]
            $kept.Add($lines[$i])
            $i++
            while ($i -lt $lines.Count -and $lines[$i].Trim() -ne $tag) { $i++ }
            $i++
        } else {
            $kept.Add($lines[$i])
            $i++
        }
    }
    $stripped = [string]::Join("`n", $kept)

    # Remove quoted string contents (double-quoted first, then single-quoted).
    $stripped = [regex]::Replace($stripped, '"[^"\r\n]*"', '""')
    $stripped = [regex]::Replace($stripped, "'[^'\r\n]*'", "''")

    # Match only at a command position: start of command, after a newline, ;, &,
    # |, (, backtick, or $(, optionally preceded by sudo / env VAR=x / rtk /
    # command. Also matches git -C <path> push and git -c k=v push.
    $separators = '(?:^|[\r\n;&|`(]+|\$\(\s*)'
    $prefixes = '(?:(?:sudo|rtk|command|env(?:\s+[A-Za-z_][A-Za-z0-9_]*=\S*)?)\s+)*'
    $target = '(?:git(?:\s+-[Cc]\s+\S+)*\s+push\b|gh\s+pr\s+create\b)'
    $pattern = '(?im)' + $separators + '[ \t]*' + $prefixes + $target

    if ($stripped -notmatch $pattern) { exit 0 }

    $reminder = '[push-gate] Before this push: (1) a neutral `codex-task -Mode review -Tier deep` review of the diff must have run this session, (2) run pr-review-digest.ps1 and read only that digest plus flagged hunks, (3) read the full diff only for auth/security/migrations/data loss/public API/secrets hits, (4) if clean, push; otherwise delegate the fix to codex-task and re-run the digest. Claude owns the final go/no-go decision.'
    $output = [ordered]@{
        hookSpecificOutput = [ordered]@{
            hookEventName = 'PreToolUse'
            additionalContext = $reminder
        }
    }
    $output | ConvertTo-Json -Compress -Depth 4
} catch {
    if ($null -eq $raw) { Exit-FailClosed -Always }
    Exit-FailClosed -Raw $raw
}

exit 0
