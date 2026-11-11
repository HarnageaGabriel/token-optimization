$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$router = Join-Path $root 'codex-task.ps1'
$fake = Join-Path $root 'tests\fake-codex.ps1'
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-router-test-' + [guid]::NewGuid().ToString('N'))
$repo = Join-Path $tempRoot 'repo'
$state = Join-Path $tempRoot 'state'
$invocations = Join-Path $tempRoot 'invocations.txt'
$passed = 0
$failed = 0

function Assert-Match([string]$Actual, [string]$Pattern, [string]$Message) {
    if ($Actual -notmatch $Pattern) { throw "$Message`nACTUAL:`n$Actual" }
}
function Run-Case([string]$Name, [scriptblock]$Body) {
    try { & $Body; Write-Output "PASS  $Name"; $script:passed++ }
    catch { Write-Output "FAIL  $Name - $($_.Exception.Message)"; $script:failed++ }
}
function Invoke-Router([string]$Scenario, [hashtable]$Extra = @{}) {
    $env:FAKE_CODEX_SCENARIO = $Scenario
    $output = @(& $router -Repo $repo -Task 'offline router test' @Extra 2>&1 | ForEach-Object { [string]$_ })
    $script:lastRouterExit = $LASTEXITCODE
    return ($output -join "`n")
}

try {
    [void](New-Item -ItemType Directory -Path $repo -Force)
    $env:CODEX_TASK_CODEX_EXE = $fake
    $env:CODEX_TASK_CODEX_INVOCATIONS = $invocations
    $env:CODEX_TASK_STATE_DIR = $state

    Run-Case 'PowerShell parser checks' {
        $parseErrors = @()
        foreach ($file in Get-ChildItem -LiteralPath (Split-Path -Parent $root) -Filter '*.ps1' -File -Recurse) {
            $tokens = $null; $errors = $null
            [void][Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
            if ($errors.Count) { $parseErrors += "$($file.FullName): $($errors[0].Message)" }
        }
        if ($parseErrors.Count) { throw ($parseErrors -join '; ') }
    }
    Run-Case 'execute success uses fake Codex and logs route' {
        $out = Invoke-Router 'success' @{ Type = 'feature' }
        if ($script:lastRouterExit -ne 0) { throw "exit=$script:lastRouterExit" }
        Assert-Match $out '(?m)^STATUS: success$' 'success report missing'
        Assert-Match $out 'provider=codex tier=std' 'standard tier was not selected'
        $log = Get-Content -Raw -LiteralPath (Join-Path $root 'routing.tsv')
        Assert-Match $log "`tcodex`tsuccess`t" 'Codex success was not logged'
    }
    Run-Case 'review is read-only and deep by default' {
        $out = Invoke-Router 'success' @{ Mode = 'review'; NoLog = $true }
        Assert-Match $out 'tier=deep effort=high mode=review sandbox=read-only' 'review routing is wrong'
    }
    Run-Case 'escalation raises fast work to standard' {
        $out = Invoke-Router 'success' @{ Type = 'docs'; Escalate = $true; NoLog = $true }
        Assert-Match $out 'tier=std\(escalated\) effort=medium' 'escalated tier is wrong'
    }
    Run-Case 'empty catalog model falls back to default with warning' {
        $catalogPath = Join-Path $root 'model-catalog.json'
        $originalCatalog = Get-Content -Raw -LiteralPath $catalogPath
        try {
            $catalog = $originalCatalog | ConvertFrom-Json
            $catalog.std.model = ''
            [IO.File]::WriteAllText($catalogPath, ($catalog | ConvertTo-Json -Depth 10), (New-Object Text.UTF8Encoding($false)))
            $out = Invoke-Router 'failure' @{ Type = 'feature'; DryRun = $true; NoLog = $true }
            Assert-Match $out 'MODEL: gpt-5\.6-sol ' 'default std model was not used'
            Assert-Match $out '(?m)^CATALOG_WARNING: std model missing in model-catalog\.json; using default "gpt-5\.6-sol"$' 'catalog warning missing'
        } finally {
            [IO.File]::WriteAllText($catalogPath, $originalCatalog, (New-Object Text.UTF8Encoding($false)))
        }
    }
    Run-Case 'dry run invokes no executable' {
        $before = if (Test-Path $invocations) { @(Get-Content $invocations).Count } else { 0 }
        $out = Invoke-Router 'failure' @{ DryRun = $true; NoLog = $true }
        $after = if (Test-Path $invocations) { @(Get-Content $invocations).Count } else { 0 }
        if ($before -ne $after) { throw 'fake Codex was invoked by dry run' }
        Assert-Match $out '(?m)^SUMMARY: dry run only; Codex was not invoked$' 'dry-run report missing'
    }
    Run-Case 'quota writes fallback marker' {
        $out = Invoke-Router 'quota' @{ NoLog = $true }
        if ($script:lastRouterExit -eq 0) { throw 'quota returned success' }
        Assert-Match $out '(?m)^FAILURE_CLASS: quota_or_rate_limit$' 'quota classification missing'
        Assert-Match (Get-Content -Raw -LiteralPath (Join-Path $state 'codex-unavailable')) 'quota_or_rate_limit' 'quota marker reason missing'
    }
    Run-Case 'exec failure writes fallback marker' {
        $out = Invoke-Router 'failure' @{ NoLog = $true }
        Assert-Match $out '(?m)^FAILURE_CLASS: exec_failed$' 'exec classification missing'
        Assert-Match (Get-Content -Raw -LiteralPath (Join-Path $state 'codex-unavailable')) 'exec_failed' 'exec marker reason missing'
    }
    Run-Case 'success clears fallback marker' {
        [void](Invoke-Router 'success' @{ NoLog = $true })
        if (Test-Path -LiteralPath (Join-Path $state 'codex-unavailable')) { throw 'marker was not cleared' }
    }
    Run-Case 'blocked compact report writes fallback marker' {
        $out = Invoke-Router 'blocked' @{ NoLog = $true }
        if ($script:lastRouterExit -eq 0) { throw 'blocked report returned success' }
        Assert-Match $out '(?m)^STATUS: blocked$' 'blocked report missing'
        if (-not (Test-Path -LiteralPath (Join-Path $state 'codex-unavailable'))) { throw 'blocked marker missing' }
    }
    Run-Case 'provider accepts Codex only' {
        $metadata = Get-Command $router
        $validateSet = @($metadata.Parameters['Provider'].Attributes | Where-Object { $_ -is [Management.Automation.ValidateSetAttribute] })[0]
        if (-not $validateSet) { throw 'Provider has no ValidateSet' }
        $values = @($validateSet.ValidValues)
        if ($values.Count -ne 1 -or $values[0] -ne 'codex') { throw "unexpected Provider values: $($values -join ', ')" }
    }
} finally {
    Remove-Item Env:CODEX_TASK_CODEX_EXE,Env:CODEX_TASK_CODEX_INVOCATIONS,Env:CODEX_TASK_STATE_DIR,Env:FAKE_CODEX_SCENARIO -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $root 'routing.tsv') -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}
Write-Output "SUMMARY passed=$passed failed=$failed"
if ($failed -gt 0) { exit 1 }
