[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Type,
    [Parameter(Mandatory = $true)][ValidateSet('claude', 'codex')][string]$Route,
    [Parameter(Mandatory = $true)][ValidateSet('success', 'partial', 'blocked')][string]$Result,
    [ValidateRange(0, 9)][int]$Retries = 0,
    [ValidateSet('none', 'review', 'fix', 'takeover', 'clarify')][string]$ClaudeIntervention = 'none',
    [string]$Model,
    [int]$InputTokens,
    [int]$CachedTokens,
    [int]$OutputTokens,
    [int]$Attempt,
    [int]$ChainPosition
)

$logPath = Join-Path $PSScriptRoot 'routing.tsv'
$cleanType = ($Type -replace "[`t`r`n]", ' ').Trim()
$cleanModel = ([string]$Model -replace "[`t`r`n]", ' ').Trim()
$inputTokensText = if ($PSBoundParameters.ContainsKey('InputTokens')) { [string]$InputTokens } else { '' }
$cachedTokensText = if ($PSBoundParameters.ContainsKey('CachedTokens')) { [string]$CachedTokens } else { '' }
$outputTokensText = if ($PSBoundParameters.ContainsKey('OutputTokens')) { [string]$OutputTokens } else { '' }
$attemptText = if ($PSBoundParameters.ContainsKey('Attempt')) { [string]$Attempt } else { '' }
$chainPositionText = if ($PSBoundParameters.ContainsKey('ChainPosition')) { [string]$ChainPosition } else { '' }
if (-not (Test-Path -LiteralPath $logPath)) {
    "utc`ttype`troute`tresult`tretries`tclaude_intervention`tmodel`tinput_tokens`tcached_tokens`toutput_tokens`tattempt`tchain_position" | Set-Content -LiteralPath $logPath -Encoding utf8
} else {
    $bytes = [System.IO.File]::ReadAllBytes($logPath)
    $headerStart = 0
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { $headerStart = 3 }
    $newline = [Array]::IndexOf($bytes, [byte]0x0A, $headerStart)
    if ($newline -lt 0) { $newline = $bytes.Length }
    $headerEnd = $newline
    if ($headerEnd -gt $headerStart -and $bytes[$headerEnd - 1] -eq 0x0D) { $headerEnd-- }
    $header = [System.Text.Encoding]::UTF8.GetString($bytes, $headerStart, $headerEnd - $headerStart)
    $columns = @($header -split "`t")
    $missingColumns = @('model', 'input_tokens', 'cached_tokens', 'output_tokens', 'attempt', 'chain_position') | Where-Object { $columns -notcontains $_ }
    if ($missingColumns.Count -gt 0) {
        $addition = [System.Text.Encoding]::UTF8.GetBytes("`t" + ($missingColumns -join "`t"))
        $updated = New-Object byte[] ($bytes.Length + $addition.Length)
        [Array]::Copy($bytes, 0, $updated, 0, $headerEnd)
        [Array]::Copy($addition, 0, $updated, $headerEnd, $addition.Length)
        [Array]::Copy($bytes, $headerEnd, $updated, $headerEnd + $addition.Length, $bytes.Length - $headerEnd)
        [System.IO.File]::WriteAllBytes($logPath, $updated)
    }
}

$line = "{0}`t{1}`t{2}`t{3}`t{4}`t{5}`t{6}`t{7}`t{8}`t{9}`t{10}`t{11}" -f [DateTime]::UtcNow.ToString('s'), $cleanType, $Route, $Result, $Retries, $ClaudeIntervention, $cleanModel, $inputTokensText, $cachedTokensText, $outputTokensText, $attemptText, $chainPositionText
Add-Content -LiteralPath $logPath -Value $line -Encoding utf8
$count = (Get-Content -LiteralPath $logPath).Count - 1
if ($count -gt 0 -and $count % 20 -eq 0) { "ROUTING_REVIEW_DUE=$count" }
