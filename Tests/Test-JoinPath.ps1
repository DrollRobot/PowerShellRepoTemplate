<#
.SYNOPSIS
    Checks all .ps1, .psm1, and .psd1 files for path-building anti-patterns.
.DESCRIPTION
    Enforces three path-building rules:

    1. PathCombine   -- [System.IO.Path]::Combine() must not be used; use Join-Path.
    2. NoNamedParams -- Join-Path must use named -Path / -ChildPath parameters, not positional.
    3. SplatRequired -- Join-Path with 3 or more named parameters must use splatting (@Params).

    Comment lines and lines inside excluded folders are ignored.

    To suppress a false positive on a specific line, append an inline exemption marker:

        <code>  # noqa: Test-JoinPath

    NOTE FOR AI AGENTS: Always fix all path-building findings, even if they are not related
    to changes you made. Do this only after all Pester tests are passing.
    Rule fixes:
      PathCombine   -- Replace [System.IO.Path]::Combine($a, $b) with
                       Join-Path -Path $a -ChildPath $b.
      NoNamedParams -- Replace positional Join-Path $x $y with
                       Join-Path -Path $x -ChildPath $y.
      SplatRequired -- Move 3+ Join-Path parameters into a splatted hashtable
                       and call Join-Path @Params.
.PARAMETER Path
    Root directory to search. Defaults to the current directory.
.PARAMETER Recurse
    Search subdirectories recursively.
.PARAMETER Quiet
    Suppress the per-finding table and the AI-agent remediation note, printing
    only the one-line summary. Useful for a quick pass/fail check.
.OUTPUTS
    Formatted table to the host. No pipeline output.
.EXAMPLE
    .\Test-JoinPath.ps1 -Path . -Recurse
    Lists all path-building anti-patterns found in the repo.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '')]
[CmdletBinding()]
param(
    [Parameter(Position = 0, ValueFromRemainingArguments)]
    [string[]] $Path = @((Get-Location).Path),
    [switch] $Recurse,
    [switch] $Quiet
)

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseDeclaredVarsMoreThanAssignments', 'ScriptVersion')]
$ScriptVersion = '1.0.1'

# Folder names to exclude from scanning. Any file under a matching folder is skipped.
$ExcludedFolders = @(
    # '.local'    # local overrides and personal test files
)

# Root-level files to exclude (relative paths from $Path).
$ExcludedFiles = @()

# Merge exclusions from the test orchestrator when called via Tests.ps1.
if (Get-Variable -Name Dev_FormattingExclusions -Scope Global -ErrorAction SilentlyContinue) {
    $ExcludedFiles += $Global:Dev_FormattingExclusions.ExcludeFiles
    $ExcludedFolders += $Global:Dev_FormattingExclusions.ExcludeFolders
}

$Stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

# Base path for relative-path exclusions and display. Tests.ps1 invokes with a
# single directory (prior behavior); pre-commit invokes with a list of files,
# which has no single base -- fall back to the current directory then.
$ScanBase = if (@($Path).Count -eq 1 -and
    (Test-Path -LiteralPath $Path[0] -PathType Container)) {
    $Path[0]
}
else {
    (Get-Location).Path
}

$files = foreach ($Item in $Path) {
    if (Test-Path -LiteralPath $Item -PathType Leaf) {
        Get-Item -LiteralPath $Item
    }
    else {
        $GetChildParams = @{ Path = $Item; File = $true }
        if ($Recurse) { $GetChildParams.Recurse = $true }
        Get-ChildItem @GetChildParams
    }
}
$files = $files |
    Where-Object Extension -in '.ps1', '.psm1', '.psd1' |
    Where-Object {
        $Rel = [System.IO.Path]::GetRelativePath($ScanBase, $_.FullName)
        (-not ($ExcludedFiles -contains $Rel)) -and
        (-not ($ExcludedFolders | Where-Object { $Rel -like "$_\*" }))
    }

$hitCount = 0
$totalLines = 0
$hits = [System.Collections.Generic.List[PSCustomObject]]::new()

$FileTotal = @($files).Count
$FileIndex = 0
foreach ($file in $files) {
    $FileIndex++
    $WpParams = @{
        Activity        = $MyInvocation.MyCommand.Name
        Status          = [System.IO.Path]::GetRelativePath($ScanBase, $file.FullName)
        PercentComplete = ($FileIndex / $FileTotal) * 100
    }
    Write-Progress @WpParams
    $lines = Get-Content -Path $file.FullName
    $totalLines += @($lines).Count
    $relativePath = [System.IO.Path]::GetRelativePath($ScanBase, $file.FullName)
    $inBlockComment = $false
    for ($i = 0; $i -lt @($lines).Count; $i++) {
        $line = $lines[$i]
        # Track <# ... #> block comments (e.g. comment-based help)
        if (-not $inBlockComment -and $line -match '<#') { $inBlockComment = $true }
        if ($inBlockComment) {
            if ($line -match '#>') { $inBlockComment = $false }
            continue
        }
        # Skip single-line comment lines
        if ($line -match '^\s*#') { continue }

        # Skip lines marked with an inline exemption
        if ($line -match '#\s*noqa:\s*Test-JoinPath') { continue }

        # Rule 1: [System.IO.Path]::Combine() -- use Join-Path instead
        if ($line -match '\[System\.IO\.Path\]::Combine\(') {
            $hitCount++
            $hits.Add([PSCustomObject]@{
                    File       = $relativePath
                    LineNumber = $i + 1
                    Rule       = 'PathCombine'
                    Line       = $line.TrimStart()
                })
            continue
        }

        if ($line -imatch '\bJoin-Path\b') {
            # Rule 2: Join-Path used positionally -- no -Path named parameter and no splatting
            # Use (?<!\w) lookbehind so 'Join-Path' itself does not satisfy the -Path check.
            if ($line -inotmatch '\bJoin-Path\s+@' -and $line -inotmatch '(?<!\w)-Path\b') {
                $hitCount++
                $hits.Add([PSCustomObject]@{
                        File       = $relativePath
                        LineNumber = $i + 1
                        Rule       = 'NoNamedParams'
                        Line       = $line.TrimStart()
                    })
                continue
            }

            # Rule 3: Join-Path with 3+ inline named parameters -- use splatting
            # Detected when -AdditionalChildPath appears on the same line without splatting.
            $hasAcp = $line -imatch '(?<!\w)-AdditionalChildPath\b'
            if ($line -inotmatch '\bJoin-Path\s+@' -and $hasAcp) {
                $hitCount++
                $hits.Add([PSCustomObject]@{
                        File       = $relativePath
                        LineNumber = $i + 1
                        Rule       = 'SplatRequired'
                        Line       = $line.TrimStart()
                    })
            }
        }
    }
}

$Count = @($files).Count

if ($hitCount -gt 0 -and -not $Quiet) {
    $Msg = 'NOTE FOR AI AGENTS: Always fix all path-building findings, even if they are ' +
    "not related to changes you made. " +
    'PathCombine: replace System.IO.Path Combine() with Join-Path. ' + # noqa: Test-JoinPath
    'NoPositionalParams: use -Path / -ChildPath named parameters. ' +
    'SplatRequired: use splatting (@Params) ' +
    'when Join-Path has 3+ parameters. ' + # noqa: Test-JoinPath
    'Address path-building findings only after all Pester tests are passing.'
    Write-Host $Msg -ForegroundColor DarkGray
    $hits | Format-Table -AutoSize
}

Write-Progress -Activity $MyInvocation.MyCommand.Name -Completed
$Stopwatch.Stop()
$Elapsed = "$([math]::Round($Stopwatch.Elapsed.TotalSeconds, 2))s"
$SummaryColor = if ($hitCount -gt 0) { 'Red' } else { 'Green' }
$Msg = "$hitCount path-building violation(s) -- $Count file(s), " +
"$totalLines line(s) checked. ($Elapsed)"
Write-Host $Msg -ForegroundColor $SummaryColor

# Nonzero exit so pre-commit and CI can gate on findings.
exit ([int]($hitCount -gt 0))
