<#
.SYNOPSIS
    Pre-import dependency check. Should be added to ScriptsToProcess in the module manifest
    to run automatically when the module is imported.
    Reads the dependency list from RequiredModules.psd1, beside this script.

.DESCRIPTION
    Reads RequiredModules.psd1 from this script's own directory and verifies that every
    module it declares is installed at a satisfying version. This script only checks --
    it never installs, and it never invokes Install-Dependency.ps1.

    If all required modules are present, no output is produced. If any are missing or
    outdated, they are listed along with the command that installs them, then this script
    throws to abort the import cleanly. This prevents PowerShell's built-in "required module
    not found" error from appearing alongside the guidance already printed.

    No hardcoded paths are used -- this script can be placed anywhere, as long as
    RequiredModules.psd1 travels with it.

.NOTES
Version 2.0.0
2.0.0 - BREAKING: reads the sibling RequiredModules.psd1 instead of walking up the
        directory tree for a manifest and delegating to Install-Dependency.ps1 -Check.
        The two scripts no longer call each other, the module tree is no longer scanned
        recursively at import time, and the check no longer runs twice on failure.
        $Global:ModuleDependenciesChecked is now keyed by this script's directory rather
        than by the module root. Requires RequiredModules.psd1 beside this script.
1.3.0 - Renamed from Confirm-Dependencies.ps1 to Confirm-Dependency.ps1 (singular),
        matching Invoke-RemoveDependency and Install-Dependency.ps1.
1.2.0 - The first successful check records the module root in the generic
        $Global:ModuleDependenciesChecked hashtable (keyed by module root path),
        and later imports of the same module skip the Get-Module scan. The table
        can be injected into child runspaces so workers skip the scan too. Keyed
        by path, so multiple modules sharing this script in one session never
        collide.
1.1.0 - Added dynamic module root discovery allowing putting scripts in any folder.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '')]
param()

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseDeclaredVarsMoreThanAssignments', 'ScriptVersion')]
$ScriptVersion = '2.0.0'

# ScriptsToProcess scripts run in the caller's scope, so the body runs inside a
# scriptblock: its variables stay out of the importing session, and `return` still
# short-circuits the check. $PSScriptRoot is passed in rather than read inside.
# Set-StrictMode is deliberately NOT set here for the same reason -- it would leak
# into the caller. Every read below is written to be safe under a caller that has
# set it itself.
& {
    param([string]$ScriptDir)

    $Red = @{ForegroundColor = 'Red' }
    $Yellow = @{ForegroundColor = 'Yellow' }

    $DataPath = Join-Path -Path $ScriptDir -ChildPath 'RequiredModules.psd1'
    if (-not (Test-Path -LiteralPath $DataPath)) { return }

    # Already verified for this script's directory in this session (or in a parent
    # session that injected the table into this runspace) - skip the Get-Module scan.
    # Get-Variable probe (not a direct $Global: read) so the script is safe under
    # Set-StrictMode in the importing scope.
    $GvParams = @{
        Name        = 'ModuleDependenciesChecked'
        Scope       = 'Global'
        ValueOnly   = $true
        ErrorAction = 'Ignore'
    }
    $DepsChecked = Get-Variable @GvParams
    if ($DepsChecked -is [hashtable] -and $DepsChecked[$ScriptDir]) { return }

    $Data = Import-PowerShellDataFile -Path $DataPath

    # Assigned in two steps, not from an `if` expression: a branch returning @()
    # emits nothing to the pipeline, so the variable would land as AutomationNull
    # instead of an empty array.
    $RequiredModules = @()
    if ($Data -is [hashtable] -and $Data.ContainsKey('RequiredModules')) {
        $RequiredModules = @($Data['RequiredModules'])
    }

    # Version-constraint parsing is duplicated in Install-Dependency.ps1 on purpose.
    # ScriptsToProcess runs before the module loads, so neither script can call a
    # module function, and a shared dot-sourced helper would leak function names into
    # the importing session. Keep the two parsers in step when either changes.
    $Unsatisfied = foreach ($Entry in $RequiredModules) {
        $ModuleName = if ($Entry -is [hashtable]) { $Entry.ModuleName } else { [string]$Entry }
        if (-not $ModuleName) { continue }

        $Min = $null; $Max = $null; $Exact = $null
        $VersionLabel = '(latest)'
        if ($Entry -is [hashtable]) {
            if ($Entry.ContainsKey('RequiredVersion')) {
                $Exact = [version]$Entry.RequiredVersion
                $VersionLabel = "== v$($Entry.RequiredVersion)"
            }
            else {
                $Parts = @()
                if ($Entry.ContainsKey('ModuleVersion')) {
                    $Min = [version]$Entry.ModuleVersion
                    $Parts += ">= $($Entry.ModuleVersion)"
                }
                if ($Entry.ContainsKey('MaximumVersion')) {
                    $Max = [version]$Entry.MaximumVersion
                    $Parts += "<= $($Entry.MaximumVersion)"
                }
                if ($Parts.Count -gt 0) { $VersionLabel = $Parts -join ' ' }
            }
        }

        $Installed = @(
            Get-Module -Name $ModuleName -ListAvailable | Select-Object -ExpandProperty Version
        )
        $Satisfied = if ($Installed.Count -eq 0) {
            $false
        }
        elseif ($Exact) {
            $Installed -contains $Exact
        }
        else {
            $null -ne ($Installed | Where-Object {
                    ($null -eq $Min -or $_ -ge $Min) -and ($null -eq $Max -or $_ -le $Max)
                } | Select-Object -First 1)
        }

        if (-not $Satisfied) {
            # Installed but below the requirement is distinct from absent.
            $InstalledMax = if ($Installed.Count -gt 0) {
                $Installed | Sort-Object -Descending | Select-Object -First 1
            }
            else {
                $null
            }
            $State = if ($InstalledMax) { "OUTDATED ($InstalledMax)" } else { 'MISSING' }
            "    $ModuleName $VersionLabel -- $State"
        }
    }

    if ($Unsatisfied) {
        Write-Host @Red 'Required module(s) not satisfied:'
        foreach ($Line in $Unsatisfied) {Write-Host @Yellow $Line}

        $InstallScript = Join-Path -Path $ScriptDir -ChildPath 'Install-Dependency.ps1'
        if (Test-Path -LiteralPath $InstallScript) {
            Write-Host @Red 'To fix, run:'
            Write-Host @Yellow "    & '$InstallScript'"
        }
        else {
            Write-Host @Yellow 'Install them with Install-Module, then retry the import.'
        }
        throw
    }

    if ($DepsChecked -isnot [hashtable]) {
        # Synchronized: child runspaces sharing the table may record concurrently.
        $DepsChecked = [hashtable]::Synchronized(@{})
        Set-Variable -Name 'ModuleDependenciesChecked' -Scope Global -Value $DepsChecked
    }
    $DepsChecked[$ScriptDir] = $true
} $PSScriptRoot
