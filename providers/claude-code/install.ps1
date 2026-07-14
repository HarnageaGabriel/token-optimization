<#
Bootstraps Claude Code config: RTK hook, model routing (opusplan), auto-mode permissions,
and dev/searcher/runner subagents. Idempotent - safe to re-run; never clobbers unrelated
settings.json keys or overwrites an agent file that differs from the template without saying so.
Targets Windows PowerShell 5.1 (no -AsHashtable on ConvertFrom-Json there).
#>

param(
    [string]$ClaudeDir = (Join-Path $HOME ".claude")
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

function Test-HasProp($obj, $name) {
    return $null -ne $obj -and ($obj.PSObject.Properties.Name -contains $name)
}

Write-Host "== Claude Code bootstrap ==" -ForegroundColor Cyan

# 0. Ponytail plugin (anti-overengineering guardrails) - check before installing
$claudeCmd = Get-Command claude -ErrorAction SilentlyContinue
if ($claudeCmd) {
    $marketplaces = claude plugin marketplace list 2>&1 | Out-String
    if ($marketplaces -notmatch 'ponytail') {
        claude plugin marketplace add DietrichGebert/ponytail 2>&1 | Out-Null
        Write-Host "[add] ponytail marketplace registered"
    } else {
        Write-Host "[ok] ponytail marketplace already registered"
    }

    $installed = claude plugin list 2>&1 | Out-String
    if ($installed -notmatch 'ponytail@ponytail') {
        claude plugin install ponytail@ponytail 2>&1 | Out-Null
        Write-Host "[add] ponytail plugin installed"
    } else {
        Write-Host "[ok] ponytail plugin already installed"
    }
} else {
    Write-Host "[skip] claude CLI not on PATH, cannot manage ponytail plugin" -ForegroundColor Yellow
}

# Set a tool's default intensity mode via both its User env var (highest
# priority, immune to config-path mistakes) and its config.json (fallback),
# at the tool's real per-OS config path - on Windows that's %APPDATA%\<tool>,
# NOT ~/.config/<tool> (that's the Mac/Linux fallback only).
function Set-ToolUltraMode($toolName, $envVarName) {
    $existingEnv = [Environment]::GetEnvironmentVariable($envVarName, "User")
    if ($existingEnv -eq 'ultra') {
        Write-Host "[ok] $envVarName already set to ultra"
    } elseif ($existingEnv) {
        Write-Host "[warn] $envVarName already set to '$existingEnv' - left untouched." -ForegroundColor Yellow
    } else {
        [Environment]::SetEnvironmentVariable($envVarName, "ultra", "User")
        Write-Host "[add] $envVarName = ultra (user env var)"
    }

    $configDir = Join-Path $env:APPDATA $toolName
    $configPath = Join-Path $configDir "config.json"
    New-Item -ItemType Directory -Force -Path $configDir | Out-Null
    if (-not (Test-Path $configPath)) {
        '{"defaultMode":"ultra"}' | Set-Content $configPath -Encoding utf8
        Write-Host "[add] $toolName config.json: defaultMode = ultra"
    } else {
        $cfg = Get-Content $configPath -Raw | ConvertFrom-Json
        if (-not (Test-HasProp $cfg 'defaultMode')) {
            $cfg | Add-Member -NotePropertyName 'defaultMode' -NotePropertyValue 'ultra'
            $cfg | ConvertTo-Json -Depth 10 | Set-Content $configPath -Encoding utf8
            Write-Host "[add] $toolName config.json: defaultMode = ultra"
        } elseif ($cfg.defaultMode -ne 'ultra') {
            Write-Host "[warn] $toolName config.json already has defaultMode='$($cfg.defaultMode)' - left untouched." -ForegroundColor Yellow
        } else {
            Write-Host "[ok] $toolName config.json: defaultMode already ultra"
        }
    }
}

Set-ToolUltraMode -toolName "ponytail" -envVarName "PONYTAIL_DEFAULT_MODE"
Set-ToolUltraMode -toolName "caveman" -envVarName "CAVEMAN_DEFAULT_MODE"

# 1. RTK check (never auto-install silently - corporate machines vary)
$rtk = Get-Command rtk -ErrorAction SilentlyContinue
if ($rtk) {
    Write-Host "[ok] rtk found: $($rtk.Source)"
} else {
    Write-Host "[skip] rtk not found. Install from https://github.com/rtk-ai/rtk, then re-run this script to wire the hook." -ForegroundColor Yellow
}

# 2. Agents - copy only if missing or identical; warn (never clobber) if different
$agentsSrc = Join-Path $here "agents"
$agentsDst = Join-Path $ClaudeDir "agents"
New-Item -ItemType Directory -Force -Path $agentsDst | Out-Null

Get-ChildItem $agentsSrc -Filter *.md | ForEach-Object {
    $dstPath = Join-Path $agentsDst $_.Name
    if (-not (Test-Path $dstPath)) {
        Copy-Item $_.FullName $dstPath
        Write-Host "[add] agents/$($_.Name)"
    } elseif ((Get-Content $dstPath -Raw) -eq (Get-Content $_.FullName -Raw)) {
        Write-Host "[ok] agents/$($_.Name) already up to date"
    } else {
        Write-Host "[warn] agents/$($_.Name) exists and differs from template - left untouched. Compare manually:" -ForegroundColor Yellow
        Write-Host "       template: $($_.FullName)"
        Write-Host "       existing: $dstPath"
    }
}

# 3. settings.json - merge, don't overwrite unrelated keys
$settingsPath = Join-Path $ClaudeDir "settings.json"
$patch = Get-Content (Join-Path $here "settings.patch.json") -Raw | ConvertFrom-Json

if (Test-Path $settingsPath) {
    $settings = Get-Content $settingsPath -Raw | ConvertFrom-Json
} else {
    $settings = [PSCustomObject]@{}
}

# model
if (-not (Test-HasProp $settings 'model')) {
    $settings | Add-Member -NotePropertyName 'model' -NotePropertyValue $patch.model
    Write-Host "[add] settings.json: model = opusplan"
} elseif ($settings.model -ne $patch.model) {
    Write-Host "[warn] settings.json already has model='$($settings.model)' - left untouched." -ForegroundColor Yellow
}

# permissions.defaultMode
if (-not (Test-HasProp $settings 'permissions')) {
    $settings | Add-Member -NotePropertyName 'permissions' -NotePropertyValue ([PSCustomObject]@{})
}
if (-not (Test-HasProp $settings.permissions 'defaultMode')) {
    $settings.permissions | Add-Member -NotePropertyName 'defaultMode' -NotePropertyValue $patch.permissions.defaultMode
    Write-Host "[add] settings.json: permissions.defaultMode = auto"
} elseif ($settings.permissions.defaultMode -ne $patch.permissions.defaultMode) {
    Write-Host "[warn] settings.json already has permissions.defaultMode='$($settings.permissions.defaultMode)' - left untouched." -ForegroundColor Yellow
}

# hooks.PreToolUse Bash -> rtk hook claude (only if rtk present, dedup)
if ($rtk) {
    if (-not (Test-HasProp $settings 'hooks')) {
        $settings | Add-Member -NotePropertyName 'hooks' -NotePropertyValue ([PSCustomObject]@{})
    }
    if (-not (Test-HasProp $settings.hooks 'PreToolUse')) {
        $settings.hooks | Add-Member -NotePropertyName 'PreToolUse' -NotePropertyValue @()
    }

    $bashEntry = $settings.hooks.PreToolUse | Where-Object { $_.matcher -eq 'Bash' } | Select-Object -First 1
    if (-not $bashEntry) {
        $newEntry = [PSCustomObject]@{
            matcher = 'Bash'
            hooks   = @([PSCustomObject]@{ type = 'command'; command = 'rtk hook claude' })
        }
        $settings.hooks.PreToolUse = @($settings.hooks.PreToolUse) + $newEntry
        Write-Host "[add] settings.json: PreToolUse Bash -> rtk hook claude"
    } else {
        $hasRtk = $bashEntry.hooks | Where-Object { $_.command -eq 'rtk hook claude' }
        if (-not $hasRtk) {
            $bashEntry.hooks = @($bashEntry.hooks) + [PSCustomObject]@{ type = 'command'; command = 'rtk hook claude' }
            Write-Host "[add] settings.json: rtk hook appended to existing Bash matcher"
        } else {
            Write-Host "[ok] settings.json: rtk hook already wired"
        }
    }
}

$settings | ConvertTo-Json -Depth 10 | Set-Content $settingsPath -Encoding utf8
Write-Host "== Done ==" -ForegroundColor Cyan
