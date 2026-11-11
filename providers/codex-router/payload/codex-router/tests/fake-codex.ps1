$model = ''
$lastMessage = ''
for ($i = 0; $i -lt $args.Count; $i++) {
    if ($args[$i] -eq '-m' -and $i + 1 -lt $args.Count) { $model = $args[++$i] }
    elseif ($args[$i] -eq '--output-last-message' -and $i + 1 -lt $args.Count) { $lastMessage = $args[++$i] }
}
if ($env:CODEX_TASK_CODEX_INVOCATIONS) { Add-Content -LiteralPath $env:CODEX_TASK_CODEX_INVOCATIONS -Value $model -Encoding utf8 }

function Write-Success {
    param([string]$Path)
    $report = "STATUS: success`nCHANGED: none`nSUMMARY: fake codex completed`nCHECKS: fake=pass`nRISKS: none`nNEEDS_CLAUDE: none`nNEXT: none"
    if ($Path) { Set-Content -LiteralPath $Path -Value $report -Encoding utf8 } else { Write-Output $report }
    exit 0
}

$scenario = [string]$env:FAKE_CODEX_SCENARIO
$quotaMessage = 'Usage limit reached: codex quota exceeded, try again at 10:00 PM'
if ($scenario -eq 'quota') {
    Write-Output $quotaMessage
    [Console]::Error.WriteLine($quotaMessage)
    exit 1
}
if ($scenario -eq 'failure') {
    [Console]::Error.WriteLine('fake codex execution failed')
    exit 7
}
if ($scenario -eq 'blocked') {
    $report = "STATUS: blocked`nCHANGED: none`nSUMMARY: fake codex blocked`nCHECKS: fake=fail`nRISKS: none`nNEEDS_CLAUDE: one decision`nNEXT: decide"
    Set-Content -LiteralPath $lastMessage -Value $report -Encoding utf8
    exit 0
}
Write-Success -Path $lastMessage
