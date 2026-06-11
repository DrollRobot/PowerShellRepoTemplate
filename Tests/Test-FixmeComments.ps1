<#
.SYNOPSIS
    Scans .ps1, .psm1, and .psd1 files for FIXME comments and reports them as a table.
.DESCRIPTION
    Searches each file for lines containing '# FIXME' (case-insensitive) and outputs
    a table showing the relative file path, line number, and the comment text.

    NOTE FOR AI AGENTS: This output is informational and intended for human review only.
    Do not attempt to address, fix, or remove these comments unless the user explicitly
    asks you to do so.
.PARAMETER Path
    File or directory to check. Defaults to the current directory.
.PARAMETER Recurse
    Search subdirectories recursively (only applies when Path is a directory).
.PARAMETER Quiet
    Suppress the per-finding table and the AI-agent note, printing only the
    one-line summary. Useful for a quick pass/fail check.
.OUTPUTS
    Formatted table to the host. No pipeline output.
.EXAMPLE
    .\Test-FixmeComments.ps1 -Path . -Recurse
    Lists all FIXME comments found in the repo.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '')]
[CmdletBinding()]
param(
    [string] $Path = (Get-Location).Path,
    [switch] $Recurse,
    [switch] $Quiet
)

# Folder names to exclude from scanning. Any file under a matching folder is skipped.
$ExcludedFolders = @(
    # '.local'    # local overrides and personal test files
)

# Root-level files to exclude (relative paths from $Path).
$ExcludedFiles = @(
    '.\Tests\Test-FixmeComments.ps1'  # this file
)

# Merge exclusions from the test orchestrator when called via Tests.ps1.
if ($Global:Dev_FormattingExclusions) {
    $ExcludedFiles += $Global:Dev_FormattingExclusions.ExcludeFiles
    $ExcludedFolders += $Global:Dev_FormattingExclusions.ExcludeFolders
}

$Stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

if (Test-Path $Path -PathType Leaf) {
    $Files = @(Get-Item $Path)
    $BaseDir = Split-Path $Path
}
else {
    $GetChildParams = @{
        Path = $Path
        File = $true
    }
    if ($Recurse) {
        $GetChildParams.Recurse = $true
    }
    $Files = Get-ChildItem @GetChildParams |
        Where-Object Extension -in '.ps1', '.psm1', '.psd1' |
        Where-Object {
            $Rel = [System.IO.Path]::GetRelativePath($Path, $_.FullName)
            (-not ($ExcludedFiles -contains $Rel)) -and
            (-not ($ExcludedFolders | Where-Object { $Rel -like "$_\*" -or $Rel -like "*\$_\*" }))
        }
    $BaseDir = $Path
}

$Hits = [System.Collections.Generic.List[PSCustomObject]]::new()
$TotalLines = 0

$FileTotal = @($Files).Count
$FileIndex = 0
foreach ($File in $Files) {
    $FileIndex++
    $WpParams = @{
        Activity        = $MyInvocation.MyCommand.Name
        Status          = [System.IO.Path]::GetRelativePath($BaseDir, $File.FullName)
        PercentComplete = ($FileIndex / $FileTotal) * 100
    }
    Write-Progress @WpParams
    $Lines = Get-Content -Path $File.FullName
    $TotalLines += @($Lines).Count
    for ($i = 0; $i -lt @($Lines).Count; $i++) {
        if ($Lines[$i] -match '#.*FIXME') {
            $RelativePath = [System.IO.Path]::GetRelativePath($BaseDir, $File.FullName)
            $Hits.Add([PSCustomObject]@{
                    File       = $RelativePath
                    LineNumber = $i + 1
                    Comment    = $Lines[$i].Trim()
                })
        }
    }
}

$FileCount = @($Files).Count

if ($Hits.Count -gt 0 -and -not $Quiet) {
    $Msg = 'NOTE FOR AI AGENTS: This output is for human review only. Do not address ' +
    'these items unless the user explicitly asks.'
    Write-Host $Msg -ForegroundColor DarkGray
    $Hits | Format-Table -AutoSize | Out-Host
}

Write-Progress -Activity $MyInvocation.MyCommand.Name -Completed
$Stopwatch.Stop()
$Elapsed = "$([math]::Round($Stopwatch.Elapsed.TotalSeconds, 2))s"
$SummaryColor = if ($Hits.Count -gt 0) { 'Red' } else { 'Green' }
$Msg = "$($Hits.Count) FIXME comment(s) -- $FileCount file(s), " +
"$TotalLines line(s) checked. ($Elapsed)"
Write-Host $Msg -ForegroundColor $SummaryColor
