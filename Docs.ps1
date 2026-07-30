#Requires -Version 7.5
#Requires -Modules @{ ModuleName = 'PlatyPS'; ModuleVersion = '0.14.0' }

<#
.SYNOPSIS
    Regenerates the PlatyPS markdown help for all exported functions.

.DESCRIPTION
    Regenerates every markdown help file from the module's comment-based help,
    overwriting whatever was there, and warns about (or deletes) orphaned doc files
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
    1.1.1 - Write docs to 'Docs\Commands' instead of 'docs\commands' for *nix
        compatibility.
    1.1.0 - Import the module from Source\ instead of built module.
    1.0.0 - Found PlaytPS 'Log' alias was conflicting with local alias. Script
        now captures, removes, then restores local alises to prevent conflict.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '')]
[CmdletBinding()]
param(
    [switch] $DeleteOrphaned
)

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseDeclaredVarsMoreThanAssignments', 'ScriptVersion')]
$ScriptVersion = '1.2.0'

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
    # Rewrite every doc file from the comment-based help in Source\. -Force
    # overwrites existing files; see .DESCRIPTION for why nothing is merged.
    $HelpParams = @{
        Module       = $ModuleName
        OutputFolder = $DocsPath
        Force        = $true
    }
    # Array subexpression: Set-StrictMode -Version Latest rejects .Count on the
    # bare FileInfo returned when the module exports exactly one function.
    $Generated = @(New-MarkdownHelp @HelpParams)
    Write-Host "Generated $($Generated.Count) doc file(s)."

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
