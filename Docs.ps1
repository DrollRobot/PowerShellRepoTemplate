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

    Note: PlatyPS has an internal function named 'log'. If your module exports a
    'Log' alias, remove it for the duration of this script (see the Remove-Alias
    call below) to avoid an ambiguous-parameter error.

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

# The module name is the repo folder name (same convention as Tests.ps1).
$ModuleName = Split-Path -Path $PSScriptRoot -Leaf

# PlatyPS calls its internal 'log' function as: log -warning "..."
# A module 'Log' alias shadows it, causing an ambiguous parameter error.
# Remove the alias for the duration of this script only.
Remove-Alias -Name 'Log' -Force -ErrorAction SilentlyContinue

Import-Module (Join-Path -Path $PSScriptRoot -ChildPath "$ModuleName.psd1") -Force

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

Write-Host "Docs updated at $DocsPath"
