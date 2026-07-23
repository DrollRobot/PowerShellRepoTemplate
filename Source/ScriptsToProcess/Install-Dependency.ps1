<#
.SYNOPSIS
    Installs required modules for a PowerShell module.

.DESCRIPTION
    Discovers the .psd1 manifest in the same directory as this script, reads
    RequiredModules, and installs each one.  Version constraints
    (ModuleVersion, RequiredVersion, MaximumVersion) are read directly from
    the manifest and passed through to Install-Module.

    The script must be placed in the root folder of a PowerShell module
    (i.e. alongside the .psd1 file).

.PARAMETER Scope
    Installation scope: CurrentUser (default) or AllUsers.

.PARAMETER Force
    Pass -Force to Install-Module, overwriting existing installations.

.EXAMPLE
    .\Install-Dependency.ps1

.PARAMETER Check
    Check whether all required modules are installed without installing anything.
    If any are missing, prints the exact command to run to install them.

.PARAMETER Quiet
    Suppress all informational output. When combined with -Check, produces no output
    if all modules are satisfied; prints only the missing-modules summary if any are missing.
    Useful for CI or wrapper scripts.

.EXAMPLE
    .\Install-Dependency.ps1 -Scope AllUsers -WhatIf

.EXAMPLE
    .\Install-Dependency.ps1 -Check

.EXAMPLE
    .\Install-Dependency.ps1 -Check -Quiet

.NOTES
Version 1.3.0
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

    [switch]$Force,

    [switch]$Check,

    [switch]$Quiet
)

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseDeclaredVarsMoreThanAssignments', 'ScriptVersion')]
$ScriptVersion = '1.3.0'

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$DarkCyan = @{ForegroundColor = 'DarkCyan' }
$Yellow = @{ForegroundColor = 'Yellow' }
$Red = @{ForegroundColor = 'Red' }

# Hard-coded fallback module list
# Used only when the manifest's RequiredModules cannot be read (missing,
# empty, or the manifest itself can't be found).
# FIXME: optionally mirror your manifest's RequiredModules here, e.g.:
#   @{ModuleName = 'PSFramework'; ModuleVersion = '1.13.0' }
$HardCodedRequiredModules = @()

# Discover manifest
$ManifestFiles = @(Get-ChildItem -Path $PSScriptRoot -Filter '*.psd1' -File)

$RequiredModules = $null
$FromManifest = $false

if (($ManifestFiles | Measure-Object).Count -eq 0) {
    # No manifest present -- silently fall back to the hard-coded list below.
}
elseif (($ManifestFiles | Measure-Object).Count -gt 1) {
    $names = $ManifestFiles.Name -join ', '
    $WarnMsg = "Multiple .psd1 manifests found in $PSScriptRoot ($names). " +
    'Cannot determine which to use.'
    Write-Warning $WarnMsg
}
else {
    $ManifestPath = $ManifestFiles[0].FullName
    $Manifest = Import-PowerShellDataFile -Path $ManifestPath
    $RequiredModules = $Manifest['RequiredModules']
    if ($RequiredModules) {
        $FromManifest = $true
    }
}

# if modules found in manifest, use hard coded list
if (-not $RequiredModules) {
    $RequiredModules = $HardCodedRequiredModules
}

# if modules not found in either, return
if (-not $RequiredModules) {
    if (-not $Quiet) { Write-Host @DarkCyan 'No required modules declared. Nothing to do.' }
    return
}

$SourcePath = if ($FromManifest) { $ManifestPath } else { $PSCommandPath }

if (-not $Quiet) {
    Write-Host @DarkCyan "Using source: $SourcePath"
    Write-Host @DarkCyan "Found $($RequiredModules.Count) required module(s)."
}

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
#         Builds $Plan; Problem = does not meet the manifest requirement.
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
            if ($Entry.ContainsKey('ModuleVersion')) {
                $Min = [version]$Entry.ModuleVersion
                $InstallParams['MinimumVersion'] = $Entry.ModuleVersion
                $VersionLabel = ">= $($Entry.ModuleVersion)"
            }
            if ($Entry.ContainsKey('MaximumVersion')) {
                $Max = [version]$Entry.MaximumVersion
                $InstallParams['MaximumVersion'] = $Entry.MaximumVersion
                $VersionLabel += " <= $($Entry.MaximumVersion)"
            }
            $VersionLabel = $VersionLabel.Trim()
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
#         Install-Module cannot fix this -- it's advisory only (see report).
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
# Loop 3: Act (unless -Check) and report. Single output section.
#   - Non-graph problem  -> uninstall (if installed) + reinstall.
#   - Missing graph (no mismatch) -> install normally (never uninstall graph).
#   - Graph mismatch     -> do not touch; warn + recommend below.
# ---------------------------------------------------------------------------
$AnyMissing = $false
$Locked = @()
foreach ($R in $Plan) {

    # --- Act -------------------------------------------------------------
    if ($R.Problem -and -not $Check) {
        $InstallParams = $R.InstallParams   # splatting requires a variable
        if ($R.IsGraph) {
            # Graph modules are never uninstalled. A mismatch is left for the
            # advisory below; a merely-missing module installs normally.
            if (-not $GraphMismatch) {
                if (-not $Quiet) { Write-Host @Yellow "Installing $($R.Name) $($R.VersionLabel)" }
                if ($PSCmdlet.ShouldProcess($R.Name, 'Install-Module')) {
                    Install-Module @InstallParams
                }
            }
        }
        else {
            # Non-graph: explicit uninstall + reinstall (no -Force reliance).
            $verb = if ($R.InstalledMax) { 'Reinstalling' } else { 'Installing' }
            if (-not $Quiet) { Write-Host @Yellow "$verb $($R.Name) $($R.VersionLabel)" }
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
        # Installed but below the manifest requirement is distinct from absent.
        $Status = if ($null -ne $R.InstalledMax) {
            "OUTDATED ($($R.InstalledMax))"
        } else { 'MISSING' }
        $AnyMissing = $true
    }
    else {
        $Status = 'OK'
    }

    if (-not $Quiet) {
        $Color = if ($Status -like 'OK*') { @{} } else { $Yellow }
        Write-Host @Color "    $($R.Name) $($R.VersionLabel) -- $Status"
    }
}

# --- Recommendation / summary --------------------------------------------
if (-not $Quiet) {
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
}

# Non-zero exit: a graph mismatch is never auto-fixed and a locked module needs a
# restart (both gate in any mode); missing modules gate only under -Check.
if ($GraphMismatch -or $Locked.Count -gt 0 -or ($Check -and $AnyMissing)) { throw }
