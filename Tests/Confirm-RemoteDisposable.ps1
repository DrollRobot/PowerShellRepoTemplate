#Requires -Version 7.5

<#
.SYNOPSIS
    Checks whether the remote target this project points at is marked disposable.

.DESCRIPTION
    Read half of a pair with Scripts\Set-RemoteDisposable.ps1, which writes the
    marker this script looks for. The mark/verify split matters: marking is a
    rare, human-confirmed action; verifying runs automatically, once per
    Destructive run, the first time Tests.ps1 discovers a Pester test tagged
    'destructive','remote' (see Tests.ps1 and the "Remote destructive tests"
    section of AGENTS.TESTING.md). Tests.ps1 only cares whether this script
    throws -- a clean return means confirmed disposable, a thrown error means
    refuse. It never calls `exit`: that can terminate the whole calling host
    session, not just this script, if it is ever dot-sourced or run directly
    at an interactive prompt instead of through Tests.ps1.

    This lives in Tests\, not Scripts\, because its only caller is the test
    orchestrator's own gate: unlike Scripts\Set-RemoteDisposable.ps1 (a
    standalone maintenance action a human runs directly, rarely), this script
    exists purely to serve Tests.ps1.

    The marker mechanism is project-specific (a cloud resource tag, a database
    marker row, a custom field on an API tenant, a file at a well-known path on
    a host reachable over SSH, ...) because it depends entirely on what kind of
    system this project's destructive-remote tests target. This stub always
    refuses until it is implemented.

    FIXME: replace the body of Confirm-RemoteDisposable below so it:
      1. Identifies which remote target this project is currently pointed at
         (read whatever configuration already names it -- environment
         variables, a settings file, IaC state, a URL, a resource ID, a tenant
         name; there is no guarantee this project even uses a Tests\.env.ps1
         file).
      2. Queries THAT SPECIFIC target for its disposability marker. Do not
         check "does a marker exist somewhere" -- it must be the live target,
         so that repointing this project's configuration at a different,
         unmarked target fails closed on its own.
      3. Confirms the marker has not expired. Set-RemoteDisposable.ps1 should
         write an expiry alongside the marker; a marker set once during initial
         setup and never revisited should not still be trusted years later.

.OUTPUTS
    None. Prints a message and returns normally if the remote target is
    confirmed disposable, or throws otherwise.

.EXAMPLE
    .\Tests\Confirm-RemoteDisposable.ps1
    Runs the check directly; throws if the target is not confirmed disposable.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '')]
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Returns whether the remote target this project points at is disposable.
# Prints a message for a human to read; the message is not parsed by the caller.
function Confirm-RemoteDisposable {
    [OutputType([bool])]
    param()

    # FIXME: implement the case-by-case check described in the help above.
    $Msg = 'Confirm-RemoteDisposable.ps1 has not been implemented for this ' +
    "project yet (see the FIXME in its help and AGENTS.TESTING.md). " +
    "Destructive tests tagged 'remote' fail closed until it is."
    Write-Host $Msg -ForegroundColor Red
    return $false
}

if (-not (Confirm-RemoteDisposable)) {
    throw "Remote target is not confirmed disposable; destructive 'remote' tests refuse."
}
