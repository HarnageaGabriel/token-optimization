$ErrorActionPreference = 'Stop'
$providerRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$installer = Join-Path $providerRoot 'codex-router\install.ps1'
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-router-install-' + [guid]::NewGuid().ToString('N'))
$claudeHome = Join-Path $tempRoot '.claude'
$codexHome = Join-Path $tempRoot '.codex'
$passed = 0
$failed = 0
$hostPath = (Get-Process -Id $PID).Path

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function Run-Case([string]$Name, [scriptblock]$Body) {
    try { & $Body; Write-Output "PASS  $Name"; $script:passed++ }
    catch { Write-Output "FAIL  $Name - $($_.Exception.Message)"; $script:failed++ }
}
function Invoke-Installer([string[]]$Extra = @()) {
    $savedPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = @(& $script:hostPath -NoProfile -File $installer -ClaudeHome $claudeHome -CodexHome $codexHome @Extra 2>&1 | ForEach-Object { [string]$_ })
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $savedPreference }
    if ($code -ne 0) { throw "installer exit=$code`n$($output -join "`n")" }
    return ($output -join "`n")
}
function Get-Sha256([string]$Path) {
    $sha = [Security.Cryptography.SHA256]::Create()
    $stream = [IO.File]::OpenRead($Path)
    try { return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '') }
    finally { $stream.Dispose(); $sha.Dispose() }
}
function Get-TreeFingerprint([string]$Root) {
    $lines = foreach ($file in Get-ChildItem -LiteralPath $Root -File -Recurse | Sort-Object FullName) {
        $relative = $file.FullName.Substring($Root.Length).TrimStart('\', '/')
        "$relative`t$(Get-Sha256 $file.FullName)"
    }
    return ($lines -join "`n")
}

try {
    Remove-Item Env:CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue
    [void](New-Item -ItemType Directory -Path $claudeHome,$codexHome -Force)
    Set-Content -LiteralPath (Join-Path $codexHome 'auth.json') -Value '{}' -Encoding ascii
    [IO.File]::WriteAllText((Join-Path $claudeHome 'settings.json'), "{`n  `"unrelated`": `"keep-me`",`n  `"hooks`": {`n    `"PreToolUse`": [{`"matcher`":`"Bash`",`"hooks`":[{`"type`":`"command`",`"command`":`"existing hook`"}]}]`n  }`n}`n", (New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText((Join-Path $claudeHome 'CLAUDE.md'), "user instructions`n", (New-Object Text.UTF8Encoding($false)))

    Run-Case 'dry run writes nothing' {
        $dryClaude = Join-Path $tempRoot 'dry-claude'
        $dryCodex = Join-Path $tempRoot 'dry-codex'
        $output = @(& $script:hostPath -NoProfile -File $installer -ClaudeHome $dryClaude -CodexHome $dryCodex -DryRun 2>&1 | ForEach-Object { [string]$_ }) -join "`n"
        Assert-True ($LASTEXITCODE -eq 0) "dry run failed: $output"
        Assert-True (-not (Test-Path -LiteralPath $dryClaude)) 'dry run created Claude home'
        Assert-True ($output -match 'plan complete; no files written') 'dry-run plan summary missing'
    }

    Run-Case 'relative CLAUDE_CONFIG_DIR resolves to an absolute path' {
        $savedConfigDir = $env:CLAUDE_CONFIG_DIR
        try {
            $env:CLAUDE_CONFIG_DIR = '.claude-relative'
            Push-Location -LiteralPath $tempRoot
            $output = @(& $script:hostPath -NoProfile -File $installer -CodexHome $codexHome -DryRun 2>&1 | ForEach-Object { [string]$_ }) -join "`n"
            Assert-True ($LASTEXITCODE -eq 0) "dry run failed: $output"
            $expected = Join-Path $tempRoot '.claude-relative'
            Assert-True ($output -match [regex]::Escape($expected)) "relative CLAUDE_CONFIG_DIR was not resolved to $expected`nACTUAL:`n$output"
        } finally {
            Pop-Location
            if ($null -eq $savedConfigDir) { Remove-Item Env:CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue }
            else { $env:CLAUDE_CONFIG_DIR = $savedConfigDir }
        }
    }

    Run-Case 'fresh install and verification' {
        $output = Invoke-Installer
        Assert-True ($output -match '\[verify\] PASS') 'installer verification did not pass'
        foreach ($relative in @('codex-router\codex-task.ps1','codex-router\test-router.ps1','hooks\codex-first.ps1','codex-router\.installed.json')) {
            Assert-True (Test-Path -LiteralPath (Join-Path $claudeHome $relative) -PathType Leaf) "missing $relative"
        }
        $settings = Get-Content -Raw -LiteralPath (Join-Path $claudeHome 'settings.json') | ConvertFrom-Json
        Assert-True ($settings.unrelated -eq 'keep-me') 'unrelated settings key changed'
        $commands = @($settings.hooks.PSObject.Properties.Value | ForEach-Object { $_ } | ForEach-Object { $_.hooks } | ForEach-Object { $_.command })
        Assert-True ($commands -contains 'existing hook') 'existing hook was removed'
        Assert-True (@($commands | Where-Object { $_ -match 'codex-(first|gate|priority)|push-review-gate' }).Count -ge 5) 'router hooks were not merged'
        $claudeText = Get-Content -Raw -LiteralPath (Join-Path $claudeHome 'CLAUDE.md')
        Assert-True ($claudeText -match '^user instructions') 'existing CLAUDE.md content changed'
        Assert-True ($claudeText -match '<!-- codex-router:begin -->') 'routing block missing'
    }

    Run-Case 'custom ClaudeHome is honoured end to end' {
        $output = Invoke-Installer
        $settings = Get-Content -Raw -LiteralPath (Join-Path $claudeHome 'settings.json') | ConvertFrom-Json
        $commands = @($settings.hooks.PSObject.Properties.Value | ForEach-Object { $_ } | ForEach-Object { $_.hooks } | ForEach-Object { $_.command })
        $routerCommands = @($commands | Where-Object { $_ -match 'codex-(first|gate|priority)|push-review-gate' })
        Assert-True ($routerCommands.Count -ge 5) 'router hooks were not merged'
        foreach ($cmd in $routerCommands) {
            Assert-True ($cmd -match [regex]::Escape($claudeHome)) "hook command does not point to custom ClaudeHome: $cmd"
        }
        Assert-True ($output -match '\[verify\] PASS') 'router self-test did not pass from custom ClaudeHome'
    }

    Run-Case 'model mapping file is read and edited value takes effect in dry run' {
        $catalogPath = Join-Path $claudeHome 'codex-router\\model-catalog.json'
        Assert-True (Test-Path -LiteralPath $catalogPath -PathType Leaf) 'model-catalog.json was not installed'
        $originalCatalog = Get-Content -Raw -LiteralPath $catalogPath
        $catalog = $originalCatalog | ConvertFrom-Json
        $catalog.std.model = 'custom-std-model-for-test'
        [IO.File]::WriteAllText($catalogPath, ($catalog | ConvertTo-Json -Depth 10), (New-Object Text.UTF8Encoding($false)))
        try {
            $router = Join-Path $claudeHome 'codex-router\\codex-task.ps1'
            $out = @(& $script:hostPath -NoProfile -File $router -Repo $claudeHome -Task 'test' -Type feature -DryRun -NoLog 2>&1 | ForEach-Object { [string]$_ }) -join "`n"
            Assert-True ($out -match 'MODEL: custom-std-model-for-test') "edited model did not take effect in dry run`nACTUAL:`n$out"
        } finally {
            [IO.File]::WriteAllText($catalogPath, $originalCatalog, (New-Object Text.UTF8Encoding($false)))
        }
    }

    Run-Case 'idempotent re-run changes no files' {
        $before = Get-TreeFingerprint $claudeHome
        [void](Invoke-Installer)
        $after = Get-TreeFingerprint $claudeHome
        Assert-True ($before -eq $after) 'second install changed the installed tree'
    }

    Run-Case 'modified owned file produces new payload' {
        $target = Join-Path $claudeHome 'codex-router\codex-task.ps1'
        Add-Content -LiteralPath $target -Value '# user modification' -Encoding ascii
        $modifiedHash = Get-Sha256 $target
        $output = Invoke-Installer
        Assert-True ($output -match 'payload already staged|write payload') 'modified-file preservation was not reported'
        Assert-True ((Get-Sha256 $target) -eq $modifiedHash) 'modified file was overwritten'
        Assert-True (Test-Path -LiteralPath "$target.new" -PathType Leaf) '.new payload was not written'
        $payload = Join-Path $providerRoot 'codex-router\payload\codex-router\codex-task.ps1'
        Assert-True ((Get-Sha256 "$target.new") -eq (Get-Sha256 $payload)) '.new does not match payload'
    }

    Run-Case 'uninstall restores user configuration' {
        [void](Invoke-Installer @('-Uninstall', '-Force'))
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $claudeHome 'codex-router\codex-task.ps1'))) 'owned router file remains'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $claudeHome 'codex-router\codex-task.ps1.new'))) 'owned .new file remains'
        $settings = Get-Content -Raw -LiteralPath (Join-Path $claudeHome 'settings.json') | ConvertFrom-Json
        Assert-True ($settings.unrelated -eq 'keep-me') 'unrelated setting was not preserved'
        $commands = @($settings.hooks.PSObject.Properties.Value | ForEach-Object { $_ } | ForEach-Object { $_.hooks } | ForEach-Object { $_.command })
        Assert-True ($commands.Count -eq 1 -and $commands[0] -eq 'existing hook') 'settings hooks were not restored'
        Assert-True ((Get-Content -Raw -LiteralPath (Join-Path $claudeHome 'CLAUDE.md')) -eq "user instructions`n") 'CLAUDE.md was not restored'
    }
} finally {
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}
Write-Output "SUMMARY passed=$passed failed=$failed"
if ($failed -gt 0) { exit 1 }
