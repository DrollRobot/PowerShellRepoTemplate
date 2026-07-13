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
.PARAMETER Quiet
    Suppress the per-finding table and the AI-agent remediation note, printing
    only the one-line summary. Useful for a quick pass/fail check.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '')]
[CmdletBinding()]
param(
    [string] $Path = (Get-Location).Path,
    [switch] $Recurse,
    [int] $MaxLength = 100,
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

if (Test-Path $Path -PathType Leaf) {
    $files = @(Get-Item $Path)
    $BaseDir = Split-Path $Path
} else {
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
    $BaseDir = $Path
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
    "no longer than ${MaxLength} characters. DO NOT USE BACKTICK CONTINUATIONS. " +
    'Address line length issues only after all Pester tests are passing.'
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
