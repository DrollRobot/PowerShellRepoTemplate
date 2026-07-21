<#
.SYNOPSIS
    Fill in the GitHub owner/repo placeholders across the repo.

.DESCRIPTION
    Replaces the template's FIXME owner/repo placeholders -- in clone URLs, CI
    badges, the docs-site URL, and config -- with your GitHub username and the
    project name:

        FIXME.github.io/FIXME  ->  <GitHubUser>.github.io/<Name>
        FIXME/FIXME            ->  <GitHubUser>/<Name>

    A blank GitHubUser is a deliberate no-op: the placeholders are left in place
    for you to fill in by hand later, and the FIXME report still lists them.

    Runnable on its own, or dot-sourced and called as one step of
    Scripts\TemplateSetup\Setup-NewProject.ps1. When dot-sourced it only defines
    the Set-GitHubUser function; the parameter-driven body below runs solely on
    a direct invocation.

.PARAMETER RepoRoot
    Repository root to scan. Defaults to the repo two levels above this script
    (Scripts\TemplateSetup\ -> repo root).

.PARAMETER Name
    Project name that replaces the repo half of each placeholder.

.PARAMETER GitHubUser
    GitHub username/org that replaces the owner half. Blank skips the step.

.PARAMETER DryRun
    Preview which files would change without writing anything.

.EXAMPLE
    .\Scripts\TemplateSetup\Set-GitHubUser.ps1 -Name MyModule -GitHubUser octocat -DryRun

    Shows every file whose FIXME owner/repo placeholders would be filled in.

.EXAMPLE
    .\Scripts\TemplateSetup\Set-GitHubUser.ps1 -Name MyModule -GitHubUser octocat

    Fills in octocat/MyModule (and octocat.github.io/MyModule) throughout.

.OUTPUTS
    Progress text to the host. Returns $true from Set-GitHubUser on success.

.NOTES
    Idempotent: once the placeholders are gone, a re-run changes nothing.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '')]
[CmdletBinding()]
param(
    [Parameter()]
    [string] $RepoRoot,

    [Parameter()]
    [string] $Name,

    [Parameter()]
    [AllowEmptyString()]
    [string] $GitHubUser,

    [Parameter()]
    [switch] $DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path -Path $PSScriptRoot -ChildPath '_Common.ps1')

# Fill in the FIXME owner/repo placeholders with $GitHubUser/$Name across every
# text file under $RepoRoot. A blank $GitHubUser is a no-op. Returns $true so
# the orchestrator's step runner treats it as a success.
function Set-GitHubUser {
    # This whole setup framework previews with its own -DryRun flag instead of the
    # PSScriptAnalyzer-expected -WhatIf/-Confirm (ShouldProcess), matching every sibling step.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '')]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][AllowEmptyString()][string]$GitHubUser,
        [Parameter(Mandatory)][bool]$DryRun
    )
    if (-not $GitHubUser) {
        Write-Info 'GitHub user' 'skipped (blank in config)'
        return $true
    }

    # Ordinal .Replace (not -replace) so no placeholder character is treated as
    # a regex metacharacter. The github.io form is replaced first; the two
    # placeholders do not overlap, so order is not load-bearing, only tidy.
    $PagesToken = 'FIXME.github.io/FIXME'
    $OwnerToken = 'FIXME/FIXME'
    $PagesValue = "$GitHubUser.github.io/$Name"
    $OwnerValue = "$GitHubUser/$Name"

    $Changed = @()
    foreach ($File in (Get-TemplateTextFile -RepoRoot $RepoRoot)) {
        $Content = Get-Content -Path $File.FullName -Raw
        $Updated = $Content.Replace($PagesToken, $PagesValue).Replace($OwnerToken, $OwnerValue)
        if ($Updated -ne $Content) {
            $Changed += $File
            if (-not $DryRun) {
                Set-Content -Path $File.FullName -Value $Updated -NoNewline
            }
        }
    }

    Write-Info 'Set GitHub owner/repo' "$GitHubUser/$Name in $($Changed.Count) file(s)"
    foreach ($File in $Changed) {
        $Rel = [System.IO.Path]::GetRelativePath($RepoRoot, $File.FullName)
        Write-Host "    $Rel"
    }
    return $true
}

# --- direct-invocation body (skipped when dot-sourced) ----------------------

if ($MyInvocation.InvocationName -eq '.') { return }

if (-not $RepoRoot) {
    $RepoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
}
if (-not $Name) {
    throw '-Name is required (the project name to substitute for the repo placeholder).'
}

$InvokeParams = @{
    RepoRoot   = $RepoRoot
    Name       = $Name
    GitHubUser = $GitHubUser
    DryRun     = [bool]$DryRun
}
$null = Set-GitHubUser @InvokeParams
if ($DryRun) {
    Write-Host ''
    Write-Host '  (dry run -- nothing changed)' -ForegroundColor Yellow
}
