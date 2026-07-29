<#
.SYNOPSIS
    Delete the ModuleBuilderNotes.md files the template ships under Source\.

.DESCRIPTION
    The template drops a ModuleBuilderNotes.md in Source\ and in each of its
    subfolders (Classes\, Private\, Public\, ScriptsToProcess\, Data\, en-US\).
    They explain what ModuleBuilder does with each folder; once a real project
    starts, they are scaffolding, not content, so setup removes every one of
    them.

    Files are found by name (ModuleBuilderNotes.md), anywhere under the repo
    root, using the same folder exclusions as every other setup step (.git,
    .local, Output, .staging, site), so a stale copy under Output\ is left
    alone -- it is rebuilt anyway.

    Runnable on its own, or dot-sourced and called as one step of
    Scripts\TemplateSetup\Setup-NewProject.ps1. When dot-sourced it only defines
    the Remove-ModuleBuilderNote function; the parameter-driven body below runs
    solely on a direct invocation.

.PARAMETER RepoRoot
    Repository root to scan. Defaults to the repo two levels above this script
    (Scripts\TemplateSetup\ -> repo root).

.PARAMETER DryRun
    Preview which files would be deleted without removing anything.

.EXAMPLE
    .\Scripts\TemplateSetup\Remove-ModuleBuilderNote.ps1 -DryRun

    Lists every ModuleBuilderNotes.md that would be deleted.

.EXAMPLE
    .\Scripts\TemplateSetup\Remove-ModuleBuilderNote.ps1

    Deletes every ModuleBuilderNotes.md under the repo root.

.OUTPUTS
    Progress text to the host. Returns $true from Remove-ModuleBuilderNote on
    success.

.NOTES
    Idempotent: once the notes are gone, a re-run finds nothing and changes
    nothing.
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

# The one file name this step deletes. Kept as a script-scope constant so the
# function and its tests agree on it.
$script:ModuleBuilderNotesName = 'ModuleBuilderNotes.md'

# Delete every ModuleBuilderNotes.md under $RepoRoot. Returns $true so the
# orchestrator's step runner treats it as a success.
function Remove-ModuleBuilderNote {
    # This whole setup framework previews with its own -DryRun flag instead of the
    # PSScriptAnalyzer-expected -WhatIf/-Confirm (ShouldProcess), matching every sibling step.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '')]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][bool]$DryRun
    )
    $Targets = @(Get-TemplateTextFile -RepoRoot $RepoRoot |
            Where-Object { $_.Name -eq $script:ModuleBuilderNotesName })

    Write-Info 'Remove notes' "$($Targets.Count) ModuleBuilderNotes.md file(s)"
    foreach ($File in $Targets) {
        $Rel = [System.IO.Path]::GetRelativePath($RepoRoot, $File.FullName)
        Write-Host "    $Rel"
        if (-not $DryRun) {
            Remove-Item -LiteralPath $File.FullName -Force
        }
    }
    return $true
}

# --- direct-invocation body (skipped when dot-sourced) ----------------------

if ($MyInvocation.InvocationName -eq '.') { return }

if (-not $RepoRoot) {
    $RepoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
}

$null = Remove-ModuleBuilderNote -RepoRoot $RepoRoot -DryRun ([bool]$DryRun)
if ($DryRun) {
    Write-Host ''
    Write-Host '  (dry run -- nothing changed)' -ForegroundColor Yellow
}
