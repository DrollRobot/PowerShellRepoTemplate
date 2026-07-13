<#
.SYNOPSIS
    Checks all .ps1, .psm1, and .psd1 files for Write-Verbose and Write-Debug calls.
.DESCRIPTION
    Flags any line that calls Write-Verbose or Write-Debug. These are typically
    leftover debugging statements; module functions should use the module's
    user-output wrapper instead (see AGENTS.md).

    Comment lines, block comments, and lines inside excluded folders are ignored.

    To suppress a finding on a specific line, append an inline exemption marker:

        <code>  # noqa: Test-WriteVerboseDebug

    NOTE FOR AI AGENTS: Always remove these findings, even if they aren't related
    to changes you made. Delete the leftover diagnostic statement, or replace
    user-facing output with the module's user-output wrapper. Do this only after
    all Pester tests are passing.
.PARAMETER Path
    File or directory to check. Defaults to the current directory.
.PARAMETER Recurse
    Search subdirectories recursively.
.PARAMETER Quiet
    Suppress the per-finding table and the AI-agent remediation note, printing
    only the one-line summary. Useful for a quick pass/fail check.
.OUTPUTS
    Formatted table to the host. No pipeline output.
.EXAMPLE
    .\Test-WriteVerboseDebug.ps1 -Path . -Recurse
    Lists all Write-Verbose and Write-Debug calls found in the repo.
.EXAMPLE
    .\Test-WriteVerboseDebug.ps1 -Path . -Recurse -Quiet
    Shows only the summary line -- useful for a quick pass/fail check.
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
        if ($line -match '#\s*noqa:\s*Test-WriteVerboseDebug') { continue }
        # Match Write-Verbose / Write-Debug command calls. The capture group names
        # which command matched at runtime, so this file never matches itself.
        if ($line -match '\bWrite-(Verbose|Debug)\b') {
            $hitCount++
            $relativePath = [System.IO.Path]::GetRelativePath($ScanBase, $file.FullName)
            $hits.Add([PSCustomObject]@{
                    File       = $relativePath
                    LineNumber = $i + 1
                    Tag        = "Write-$($Matches[1])"
                    Line       = $line.TrimStart()
                })
        }
    }
}

$Count = @($files).Count

if ($hitCount -gt 0 -and -not $Quiet) {
    $Msg = 'NOTE FOR AI AGENTS: ' +
    'Write-Verbose and Write-Debug calls should be replaced ' + # noqa: Test-WriteVerboseDebug
    'based on the Debug Output instructions in AGENTS.md'
    Write-Host $Msg -ForegroundColor DarkGray
    $hits | Format-Table -AutoSize
}

Write-Progress -Activity $MyInvocation.MyCommand.Name -Completed
$Stopwatch.Stop()
$Elapsed = "$([math]::Round($Stopwatch.Elapsed.TotalSeconds, 2))s"
$SummaryColor = if ($hitCount -gt 0) { 'Red' } else { 'Green' }
$Msg = "$hitCount verbose/debug statement(s) -- $Count file(s), " +
"$totalLines line(s) checked. ($Elapsed)"
Write-Host $Msg -ForegroundColor $SummaryColor

# Nonzero exit so pre-commit and CI can gate on findings.
exit ([int]($hitCount -gt 0))
