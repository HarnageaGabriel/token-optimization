<#
One-command bootstrap for AI coding agent config.
Usage: .\init.ps1 [-Provider claude-code]
#>

param(
    [ValidateSet("claude-code", "copilot")]
    [string]$Provider = "claude-code"
)

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$providerScript = Join-Path $here "providers\$Provider\install.ps1"

if (-not (Test-Path $providerScript)) {
    Write-Error "No provider '$Provider' found under providers\. Available: $((Get-ChildItem (Join-Path $here 'providers') -Directory).Name -join ', ')"
    exit 1
}

& $providerScript
