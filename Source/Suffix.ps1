# ModuleBuilder Notes: Code in this file will be appended to the built .psm1 file.

Import-IRTModule -Name 'PSFramework'

# when removing module from session, restore original prompt function if it was modified
$ExecutionContext.SessionState.Module.OnRemove = {
    if ($Global:IRT_OriginalPrompt) {
        ${function:global:prompt} = $Global:IRT_OriginalPrompt
    }
}

# Initialize shared global caches as synchronized hashtables.
# Using Synchronized everywhere costs nothing measurable and is safe for runspace sharing.
# Existing data is preserved on module re-import (-Force).
foreach ($VarName in 'IRT_IpInfo', 'IRT_MessageTraceTable') {
    $Current = Get-Variable -Name $VarName -Scope Global -ValueOnly -ErrorAction SilentlyContinue
    if (-not ($Current -is [hashtable] -and $Current.IsSynchronized)) {
        $Existing = if ($Current -is [hashtable]) { $Current } else { @{} }
        Set-Variable -Name $VarName -Scope Global -Value ([hashtable]::Synchronized($Existing))
    }
}

# Initialize the email search collection. Preserve existing entries on module re-import.
if ($Global:IRT_EmailSearch -isnot [System.Collections.Generic.List[psobject]]) {
    $Global:IRT_EmailSearch = [System.Collections.Generic.List[psobject]]::new()
}

# Load user config on module import
Import-IRTConfig

# Set the default MSAL cache path if the config does not override it.
if (-not $Global:IRT_Config.MsalCachePath) {
    $JpParams = @{
        Path                = $env:LOCALAPPDATA
        ChildPath           = 'M365IncidentResponseTools'
        AdditionalChildPath = 'IRT-Cache.bin'
    }
    $Global:IRT_Config.MsalCachePath = Join-Path @JpParams
}

# Set the default IP address CF template path when the config does not override it.
if (-not $Global:IRT_Config.IPConditionalFormattingTemplatePath) {
    $IpcftJoin = @{
        Path                = $PSScriptRoot
        ChildPath           = 'Data'
        AdditionalChildPath = 'IpAddressConditionalFormattingTemplate.xlsx'
    }
    $Global:IRT_Config.IPConditionalFormattingTemplatePath = Join-Path @IpcftJoin
}

# Check ip_info availability once at module load and cache in config.
$Global:IRT_Config.IpInfoAvailable = (Test-PythonPackage -Name 'ip_info').Present

# Load static reference data (error codes, UAL operation metadata, UAL user types).
Import-ReferenceData

# Set terminal title on module load.
Set-TerminalTitle '[IRT]'

# debug: output module load time
if ($Global:IRT_LoadStopwatch) {
    $Global:IRT_LoadStopwatch.Stop()
    $Elapsed = $Global:IRT_LoadStopwatch.Elapsed.TotalSeconds
    Write-PSFMessage -Level 8 -Message "Module loaded in $($Elapsed.ToString('N2'))s."
    Remove-Variable -Name 'IRT_LoadStopwatch' -Scope Global
}
