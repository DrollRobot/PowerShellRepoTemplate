<#
.SYNOPSIS
    Installs the modules declared in RequiredModules.psd1.

.DESCRIPTION
    Reads RequiredModules.psd1 from this script's own directory and installs every module
    it declares. Version constraints (ModuleVersion, RequiredVersion, MaximumVersion) are
    read from that file and passed through to Install-Module.

    This script only installs. The pre-import check lives in Confirm-Dependency.ps1, which
    reads the same RequiredModules.psd1; neither script calls the other.

    RequiredModules.psd1 must sit beside this script. Both files travel together into the
    built module, so no path configuration is needed.

.PARAMETER Scope
    Installation scope: CurrentUser (default) or AllUsers.

.PARAMETER Force
    Pass -Force to Install-Module, overwriting existing installations.

.EXAMPLE
    .\Install-Dependency.ps1

    Installs or repairs every module declared in RequiredModules.psd1.

.EXAMPLE
    .\Install-Dependency.ps1 -Scope AllUsers -WhatIf

    Reports what would be installed machine-wide without changing anything.

.OUTPUTS
    None. Progress and a per-module status line are written to the host.

.NOTES
Version 2.0.0
2.0.0 - BREAKING: -Check and -Quiet removed, along with the hard-coded fallback module
        list. The module list now comes from the sibling RequiredModules.psd1 instead of
        a .psd1 discovered in $PSScriptRoot -- which never resolved once the script was
        deployed under ScriptsToProcess\, silently leaving the list empty. Checking is
        now solely Confirm-Dependency.ps1's job. The final throw carries a message.
1.3.0 - Renamed from Install-Dependencies.ps1 to Install-Dependency.ps1 (singular),
        matching Invoke-RemoveDependency and Confirm-Dependency.ps1.
1.2.1 - InstalledMax now coalesces to $null when nothing is installed, so
        $Plan.InstalledMax member access no longer throws PropertyNotFound
        under Set-StrictMode -Version Latest.
1.2.0 - Non-graph modules are now uninstalled + reinstalled when they don't meet
        the manifest. Microsoft.Graph modules are never uninstalled by the script;
        a version mismatch among them is reported with a recommendation to
        uninstall all Microsoft.Graph.* modules and re-run.
1.1.0 - Added -Check and -Quiet parameters and hard coded module list for better integration
        with Confirm-Dependency.ps1.

#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '')]
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('CurrentUser', 'AllUsers')]
    [string]$Scope = 'CurrentUser',

    [switch]$Force
)

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseDeclaredVarsMoreThanAssignments', 'ScriptVersion')]
$ScriptVersion = '2.0.0'

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$DarkCyan = @{ForegroundColor = 'DarkCyan' }
$Yellow = @{ForegroundColor = 'Yellow' }
$Red = @{ForegroundColor = 'Red' }

# Single source of truth, shared with Confirm-Dependency.ps1.
$DataPath = Join-Path -Path $PSScriptRoot -ChildPath 'RequiredModules.psd1'

if (-not (Test-Path -LiteralPath $DataPath)) {
    throw "RequiredModules.psd1 not found beside this script (expected at $DataPath)."
}

$Data = Import-PowerShellDataFile -Path $DataPath

# Assigned in two steps, not from an `if` expression: a branch returning @() emits
# nothing to the pipeline, so the variable would land as AutomationNull and .Count
# would throw PropertyNotFound under Set-StrictMode -Version Latest.
$RequiredModules = @()
if ($Data -is [hashtable] -and $Data.ContainsKey('RequiredModules')) {
    $RequiredModules = @($Data['RequiredModules'])
}

if ($RequiredModules.Count -eq 0) {
    Write-Host @DarkCyan 'No required modules declared. Nothing to do.'
    return
}

Write-Host @DarkCyan "Using source: $DataPath"
Write-Host @DarkCyan "Found $($RequiredModules.Count) required module(s)."

function Test-VersionSatisfied {
    param([version[]]$Installed, [version]$Min, [version]$Max, [version]$Required)

    if ($Installed.Count -eq 0) { return $false }
    if ($Required) { return $Installed -contains $Required }
    return $null -ne ($Installed | Where-Object {
            ($null -eq $Min -or $_ -ge $Min) -and ($null -eq $Max -or $_ -le $Max)
        } | Select-Object -First 1)
}

# ---------------------------------------------------------------------------
# Loop 1: Assess each required module (no installs, no output).
#         Builds $Plan; Problem = does not meet the declared requirement.
#         The constraint parsing here is mirrored in Confirm-Dependency.ps1 --
#         that duplication is deliberate; see the note in that script.
# ---------------------------------------------------------------------------
$Plan = foreach ($Entry in $RequiredModules) {
    # Entries can be a plain string or a hashtable with version constraints.
    $ModuleName = if ($Entry -is [hashtable]) { $Entry.ModuleName } else { $Entry }

    $InstallParams = @{
        Name               = $ModuleName
        Scope              = $Scope
        SkipPublisherCheck = $true
        AllowClobber       = $true
    }
    if ($Force) { $InstallParams['Force'] = $true }

    $Min = $null; $Max = $null; $Required = $null
    $VersionLabel = '(latest)'
    if ($Entry -is [hashtable]) {
        if ($Entry.ContainsKey('RequiredVersion')) {
            $Required = [version]$Entry.RequiredVersion
            $InstallParams['RequiredVersion'] = $Entry.RequiredVersion
            $VersionLabel = "== v$($Entry.RequiredVersion)"
        }
        else {
            $Parts = @()
            if ($Entry.ContainsKey('ModuleVersion')) {
                $Min = [version]$Entry.ModuleVersion
                $InstallParams['MinimumVersion'] = $Entry.ModuleVersion
                $Parts += ">= $($Entry.ModuleVersion)"
            }
            if ($Entry.ContainsKey('MaximumVersion')) {
                $Max = [version]$Entry.MaximumVersion
                $InstallParams['MaximumVersion'] = $Entry.MaximumVersion
                $Parts += "<= $($Entry.MaximumVersion)"
            }
            if ($Parts.Count -gt 0) { $VersionLabel = $Parts -join ' ' }
        }
    }

    $Installed = @(
        Get-Module -Name $ModuleName -ListAvailable | Select-Object -ExpandProperty Version
    )
    $SatisfiedParams = @{
        Installed = $Installed
        Min       = $Min
        Max       = $Max
        Required  = $Required
    }
    $Satisfied = Test-VersionSatisfied @SatisfiedParams

    [pscustomobject]@{
        Name          = $ModuleName
        VersionLabel  = $VersionLabel
        InstallParams = $InstallParams
        Min           = $Min
        Max           = $Max
        Required      = $Required
        IsGraph       = $ModuleName -like 'Microsoft.Graph.*'
        # Coalesce to a real $null when nothing is installed. An empty pipeline
        # yields AutomationNull, which under Set-StrictMode -Version Latest makes
        # member-access enumeration ($Plan.InstalledMax) throw PropertyNotFound.
        InstalledMax  = if ($Installed.Count) {
            $Installed | Sort-Object -Descending | Select-Object -First 1
        } else { $null }
        Satisfied     = $Satisfied
        Problem       = -not $Satisfied
    }
}

# ---------------------------------------------------------------------------
# Loop 2: Graph version mismatch. If the installed graph modules disagree
#         (>=2 distinct versions), flag ALL graph modules as a problem.
# ---------------------------------------------------------------------------
$GraphMismatch = $false
$GraphMax = $null
$GraphPlan = @($Plan | Where-Object IsGraph)
if ($GraphPlan.Count -gt 1) {
    $GraphVersions = @($GraphPlan.InstalledMax | Where-Object { $_ } | Sort-Object -Unique)
    if ($GraphVersions.Count -gt 1) {
        $GraphMismatch = $true
        $GraphMax = $GraphVersions[-1]
        foreach ($G in $GraphPlan) { $G.Problem = $true }
    }
}

# ---------------------------------------------------------------------------
# Loop 3: Act and report. Single output section.
#   - Non-graph problem  -> uninstall (if installed) + reinstall.
#   - Missing graph (no mismatch) -> install normally (never uninstall graph).
#   - Graph mismatch     -> do not touch; warn + recommend below.
# ---------------------------------------------------------------------------
$AnyMissing = $false
$Locked = @()
foreach ($R in $Plan) {

    # --- Act -------------------------------------------------------------
    if ($R.Problem) {
        $InstallParams = $R.InstallParams   # splatting requires a variable
        if ($R.IsGraph) {
            # Graph modules are never uninstalled. A mismatch is left for the
            # advisory below; a merely-missing module installs normally.
            if (-not $GraphMismatch) {
                Write-Host @Yellow "Installing $($R.Name) $($R.VersionLabel)"
                if ($PSCmdlet.ShouldProcess($R.Name, 'Install-Module')) {
                    Install-Module @InstallParams
                }
            }
        }
        else {
            # Non-graph: explicit uninstall + reinstall (no -Force reliance).
            $verb = if ($R.InstalledMax) { 'Reinstalling' } else { 'Installing' }
            Write-Host @Yellow "$verb $($R.Name) $($R.VersionLabel)"
            if ($PSCmdlet.ShouldProcess($R.Name, "$verb (uninstall + install)")) {
                $uninstallBlocked = $false
                if ($R.InstalledMax) {
                    try {
                        Uninstall-Module -Name $R.Name -AllVersions -ErrorAction Stop
                    }
                    catch {
                        # A loaded DLL (module open in this or another session)
                        # surfaces as an access/in-use error. Don't stack a second
                        # copy on top -- flag it for a clean retry after a restart.
                        $LockPattern = 'Access to the path|is denied|' +
                        'being used by another process|could not be deleted|' +
                        'cannot access the file'
                        if ($_.Exception.Message -match $LockPattern) {
                            $uninstallBlocked = $true
                            $Locked += $R.Name
                        }
                        else {
                            Write-Warning "Could not uninstall $($R.Name): $($_.Exception.Message)"
                        }
                    }
                }
                if (-not $uninstallBlocked) {
                    Install-Module @InstallParams
                }
            }
        }

        # Re-read post-action so the status line reflects reality.
        $Installed = @(
            Get-Module -Name $R.Name -ListAvailable | Select-Object -ExpandProperty Version
        )
        $R.InstalledMax = if ($Installed.Count) {
            $Installed | Sort-Object -Descending | Select-Object -First 1
        } else { $null }
        $SatisfiedParams = @{
            Installed = $Installed
            Min       = $R.Min
            Max       = $R.Max
            Required  = $R.Required
        }
        $R.Satisfied = Test-VersionSatisfied @SatisfiedParams
    }

    # --- Report ----------------------------------------------------------
    if ($R.IsGraph -and $GraphMismatch) {
        if ($null -ne $R.InstalledMax -and $R.InstalledMax -lt $GraphMax) {
            $Status = "Graph version mismatch ($($R.InstalledMax))"
        }
        else {
            $Status = "OK ($($R.InstalledMax))"
        }
    }
    elseif ($Locked -contains $R.Name) {
        $Status = 'UNINSTALL FAILED - FILE LOCKED'
    }
    elseif (-not $R.Satisfied) {
        # Installed but below the declared requirement is distinct from absent.
        $Status = if ($null -ne $R.InstalledMax) {
            "OUTDATED ($($R.InstalledMax))"
        } else { 'MISSING' }
        $AnyMissing = $true
    }
    else {
        $Status = 'OK'
    }

    $Color = if ($Status -like 'OK*') { @{} } else { $Yellow }
    Write-Host @Color "    $($R.Name) $($R.VersionLabel) -- $Status"
}

# --- Recommendation / summary --------------------------------------------
if ($GraphMismatch) {
    Write-Host @Red @"

Microsoft.Graph modules have mismatched versions.
To resolve, uninstall all graph modules:
"@
    Write-Host @Yellow @"
Get-InstalledModule Microsoft.Graph* |
    Where-Object Name -ne 'Microsoft.Graph.Authentication' |
    ForEach-Object { Uninstall-Module `$_.Name -AllVersions -Force -ErrorAction SilentlyContinue }
Uninstall-Module Microsoft.Graph.Authentication -AllVersions -Force
"@
    Write-Host @Red @"

Then, reinstall latest versions with:
"@
    Write-Host @Yellow @"
& '$PSCommandPath'

"@
}
elseif ($Locked.Count -gt 0) {
    Write-Host @Yellow "Uninstall failed because of a locked file: $($Locked -join ', ')"
    Write-Host @Yellow 'Close ALL open PowerShell sessions, then re-run:'
    Write-Host @Yellow "    & '$PSCommandPath'"
}
elseif ($AnyMissing) {
    Write-Host @Yellow 'To fix, run:'
    Write-Host @Yellow "    & '$PSCommandPath'"
}
else {
    Write-Host @DarkCyan 'All required modules are installed and consistent.'
}

# Non-zero exit: a graph mismatch is never auto-fixed, and a locked module needs a
# restart before the reinstall can be retried. Neither is resolved by re-running as-is.
if ($GraphMismatch) {
    throw
}
if ($Locked.Count -gt 0) {
    throw
}
