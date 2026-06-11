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

    Note: PlatyPS has an internal function named 'log' that conflicts with the
    module's 'Log' alias. The alias is removed for the duration of this script
    and restored afterward.

.PARAMETER DeleteOrphaned
    When specified, orphaned doc files are deleted instead of just warned about.

.EXAMPLE
    .\Update-Docs.ps1

.EXAMPLE
    .\Update-Docs.ps1 -DeleteOrphaned
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '')]
[CmdletBinding()]
param(
    [switch] $DeleteOrphaned
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$DocsPath = Join-Path -Path $PSScriptRoot -ChildPath 'docs\commands'

# PlatyPS calls its internal 'log' function as: log -warning "..."
# The module's 'Log' alias shadows it, causing an ambiguous parameter error.
# Remove the alias for the duration of this script only.
Remove-Alias -Name 'Log' -Force -ErrorAction SilentlyContinue

Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'M365IncidentResponseTools.psd1') -Force

# Create a doc file for any exported function that does not have one yet
(Get-Module M365IncidentResponseTools).ExportedFunctions.Keys |
    Where-Object { -not (Test-Path (Join-Path -Path $DocsPath -ChildPath "$_.md")) } |
    ForEach-Object { New-MarkdownHelp -Command $_ -OutputFolder $DocsPath }

# Update all existing doc files (including any just created)
Update-MarkdownHelp -Path $DocsPath

# Warn about (or delete) orphaned doc files whose function no longer exists
$ExportedFunctions = (Get-Module M365IncidentResponseTools).ExportedFunctions.Keys
Get-ChildItem -Path $DocsPath -Filter '*.md' |
    Where-Object {
        $_.BaseName -notin $ExportedFunctions -and $_.BaseName -ne 'M365IncidentResponseTools'
    } |
    ForEach-Object {
        if ($DeleteOrphaned) {
            Remove-Item -Path $_.FullName
            Write-Host "Deleted orphaned doc: $($_.Name)"
        } else {
            Write-Warning "Orphaned doc (no matching exported function): $($_.Name)"
        }
    }

New-Alias -Name 'Log' -Value 'Write-LogFile' -Force

Write-Host "Docs updated at $DocsPath"
