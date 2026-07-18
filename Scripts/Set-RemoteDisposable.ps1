#Requires -Version 7.5

<#
.SYNOPSIS
    Marks the remote target this project points at as safe to destroy.

.DESCRIPTION
    Write half of a pair with Tests\Confirm-RemoteDisposable.ps1, which the test
    orchestrator (Tests.ps1) runs automatically before any Pester test tagged
    'destructive','remote'. This script is the opposite: run it manually,
    rarely -- once per remote target, or to renew an expiring marker -- never
    automatically.

    Marking a target disposable is a promise that destructive-remote tests may
    mutate or destroy it. Get the target identity right before confirming --
    there is no "no" once a destructive test has run.

    FIXME: replace the body below so it:
      1. Identifies which remote target this project is currently pointed at
         (the same identity Tests\Confirm-RemoteDisposable.ps1's FIXME reads --
         read whatever configuration already names it, whether that is
         environment variables, a settings file, IaC state, or something else;
         there is no guarantee this project even uses a Tests\.env.ps1 file),
         and prints it clearly before asking for confirmation.
      2. Writes a marker onto that target using whatever mechanism it supports
         (a resource tag, a database marker row/table, a custom field on an
         API tenant, a file at a well-known path, ...), including an expiry so
         a marker set once does not silently outlive the review that justified
         it.

    Until this is implemented, there is nothing for
    Tests\Confirm-RemoteDisposable.ps1 to find, so destructive-remote tests
    keep failing closed.

.PARAMETER Force
    Skip the confirmation prompt. Reserved for the confirmation flow the FIXME
    above adds; this stub still refuses unconditionally either way.

.OUTPUTS
    None. Writes status to the host and exits 1 until implemented.

.EXAMPLE
    .\Scripts\Set-RemoteDisposable.ps1
    Confirms with the user, then writes the disposability marker.

.EXAMPLE
    .\Scripts\Set-RemoteDisposable.ps1 -Force
    Skips the confirmation prompt.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '')]
[CmdletBinding()]
param(
    [switch] $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseDeclaredVarsMoreThanAssignments', 'ScriptVersion')]
$ScriptVersion = '1.0.0'

# Carried forward for the confirmation prompt the FIXME below adds.
$script:AssumeYes = [bool] $Force

Write-Host ''
Write-Host '== Mark remote target disposable ==' -ForegroundColor Cyan
$WarnMsg = '  This asserts the remote target is safe for destructive-remote ' +
"tests to mutate or destroy. There is no 'no' once one has run."
Write-Host $WarnMsg -ForegroundColor Yellow

# FIXME: identify and print the actual target here so the user confirms the
# right thing, e.g.:
#   Write-Host "  Target: $env:SOME_TARGET_URL"
# then replace the failure below with a confirmation prompt (honoring
# $script:AssumeYes) and the marker-writing logic described in the help above.
Write-Host ''
$ErrMsg = 'ERROR: Set-RemoteDisposable.ps1 has not been implemented for this ' +
'project yet (see the FIXME in its help and AGENTS.TESTING.md).'
Write-Host $ErrMsg -ForegroundColor Red
exit 1
