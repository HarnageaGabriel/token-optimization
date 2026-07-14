<#
Bootstraps GitHub Copilot Chat (VS Code) token-efficiency config. Idempotent.
Scope is deliberately smaller than the claude-code provider: Copilot's
per-repo instructions file (.github/copilot-instructions.md) is NOT global
like ~/.claude, so this only sets the global VS Code setting that makes
Copilot pick that file up, plus ships a template to copy into a project.
It never writes into a project's .github/ folder on your behalf - that's
a per-repo decision you make, not something a global bootstrap should do.
#>

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

function Test-HasProp($obj, $name) {
    return $null -ne $obj -and ($obj.PSObject.Properties.Name -contains $name)
}

Write-Host "== Copilot (VS Code) bootstrap ==" -ForegroundColor Cyan

# 1. VS Code CLI check
$code = Get-Command code -ErrorAction SilentlyContinue
if ($code) {
    Write-Host "[ok] VS Code CLI found: $($code.Source)"
} else {
    Write-Host "[skip] VS Code CLI ('code') not on PATH. Install VS Code first, then re-run." -ForegroundColor Yellow
}

# 2. Copilot Chat extension - check only, never auto-download on a corporate machine
if ($code) {
    $extensions = code --list-extensions 2>&1 | Out-String
    if ($extensions -match 'GitHub\.copilot-chat') {
        Write-Host "[ok] GitHub Copilot Chat extension installed"
    } else {
        Write-Host "[skip] GitHub Copilot Chat extension not installed. Install manually (or: code --install-extension GitHub.copilot-chat), then sign in - auth can't be automated." -ForegroundColor Yellow
    }
}

# 3. Global VS Code setting: pick up .github/copilot-instructions.md per repo
$vscodeUserDir = Join-Path $env:APPDATA "Code\User"
$settingsPath = Join-Path $vscodeUserDir "settings.json"
New-Item -ItemType Directory -Force -Path $vscodeUserDir | Out-Null

if (Test-Path $settingsPath) {
    $settings = Get-Content $settingsPath -Raw | ConvertFrom-Json
} else {
    $settings = [PSCustomObject]@{}
}

$key = 'github.copilot.chat.codeGeneration.useInstructionFiles'
if (-not (Test-HasProp $settings $key)) {
    $settings | Add-Member -NotePropertyName $key -NotePropertyValue $true
    Write-Host "[add] VS Code setting: $key = true"
} elseif ($settings.$key -ne $true) {
    Write-Host "[warn] VS Code setting '$key' already set to '$($settings.$key)' - left untouched." -ForegroundColor Yellow
} else {
    Write-Host "[ok] VS Code setting: $key already true"
}

$settings | ConvertTo-Json -Depth 10 | Set-Content $settingsPath -Encoding utf8

Write-Host "[info] Template at $here\copilot-instructions.md - copy it to <project>\.github\copilot-instructions.md per repo you want it in." -ForegroundColor Cyan
Write-Host "== Done ==" -ForegroundColor Cyan
