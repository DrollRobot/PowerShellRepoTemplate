<#
.SYNOPSIS
    Arm or disarm the release workflow's build-and-publish job.

.DESCRIPTION
    .github\workflows\release.yml only builds and publishes a GitHub release
    when Scripts\setup.psd1's Release.Enabled is true. A fresh clone --
    including this template's own repo -- ships with it false, so pushing a
    v* tag never auto-publishes before you are ready.

    Flips Release.Enabled in place, editing only that line so the rest of
    setup.psd1 (comments, other sections, your own choices) is untouched --
    the same surgical, targeted-line approach used for module version bumps,
    since a full re-serialize of the file would strip its comments.

.PARAMETER SetupPath
    Path to setup.psd1. Defaults to Scripts\setup.psd1 next to this script.

.PARAMETER Disable
    Set Release.Enabled back to false instead of true.

.PARAMETER DryRun
    Report what would change without writing anything.

.EXAMPLE
    .\Scripts\Enable-Release.ps1

    Arms the release workflow: pushing a v* tag now builds and publishes.

.EXAMPLE
    .\Scripts\Enable-Release.ps1 -Disable

    Disarms it again -- tags still push, nothing gets built or published.

.OUTPUTS
    Progress text to the host. Returns $true from Enable-Release when
    Release.Enabled changed, $false when it already matched the target.

.NOTES
    Idempotent: re-running in the same direction changes nothing.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '')]
[CmdletBinding()]
param(
    [Parameter()]
    [string] $SetupPath,

    [Parameter()]
    [switch] $Disable,

    [Parameter()]
    [switch] $DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseDeclaredVarsMoreThanAssignments', 'ScriptVersion')]
$ScriptVersion = '1.0.0'

# Matches the single `Enabled = $true|$false` line inside setup.psd1's Release
# block. Anchored on the key name alone, not nested inside `Release = @{ ... }`,
# since Enabled is not reused anywhere else in the file.
$script:EnabledPattern = '(?m)^(\s*Enabled\s*=\s*)\$(true|false)\b'

# Flip Release.Enabled in $SetupPath to $Target, editing only that line.
# Returns $true on a real change, $false when already at the target value.
function Enable-Release {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '')]
    param(
        [Parameter(Mandatory)][string]$SetupPath,
        [Parameter(Mandatory)][bool]$Target,
        [Parameter(Mandatory)][bool]$DryRun
    )
    if (-not (Test-Path -LiteralPath $SetupPath)) {
        throw "setup.psd1 not found: $SetupPath"
    }

    $Content = Get-Content -LiteralPath $SetupPath -Raw
    $Match = [regex]::Match($Content, $script:EnabledPattern)
    if (-not $Match.Success) {
        throw "Release.Enabled not found in $SetupPath -- has its shape changed?"
    }

    $Current = $Match.Groups[2].Value -eq 'true'
    if ($Current -eq $Target) {
        $State = if ($Target) { 'enabled' } else { 'disabled' }
        Write-Host "Release feature already $State -- nothing to do."
        return $false
    }

    $TargetText = if ($Target) { 'true' } else { 'false' }
    $Replacement = '${1}$' + $TargetText
    $Updated = [regex]::Replace($Content, $script:EnabledPattern, $Replacement, 1)

    $Verb = if ($Target) { 'Enabling' } else { 'Disabling' }
    Write-Host "$Verb release feature in $SetupPath"
    if (-not $DryRun) {
        Set-Content -LiteralPath $SetupPath -Value $Updated -NoNewline
    }
    return $true
}

# --- direct-invocation body (skipped when dot-sourced) ----------------------

if ($MyInvocation.InvocationName -eq '.') { return }

if (-not $SetupPath) {
    $SetupPath = Join-Path -Path $PSScriptRoot -ChildPath 'setup.psd1'
}

$InvokeParams = @{
    SetupPath = $SetupPath
    Target    = -not [bool]$Disable
    DryRun    = [bool]$DryRun
}
$null = Enable-Release @InvokeParams
if ($DryRun) {
    Write-Host ''
    Write-Host '  (dry run -- nothing changed)' -ForegroundColor Yellow
}
