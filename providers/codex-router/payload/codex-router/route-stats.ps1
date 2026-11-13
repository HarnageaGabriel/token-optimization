[CmdletBinding()]
param([ValidateRange(10, 200)][int]$Last = 40)

$logPath = Join-Path $PSScriptRoot 'routing.tsv'
if (-not (Test-Path -LiteralPath $logPath)) { 'No routing samples.'; exit 0 }
$rows = Import-Csv -Delimiter "`t" -LiteralPath $logPath | Select-Object -Last $Last | ForEach-Object {
    if ([string]::IsNullOrWhiteSpace($_.model)) { $_ | Add-Member -NotePropertyName model -NotePropertyValue '-' -Force }
    $_
}
if (-not $rows) { 'No routing samples.'; exit 0 }

$rows | Group-Object type, route, model | ForEach-Object {
    $items = $_.Group
    [pscustomobject]@{
        Type = $items[0].type
        Route = $items[0].route
        Model = $items[0].model
        N = $items.Count
        Success = @($items | Where-Object result -eq 'success').Count
        Retried = @($items | Where-Object { [int]$_.retries -gt 0 }).Count
        Takeover = @($items | Where-Object claude_intervention -eq 'takeover').Count
        InputTokens = [long](($items | ForEach-Object { [long]$_.input_tokens } | Measure-Object -Sum).Sum)
        OutputTokens = [long](($items | ForEach-Object { [long]$_.output_tokens } | Measure-Object -Sum).Sum)
        Uncached = [long](($items | ForEach-Object { [long]$_.input_tokens - [long]$_.cached_tokens } | Measure-Object -Sum).Sum)
    }
} | Sort-Object Type, Route, Model | Format-Table -AutoSize
