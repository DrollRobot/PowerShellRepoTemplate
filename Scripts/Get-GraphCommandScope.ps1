function Get-CommandGraphScope {
    <#
    .SYNOPSIS
        Maps Graph commands to the permission scopes required to run them.

    .DESCRIPTION
        For each supplied command name, looks up the Microsoft Graph permissions
        associated with it via Find-MgGraphCommand and returns one row per command, API
        variant, and permission. Non-Graph commands are skipped. By default all
        permission types are returned; use -PermissionType to narrow to Delegated or
        Application permissions only.

        Requires the Microsoft.Graph.Authentication module to be available. No Graph
        connection is needed -- this is a local metadata lookup, not an API call.

    .PARAMETER Name
        One or more command names to look up. Accepts pipeline input. Names that are not
        Graph SDK commands are silently skipped.

    .PARAMETER PermissionType
        Optional filter limiting results to a single permission type: Delegated or
        Application. When omitted, both types are returned.

    .PARAMETER Trace
        Emits diagnostic trace output describing each lookup.

    .EXAMPLE
        Get-CommandGraphScope -Name Get-MgUser

        Returns every permission (both types) across every API variant of Get-MgUser.

    .EXAMPLE
        Get-CommandGraphScope -Name Get-MgUser -PermissionType Delegated

        Returns only the delegated scopes -- the relevant set for public-client auth.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [string[]] $Name,

        [ValidateSet('DelegatedWork', 'DelegatedPersonal', 'Application')]
        [string] $PermissionType,

        [switch] $Trace
    )

    begin {
        if ($Trace) { $InformationPreference = 'Continue' }
        function Write-Trace {
            param([Parameter(Mandatory)][string] $Message)
            Write-Information $Message -Tags 'Trace'
        }
    }

    process {
        foreach ($commandName in $Name) {
            $found = Find-MgGraphCommand -Command $commandName -ErrorAction SilentlyContinue
            if (-not $found) {
                Write-Trace "Get-CommandGraphScope: not a Graph command, skipping '$commandName'"
                continue
            }

            foreach ($variant in $found) {
                foreach ($permission in $variant.Permissions) {
                    if ($PermissionType -and $permission.PermissionType -ne $PermissionType) {
                        continue
                    }

                    [PSCustomObject]@{
                        Command          = $commandName
                        Uri              = $variant.Uri
                        Method           = $variant.Method
                        Scope            = $permission.Name
                        PermissionType   = $permission.PermissionType
                        IsAdmin          = $permission.IsAdmin
                        IsLeastPrivilege = $permission.IsLeastPrivilege
                    }
                }
            }
        }
    }
}
