<#
.SYNOPSIS
    Project-specific build steps that run before ModuleBuilder is invoked.

.DESCRIPTION
    Build.ps1 is intentionally generic and reusable across any ModuleBuilder project.
    Put anything specific to this project here: generating files, updating version metadata,
    copying assets into the source tree, etc.

    This script is invoked automatically by Build.ps1 if it exists in the repo root.
    Delete or rename it to skip the pre-build phase entirely.
#>

$ErrorActionPreference = 'Stop'

# Ensure ImportExcel is available
if (-not (Get-Module -ListAvailable -Name ImportExcel)) {
    Write-Host "Installing ImportExcel module..." -ForegroundColor Cyan
    Install-Module -Name ImportExcel -Scope CurrentUser -Force -AllowClobber
}
Import-Module -Name ImportExcel -Force

# Reapply conditional formatting rules to the template to prevent drift
$RepoRoot = Split-Path -Path $PSScriptRoot -Parent
$JoinPathParams = @{
    Path                = $RepoRoot
    ChildPath           = 'Source'
    AdditionalChildPath = @('Data', 'IpAddressConditionalFormattingTemplate.xlsx')
}
$TemplatePath = Join-Path @JoinPathParams

$ScriptParams = @{
    Path          = $TemplatePath
    ColumnName    = 'ipaddress'
    ClearExisting = $true
}

$ScriptPathParams = @{
    Path                = $RepoRoot
    ChildPath           = 'Build'
    AdditionalChildPath = @('Add-IpAddressConditionalFormattingTemplate.ps1')
}
$ScriptPath = Join-Path @ScriptPathParams

& $ScriptPath @ScriptParams
