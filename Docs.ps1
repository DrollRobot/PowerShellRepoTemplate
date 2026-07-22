#Requires -Version 7.5
#Requires -Modules @{ ModuleName = 'PlatyPS'; ModuleVersion = '0.14.0' }

<#
.SYNOPSIS
    Generates and updates PlatyPS markdown help for all exported functions.

.DESCRIPTION
    Creates a markdown help file for any exported function that does not have one,
    updates all existing help files, and warns about (or deletes) orphaned doc files
    whose corresponding function no longer exists in the module.

    Must be run from the repo root in a pwsh session where the module is not yet
    imported, or use -Force to reload it.

    Note: PlatyPS has an internal function named 'log'. If the module exports a
    'Log' alias it shadows that internal function and causes an ambiguous-parameter
    error, so any existing 'Log' alias is captured, removed for the duration of
    this script, and restored afterward (to whatever it originally pointed at).

.PARAMETER DeleteOrphaned
    When specified, orphaned doc files are deleted instead of just warned about.

.EXAMPLE
    .\Docs.ps1

.EXAMPLE
    .\Docs.ps1 -DeleteOrphaned

.NOTES
    1.1.1 - Write docs to 'Docs\Commands' (matching the repo's casing) instead of
        'docs\commands'. On a case-sensitive filesystem (e.g. the Linux CI that
        publishes the site) the lowercase path was a different folder from the
        committed one.
    1.1.0 - Import the module from Source\ (the source manifest, found by excluding
        Build.psd1) instead of a built manifest in the repo root. The comment-based
        help is identical either way, so docs no longer depend on a prior build or on
        locating one. Module name is now derived from the source manifest.
    1.0.0 - Capture and restore any existing 'Log' alias around the run (it was
        previously removed and never restored), reading the alias target from the
        session instead of hard-coding it.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '')]
[CmdletBinding()]
param(
    [switch] $DeleteOrphaned
)

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseDeclaredVarsMoreThanAssignments', 'ScriptVersion')]
$ScriptVersion = '1.1.1'

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$DocsPath = Join-Path -Path $PSScriptRoot -ChildPath 'Docs\Commands'

# Generate docs from the source tree, not a build: the comment-based help is
# identical (the build only concatenates the same function files), and importing
# source removes any dependency on where a build happens to live. The source
# manifest is the module-name source of truth (exclude ModuleBuilder's Build.psd1),
# matching how Build.ps1 and Tests.ps1 resolve it.
$SourcePath = Join-Path -Path $PSScriptRoot -ChildPath 'Source'
$SrcManifest = Get-ChildItem -Path $SourcePath -Filter '*.psd1' |
    Where-Object Name -ne 'Build.psd1' |
    Select-Object -First 1
if (-not $SrcManifest) { throw "No source manifest found under $SourcePath" }
$ModuleName = $SrcManifest.BaseName

Import-Module $SrcManifest.FullName -Force

# PlatyPS calls its internal 'log' function as: log -warning "..." If the module
# exports a 'Log' alias it shadows that and causes an ambiguous-parameter error.
# Capture any existing 'Log' alias (after import, so a module-exported one is
# seen), remove it for the duration of this script, and restore it in the finally
# block -- to whatever it originally pointed at, not an assumed target.
$OriginalLogAlias = Get-Alias -Name 'Log' -ErrorAction SilentlyContinue
if ($OriginalLogAlias) {
    Remove-Alias -Name 'Log' -Force
}

try {
    # Create a doc file for any exported function that does not have one yet
    (Get-Module $ModuleName).ExportedFunctions.Keys |
        Where-Object { -not (Test-Path (Join-Path -Path $DocsPath -ChildPath "$_.md")) } |
        ForEach-Object { New-MarkdownHelp -Command $_ -OutputFolder $DocsPath }

    # Update all existing doc files (including any just created)
    Update-MarkdownHelp -Path $DocsPath

    # Warn about (or delete) orphaned doc files whose function no longer exists
    $ExportedFunctions = (Get-Module $ModuleName).ExportedFunctions.Keys
    Get-ChildItem -Path $DocsPath -Filter '*.md' |
        Where-Object {
            $_.BaseName -notin $ExportedFunctions -and $_.BaseName -ne $ModuleName
        } |
        ForEach-Object {
            if ($DeleteOrphaned) {
                Remove-Item -Path $_.FullName
                Write-Host "Deleted orphaned doc: $($_.Name)"
            } else {
                Write-Warning "Orphaned doc (no matching exported function): $($_.Name)"
            }
        }
}
finally {
    # Restore the 'Log' alias exactly as it was, if it existed.
    if ($OriginalLogAlias) {
        Set-Alias -Name 'Log' -Value $OriginalLogAlias.Definition -Scope Global
    }
}

Write-Host "Docs updated at $DocsPath"
