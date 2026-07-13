#Requires -Version 7.5

<#
.SYNOPSIS
    Project-specific test setup, dot-sourced by Tests.ps1.

.DESCRIPTION
    Tests.ps1 dot-sources this hook (when present) after the module is imported
    and before the test sections run, passing the $TestContext hashtable
    (ModuleName, RepoRoot, PesterTestsFolder, the bound parameters, and
    OnlineHandled). Because it is dot-sourced, anything it sets -- variables or
    globals -- is visible to the test sections and to PostTests.ps1.

    Keep per-project test configuration here so the orchestrator (Tests.ps1) and
    the generic checks (Tests\*.ps1) stay identical across repos. Two uses:

      * PSScriptAnalyzer config consumed by Tests\Test-PSSA.ps1
        ($Global:Dev_PSSAConfig), below.
      * Online setup (auth, a live session) that your Online-tagged Pester tests
        need. A hook that fully owns the Online run sets
        $TestContext.OnlineHandled = $true to suppress the generic Online run.

    A throw here aborts the run; Tests.ps1 still runs PostTests.ps1 for cleanup.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- PSScriptAnalyzer config (consumed by Tests\Test-PSSA.ps1) ---------------
# Test-PSSA.ps1 already handles the generic cases: the source manifest's
# FunctionsToExport = '*', and Write-Host under Build\, Tests\, Scripts\, and
# Source\Private\Lib\. Add only this project's specifics here; they are merged
# on top of those defaults.
$Global:Dev_PSSAConfig = @{
    # The module's user-output wrapper(s), allowed to use positional parameters
    # (PSAvoidUsingPositionalParameters). 'Write-Trace' is already allowed.
    # FIXME: add your module's wrapper, e.g. 'Write-XYZ'.
    CommandAllowList    = @()

    # Bespoke per-file suppressions for findings that cannot be suppressed in
    # source and where a global rule would be too broad. Key: path relative to
    # the repo root. Value: rule names to suppress. Example:
    #   'Source\Private\Lib\Format-Tree\Format-Tree.ps1' = @('PSAvoidUsingPositionalParameters')
    PerFileSuppressions = @{}

    # Extra per-path suppressions (relative path prefix -> rule names), merged
    # on top of Test-PSSA.ps1's defaults.
    PerPathSuppressions = @{}
}

# --- Online setup (optional) -------------------------------------------------
# If your Online-tagged tests need a live session, establish it here. If this
# hook runs the Online tests itself, set $TestContext.OnlineHandled = $true so
# the orchestrator skips its generic Online run.
# if ('Online' -in $TestContext.Test) {
#     # ... connect, then optionally drive Invoke-Pester and set OnlineHandled.
# }
