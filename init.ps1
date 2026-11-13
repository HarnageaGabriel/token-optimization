<#
One-command bootstrap for AI coding agent config.
Usage: .\init.ps1 [-Provider claude-code|copilot|codex-router]
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateSet('claude-code', 'copilot', 'codex-router')]
    [string]$Provider = 'claude-code',
    [string]$ClaudeHome,
    [string]$CodexHome,
    [switch]$DryRun,
    [switch]$Force,
    [switch]$Doctor,
    [switch]$FixRtk,
    [switch]$Uninstall
)

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$providerScript = Join-Path $here "providers\$Provider\install.ps1"

if (-not (Test-Path $providerScript)) {
    Write-Error "No provider '$Provider' found under providers\. Available: $((Get-ChildItem (Join-Path $here 'providers') -Directory).Name -join ', ')"
    exit 1
}

if ($Provider -eq 'codex-router') {
    $arguments = @{}
    foreach ($name in @('ClaudeHome', 'CodexHome')) {
        if ($PSBoundParameters.ContainsKey($name)) { $arguments[$name] = $PSBoundParameters[$name] }
    }
    foreach ($name in @('DryRun', 'Force', 'Doctor', 'FixRtk', 'Uninstall')) {
        if ($PSBoundParameters.ContainsKey($name)) { $arguments[$name] = [bool]$PSBoundParameters[$name] }
    }
    if ($WhatIfPreference) { $arguments['WhatIf'] = $true }
    & $providerScript @arguments
} else {
    $routerOnlyArguments = @('ClaudeHome', 'CodexHome', 'DryRun', 'Force', 'Doctor', 'FixRtk', 'Uninstall') |
        Where-Object { $PSBoundParameters.ContainsKey($_) }
    if ($routerOnlyArguments.Count -gt 0 -or $WhatIfPreference) {
        throw "The following options are only supported by -Provider codex-router: $($routerOnlyArguments -join ', ')"
    }
    & $providerScript
}
