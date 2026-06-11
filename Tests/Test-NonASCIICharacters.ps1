<#
.SYNOPSIS
    Checks all .ps1, .psm1, and .psd1 files in a directory for non-ASCII characters.
.DESCRIPTION
    To suppress a finding on a specific line, append an inline exemption marker:

        <code>  # noqa: Test-NonASCIICharacters
.PARAMETER Path
    Root directory to search. Defaults to the current directory.
.PARAMETER Recurse
    Search subdirectories recursively.
.PARAMETER ExemptCharacters
    Array of specific non-ASCII characters to ignore. Matches are suppressed when
    the offending character is in this list.
.PARAMETER Quiet
    Suppress the per-finding table and the AI-agent remediation note, printing
    only the one-line summary. Useful for a quick pass/fail check.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '')]
[CmdletBinding()]
param(
    [string] $Path = (Get-Location).Path,
    [switch] $Recurse,
    [char[]] $ExemptCharacters = @(),
    [switch] $Quiet
)

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
        (-not ($ExcludedFolders | Where-Object { $Rel -like "$_\*" -or $Rel -like "*\$_\*" }))
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
    $nonAsciiMatches = $lines | Select-String -Pattern '[^\x00-\x7F]' | Where-Object {
        $line = $_.Line
        $line -notmatch '#\s*noqa:\s*Test-NonASCIICharacters' -and
        @($line.ToCharArray() |
                Where-Object { [int]$_ -gt 0x7F -and $_ -notin $ExemptCharacters }).Count -gt 0
        }
        if ($nonAsciiMatches) {
            $hitCount += @($nonAsciiMatches).Count
            foreach ($match in $nonAsciiMatches) {
                $relativePath = [System.IO.Path]::GetRelativePath($Path, $file.FullName)
                $hits.Add([PSCustomObject]@{
                        File       = $relativePath
                        LineNumber = $match.LineNumber
                        Line       = $match.Line.Trim()
                    })
            }
        }
    }

    $Count = @($files).Count

    if ($hitCount -gt 0 -and -not $Quiet) {
        $Msg = 'NOTE FOR AI AGENTS: Always fix all non-ASCII character findings, ' +
        "even if they aren't related to changes you made. " +
        'Replace non-ASCII characters with plain ASCII equivalents. ' +
        'Do this only after all Pester tests are passing.'
        Write-Host $Msg -ForegroundColor DarkGray
        $hits | Format-Table -AutoSize
    }

    Write-Progress -Activity $MyInvocation.MyCommand.Name -Completed
    $Stopwatch.Stop()
    $Elapsed = "$([math]::Round($Stopwatch.Elapsed.TotalSeconds, 2))s"
    $SummaryColor = if ($hitCount -gt 0) { 'Red' } else { 'Green' }
    $Msg = "$hitCount non-ASCII occurrence(s) -- $Count file(s), " +
    "$totalLines line(s) checked. ($Elapsed)"
    Write-Host $Msg -ForegroundColor $SummaryColor
