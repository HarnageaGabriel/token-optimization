[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Task,
    [string]$Repo = '.',
    [ValidateSet('codex')][string]$Provider = 'codex',
    [ValidateSet('execute', 'investigate', 'review')][string]$Mode = 'execute',
    [string]$Type = 'other',
    [string]$PromptFile,
    [ValidateSet('auto', 'fast', 'std', 'deep', 'max')][string]$Tier = 'auto',
    [string]$Model,
    [ValidateSet('minimal', 'low', 'medium', 'high', 'xhigh', 'max', 'ultra')][string]$Effort,
    [switch]$Escalate,
    [switch]$DryRun,
    [switch]$NoLog
)

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

function Test-HasProp($Object, [string]$Name) {
    return $null -ne $Object -and ($Object.PSObject.Properties.Name -contains $Name)
}

function Write-Blocked {
    param([string]$Summary, [string]$FailureClass, [string]$Next = 'retry after resolving the Codex failure')
    Write-Output 'STATUS: blocked'
    Write-Output 'CHANGED: unknown'
    Write-Output "SUMMARY: $Summary"
    Write-Output 'CHECKS: codex-task=fail'
    Write-Output 'RISKS: Codex may have changed the worktree before failing; inspect git diff'
    Write-Output 'NEEDS_CLAUDE: use [claude-fallback] only while the codex-unavailable marker is fresh'
    Write-Output "NEXT: $Next"
    Write-Output "FAILURE_CLASS: $FailureClass"
}

function Set-CodexUnavailableMarker {
    param([string]$Reason)
    [void](New-Item -ItemType Directory -Path $script:stateDir -Force)
    Set-Content -LiteralPath $script:unavailableMarker -Value @([DateTimeOffset]::UtcNow.ToString('o'), $Reason) -Encoding utf8
}

function Get-TaskStatus {
    param([string]$Text)
    if ($Text -match '(?m)^STATUS:\s*(success|partial|blocked)\s*$') { return $Matches[1] }
    return 'partial'
}

$resolvedRepo = Resolve-Path -LiteralPath $Repo -ErrorAction SilentlyContinue
if (-not $resolvedRepo -or -not (Test-Path -LiteralPath $resolvedRepo.Path -PathType Container)) {
    Write-Blocked -Summary "Repository directory not found: $Repo" -FailureClass 'invalid_repo' -Next 'provide an existing directory with -Repo'
    exit 1
}
$repoPath = $resolvedRepo.Path
$stateDir = if ($env:CODEX_TASK_STATE_DIR) { $env:CODEX_TASK_STATE_DIR } else { Join-Path (Get-ClaudeHome) '.codex-drift' }
$unavailableMarker = Join-Path $stateDir 'codex-unavailable'
$codexExecutable = if ($env:CODEX_TASK_CODEX_EXE) { $env:CODEX_TASK_CODEX_EXE } else { 'codex' }

if ($PromptFile) {
    if (-not (Test-Path -LiteralPath $PromptFile -PathType Leaf)) { throw "Prompt file not found: $PromptFile" }
    $taskText = Get-Content -Raw -LiteralPath $PromptFile
} elseif ($Task) {
    $taskText = $Task
    if ($Task -match "\r?\n" -or $Task.Length -gt 600) { [Console]::Error.WriteLine('[codex-task] Long inline tasks are fragile; prefer -PromptFile.') }
} elseif ($DryRun) {
    $taskText = '<dry-run>'
} elseif ([Console]::IsInputRedirected) {
    $taskText = [Console]::In.ReadToEnd()
} else {
    throw 'Provide -Task, -PromptFile, or piped stdin.'
}
if ([string]::IsNullOrWhiteSpace($taskText)) { throw 'Task is empty.' }

$resolvedTier = $Tier
if ($resolvedTier -eq 'auto') {
    if ($Mode -in @('investigate', 'review')) { $resolvedTier = 'deep' }
    elseif ($Type -in @('chore', 'docs', 'format', 'rename', 'search', 'lint', 'run', 'other')) { $resolvedTier = 'fast' }
    elseif ($Type -in @('debug', 'migration', 'architecture', 'security', 'perf')) { $resolvedTier = 'deep' }
    else { $resolvedTier = 'std' }
}
if ($Escalate) {
    $resolvedTier = switch ($resolvedTier) { 'fast' { 'std' } 'std' { 'deep' } 'deep' { 'max' } default { 'max' } }
}
$modelCatalogPath = Join-Path $PSScriptRoot 'model-catalog.json'
$defaultTierSettings = @{
    fast = @{ Model = 'gpt-reserve'; Effort = 'low' }
    std  = @{ Model = 'gpt-5.6-sol'; Effort = 'medium' }
    deep = @{ Model = 'gpt-5.6-sol'; Effort = 'high' }
    max  = @{ Model = 'gpt-6-astra'; Effort = 'high' }
}
$tierSettings = $defaultTierSettings.Clone()
if (Test-Path -LiteralPath $modelCatalogPath -PathType Leaf) {
    try {
        $catalog = Get-Content -Raw -LiteralPath $modelCatalogPath | ConvertFrom-Json
        foreach ($tier in $defaultTierSettings.Keys) {
            $tierConfig = $catalog.$tier
            $tierModel = if ($tierConfig -and (Test-HasProp $tierConfig 'model')) { [string]$tierConfig.model } else { $null }
            $tierEffort = if ($tierConfig -and (Test-HasProp $tierConfig 'effort')) { [string]$tierConfig.effort } else { $null }
            $tierSettings[$tier] = @{ Model = $tierModel; Effort = $tierEffort }
        }
    } catch {
        Write-Warning "Could not read model catalog '$modelCatalogPath': $($_.Exception.Message)"
    }
}
$tierSetting = $tierSettings[$resolvedTier]
if ([string]::IsNullOrWhiteSpace([string]$tierSetting.Model)) {
    $tierSetting.Model = $defaultTierSettings[$resolvedTier].Model
    Write-Output "CATALOG_WARNING: $resolvedTier model missing in model-catalog.json; using default `"$($tierSetting.Model)`""
}
if ([string]::IsNullOrWhiteSpace([string]$tierSetting.Effort)) {
    $tierSetting.Effort = $defaultTierSettings[$resolvedTier].Effort
    Write-Output "CATALOG_WARNING: $resolvedTier effort missing in model-catalog.json; using default `"$($tierSetting.Effort)`""
}
if ([string]::IsNullOrWhiteSpace($Model)) { $Model = $tierSetting.Model }
if ([string]::IsNullOrWhiteSpace($Effort)) { $Effort = $tierSetting.Effort }
$tierLabel = if ($Escalate) { "$resolvedTier(escalated)" } else { $resolvedTier }
$sandbox = if ($Mode -eq 'execute') { 'workspace-write' } else { 'read-only' }

$policy = if ($Mode -eq 'execute') {
@'
Work autonomously: inspect the repo, make one narrow coherent change set, verify it, and inspect the final diff. Preserve unrelated user changes. Git reads are allowed; do not commit, push, reset, checkout, clean, deploy, touch production, expose secrets, or use irreversible commands. Run the exact VERIFY commands and git status --porcelain, quoting their output. Stop for unsafe actions or genuine product decisions.
'@
} else {
@'
Work strictly read-only. Inspect the repo and run only non-mutating checks. Do not edit, create, delete, commit, push, deploy, touch production, expose secrets, or use irreversible commands.
'@
}
$compact = @'
Return the compact block FIRST, exactly these keys:
STATUS: success|partial|blocked
CHANGED: paths or none
SUMMARY: at most 3 short lines
CHECKS: command=pass|fail; one essential error line only
RISKS: none or short bullets
NEEDS_CLAUDE: none or one decision
NEXT: none or one action
'@
$fullTail = if ($Mode -eq 'execute') { '' } else { "`nThen a line containing only === FULL === followed by detailed findings with file:line evidence." }
$prompt = "MODE: $Mode`nTASK_TYPE: $Type`n`n$policy`n`n$taskText`n`n$compact$fullTail"

$lastMessage = Join-Path ([IO.Path]::GetTempPath()) ('codex-task-' + [guid]::NewGuid().ToString('N') + '.txt')
$arguments = @('exec', '-m', $Model, '--color', 'never', '--sandbox', $sandbox, '-c', "model_reasoning_effort=`"$Effort`"", '--cd', $repoPath, '--skip-git-repo-check', '--output-last-message', $lastMessage, '-')
Write-Output "MODEL: $Model provider=codex tier=$tierLabel effort=$Effort mode=$Mode sandbox=$sandbox"
if ($DryRun) {
    Write-Output "COMMAND: $codexExecutable $($arguments -join ' ')"
    Write-Output 'STATUS: success'
    Write-Output 'CHANGED: none'
    Write-Output 'SUMMARY: dry run only; Codex was not invoked'
    Write-Output 'CHECKS: invocation-plan=pass'
    Write-Output 'RISKS: none'
    Write-Output 'NEEDS_CLAUDE: none'
    Write-Output 'NEXT: remove -DryRun to execute'
    exit 0
}

$startedAt = Get-Date
$tail = New-Object 'System.Collections.Generic.Queue[string]'
$exitCode = 1
try {
    $prompt | & $codexExecutable @arguments 2>&1 | ForEach-Object {
        $line = [string]$_
        if ($tail.Count -ge 40) { [void]$tail.Dequeue() }
        $tail.Enqueue($line)
    }
    $exitCode = $LASTEXITCODE
} catch {
    if ($tail.Count -ge 40) { [void]$tail.Dequeue() }
    $tail.Enqueue($_.Exception.Message)
}
$duration = ((Get-Date) - $startedAt).TotalSeconds
$tailText = $tail -join "`n"
if ($exitCode -ne 0) {
    $failureClass = if ($tailText -match '(?i)usage limit|rate[ -]?limit|quota|\b429\b|too many requests') { 'quota_or_rate_limit' } else { 'exec_failed' }
    $summary = if ($failureClass -eq 'quota_or_rate_limit') { 'Codex quota or rate limit is unavailable' } else { "Codex execution failed with exit code $exitCode" }
    Set-CodexUnavailableMarker "$failureClass`: $summary"
    Write-Blocked -Summary $summary -FailureClass $failureClass
    if ($tailText) { Write-Output "ERROR_TAIL:`n$tailText" }
    Write-Output ('DURATION_S: {0:0.###}' -f $duration)
    Write-Output 'REPORT_FILE: n/a'
    if (-not $NoLog) { & (Join-Path $PSScriptRoot 'route-log.ps1') -Type $Type -Route codex -Result blocked -Model $Model 2>&1 | Where-Object { $_ -match 'ROUTING_REVIEW_DUE' } }
    Remove-Item -LiteralPath $lastMessage -Force -ErrorAction SilentlyContinue
    exit 1
}

$report = if (Test-Path -LiteralPath $lastMessage -PathType Leaf) { Get-Content -Raw -LiteralPath $lastMessage } else { '' }
if ([string]::IsNullOrWhiteSpace($report)) {
    $report = "STATUS: partial`nCHANGED: unknown`nSUMMARY: Codex exited successfully but returned no compact report`nCHECKS: compact-report=fail`nRISKS: inspect git diff`nNEEDS_CLAUDE: review the worktree`nNEXT: inspect the diff"
}
$status = Get-TaskStatus $report
if ($status -eq 'blocked') { Set-CodexUnavailableMarker 'blocked: Codex reported a blocked task' }
else { Remove-Item -LiteralPath $unavailableMarker -Force -ErrorAction SilentlyContinue }

$reportPath = Join-Path ([IO.Path]::GetTempPath()) ('codex-task-report-' + [guid]::NewGuid().ToString('N') + '.txt')
[IO.File]::WriteAllText($reportPath, $report, (New-Object Text.UTF8Encoding($false)))
$compactReport = ($report -split '(?m)^=== FULL ===\s*$')[0].Trim()
Write-Output $compactReport
Write-Output ('DURATION_S: {0:0.###}' -f $duration)
Write-Output "REPORT_FILE: $reportPath"
if (-not $NoLog) {
    & (Join-Path $PSScriptRoot 'route-log.ps1') -Type $Type -Route codex -Result $status -Model $Model 2>&1 |
        Where-Object { $_ -match 'ROUTING_REVIEW_DUE' } | ForEach-Object { Write-Output $_ }
}
Remove-Item -LiteralPath $lastMessage -Force -ErrorAction SilentlyContinue
if ($status -eq 'blocked') { exit 1 }
exit 0
