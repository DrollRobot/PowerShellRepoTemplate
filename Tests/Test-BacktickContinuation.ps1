<#
.SYNOPSIS
    Checks all .ps1, .psm1, and .psd1 files for backtick line continuations.
.DESCRIPTION
    Flags any line ending with a backtick (`) used as a line continuation
    escape. Splatting or string concatenation should be used instead.
    Here-strings and comment lines are excluded.

    To suppress a finding on a specific line, append an inline exemption marker:

        <code>  # noqa: Test-BacktickContinuation
.PARAMETER Path
    Root directory to search. Defaults to the current directory.
.PARAMETER Recurse
    Search subdirectories recursively.
.PARAMETER Quiet
    Suppress the per-finding table and the AI-agent remediation note, printing
    only the one-line summary. Useful for a quick pass/fail check.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '')]
[CmdletBinding()]
param(
    [string[]] $Path = @((Get-Location).Path),
    [switch] $Recurse,
    [switch] $Quiet
)

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseDeclaredVarsMoreThanAssignments', 'ScriptVersion')]
$ScriptVersion = '1.0.0'

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
    for ($i = 0; $i -lt @($lines).Count; $i++) {
        $line = $lines[$i]
        # Skip comment lines
        if ($line -match '^\s*#') { continue }
        # Skip lines marked with an inline exemption
        if ($line -match '#\s*noqa:\s*Test-BacktickContinuation') { continue }
        # Match lines ending with a backtick (optionally followed by whitespace)
        if ($line -match '`\s*$') {
            $hitCount++
            $relativePath = [System.IO.Path]::GetRelativePath($ScanBase, $file.FullName)
            $hits.Add([PSCustomObject]@{
                    File       = $relativePath
                    LineNumber = $i + 1
                    Line       = $line.TrimStart()
                })
        }
    }
}

$Count = @($files).Count

if ($hitCount -gt 0 -and -not $Quiet) {
    $Msg = 'NOTE FOR AI AGENTS: Always fix all backtick continuation findings, ' +
    "even if they aren't related to changes you made. " +
    'Use splatting or string concatenation instead of backtick continuations. ' +
    'Do this only after all Pester tests are passing.'
    Write-Host $Msg -ForegroundColor DarkGray
    $hits | Format-Table -AutoSize
}

Write-Progress -Activity $MyInvocation.MyCommand.Name -Completed
$Stopwatch.Stop()
$Elapsed = "$([math]::Round($Stopwatch.Elapsed.TotalSeconds, 2))s"
$SummaryColor = if ($hitCount -gt 0) { 'Red' } else { 'Green' }
$Msg = "$hitCount backtick continuation(s) -- $Count file(s), " +
"$totalLines line(s) checked. ($Elapsed)"
Write-Host $Msg -ForegroundColor $SummaryColor

# Nonzero exit so pre-commit and CI can gate on findings.
exit ([int]($hitCount -gt 0))
