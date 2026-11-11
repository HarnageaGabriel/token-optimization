[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$ClaudeHome,
    [string]$CodexHome,
    [switch]$DryRun,
    [switch]$Force,
    [switch]$Doctor,
    [switch]$FixRtk,
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$payloadRoot = Join-Path $scriptRoot 'payload'
$planOnly = [bool]($DryRun -or $WhatIfPreference)

function Get-UserHome {
    if ($HOME) { return $HOME }
    $profilePath = [Environment]::GetFolderPath('UserProfile')
    if ($profilePath) { return $profilePath }
    throw 'Cannot determine user home directory ($HOME or UserProfile).'
}

function Get-ClaudeHome {
    $configDir = ([string]$env:CLAUDE_CONFIG_DIR).Trim()
    if (-not [string]::IsNullOrWhiteSpace($configDir)) { return [IO.Path]::GetFullPath($configDir) }
    return Join-Path (Get-UserHome) '.claude'
}

if ([string]::IsNullOrWhiteSpace($ClaudeHome)) { $ClaudeHome = Get-ClaudeHome }
if ([string]::IsNullOrWhiteSpace($CodexHome)) { $CodexHome = Join-Path (Get-UserHome) '.codex' }
$routerHome = Join-Path $ClaudeHome 'codex-router'
$hooksHome = Join-Path $ClaudeHome 'hooks'
$statePath = Join-Path $routerHome '.installed.json'
$settingsPath = Join-Path $ClaudeHome 'settings.json'
$claudeMdPath = Join-Path $ClaudeHome 'CLAUDE.md'
$beginMarker = '<!-- codex-router:begin -->'
$endMarker = '<!-- codex-router:end -->'

function Test-HasProp($Object, [string]$Name) {
    return $null -ne $Object -and ($Object.PSObject.Properties.Name -contains $Name)
}

function Get-Hash([string]$Path) {
    $sha = [Security.Cryptography.SHA256]::Create()
    $stream = [IO.File]::OpenRead($Path)
    try { return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '').ToLowerInvariant() }
    finally { $stream.Dispose(); $sha.Dispose() }
}

function Get-TextHash([string]$Text) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    } finally { $sha.Dispose() }
}

function Write-Utf8([string]$Path, [string]$Text) {
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) { [void](New-Item -ItemType Directory -Force -Path $parent) }
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($false)))
}

function Read-State {
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
        return [pscustomobject]@{ version = 1; files = @(); settingsHooks = @(); claudeBlockHash = $null }
    }
    try {
        $state = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json
        if (-not (Test-HasProp $state 'files')) { $state | Add-Member files @() }
        if (-not (Test-HasProp $state 'settingsHooks')) { $state | Add-Member settingsHooks @() }
        if (-not (Test-HasProp $state 'claudeBlockHash')) { $state | Add-Member claudeBlockHash $null }
        return $state
    } catch {
        throw "Cannot read installer state '$statePath': $($_.Exception.Message)"
    }
}

function Get-StateFile($State, [string]$RelativePath) {
    return @($State.files | Where-Object { $_.path -eq $RelativePath } | Select-Object -First 1)[0]
}

function Set-StateFile($State, [string]$RelativePath, [string]$Hash) {
    $existing = Get-StateFile $State $RelativePath
    if ($existing) { $existing.hash = $Hash }
    else { $State.files = @($State.files) + [pscustomobject]@{ path = $RelativePath; hash = $Hash } }
}

function Get-RtkCommand {
    $cmd = Get-Command rtk -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    if ($env:RTK -and (Test-Path -LiteralPath $env:RTK -PathType Leaf)) { return $env:RTK }
    return $null
}

function Find-RtkCandidate {
    $known = @(
        (Join-Path $HOME '.cache\codex-runtimes\tools\rtk.exe'),
        (Join-Path $HOME '.cache\codex-runtimes\tools\rtk'),
        (Join-Path $env:LOCALAPPDATA 'rtk\rtk.exe')
    )
    foreach ($path in $known) { if (Test-Path -LiteralPath $path -PathType Leaf) { return $path } }
    return $null
}

function Invoke-RtkFix {
    if (Get-RtkCommand) { return }
    $candidate = Find-RtkCandidate
    if (-not $candidate) {
        Write-Host '[doctor] rtk not found; install Rust Token Killer: https://github.com/rtk-ai/rtk' -ForegroundColor Yellow
        return
    }
    $targetDir = Join-Path $env:LOCALAPPDATA 'rtk'
    $target = Join-Path $targetDir 'rtk.exe'
    if ($planOnly) {
        Write-Host "[plan] copy rtk from '$candidate' to '$target' and set user RTK=$target"
        return
    }
    [void](New-Item -ItemType Directory -Force -Path $targetDir)
    Copy-Item -LiteralPath $candidate -Destination $target -Force
    [Environment]::SetEnvironmentVariable('RTK', $target, 'User')
    $env:RTK = $target
    Write-Host "[add] copied rtk to $target and set user RTK"
}

function Invoke-Doctor {
    Write-Host '== Codex router doctor ==' -ForegroundColor Cyan
    $requirements = @(
        [pscustomobject]@{ Name = 'pwsh'; Hint = 'Install PowerShell 7: winget install --id Microsoft.PowerShell --source winget' },
        [pscustomobject]@{ Name = 'git'; Hint = 'Install Git: winget install --id Git.Git --source winget' },
        [pscustomobject]@{ Name = 'node'; Hint = 'Install Node.js: winget install --id OpenJS.NodeJS.LTS --source winget' },
        [pscustomobject]@{ Name = 'codex'; Hint = 'Install Codex CLI: npm i -g @openai/codex' },
        [pscustomobject]@{ Name = 'rtk'; Hint = 'Install Rust Token Killer: https://github.com/rtk-ai/rtk' }
    )
    foreach ($item in $requirements) {
        $found = Get-Command $item.Name -ErrorAction SilentlyContinue
        if (-not $found -and $item.Name -eq 'rtk') {
            $rtkPath = Get-RtkCommand
            if ($rtkPath) { Write-Host "[ok] rtk: $rtkPath"; continue }
            $candidate = Find-RtkCandidate
            if ($candidate) {
                Write-Host "[warn] rtk exists at $candidate but is not resolvable. Re-run with -FixRtk to copy it into %LOCALAPPDATA%\rtk and set user RTK." -ForegroundColor Yellow
                continue
            }
        }
        if ($found) { Write-Host "[ok] $($item.Name): $($found.Source)" }
        else { Write-Host "[missing] $($item.Name). $($item.Hint)" -ForegroundColor Yellow }
    }

    $codexAuthenticated = Test-Path -LiteralPath (Join-Path $CodexHome 'auth.json') -PathType Leaf
    $codex = Get-Command codex -ErrorAction SilentlyContinue
    if ($codex -and -not $codexAuthenticated -and -not $planOnly) {
        $loginOutput = & $codex.Source login status 2>&1 | Out-String
        $codexAuthenticated = ($LASTEXITCODE -eq 0 -and $loginOutput -match '(?i)logged in|authenticated')
    }
    if ($codexAuthenticated) { Write-Host '[ok] Codex authentication detected (credentials were not read)' }
    else { Write-Host '[auth] Codex is not logged in. Run: codex login' -ForegroundColor Yellow }

}

function Get-RoutingBlock {
    return @'
<!-- codex-router:begin -->
## Codex router: Codex execution, Claude supervision

Claude is the decision-maker and final reviewer. Delegate implementation work to
`~/.claude/codex-router/codex-task.ps1`: code edits, repository search,
investigation, debugging, and test execution belong there. Give the worker a
bounded prompt with the objective, constraints, exact verification commands,
and the required compact result block. Do not duplicate Codex's search or
re-read unchanged files after a successful result. Codex CLI is the only
execution party; this setup does not route work to other model providers.

Claude should plan and resolve product decisions, then dispatch execution with
`codex-task -Mode execute` (or `investigate` / `review`). Inspect the returned
status, changed paths, checks, risks, and owner decision. Review only the diff
and flagged areas unless the change touches authentication, security,
migrations, data loss, public APIs, or secrets. If a provider fails with quota,
rate limit, or an execution error, `codex-task` writes `codex-unavailable`.
That marker re-opens direct Claude edits and Claude subagents as the only
fallback; subagent descriptions must include `[claude-fallback]`.

Before one push or PR creation, run exactly one neutral Codex review of the
final diff with `-Mode review -Tier deep`, then run `pr-review-digest.ps1` and inspect the digest plus any
flagged hunks. Fix findings through `codex-task`, re-run focused checks, and
repeat the digest. Claude owns the final go/no-go decision. Codex must not
commit, push, reset, clean, rebase, deploy, access production, expose secrets,
or use unrestricted/danger-full-access sandboxes.
<!-- codex-router:end -->
'@
}

function Get-BlockMatch([string]$Text) {
    return [regex]::Match($Text, '(?s)<!-- codex-router:begin -->.*?<!-- codex-router:end -->')
}

function Install-Payload($State) {
    $mappings = @(
        [pscustomobject]@{ source = Join-Path $payloadRoot 'codex-router'; target = $routerHome; prefix = 'codex-router' },
        [pscustomobject]@{ source = Join-Path $payloadRoot 'hooks'; target = $hooksHome; prefix = 'hooks' }
    )
    foreach ($mapping in $mappings) {
        foreach ($source in Get-ChildItem -LiteralPath $mapping.source -Recurse -File) {
            $relative = $source.FullName.Substring($mapping.source.Length).TrimStart('\', '/')
            if ($relative -match '(^|[\\/])(_bak|prompts)([\\/]|$)' -or $source.Name -eq 'routing.tsv') { continue }
            $stateRelative = ($mapping.prefix + '/' + ($relative -replace '\\', '/'))
            $target = Join-Path $mapping.target $relative
            $payloadHash = Get-Hash $source.FullName
            $record = Get-StateFile $State $stateRelative
            $action = 'copy'
            if (Test-Path -LiteralPath $target -PathType Leaf) {
                $targetHash = Get-Hash $target
                if ($targetHash -eq $payloadHash) { $action = 'ok' }
                elseif (($record -and $record.hash -eq $targetHash) -or ($Force -and $record)) { $action = 'update' }
                else { $action = 'new' }
            }

            if ($action -eq 'ok') {
                Write-Host "[ok] $stateRelative"
                if ($record) { Set-StateFile $State $stateRelative $payloadHash }
                continue
            }
            if ($action -eq 'new') {
                $newPath = "$target.new"
                if ((Test-Path -LiteralPath $newPath -PathType Leaf) -and (Get-Hash $newPath) -eq $payloadHash) {
                    Write-Host "[skip] $stateRelative differs; payload already staged as $newPath" -ForegroundColor Yellow
                    Set-StateFile $State "$stateRelative.new" $payloadHash
                } else {
                    Write-Host "[plan] preserve modified $target; write payload to $newPath" -ForegroundColor Yellow
                    if (-not $planOnly) {
                        [void](New-Item -ItemType Directory -Force -Path (Split-Path -Parent $newPath))
                        Copy-Item -LiteralPath $source.FullName -Destination $newPath -Force
                    }
                    Set-StateFile $State "$stateRelative.new" $payloadHash
                }
                continue
            }

            Write-Host "[$(if ($action -eq 'update') { 'update' } else { 'add' })] $stateRelative"
            if (-not $planOnly) {
                [void](New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target))
                Copy-Item -LiteralPath $source.FullName -Destination $target -Force
            }
            Set-StateFile $State $stateRelative $payloadHash
        }
    }
}

function Add-Hook($Settings, $State, [string]$Event, [string]$Matcher, [string]$Command) {
    if (-not (Test-HasProp $Settings 'hooks')) { $Settings | Add-Member hooks ([pscustomobject]@{}) }
    if (-not (Test-HasProp $Settings.hooks $Event)) { $Settings.hooks | Add-Member $Event @() }
    $entries = @($Settings.hooks.$Event)
    $entry = @($entries | Where-Object { [string]$_.matcher -eq $Matcher } | Select-Object -First 1)[0]
    if (-not $entry) {
        $entry = [pscustomobject]@{ matcher = $Matcher; hooks = @() }
        $Settings.hooks.$Event = $entries + $entry
    }
    if (@($entry.hooks | Where-Object { $_.type -eq 'command' -and $_.command -eq $Command }).Count) {
        Write-Host "[ok] settings.json: $Event $Matcher -> $Command"
        return $false
    }
    $entry.hooks = @($entry.hooks) + [pscustomobject]@{ type = 'command'; command = $Command }
    $State.settingsHooks = @($State.settingsHooks) + [pscustomobject]@{ event = $Event; matcher = $Matcher; command = $Command }
    Write-Host "[add] settings.json: $Event $Matcher -> $Command"
    return $true
}

function Install-Settings($State) {
    if (Test-Path -LiteralPath $settingsPath -PathType Leaf) {
        try { $settings = Get-Content -Raw -LiteralPath $settingsPath | ConvertFrom-Json }
        catch { throw "Cannot merge invalid JSON in '$settingsPath': $($_.Exception.Message)" }
    } else { $settings = [pscustomobject]@{} }

    $changed = $false
    $hookCommands = @(
        @('PreToolUse', 'Agent|mcp__ccd_session__spawn_task', (Join-Path $hooksHome 'codex-priority-guard.ps1')),
        @('PreToolUse', 'Edit|Write|MultiEdit|NotebookEdit', (Join-Path $hooksHome 'codex-gate.ps1')),
        @('PreToolUse', 'Bash|PowerShell', (Join-Path $hooksHome 'push-review-gate.ps1')),
        @('UserPromptSubmit', '', (Join-Path $hooksHome 'codex-first.ps1')),
        @('PostToolUse', 'Edit|Write|MultiEdit|NotebookEdit|Bash|PowerShell', (Join-Path $hooksHome 'codex-gate.ps1'))
    )
    foreach ($spec in $hookCommands) {
        $command = 'pwsh -NoProfile -File "' + $spec[2] + '"'
        if (Add-Hook $settings $State $spec[0] $spec[1] $command) { $changed = $true }
    }
    if (Get-RtkCommand) {
        if (Add-Hook $settings $State 'PreToolUse' 'Bash|PowerShell' 'rtk hook claude') { $changed = $true }
    } else { Write-Host '[skip] settings.json: rtk hook not added because rtk is not resolvable' -ForegroundColor Yellow }

    if ($changed -and -not $planOnly) {
        Write-Utf8 $settingsPath (($settings | ConvertTo-Json -Depth 20) + "`n")
    }
}

function Install-ClaudeBlock($State) {
    $block = (Get-RoutingBlock).Trim()
    $blockHash = Get-TextHash $block
    $text = if (Test-Path -LiteralPath $claudeMdPath -PathType Leaf) { Get-Content -Raw -LiteralPath $claudeMdPath } else { '' }
    $match = Get-BlockMatch $text
    if ($match.Success) {
        $currentHash = Get-TextHash $match.Value.Trim()
        if ($currentHash -eq $blockHash) { Write-Host '[ok] CLAUDE.md routing block'; $State.claudeBlockHash = $blockHash; return }
        if ($State.claudeBlockHash -and ($currentHash -eq $State.claudeBlockHash -or $Force)) {
            $updated = $text.Substring(0, $match.Index) + $block + $text.Substring($match.Index + $match.Length)
            Write-Host '[update] CLAUDE.md routing block'
            if (-not $planOnly) { Write-Utf8 $claudeMdPath $updated }
            $State.claudeBlockHash = $blockHash
        } else { Write-Host '[skip] CLAUDE.md routing block differs; left untouched' -ForegroundColor Yellow }
        return
    }
    $separator = if (-not $text) { '' } elseif ($text.EndsWith("`n")) { "`n" } else { "`n`n" }
    Write-Host '[add] CLAUDE.md routing block'
    if (-not $planOnly) { Write-Utf8 $claudeMdPath ($text + $separator + $block + "`n") }
    $State.claudeBlockHash = $blockHash
}

function Remove-Hooks($Settings, $State) {
    $changed = $false
    foreach ($record in @($State.settingsHooks)) {
        if (-not (Test-HasProp $Settings 'hooks') -or -not (Test-HasProp $Settings.hooks $record.event)) { continue }
        $keptEntries = @()
        foreach ($entry in @($Settings.hooks.($record.event))) {
            if ([string]$entry.matcher -eq [string]$record.matcher) {
                $before = @($entry.hooks).Count
                $entry.hooks = @($entry.hooks | Where-Object { -not ($_.type -eq 'command' -and $_.command -eq $record.command) })
                if (@($entry.hooks).Count -ne $before) { $changed = $true; Write-Host "[remove] settings.json: $($record.event) $($record.matcher) -> $($record.command)" }
            }
            if (@($entry.hooks).Count) { $keptEntries += $entry }
        }
        $Settings.hooks.($record.event) = $keptEntries
    }
    if (Test-HasProp $Settings 'hooks') {
        foreach ($eventName in @($Settings.hooks.PSObject.Properties.Name)) {
            if (@($Settings.hooks.$eventName).Count -eq 0) { $Settings.hooks.PSObject.Properties.Remove($eventName) }
        }
        if ($Settings.hooks.PSObject.Properties.Count -eq 0) { $Settings.PSObject.Properties.Remove('hooks') }
    }
    return $changed
}

function Invoke-Uninstall {
    $state = Read-State
    $remaining = @()
    foreach ($record in @($state.files)) {
        $parts = $record.path -split '/', 2
        $base = if ($parts[0] -eq 'hooks') { $hooksHome } else { $routerHome }
        $target = Join-Path $base ($parts[1] -replace '/', '\')
        if (-not (Test-Path -LiteralPath $target -PathType Leaf)) { continue }
        if ((Get-Hash $target) -ne $record.hash -and -not $Force) {
            Write-Host "[skip] modified installer file retained: $target (use -Force to remove)" -ForegroundColor Yellow
            $remaining += $record
            continue
        }
        Write-Host "[remove] $target"
        if (-not $planOnly) { Remove-Item -LiteralPath $target -Force }
    }

    if (Test-Path -LiteralPath $settingsPath -PathType Leaf) {
        $settings = Get-Content -Raw -LiteralPath $settingsPath | ConvertFrom-Json
        if ((Remove-Hooks $settings $state) -and -not $planOnly) {
            if ($settings.PSObject.Properties.Count -eq 0) { Remove-Item -LiteralPath $settingsPath -Force }
            else { Write-Utf8 $settingsPath (($settings | ConvertTo-Json -Depth 20) + "`n") }
        }
    }
    if (Test-Path -LiteralPath $claudeMdPath -PathType Leaf) {
        $text = Get-Content -Raw -LiteralPath $claudeMdPath
        $match = Get-BlockMatch $text
        if ($match.Success) {
            $currentHash = Get-TextHash $match.Value.Trim()
            if ($state.claudeBlockHash -and ($currentHash -eq $state.claudeBlockHash -or $Force)) {
                $updated = ($text.Substring(0, $match.Index) + $text.Substring($match.Index + $match.Length)) -replace '(?s)\s+$', "`n"
                Write-Host '[remove] CLAUDE.md routing block'
                if (-not $planOnly) {
                    if ([string]::IsNullOrWhiteSpace($updated)) { Remove-Item -LiteralPath $claudeMdPath -Force }
                    else { Write-Utf8 $claudeMdPath $updated }
                }
            } else { Write-Host '[skip] modified CLAUDE.md routing block retained (use -Force to remove)' -ForegroundColor Yellow }
        }
    }

    if (-not $planOnly) {
        if ($remaining.Count) {
            $state.files = $remaining
            $state.settingsHooks = @()
            Write-Utf8 $statePath (($state | ConvertTo-Json -Depth 10) + "`n")
        } elseif (Test-Path -LiteralPath $statePath) { Remove-Item -LiteralPath $statePath -Force }
        foreach ($dir in @((Join-Path $routerHome 'tests'), $routerHome, $hooksHome)) {
            if ((Test-Path -LiteralPath $dir -PathType Container) -and -not (Get-ChildItem -LiteralPath $dir -Force | Select-Object -First 1)) { Remove-Item -LiteralPath $dir }
        }
    }
    Write-Host '== Codex router uninstall complete ==' -ForegroundColor Cyan
}

function Invoke-Verification {
    $tests = @(
        (Join-Path $routerHome 'test-router.ps1'),
        (Join-Path $hooksHome 'test-push-review-gate.ps1')
    )
    $hostCommand = Get-Command pwsh -ErrorAction SilentlyContinue
    if (-not $hostCommand) { $hostCommand = Get-Command powershell -ErrorAction SilentlyContinue }
    $failed = 0
    foreach ($test in $tests) {
        if (-not $hostCommand -or -not (Test-Path -LiteralPath $test)) { Write-Host "[verify] FAIL $test (PowerShell host or test missing)" -ForegroundColor Red; $failed++; continue }
        & $hostCommand.Source -NoProfile -File $test
        if ($LASTEXITCODE -eq 0) { Write-Host "[verify] PASS $test" -ForegroundColor Green }
        else { Write-Host "[verify] FAIL $test (exit $LASTEXITCODE)" -ForegroundColor Red; $failed++ }
    }
    if ($failed) { throw "$failed Codex router verification test(s) failed" }
}

if ($FixRtk) { Invoke-RtkFix }
if ($Uninstall) { Invoke-Uninstall; exit 0 }
if ($Doctor -and -not $FixRtk) { Invoke-Doctor; exit 0 }

Write-Host "== Codex router install$(if ($planOnly) { ' plan' }) ==" -ForegroundColor Cyan
$state = Read-State
Install-Payload $state
Install-Settings $state
Install-ClaudeBlock $state
if (-not $planOnly) {
    [void](New-Item -ItemType Directory -Force -Path $routerHome)
    Write-Utf8 $statePath (($state | ConvertTo-Json -Depth 10) + "`n")
    Invoke-Verification
}
Invoke-Doctor
Write-Host "== Codex router $(if ($planOnly) { 'plan complete; no files written' } else { 'installed' }) ==" -ForegroundColor Cyan
