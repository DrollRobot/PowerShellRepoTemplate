<#
.SYNOPSIS
    Offer to delete the one-time template-setup scripts and the tests covering them.

.DESCRIPTION
    Everything in Scripts\TemplateSetup\ exists to turn a fresh clone of this
    template into a real project. Once that conversion has run, the folder is
    dead weight in the new project, and so are the Pester files that test it --
    they cover scripts the project no longer ships, so they would fail (or, at
    best, test nothing) after the folder goes.

    This step removes both, together, after asking. It is the last step
    Scripts\TemplateSetup\Setup-NewProject.ps1 runs, and the only one that
    always asks even under a config-driven run: keeping the setup scripts is a
    legitimate choice (re-running a step by hand, or converting a second time
    from the same clone), so nothing here is implied by the config file.

    The test files are found by name, not from a hard-coded list: every
    <Name>.ps1 in Scripts\TemplateSetup\ is paired with
    Tests\Pester\<Name>.Tests.ps1, and the pair is removed when that test file
    exists. A step script added to the folder later is therefore covered with no
    change here. The pairing is driven by the folder's contents, so once
    Scripts\TemplateSetup\ is gone this step finds nothing at all -- an
    interrupted run that deleted the folder but not the tests leaves those test
    files to remove by hand.

    Runnable on its own, or dot-sourced and called as one step of
    Scripts\TemplateSetup\Setup-NewProject.ps1. When dot-sourced it only defines
    the Remove-TemplateSetup function; the parameter-driven body below runs
    solely on a direct invocation.

.PARAMETER RepoRoot
    Repository root to clean. Defaults to the repo two levels above this script
    (Scripts\TemplateSetup\ -> repo root).

.PARAMETER DryRun
    List what would be deleted, without removing anything or prompting.

.PARAMETER Yes
    Skip the confirmation prompt and delete.

.EXAMPLE
    .\Scripts\TemplateSetup\Remove-TemplateSetup.ps1 -DryRun

    Lists the setup folder and every setup test file that would be deleted.

.EXAMPLE
    .\Scripts\TemplateSetup\Remove-TemplateSetup.ps1

    Lists the same targets, then asks once before deleting them.

.OUTPUTS
    Progress text to the host. Returns $true from Remove-TemplateSetup on
    success, including when the user declines.

.NOTES
    Deletes the folder this script itself lives in. That is safe: PowerShell
    reads a script into memory before running it and holds no handle on the
    file afterwards. Run it from the repo root (or anywhere outside
    Scripts\TemplateSetup\), not with that folder as the current directory.

    Idempotent: once the folder is gone, a re-run finds nothing and changes
    nothing.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '')]
[CmdletBinding()]
param(
    [Parameter()]
    [string] $RepoRoot,

    [Parameter()]
    [switch] $DryRun,

    [Parameter()]
    [switch] $Yes
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path -Path $PSScriptRoot -ChildPath '_Common.ps1')

# Repo-relative folders this step works from. Kept as script-scope constants so
# the functions and their tests agree on them.
$script:TemplateSetupDir = 'Scripts\TemplateSetup'
$script:PesterDir = 'Tests\Pester'

# Every repo-relative path this step would delete: each setup test file first,
# then the setup folder itself. Returns an empty array once the folder is gone.
function Get-TemplateSetupTarget {
    param([Parameter(Mandatory)][string]$RepoRoot)
    $SetupDir = Join-Path -Path $RepoRoot -ChildPath $script:TemplateSetupDir
    if (-not (Test-Path -LiteralPath $SetupDir -PathType Container)) { return @() }

    $Targets = [System.Collections.Generic.List[string]]::new()
    foreach ($Step in (Get-ChildItem -Path $SetupDir -Filter '*.ps1' -File)) {
        $TestRelParams = @{
            Path      = $script:PesterDir
            ChildPath = "$($Step.BaseName).Tests.ps1"
        }
        $TestRel = Join-Path @TestRelParams
        $TestFull = Join-Path -Path $RepoRoot -ChildPath $TestRel
        if (Test-Path -LiteralPath $TestFull -PathType Leaf) { $Targets.Add($TestRel) }
    }
    $Targets.Add($script:TemplateSetupDir)
    return $Targets.ToArray()
}

# Preview, then (unless -DryRun) ask once and delete. Returns $true so the
# orchestrator's step runner treats it as a success -- including when the user
# declines, which is an answer, not a failure.
function Remove-TemplateSetup {
    # This whole setup framework previews with its own -DryRun flag instead of the
    # PSScriptAnalyzer-expected -WhatIf/-Confirm (ShouldProcess), matching every sibling step.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '')]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][bool]$DryRun,
        [Parameter()][switch]$AssumeYes
    )
    $Targets = @(Get-TemplateSetupTarget -RepoRoot $RepoRoot)
    if ($Targets.Count -eq 0) {
        Write-Info 'Remove template setup' 'nothing to remove'
        return $true
    }

    Write-Info 'Remove template setup' "$($Targets.Count) path(s)"
    foreach ($Rel in $Targets) {
        Write-Host "    $Rel"
    }
    if ($DryRun) { return $true }

    $Prompt = 'Delete the template-setup scripts and their tests? They are not needed again.'
    if (-not (Confirm-Step -Prompt $Prompt -AssumeYes:$AssumeYes)) {
        Write-Warn '  Kept the template-setup scripts; delete them by hand when you are done.'
        return $true
    }

    foreach ($Rel in $Targets) {
        $Full = Join-Path -Path $RepoRoot -ChildPath $Rel
        if (Test-Path -LiteralPath $Full) {
            Remove-Item -LiteralPath $Full -Recurse -Force
        }
    }
    Write-Success '  Template setup scripts and their tests removed.'
    return $true
}

# --- direct-invocation body (skipped when dot-sourced) ----------------------

if ($MyInvocation.InvocationName -eq '.') { return }

if (-not $RepoRoot) {
    $RepoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
}

$Params = @{
    RepoRoot  = $RepoRoot
    DryRun    = [bool]$DryRun
    AssumeYes = [bool]$Yes
}
$null = Remove-TemplateSetup @Params
if ($DryRun) {
    Write-Host ''
    Write-Host '  (dry run -- nothing changed)' -ForegroundColor Yellow
}
