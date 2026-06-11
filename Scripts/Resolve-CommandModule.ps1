#Requires -Version 7.0

function Resolve-CommandModule {
    <#
    .SYNOPSIS
        Finds the module that provides one or more command names.

    .DESCRIPTION
        Looks up each supplied command name with Get-Command and reports the module that
        provides it, the module's location on disk, and a best-effort classification of
        the command's source. Aliases are followed to the command they ultimately resolve
        to, so the reported module reflects the real implementation rather than the alias.

        The Source classification is a heuristic based on where the module lives, not on
        installation metadata, because the originating repository (for example, the
        PowerShell Gallery) is not recorded on the resolved command. The classifications
        are:

            Installed    - Module resides outside $PSHOME; an explicit import is
                           appropriate.
            Builtin      - Module ships with PowerShell (module base under $PSHOME) and
                           is already available; no explicit import is needed.
            None         - The command resolved but belongs to no module, such as a
                           function defined locally or a language element.
            NotFound     - No command of that name could be resolved in the current
                           session.
            HostPublic   - Exported function from the module named by -HostModuleName,
                           verified discoverable via Get-Command auto-discovery.
            HostPrivate  - Non-exported (private) function from the module named by
                           -HostModuleName, found by probing the module's internal scope.
                           Only produced when -HostModuleName is supplied.

    .PARAMETER Name
        One or more command names to resolve. Accepts pipeline input.

    .PARAMETER HostModuleName
        Optional. The name of the module being analysed. When supplied, commands that
        belong to this module are classified as HostPublic (exported, discoverable via
        Get-Command) or HostPrivate (non-exported, found by probing module scope)
        instead of Installed or NotFound respectively.

    .PARAMETER Trace
        Emits diagnostic trace output describing each resolution, including alias
        following and the source classification applied.

    .EXAMPLE
        Resolve-CommandModule -Name Get-MgUser

        Resolves a single command and reports its module, path, and source.

    .EXAMPLE
        Find-ScriptCommand -Path .\Get-Greeting.ps1 | Resolve-CommandModule

        Resolves every command found in a file, classifying each by source.

    .EXAMPLE
        Find-ScriptCommand -Path .\Get-Greeting.ps1 |
            Resolve-CommandModule -HostModuleName 'PowershellRepoTemplate'

        Resolves every command, distinguishing the host module's own public and
        private functions from external dependencies.

    .OUTPUTS
        PSCustomObject with the properties: Name, Module, ModulePath, Source.

    .NOTES
        Source is a heuristic and does not distinguish gallery-installed modules from
        other locally installed ones; it only separates PowerShell-shipped modules from
        everything else. To build an import list from the results, filter to
        Source -eq 'Installed' and select the unique Module values.

        HostPrivate classification requires the module named by -HostModuleName to be
        loaded in the current session.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [string[]] $Name,

        [Parameter()]
        [string] $HostModuleName,

        [switch] $Trace
    )

    begin {
        if ($Trace) { $InformationPreference = 'Continue' }
        function Write-Trace {
            param([Parameter(Mandatory)][string] $Message)
            Write-Information $Message -Tags 'Trace'
        }

        $FunctionName = $MyInvocation.MyCommand.Name

        # When a host module is named, probe its internal scope to find private
        # functions. Get-Command run from outside only sees exported commands; running
        # it via Invoke executes inside the module's scope where private functions are
        # visible. The private set is the difference between the two.
        $HostModule = $null
        $PrivateHostFunctions = $null
        if ($HostModuleName) {
            $HostModule = Get-Module -Name $HostModuleName
            if ($HostModule) {
                $AllHostFunctions = [System.Collections.Generic.HashSet[string]](
                    $HostModule.Invoke({ Get-Command -Module $args[0] }, $HostModuleName) |
                        Where-Object { $_.CommandType -eq 'Function' } |
                        Select-Object -ExpandProperty Name
                )
                $PublicHostFunctions = [System.Collections.Generic.HashSet[string]](
                    Get-Command -Module $HostModuleName |
                        Where-Object { $_.CommandType -eq 'Function' } |
                        Select-Object -ExpandProperty Name
                )
                $PrivateHostFunctions = [System.Collections.Generic.HashSet[string]](
                    $AllHostFunctions | Where-Object { -not $PublicHostFunctions.Contains($_) }
                )
                Write-Trace ("${FunctionName}: host module '$HostModuleName' -- " +
                    "$($PublicHostFunctions.Count) public, " +
                    "$($PrivateHostFunctions.Count) private")
            }
            else {
                Write-Trace "${FunctionName}: host module '$HostModuleName' is not loaded"
            }
        }
    }

    process {
        foreach ($commandName in $Name) {
            $emittedAny = $false

            # Check the host-module private set independently of Get-Command.
            # A private function shadows any external command with the same name at
            # runtime, but Get-Command from outside cannot see it - checking separately
            # lets us emit both rows when a name collision exists.
            if ($PrivateHostFunctions -and $PrivateHostFunctions.Contains($commandName)) {
                Write-Trace "${FunctionName}: '$commandName' -> $HostModuleName [HostPrivate]"
                [PSCustomObject]@{
                    Name       = $commandName
                    Module     = $HostModuleName
                    ModulePath = $HostModule.ModuleBase
                    Source     = 'HostPrivate'
                }
                $emittedAny = $true
            }

            $command = Get-Command -Name $commandName -ErrorAction SilentlyContinue

            if ($command) {
                while ($command.CommandType -eq 'Alias') {
                    Write-Trace ("${FunctionName}: '$commandName' is an alias for " +
                        "'$($command.ResolvedCommand)'")
                    $command = $command.ResolvedCommand
                }

                # Applications (git, gh, ...) and local functions have no module;
                # guard the property reads so strict mode does not choke on $null.
                $module = $command.Module
                $moduleName = if ($module) { $module.Name } else { $null }
                $modulePath = if ($module) { $module.ModuleBase } else { $null }

                if (-not $module) {
                    $source = 'None'
                }
                elseif ($HostModuleName -and $module.Name -eq $HostModuleName) {
                    $source = 'HostPublic'
                }
                elseif ($module.ModuleBase -and $module.ModuleBase -like "$PSHOME*") {
                    $source = 'Builtin'
                }
                else {
                    $source = 'Installed'
                }

                Write-Trace "${FunctionName}: '$commandName' -> $moduleName [$source]"
                [PSCustomObject]@{
                    Name       = $commandName
                    Module     = $moduleName
                    ModulePath = $modulePath
                    Source     = $source
                }
                $emittedAny = $true
            }

            if (-not $emittedAny) {
                Write-Trace "${FunctionName}: not found '$commandName'"
                [PSCustomObject]@{
                    Name       = $commandName
                    Module     = $null
                    ModulePath = $null
                    Source     = 'NotFound'
                }
            }
        }
    }
}
