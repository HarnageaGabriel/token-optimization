[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Repo,

    [string]$Base = 'main',

    [string]$TestCmd
)

$ErrorActionPreference = 'Stop'

function Add-SourceLines {
    param(
        [System.Collections.Generic.List[string]]$Target,
        [object[]]$Source,
        [int]$Maximum
    )

    $items = @($Source)
    foreach ($item in $items | Select-Object -First $Maximum) {
        [void]$Target.Add([string]$item)
    }
    if ($items.Count -gt $Maximum) {
        [void]$Target.Add("... {0} more lines omitted" -f ($items.Count - $Maximum))
    }
}

function Get-RiskyRules {
    return [ordered]@{
        auth = '(?i)auth'
        secret = '(?i)secret'
        token = '(?i)token'
        password = '(?i)password'
        crypt = '(?i)crypt'
        migration = '(?i)migration'
        schema = '(?i)schema'
        sql = '(?i)\.sql$'
        permission = '(?i)permission'
        iam = '(?i)iam'
        workflow = '(?i)\.github/workflows'
        dockerfile = '(?i)Dockerfile'
        deploy = '(?i)deploy'
        terraform = '(?i)terraform'
        helm = '(?i)helm'
        package = '(?i)package(-lock)?\.json$'
        requirements = '(?i)requirements'
        go_mod = '(?i)go\.mod$'
        public_api = '(?i)public[ _-]?api'
    }
}

function Test-IsTestPath {
    param([string]$Path)

    return $Path -match '(?i)(^|/)(tests?|specs?|__tests__)(/|$)' -or
        $Path -match '(?i)\.(test|spec)\.[^/]+$' -or
        $Path -match '(?i)(^|[-_.])(test|spec)([-_.]|$)[^/]*\.[^/]+$'
}

function Get-DiffHunks {
    param(
        [string]$Repository,
        [string]$RevisionRange,
        [string]$Path
    )

    $hunks = [System.Collections.Generic.List[string]]::new()
    $collecting = $false
    $output = @(& git -C $Repository diff --unified=3 $RevisionRange -- $Path 2>$null)
    foreach ($line in $output) {
        $text = [string]$line
        if ($text -match '^diff --git ') {
            $collecting = $false
            continue
        }
        if ($text -match '^@@') { $collecting = $true }
        if ($collecting) { [void]$hunks.Add($text) }
    }
    return $hunks
}

$lines = [System.Collections.Generic.List[string]]::new()

try {
    $repoPath = (Resolve-Path -LiteralPath $Repo).Path
    if (-not (Test-Path -LiteralPath (Join-Path $repoPath '.git'))) {
        throw "Not a git repository: $repoPath"
    }

    $revisionRange = "$Base...HEAD"
    $stat = @(& git -C $repoPath diff --stat $revisionRange 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "git diff --stat failed: $Base" }

    $changedFiles = @(& git -C $repoPath diff --name-only $revisionRange 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "git diff --name-only failed: $Base" }
    $changedFiles = @($changedFiles | ForEach-Object { [string]$_ })

    $trackedFiles = @(& git -C $repoPath ls-files 2>&1)
    if ($LASTEXITCODE -ne 0) { throw 'git ls-files failed' }
    $trackedFiles = @($trackedFiles | ForEach-Object { [string]$_ })

    $diffLines = @(& git -C $repoPath diff $revisionRange 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "git diff failed: $Base" }
    $diffLines = @($diffLines | ForEach-Object { [string]$_ })

    $addedLines = 0
    $removedLines = 0
    $secretPatterns = [ordered]@{
        AKIA = '\bAKIA[0-9A-Z]{16}\b'
        PRIVATE_KEY = '-----BEGIN [A-Z ]*PRIVATE KEY-----'
        SK = '(?i)\bsk-[A-Za-z0-9_-]{8,}\b'
        GHP = '(?i)\bghp_[A-Za-z0-9]{20,}\b'
        PASSWORD_ASSIGN = '(?i)\bpassword\s*='
    }
    $secretCounts = [ordered]@{}
    foreach ($name in $secretPatterns.Keys) { $secretCounts[$name] = 0 }

    foreach ($line in $diffLines) {
        if ($line.StartsWith('+') -and -not $line.StartsWith('+++')) {
            $addedLines++
            foreach ($name in $secretPatterns.Keys) {
                if ($line -match $secretPatterns[$name]) { $secretCounts[$name]++ }
            }
        } elseif ($line.StartsWith('-') -and -not $line.StartsWith('---')) {
            $removedLines++
        }
    }

    $riskRules = Get-RiskyRules
    $riskyFiles = [System.Collections.Generic.List[object]]::new()
    foreach ($path in $changedFiles) {
        $riskMatches = @($riskRules.Keys | Where-Object { $path -match $riskRules[$_] })
        if ($riskMatches.Count -gt 0) {
            [void]$riskyFiles.Add([pscustomobject]@{
                Path = $path
                Matches = ($riskMatches -join ',')
            })
        }
    }

    $testLines = [System.Collections.Generic.List[string]]::new()
    $testsExist = [bool]($trackedFiles | Where-Object { Test-IsTestPath $_ })
    if ([string]::IsNullOrWhiteSpace($TestCmd)) {
        [void]$testLines.Add('TEST=NOT_REQUESTED')
    } elseif (-not $testsExist) {
        [void]$testLines.Add('TEST=SKIP_NO_TESTS')
    } else {
        $testOutput = @()
        $testExitCode = 0
        try {
            $pwshPath = (Get-Process -Id $PID).Path
            $testOutput = @(& $pwshPath -NoLogo -NoProfile -NonInteractive -Command $TestCmd 2>&1 |
                ForEach-Object { [string]$_ })
            $testExitCode = $LASTEXITCODE
        } catch {
            $testOutput = @([string]$_)
            $testExitCode = 1
        }

        if ($testExitCode -eq 0) {
            [void]$testLines.Add('TEST=PASS')
        } else {
            [void]$testLines.Add('TEST=FAIL')
            Add-SourceLines -Target $testLines -Source $testOutput -Maximum 15
        }
    }

    $tail = [System.Collections.Generic.List[string]]::new()
    [void]$tail.Add("LINE_COUNTS=added:$addedLines removed:$removedLines")
    $secretHits = @($secretCounts.GetEnumerator() | Where-Object { $_.Value -gt 0 })
    if ($secretHits.Count -eq 0) {
        [void]$tail.Add('SECRET_HITS=0')
    } else {
        $secretSummary = @($secretHits | ForEach-Object { '{0}:{1}' -f $_.Key, $_.Value }) -join ' '
        $secretTotal = ($secretHits | Measure-Object -Property Value -Sum).Sum
        [void]$tail.Add("SECRET_HITS=$secretTotal $secretSummary")
    }
    foreach ($line in $testLines) { [void]$tail.Add($line) }

    [void]$lines.Add("REPO=$repoPath")
    [void]$lines.Add("BASE=$Base")
    [void]$lines.Add('DIFF STAT')
    Add-SourceLines -Target $lines -Source $stat -Maximum 10
    [void]$lines.Add("FILES CHANGED=$($changedFiles.Count)")
    Add-SourceLines -Target $lines -Source $changedFiles -Maximum 20
    [void]$lines.Add("RISKY FILES=$($riskyFiles.Count)")
    Add-SourceLines -Target $lines -Source @($riskyFiles | ForEach-Object { '{0} [{1}]' -f $_.Path, $_.Matches }) -Maximum 8

    $hunkBudget = 119 - $lines.Count - $tail.Count - 2
    if ($hunkBudget -lt 0) { $hunkBudget = 0 }
    $hunksPrinted = 0
    $hunksTruncated = $false
    $displayedRisks = @($riskyFiles | Select-Object -First 8)

    for ($riskIndex = 0; $riskIndex -lt $displayedRisks.Count; $riskIndex++) {
        if ($hunkBudget -le 0) {
            $hunksTruncated = $true
            break
        }

        $hunks = @(Get-DiffHunks -Repository $repoPath -RevisionRange $revisionRange -Path $displayedRisks[$riskIndex].Path)
        $remainingRisks = $displayedRisks.Count - $riskIndex
        $fileBudget = [Math]::Min(60, [Math]::Max(1, [Math]::Floor($hunkBudget / $remainingRisks)))
        $fileCount = 0

        foreach ($hunkLine in $hunks) {
            if ($fileCount -ge $fileBudget -or $hunksPrinted -ge $hunkBudget) {
                $hunksTruncated = $true
                break
            }
            [void]$lines.Add($hunkLine)
            $fileCount++
            $hunksPrinted++
        }
        if ($hunks.Count -eq 0 -and $hunksPrinted -lt $hunkBudget) {
            [void]$lines.Add('NO_DIFF_HUNKS')
            $hunksPrinted++
        } elseif ($hunks.Count -gt $fileCount) {
            $hunksTruncated = $true
        }
    }

    if ($hunksTruncated) {
        [void]$lines.Add('... risky hunks truncated to keep this digest under 120 lines')
    }
    foreach ($line in $tail) { [void]$lines.Add($line) }

    if ($lines.Count + 1 -gt 119) {
        throw "Internal digest cap exceeded: $($lines.Count + 1)"
    }
    [void]$lines.Add("DIGEST_LINES=$($lines.Count + 1)")
} catch {
    $lines.Clear()
    [void]$lines.Add("ERROR=$($_.Exception.Message -replace '\r?\n', ' ')")
    [void]$lines.Add('DIGEST_LINES=2')
}

$lines
