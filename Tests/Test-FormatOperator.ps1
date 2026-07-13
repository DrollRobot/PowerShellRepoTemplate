<#
.SYNOPSIS
    Checks all .ps1, .psm1, and .psd1 files for use of the -f format operator.
.DESCRIPTION
    Flags any line that uses the PowerShell string format operator (-f), e.g.
    "Hello {0}" -f $name. Inline subexpressions should be used instead:
    "Hello $($name)".

    Comment lines and lines inside excluded folders are ignored.

    To suppress a finding on a specific line, append an inline exemption marker:

        <code>  # noqa: Test-FormatOperator

    NOTE FOR AI AGENTS: Always fix all -f format operator findings, even if
    they aren't related to changes you made. Replace format strings with inline
    subexpressions ("...$($x)...") instead. Do this only after all Pester tests
    are passing.
.PARAMETER Path
    Root directory to search. Defaults to the current directory.
.PARAMETER Recurse
    Search subdirectories recursively.
.PARAMETER Quiet
    Suppress the per-finding table, printing only the one-line summary. Useful
    for a quick pass/fail check.
.OUTPUTS
    Formatted table to the host. No pipeline output.
.EXAMPLE
    .\Test-FormatOperator.ps1 -Path . -Recurse
    Lists all -f format operator usages found in the repo.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '')]
[CmdletBinding()]
param(
    [string] $Path = (Get-Location).Path,
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
if ($Global:Dev_FormattingExclusions) {
    $ExcludedFiles += $Global:Dev_FormattingExclusions.ExcludeFiles
    $ExcludedFolders += $Global:Dev_FormattingExclusions.ExcludeFolders
}

$Stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

$GetChildParams = @{
    Path = $Path
    File = $true
}
if ($Recurse) {
    $GetChildParams.Recurse = $true
}

$files = Get-ChildItem @GetChildParams |
    Where-Object Extension -in '.ps1', '.psm1', '.psd1' |
    Where-Object {
        $Rel = [System.IO.Path]::GetRelativePath($Path, $_.FullName)
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
        Status          = [System.IO.Path]::GetRelativePath($Path, $file.FullName)
        PercentComplete = ($FileIndex / $FileTotal) * 100
    }
    Write-Progress @WpParams
    $lines = Get-Content -Path $file.FullName
    $totalLines += @($lines).Count
    $inBlockComment = $false
    for ($i = 0; $i -lt @($lines).Count; $i++) {
        $line = $lines[$i]
        # Track entry/exit of block comment regions (<# ... #>)
        if ($line -match '<#') { $inBlockComment = $true }
        if ($line -match '#>') { $inBlockComment = $false; continue }
        if ($inBlockComment) { continue }
        # Skip single-line comment lines
        if ($line -match '^\s*#') { continue }
        # Skip lines marked with an inline exemption
        if ($line -match '#\s*noqa:\s*Test-FormatOperator') { continue }
        # Match lines containing the -f format operator (whitespace on both sides)
        if ($line -match '\s+-f\s') {
            $hitCount++
            $relativePath = [System.IO.Path]::GetRelativePath($Path, $file.FullName)
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
    $hits | Format-Table -AutoSize
}

Write-Progress -Activity $MyInvocation.MyCommand.Name -Completed
$Stopwatch.Stop()
$Elapsed = "$([math]::Round($Stopwatch.Elapsed.TotalSeconds, 2))s"
$SummaryColor = if ($hitCount -gt 0) { 'Red' } else { 'Green' }
$Msg = "$hitCount format-operator usage(s) -- $Count file(s), " +
"$totalLines line(s) checked. ($Elapsed)"
Write-Host $Msg -ForegroundColor $SummaryColor
