$ErrorActionPreference = 'Stop'
$THRESHOLD = 3
$EDIT_TOOLS = @('Edit', 'Write', 'MultiEdit', 'NotebookEdit')

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

function Test-AllowlistedPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $fullPath = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    $prefixes = @(
        (Get-ClaudeHome),
        [IO.Path]::GetTempPath(),
        (Join-Path $env:LOCALAPPDATA 'Temp')
    )
    foreach ($prefix in $prefixes) {
        $fullPrefix = [IO.Path]::GetFullPath($prefix).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
        if ($fullPath.StartsWith($fullPrefix, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Test-FreshCodexUnavailableMarker {
    param([string]$MarkerPath)

    if (-not (Test-Path -LiteralPath $MarkerPath -PathType Leaf)) { return $false }
    $firstLine = Get-Content -LiteralPath $MarkerPath -TotalCount 1
    $timestamp = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse([string]$firstLine, [ref]$timestamp)) { return $false }
    return $timestamp.ToUniversalTime() -gt [DateTimeOffset]::UtcNow.AddHours(-3)
}

try {
    $data = [Console]::In.ReadToEnd() | ConvertFrom-Json
    $sessionId = [string]$data.session_id
    if ([string]::IsNullOrWhiteSpace($sessionId)) { exit 0 }

    $toolName = [string]$data.tool_name
    $stateDir = Join-Path (Get-ClaudeHome) '.codex-drift'
    $stateFile = Join-Path $stateDir "$sessionId.count"
    $markerFile = Join-Path $stateDir 'codex-unavailable'

    # Prune stale per-session counters (older than 7 days).
    if (Test-Path -LiteralPath $stateDir -PathType Container) {
        Get-ChildItem -LiteralPath $stateDir -Filter '*.count' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-7) } |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }

    $count = 0
    if (Test-Path -LiteralPath $stateFile -PathType Leaf) {
        $raw = Get-Content -Raw -LiteralPath $stateFile
        [int]::TryParse($raw, [ref]$count) | Out-Null
    }

    if ([string]$data.hook_event_name -eq 'PostToolUse') {
        if ($toolName -in @('Bash', 'PowerShell') -and ([string]$data.tool_input.command -match 'codex-task')) {
            New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
            Set-Content -LiteralPath $stateFile -Value '0' -Encoding ascii
        } elseif ($toolName -in $EDIT_TOOLS) {
            $path = if ($toolName -eq 'NotebookEdit') {
                [string]$data.tool_input.notebook_path
            } else {
                [string]$data.tool_input.file_path
            }
            if (-not (Test-AllowlistedPath $path)) {
                New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
                Set-Content -LiteralPath $stateFile -Value ($count + 1) -Encoding ascii
            }
        }
        exit 0
    }

    if ([string]$data.hook_event_name -ne 'PreToolUse') { exit 0 }

    if ($toolName -in $EDIT_TOOLS) {
        $path = if ($toolName -eq 'NotebookEdit') {
            [string]$data.tool_input.notebook_path
        } else {
            [string]$data.tool_input.file_path
        }
        if ((-not (Test-AllowlistedPath $path)) -and $count -ge $THRESHOLD -and
            (-not (Test-FreshCodexUnavailableMarker $markerFile))) {
            [Console]::Error.WriteLine('[codex-gate] Blocked: 3 direct edits since the last codex-task dispatch in this session. Delegate this change to codex-task (that resets the counter). Edits under ~/.claude or temp/scratchpad are always allowed; direct edits re-open automatically if Codex is unavailable (quota/failure).')
            exit 2
        }
        exit 0
    }
    # Agent/Task policy lives in codex-priority-guard.ps1 (single source of truth).
} catch {
    exit 0
}

exit 0
