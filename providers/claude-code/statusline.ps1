# Statusline: shows active caveman/ponytail level and live context usage.
# Runs outside the model - costs zero tokens. Claude Code passes session JSON
# on stdin; context size comes from the last usage record in the transcript,
# so it's the real number the API saw, not an estimate.

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$LIMIT = 200000
$WARN  = 0.60
$HIGH  = 0.80

$claudeDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $HOME ".claude" }

function Get-Level($flagName) {
    $flag = Join-Path $claudeDir $flagName
    if (-not (Test-Path $flag)) { return $null }
    try {
        $item = Get-Item -LiteralPath $flag -Force -ErrorAction Stop
        if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { return $null }
        if ($item.Length -gt 64) { return $null }
        return (Get-Content -LiteralPath $flag -TotalCount 1 -ErrorAction Stop).Trim()
    } catch { return $null }
}

$parts = @()

$cm = Get-Level ".caveman-active"
if ($cm) { $parts += "CAVE:$($cm.ToUpper())" }
$pt = Get-Level ".ponytail-active"
if ($pt) { $parts += "PONY:$($pt.ToUpper())" }

# Context usage from the transcript's last usage record
try {
    $stdin = [Console]::In.ReadToEnd()
    $session = $stdin | ConvertFrom-Json
    $transcript = $session.transcript_path

    if ($transcript -and (Test-Path $transcript)) {
        $ctx = 0
        # Walk backwards: the last line carrying a usage block is the current context
        $lines = Get-Content -LiteralPath $transcript -ErrorAction Stop
        for ($i = $lines.Count - 1; $i -ge 0 -and $ctx -eq 0; $i--) {
            if ($lines[$i] -notmatch '"usage"') { continue }
            try {
                $u = ($lines[$i] | ConvertFrom-Json).message.usage
                if ($u) {
                    $ctx = [int]$u.input_tokens + [int]$u.cache_read_input_tokens + [int]$u.cache_creation_input_tokens
                }
            } catch {
                # A malformed transcript line is expected; keep scanning older lines.
                Write-Debug "skipped unparsable transcript line: $_"
            }
        }

        if ($ctx -gt 0) {
            $pct = $ctx / $LIMIT
            $k = [math]::Round($ctx / 1000)
            $label = "ctx ${k}K/$([math]::Round($LIMIT/1000))K"
            if ($pct -ge $HIGH) {
                $parts += "$label $([math]::Round($pct*100))% -- /clear now"
            } elseif ($pct -ge $WARN) {
                $parts += "$label $([math]::Round($pct*100))% -- wrap up or /compact"
            } else {
                $parts += $label
            }
        }
    }
} catch {
    # The statusline must never fail the host shell: degrade to no output.
    Write-Debug "statusline suppressed error: $_"
}

if ($parts.Count) { Write-Output ($parts -join "  |  ") }
