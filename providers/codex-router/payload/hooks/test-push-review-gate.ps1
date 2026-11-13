$ErrorActionPreference = 'Stop'

$hook = Join-Path $PSScriptRoot 'push-review-gate.ps1'
$hostPath = (Get-Process -Id $PID).Path
$passCount = 0
$failCount = 0

function Invoke-HookCase {
    param([string]$Tool, [string]$Command)
    $payload = @{ tool_name = $Tool; tool_input = @{ command = $Command } } | ConvertTo-Json -Depth 3 -Compress
    $savedPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = $payload | & $script:hostPath -NoProfile -File $script:hook
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $savedPreference }
    return [pscustomobject]@{ Output = [string]($out -join "`n"); ExitCode = $code }
}

function Invoke-HookRaw {
    param([string]$Payload)
    $errFile = Join-Path ([System.IO.Path]::GetTempPath()) ('hook-stderr-' + [guid]::NewGuid().ToString('N') + '.tmp')
    $savedPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = $Payload | & $script:hostPath -NoProfile -File $script:hook 2> $errFile
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $savedPreference }
    $errText = if (Test-Path $errFile) { [string](Get-Content $errFile -Raw) } else { '' }
    Remove-Item $errFile -ErrorAction SilentlyContinue
    return [pscustomobject]@{ Output = [string]($out -join "`n"); StdErr = $errText; ExitCode = $code }
}

function Assert-Case {
    param([string]$Name, [string]$Tool = 'Bash', [string]$Command, [bool]$ExpectFire, [int]$ExpectExit = 0)
    $res = Invoke-HookCase -Tool $Tool -Command $Command
    $fired = -not [string]::IsNullOrWhiteSpace($res.Output)
    $ok = ($fired -eq $ExpectFire) -and ($res.ExitCode -eq $ExpectExit)
    if ($ok) {
        Write-Output ("PASS  {0}" -f $Name)
        $script:passCount++
    } else {
        Write-Output ("FAIL  {0}  (fired={1}, expected fire={2}, exit={3}, expected exit={4})" -f $Name, $fired, $ExpectFire, $res.ExitCode, $ExpectExit)
        $script:failCount++
    }
}

function Assert-RawCase {
    param([string]$Name, [string]$Payload, [int]$ExpectExit = 0, [bool]$ExpectFire = $false, [bool]$ExpectMessage = $false)
    $res = Invoke-HookRaw -Payload $Payload
    $fired = -not [string]::IsNullOrWhiteSpace($res.Output)
    $ok = ($res.ExitCode -eq $ExpectExit) -and ($fired -eq $ExpectFire)
    if ($ExpectMessage) {
        $ok = $ok -and $res.StdErr -match 'push-review-gate: could not verify push command, blocked \(fail-closed\)'
    }
    if ($ok) {
        Write-Output ("PASS  {0}" -f $Name)
        $script:passCount++
    } else {
        Write-Output ("FAIL  {0}  (fired={1}, expected fire={2}, exit={3}, expected exit={4}, stderr=[{5}])" -f $Name, $fired, $ExpectFire, $res.ExitCode, $ExpectExit, $res.StdErr.Trim())
        $script:failCount++
    }
}

# --- must FIRE ---
Assert-Case -Name 'fire: git push origin main' -Command 'git push origin main' -ExpectFire $true
Assert-Case -Name 'fire: cd repo && git push' -Command 'cd repo && git push' -ExpectFire $true
Assert-Case -Name 'fire: git -C repo push -u origin b' -Command 'git -C repo push -u origin b' -ExpectFire $true
Assert-Case -Name 'fire: gh pr create --fill' -Command 'gh pr create --fill' -ExpectFire $true
Assert-Case -Name 'fire: rtk git push' -Command 'rtk git push' -ExpectFire $true
Assert-Case -Name 'fire: echo a; git push --force-with-lease' -Command 'echo a; git push --force-with-lease' -ExpectFire $true

# --- must NOT fire ---
Assert-Case -Name 'nofire: ls' -Command 'ls' -ExpectFire $false
Assert-Case -Name 'nofire: git status' -Command 'git status' -ExpectFire $false
Assert-Case -Name 'nofire: heredoc body mentions git push' -Command "cat > f.txt <<'EOF'`n- git push* deny`nEOF" -ExpectFire $false
Assert-Case -Name 'nofire: echo quoted git push' -Command 'echo "remember to git push later"' -ExpectFire $false
Assert-Case -Name 'nofire: grep quoted git push' -Command "grep -n 'git push' file" -ExpectFire $false
Assert-Case -Name 'nofire: git pushx' -Command 'git pushx' -ExpectFire $false
Assert-Case -Name 'nofire: tool_name Edit' -Tool 'Edit' -Command 'git push' -ExpectFire $false

# --- fail-closed / edge cases ---
Assert-RawCase -Name 'fail-closed: invalid JSON mentions git push' -Payload '{"tool_name":"Bash","cmd":"git push origin main}' -ExpectExit 2 -ExpectFire $false -ExpectMessage $true
Assert-RawCase -Name 'nofire: invalid JSON no push mention' -Payload 'hello' -ExpectExit 0 -ExpectFire $false
Assert-RawCase -Name 'nofire: empty stdin' -Payload '' -ExpectExit 0 -ExpectFire $false
Assert-RawCase -Name 'nofire: tool_input.command is a number' -Payload '{"tool_name":"Bash","tool_input":{"command":123}}' -ExpectExit 0 -ExpectFire $false
Assert-RawCase -Name 'fail-closed: tool_input missing, raw mentions gh pr create' -Payload '{"tool_name":"Bash","args":"gh pr create --fill now"}' -ExpectExit 2 -ExpectFire $false -ExpectMessage $true
Assert-Case -Name 'fire: valid push exits 0 with reminder (exit code)' -Command 'git push origin main' -ExpectFire $true -ExpectExit 0

Write-Output ("SUMMARY: {0} passed, {1} failed" -f $passCount, $failCount)
if ($failCount -gt 0) { exit 1 }
exit 0
