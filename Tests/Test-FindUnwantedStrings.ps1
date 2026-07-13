<#
.SYNOPSIS
    Scans all files for unwanted patterns and reports them as a table.
.DESCRIPTION
    Searches each file against an internal list of regex patterns (e.g. FIXME comments,
    Write-Host calls) and outputs a table showing the relative file path, line number,
    matched tag, and the offending line text. Binary file extensions are excluded.

    Matches whose lines also satisfy any entry in the internal exceptions list are silently
    suppressed and counted separately; the exception count is shown in the summary line.

    NOTE FOR AI AGENTS: This output is informational and intended for human review only.
    Do not attempt to address, fix, or remove these findings unless the user explicitly
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
    .\Test-FindUnwantedStrings.ps1 -Path . -Recurse
    Lists all unwanted pattern matches found in the repo.
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

# Internal list of patterns to search for.
# Each entry has a Tag (label shown in output) and a Pattern (case-insensitive regex).
$UnwantedPatterns = @(
    # [PSCustomObject]@{ Tag = 'TODO';       Pattern = '#.*\bTODO\b' }
    # [PSCustomObject]@{ Tag = 'Write-Host'; Pattern = '\bWrite-Host\b' }
)

# Lines whose full text matches any exception pattern are excluded from the results.
# The suppressed count is still shown in the summary.
$ExceptionPatterns = @(
    # '\bSuppressMessageAttribute\b'                   # PSScriptAnalyzer suppression attributes
    # "Write-Host.*-ForegroundColor '?DarkGray'?"      # intentional diagnostic Write-Host calls
)

# Binary extensions excluded from scanning to avoid garbled output or false positives.
$ExcludedExtensions = @(
    '.png', '.jpg', '.jpeg', '.gif', '.bmp', '.ico', '.webp', '.svg',
    '.zip', '.gz', '.tar', '.7z', '.rar',
    '.dll', '.exe', '.pdb', '.bin', '.lib', '.obj',
    '.pdf', '.docx', '.xlsx', '.pptx'
)

# Folder names to exclude from scanning. Any file under a matching folder is skipped.
$ExcludedFolders = @(
    '.local'    # local overrides and personal test files
)

# Root-level files to exclude (relative paths from $Path).
$ExcludedFiles = @()

# Merge exclusions from the test orchestrator when called via Tests.ps1.
if (Get-Variable -Name Dev_FormattingExclusions -Scope Global -ErrorAction SilentlyContinue) {
    $ExcludedFiles += $Global:Dev_FormattingExclusions.ExcludeFiles
    $ExcludedFolders += $Global:Dev_FormattingExclusions.ExcludeFolders
}

if ($UnwantedPatterns.Count -eq 0) {
    Write-Host 'No patterns defined -- skipping.' -ForegroundColor DarkGray
    exit 0
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

$Files = foreach ($Item in $Path) {
    if (Test-Path -LiteralPath $Item -PathType Leaf) {
        Get-Item -LiteralPath $Item
    }
    else {
        $GetChildParams = @{ Path = $Item; File = $true }
        if ($Recurse) { $GetChildParams.Recurse = $true }
        Get-ChildItem @GetChildParams
    }
}
$Files = @($Files |
    Where-Object { $_.Extension -notin $ExcludedExtensions } |
    Where-Object {
        $Rel = [System.IO.Path]::GetRelativePath($ScanBase, $_.FullName)
        (-not ($ExcludedFiles -contains $Rel)) -and
        (-not ($ExcludedFolders | Where-Object { $Rel -like "$_\*" }))
    })

$Hits = [System.Collections.Generic.List[PSCustomObject]]::new()
$ExceptionCount = 0
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
        foreach ($Entry in $UnwantedPatterns) {
            if ($Lines[$i] -match $Entry.Pattern) {
                $IsException = $false
                foreach ($ExPattern in $ExceptionPatterns) {
                    if ($Lines[$i] -match $ExPattern) {
                        $IsException = $true
                        break
                    }
                }
                if ($IsException) {
                    $ExceptionCount++
                    continue
                }
                $RelativePath = [System.IO.Path]::GetRelativePath($BaseDir, $File.FullName)
                $Hits.Add([PSCustomObject]@{
                        File       = $RelativePath
                        LineNumber = $i + 1
                        Tag        = $Entry.Tag
                        Line       = $Lines[$i].Trim()
                    })
            }
        }
    }
}

$FileCount = @($Files).Count

if ($Hits.Count -gt 0 -and -not $Quiet) {
    $Msg = 'NOTE FOR AI AGENTS: Findings from this test should be treated as critical errors for ' +
    'human review and repair. Do not attempt to address, fix, or remove these strings. Simply ' +
    'stop and warn the user.'
    Write-Host $Msg -ForegroundColor DarkGray
    $Hits | Format-Table -AutoSize | Out-Host
}

Write-Progress -Activity $MyInvocation.MyCommand.Name -Completed
$Stopwatch.Stop()
$Elapsed = "$([math]::Round($Stopwatch.Elapsed.TotalSeconds, 2))s"
$SummaryColor = if ($Hits.Count -gt 0) { 'Red' } else { 'Green' }
$Msg = "$($Hits.Count) match(es), $ExceptionCount exception(s) suppressed -- " +
"$FileCount file(s), $TotalLines line(s) checked. ($Elapsed)"
Write-Host $Msg -ForegroundColor $SummaryColor

# Nonzero exit so pre-commit and CI can gate on findings.
exit ([int]($Hits.Count -gt 0))
