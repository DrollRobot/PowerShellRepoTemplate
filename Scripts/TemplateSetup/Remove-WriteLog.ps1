<#
.SYNOPSIS
    Remove the Write-Log logging library when a project declines it.

.DESCRIPTION
    The template ships an internal logging library under
    Source\Private\Lib\Write-log\ -- Set-LogConfig, Write-Log, Get-LogMessage,
    Get-LogConfig, Write-LogEvent, Write-LogEventBuffer and
    Register-LogEventSource -- wired in by a Set-LogConfig block in
    Source\Suffix.ps1 that creates the logging context at module load, and
    covered by five Pester files. A project that logs some other way wants none
    of it, so this step removes all three parts together:

      - the Source\Private\Lib\Write-log\ folder,
      - the Set-LogConfig block in Source\Suffix.ps1 -- left in place, the
        module would fail to import, calling a command that no longer exists,
      - the Tests\Pester\ files covering the library.

    The Suffix.ps1 edit matches the block exactly as the template ships it: the
    '# Configure internal logging' comment run, the $logConfigParams table and
    the Set-LogConfig call. If Suffix.ps1 still calls Set-LogConfig once that
    block is gone -- the block was edited, or another call was added -- the
    step reports it and returns $false rather than leave a module that cannot
    import; remove the call by hand and re-run.

    Runnable on its own, or dot-sourced and called as one step of
    Scripts\TemplateSetup\Setup-NewProject.ps1, which runs it when
    [Features].WriteLog in Scripts\setup.psd1 is false. When dot-sourced it
    only defines the Remove-WriteLog function; the parameter-driven body below
    runs solely on a direct invocation.

.PARAMETER RepoRoot
    Repository root to clean. Defaults to the repo two levels above this script
    (Scripts\TemplateSetup\ -> repo root).

.PARAMETER DryRun
    List what would be deleted and edited, without changing anything.

.EXAMPLE
    .\Scripts\TemplateSetup\Remove-WriteLog.ps1 -DryRun

    Lists the library folder, the test files, and the Suffix.ps1 block that
    would go.

.EXAMPLE
    .\Scripts\TemplateSetup\Remove-WriteLog.ps1

    Removes the library, its tests, and its Suffix.ps1 wiring.

.OUTPUTS
    Progress text to the host. Returns $true from Remove-WriteLog on success,
    $false when Source\Suffix.ps1 still calls Set-LogConfig afterward.

.NOTES
    Idempotent: once the library is gone, a re-run finds nothing to delete and
    leaves Suffix.ps1 alone.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '')]
[CmdletBinding()]
param(
    [Parameter()]
    [string] $RepoRoot,

    [Parameter()]
    [switch] $DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path -Path $PSScriptRoot -ChildPath '_Common.ps1')

# Repo-relative paths this step works from. The library and the tests covering
# it are template-owned, so the set is fixed rather than discovered. Kept as
# script-scope constants so the functions and their tests agree on them.
$script:WriteLogLibDir = 'Source\Private\Lib\Write-log'
$script:WriteLogTestFiles = @(
    'Tests\Pester\Get-LogConfig.Tests.ps1'
    'Tests\Pester\Get-LogMessage.Tests.ps1'
    'Tests\Pester\Set-LogConfig.Tests.ps1'
    'Tests\Pester\Write-Log.Tests.ps1'
    'Tests\Pester\Write-LogEventBuffer.Tests.ps1'
)
$script:SuffixRel = 'Source\Suffix.ps1'

# The Set-LogConfig block exactly as Source\Suffix.ps1 ships it: the comment run
# that opens with '# Configure internal logging', the $logConfigParams table, the
# splatted call, and one trailing blank line. Kept in lock-step with that file.
$script:SuffixLogBlock = '(?ms)^# Configure internal logging[^\n]*\r?\n(?:#[^\n]*\r?\n)*' +
'\$logConfigParams = @\{\r?\n.*?^\}\r?\nSet-LogConfig @logConfigParams[ \t]*\r?\n' +
'(?:[ \t]*\r?\n)?'

# Any remaining Set-LogConfig call at the start of a line (comments excluded).
$script:SuffixLogCall = '(?m)^[ \t]*Set-LogConfig\b'

# Every repo-relative path this step would delete, in a fixed order: the
# library folder first, then each test file that exists. Returns an empty array
# once they are all gone.
function Get-WriteLogTarget {
    param([Parameter(Mandatory)][string]$RepoRoot)
    $Targets = [System.Collections.Generic.List[string]]::new()
    foreach ($Rel in (@($script:WriteLogLibDir) + $script:WriteLogTestFiles)) {
        $Full = Join-Path -Path $RepoRoot -ChildPath $Rel
        if (Test-Path -LiteralPath $Full) { $Targets.Add($Rel) }
    }
    return $Targets.ToArray()
}

# Preview, then (unless -DryRun) delete the targets and drop the Suffix.ps1
# block. Returns $true so the orchestrator's step runner treats it as a
# success, $false when Suffix.ps1 would still call Set-LogConfig afterward.
function Remove-WriteLog {
    # This whole setup framework previews with its own -DryRun flag instead of the
    # PSScriptAnalyzer-expected -WhatIf/-Confirm (ShouldProcess), matching every sibling step.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '')]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][bool]$DryRun
    )
    $Targets = @(Get-WriteLogTarget -RepoRoot $RepoRoot)

    # Work out the Suffix.ps1 edit up front so the preview and the apply agree,
    # and so a stray call left behind is reported in both modes.
    $SuffixPath = Join-Path -Path $RepoRoot -ChildPath $script:SuffixRel
    $SuffixText = $null
    $SuffixUpdated = $null
    if (Test-Path -LiteralPath $SuffixPath -PathType Leaf) {
        $SuffixText = Get-Content -Path $SuffixPath -Raw
        $SuffixUpdated = $SuffixText -replace $script:SuffixLogBlock, ''
    }
    $DropBlock = $null -ne $SuffixText -and $SuffixUpdated -cne $SuffixText
    $StrayCall = $null -ne $SuffixUpdated -and $SuffixUpdated -match $script:SuffixLogCall

    if ($Targets.Count -eq 0 -and -not $DropBlock -and -not $StrayCall) {
        Write-Info 'Remove Write-Log library' 'nothing to remove'
        return $true
    }

    Write-Info 'Remove Write-Log library' "$($Targets.Count) path(s)"
    foreach ($Rel in $Targets) {
        Write-Host "    $Rel"
    }
    if ($DropBlock) {
        Write-Host "    $($script:SuffixRel): drop the Set-LogConfig block"
    }
    if ($StrayCall) {
        Write-Warn ("  $($script:SuffixRel) calls Set-LogConfig outside the template's block; " +
            'the module cannot import until that call is removed by hand.')
    }
    if ($DryRun) { return $true }

    foreach ($Rel in $Targets) {
        $Full = Join-Path -Path $RepoRoot -ChildPath $Rel
        if (Test-Path -LiteralPath $Full) {
            Remove-Item -LiteralPath $Full -Recurse -Force
        }
    }
    if ($DropBlock) {
        Set-Content -Path $SuffixPath -Value $SuffixUpdated -NoNewline
    }
    if ($StrayCall) { return $false }
    Write-Success '  Write-Log library, its tests, and its Suffix.ps1 wiring removed.'
    return $true
}

# --- direct-invocation body (skipped when dot-sourced) ----------------------

if ($MyInvocation.InvocationName -eq '.') { return }

if (-not $RepoRoot) {
    $RepoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
}

$Applied = Remove-WriteLog -RepoRoot $RepoRoot -DryRun ([bool]$DryRun)
if ($DryRun) {
    Write-Host ''
    Write-Host '  (dry run -- nothing changed)' -ForegroundColor Yellow
}
if (-not $Applied) {
    throw "Remove-WriteLog finished with a problem; see the output above."
}
