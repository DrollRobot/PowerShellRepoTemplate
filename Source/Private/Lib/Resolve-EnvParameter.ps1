function Resolve-EnvParameter {
    <#
    .SYNOPSIS
        Resolves injected env_<ParameterName> values for a command's unbound
        parameters.

    .DESCRIPTION
        Some deployment platforms (RMM tools, task runners, MDM payloads)
        cannot pass command-line arguments to a script they deploy: each
        configured parameter is surfaced to the running script as a variable
        named env_<ParameterName> instead. This helper collects those injected
        values for a set of parameter names, so a command works both as a
        normal PowerShell call (directly bound parameters) and as a deployment
        (injected variables).

        A directly bound parameter always wins: names present in
        BoundParameters are skipped entirely. For the rest, each scope in
        Scope is searched in order for a variable named env_<ParameterName>,
        and the first non-blank value wins. The scope name 'Environment' reads
        the process environment ($env:env_<ParameterName>); every other entry
        is handed to Get-Variable -Scope as-is (for example 'Global').

        Which scope a given platform really injects into varies, so Scope
        defaults to $Script:EnvParameterScopes when the module defines it (set
        it in Source\Suffix.ps1 to change the list module-wide) and to
        'Global', 'Environment' otherwise.

        Values for SwitchName entries are converted to booleans: 'true' and
        'false' (case-insensitive) are accepted, anything else throws, so a
        misconfigured deployment parameter fails the run instead of silently
        doing the wrong thing.

        This is the module half of the standalone-script generator's
        EnvResolver contract: ConvertTo-StandaloneScript and
        ConvertTo-ScriptVariant emit a '#region Baked defaults' block that
        calls this command, so an injected value outranks a value baked in at
        build time. Precedence per parameter: command-line argument, injected
        env_<Name> value, baked default.

    .PARAMETER BoundParameters
        The caller's $PSBoundParameters. Names present here are never resolved
        from injected variables.

    .PARAMETER ParameterName
        String-typed parameter names to resolve. Injected values are returned
        unchanged.

    .PARAMETER SwitchName
        Switch-typed parameter names to resolve. Injected values must be
        'true' or 'false' and are returned as booleans.

    .PARAMETER Scope
        Scopes to search, in priority order. 'Environment' means the process
        environment; any other entry is a scope name understood by
        Get-Variable -Scope. Defaults to $Script:EnvParameterScopes when the
        module defines it, otherwise to 'Global', 'Environment'.

    .EXAMPLE
        $ResolveParams = @{
            BoundParameters = $PSBoundParameters
            ParameterName   = 'TenantId', 'LogPath'
            SwitchName      = 'ForceReinstall'
        }
        $Injected = Resolve-EnvParameter @ResolveParams

        Returns, for example, @{ TenantId = '<tenant>'; ForceReinstall = $true }
        when those injected variables exist and neither parameter was bound.

    .OUTPUTS
        System.Collections.Hashtable. Parameter name to resolved value, holding
        only the names an injected value was found for.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param (
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $BoundParameters,

        [string[]] $ParameterName,

        [string[]] $SwitchName,

        [string[]] $Scope
    )

    # Template file version, read by Scripts\Compare-Template.ps1, which keeps a
    # child repo's copy of this file in sync by version. Declared inside the
    # function so ModuleBuilder does not inline a module-scope assignment.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseDeclaredVarsMoreThanAssignments', 'ScriptVersion')]
    $ScriptVersion = '1.0.0'

    if (-not $Scope) {
        # Get-Variable rather than $Script:EnvParameterScopes directly: under
        # Set-StrictMode the bare reference throws when a module does not
        # define the override.
        $OverrideParams = @{
            Name        = 'EnvParameterScopes'
            Scope       = 'Script'
            ValueOnly   = $true
            ErrorAction = 'SilentlyContinue'
        }
        $Override = Get-Variable @OverrideParams
        $Scope = if ($Override) { $Override } else { @('Global', 'Environment') }
    }

    $Resolved = @{}
    $AllNames = @($ParameterName) + @($SwitchName) | Where-Object { $_ }

    foreach ($Name in $AllNames) {
        if ($BoundParameters.ContainsKey($Name)) { continue }

        $VariableName = "env_${Name}"
        $Value = $null
        foreach ($Entry in $Scope) {
            if ($Entry -eq 'Environment') {
                $Candidate = [Environment]::GetEnvironmentVariable($VariableName)
            }
            else {
                $GetParams = @{
                    Name        = $VariableName
                    Scope       = $Entry
                    ValueOnly   = $true
                    ErrorAction = 'SilentlyContinue'
                }
                $Candidate = Get-Variable @GetParams
            }
            if (-not [string]::IsNullOrWhiteSpace($Candidate)) {
                $Value = [string]$Candidate
                break
            }
        }

        if ($null -eq $Value) { continue }

        if ($SwitchName -contains $Name) {
            if ($Value -notin @('true', 'false')) {
                throw ("Injected value for ${Name} must be 'true' or 'false'; " +
                    "got '${Value}'.")
            }
            $Resolved[$Name] = $Value -eq 'true'
        }
        else {
            $Resolved[$Name] = $Value
        }
    }

    return $Resolved
}
