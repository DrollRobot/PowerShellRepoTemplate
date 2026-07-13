<#
.SYNOPSIS
    Parses all .ps1, .psm1, and .psd1 files in a directory for syntax errors.
.PARAMETER Path
    Root directory to search. Defaults to the current directory.
.PARAMETER Recurse
    Search subdirectories recursively.
.PARAMETER Quiet
    Suppress the per-file error detail and the AI-agent remediation note,
    printing only the one-line summary. Useful for a quick pass/fail check.
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
if ($Global:Dev_FormattingExclusions) {
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
$errorCount = 0
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
    $totalLines += @(Get-Content -Path $file.FullName).Count
    $parseErrors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile(
        $file.FullName, [ref]$null, [ref]$parseErrors
    )
    if ($parseErrors) {
        $errorCount += @($parseErrors).Count
        $hits.Add([PSCustomObject]@{
                File   = $file.Name
                Errors = $parseErrors
            })
    }
}

$Count = @($files).Count

if ($errorCount -gt 0 -and -not $Quiet) {
    $Msg = 'NOTE FOR AI AGENTS: Always fix all syntax errors below, ' +
    "even if they aren't related to changes you made. " +
    'Do this only after all Pester tests are passing.'
    Write-Host $Msg -ForegroundColor DarkGray
    $hits | Out-Host
}

Write-Progress -Activity $MyInvocation.MyCommand.Name -Completed
$Stopwatch.Stop()
$Elapsed = "$([math]::Round($Stopwatch.Elapsed.TotalSeconds, 2))s"
$SummaryColor = if ($errorCount -gt 0) { 'Red' } else { 'Green' }
$Msg = "$errorCount syntax error(s) -- $Count file(s), $totalLines line(s) checked. ($Elapsed)"
Write-Host $Msg -ForegroundColor $SummaryColor

# Nonzero exit so pre-commit and CI can gate on findings.
exit ([int]($errorCount -gt 0))
