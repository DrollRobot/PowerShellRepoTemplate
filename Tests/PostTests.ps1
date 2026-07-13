#Requires -Version 7.5

<#
.SYNOPSIS
    Project-specific test teardown, dot-sourced by Tests.ps1.

.DESCRIPTION
    Tests.ps1 dot-sources this hook (when present) inside a finally block, so it
    always runs -- even if a test section or PreTests.ps1 threw. Use it to undo
    whatever PreTests.ps1 set up for the run: restore overridden config, clear
    environment variables, or tear down a live session.

    Read saved values from the shared $TestContext hashtable (the same object
    PreTests.ps1 received) and guard each with ContainsKey, so a partial or failed
    setup still tears down cleanly. Typically only Online runs need teardown;
    $TestContext.OnlineHandled signals that PreTests.ps1 performed Online setup,
    so gate the restore on it.

    Keep per-project teardown here so the orchestrator (Tests.ps1) and the generic
    checks (Tests\*.ps1) stay identical across repos.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Online teardown (optional) ----------------------------------------------
# Mirror whatever PreTests.ps1 set up, and only when it actually ran the Online
# setup (it sets $TestContext.OnlineHandled = $true). Guard each saved value with
# ContainsKey so a setup that threw partway through still cleans up.
# if ($TestContext.OnlineHandled) {
#     # FIXME: restore state PreTests.ps1 stashed on $TestContext, e.g.:
#     # if ($TestContext.ContainsKey('OriginalSetting')) {
#     #     $Global:XYZ_Config.Setting = $TestContext.OriginalSetting
#     # }
#     # $env:XYZ_TEST_SILENT_AUTH = $null
# }
