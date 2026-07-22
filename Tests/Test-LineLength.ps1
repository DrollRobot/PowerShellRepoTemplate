<#
.SYNOPSIS
    Checks .ps1, .psm1, and .psd1 files for lines exceeding a maximum length.
    Pass a file path to check a single file, or a folder path to check all matching files.
.DESCRIPTION
    To suppress a long-line finding on a specific line, append an inline exemption marker:

        <code>  # noqa: Test-LineLength
.PARAMETER Path
    File or directory to check. Defaults to the current directory.
.PARAMETER Recurse
    Search subdirectories recursively (only applies when Path is a directory).
.PARAMETER MaxLength
    Maximum allowed line length in characters. Defaults to 100.
.PARAMETER AnyType
    Check files of any extension instead of only .ps1, .psm1, and .psd1.
.PARAMETER Quiet
    Suppress the per-finding table and the AI-agent remediation note, printing
    only the one-line summary. Useful for a quick pass/fail check.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '')]
[CmdletBinding()]
param(
    [Parameter(Position = 0, ValueFromRemainingArguments)]
    [string[]] $Path = @((Get-Location).Path),
    [switch] $Recurse,
    [int] $MaxLength = 100,
    [switch] $AnyType,
    [switch] $Quiet
)

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseDeclaredVarsMoreThanAssignments', 'ScriptVersion')]
$ScriptVersion = '1.0.4'

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
$BaseDir = $ScanBase

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
if (-not $AnyType) {
    $files = @($files | Where-Object Extension -in '.ps1', '.psm1', '.psd1')
}
$files = @($files |
    Where-Object {
        $Rel = [System.IO.Path]::GetRelativePath($ScanBase, $_.FullName)
        (-not ($ExcludedFiles -contains $Rel)) -and
        (-not ($ExcludedFolders | Where-Object { $Rel -like "$_\*" }))
    })
$hitCount = 0
$totalLines = 0
$hits = [System.Collections.Generic.List[PSCustomObject]]::new()

$FileTotal = @($files).Count
$FileIndex = 0
foreach ($file in $files) {
    $FileIndex++
    $WpParams = @{
        Activity        = $MyInvocation.MyCommand.Name
        Status          = [System.IO.Path]::GetRelativePath($BaseDir, $file.FullName)
        PercentComplete = ($FileIndex / $FileTotal) * 100
    }
    Write-Progress @WpParams
    $lines = @(Get-Content -Path $file.FullName)
    $totalLines += $lines.Count
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($null -eq $lines[$i]) { continue }
        # Skip lines marked with an inline exemption
        if ($lines[$i] -match '#\s*noqa:\s*Test-LineLength') { continue }
        $length = $lines[$i].Length
        if ($length -gt $MaxLength) {
            $hitCount++
            $relativePath = [System.IO.Path]::GetRelativePath($BaseDir, $file.FullName)
            $hits.Add([PSCustomObject]@{
                    File       = $relativePath
                    LineNumber = $i + 1
                    Length     = $length
                })
        }
    }
}

$Count = @($files).Count

if ($hitCount -gt 0 -and -not $Quiet) {
    $Msg = 'NOTE FOR AI AGENTS: Always fix all line length findings, ' +
    "even if they aren't related to changes you made. Lines should be " +
    "no longer than ${MaxLength} characters. DO NOT USE BACKTICK CONTINUATIONS."
    Write-Host $Msg -ForegroundColor DarkGray
    $hits | Format-Table -AutoSize
}

Write-Progress -Activity $MyInvocation.MyCommand.Name -Completed
$Stopwatch.Stop()
$Elapsed = "$([math]::Round($Stopwatch.Elapsed.TotalSeconds, 2))s"
$SummaryColor = if ($hitCount -gt 0) { 'Red' } else { 'Green' }
$Msg = "$hitCount long line(s) (>${MaxLength} chars) -- $Count file(s), " +
"$totalLines line(s) checked. ($Elapsed)"
Write-Host $Msg -ForegroundColor $SummaryColor

# Throw (not exit) so pre-commit/CI still see a nonzero process exit via an
# uncaught error, without risking closing an interactive host if this script
# is ever dot-sourced or run directly at a prompt instead of through Tests.ps1.
if ($hitCount -gt 0) { throw $Msg }
