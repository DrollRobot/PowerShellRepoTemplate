function Find-ScriptCommand {
    <#
    .SYNOPSIS
        Finds the PowerShell commands invoked in a script file or text input.

    .DESCRIPTION
        Parses PowerShell code into an abstract syntax tree and returns the unique,
        sorted names of every command invocation it contains. Because parsing is used
        instead of text matching, command names appearing inside strings or comments are
        not reported, and only genuine invocations are returned.

        Dynamic invocations whose name is not known until runtime (for example, calling a
        command through a variable with the call operator) are skipped, since no static
        name can be resolved for them.

    .PARAMETER Path
        Path to a PowerShell file to parse. Cannot be combined with -Text.

    .PARAMETER Text
        A string of PowerShell code to parse. Cannot be combined with -Path.

    .PARAMETER ExcludeLocalFunctions
        Omit commands whose name matches a function defined anywhere in the parsed code
        itself, including functions nested inside other functions. Useful when the goal
        is to find a script's external dependencies rather than every invocation.

    .PARAMETER Trace
        Emits diagnostic trace output describing what is being parsed and which command
        names are found or skipped.

    .EXAMPLE
        Find-ScriptCommand -Path .\Connect-IRTGraph.ps1

        Returns the unique command names invoked in the specified file.

    .EXAMPLE
        Find-ScriptCommand -Text 'Get-MgUser | Where-Object Enabled'

        Returns the command names invoked in the supplied string: Get-MgUser and
        Where-Object.

    .OUTPUTS
        System.String

        One string per unique command name, sorted alphabetically.

    .NOTES
        By default, command names returned include functions defined within the parsed
        code itself; pass -ExcludeLocalFunctions to omit them. To map commands to their
        owning modules, pipe the results through Get-Command and inspect the ModuleName
        property; locally defined functions will resolve to no module.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Path')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Path', Position = 0)]
        [string] $Path,

        [Parameter(Mandatory, ParameterSetName = 'Text')]
        [string] $Text,

        [switch] $ExcludeLocalFunctions,

        [switch] $Trace
    )

    if ($Trace) { $InformationPreference = 'Continue' }
    function Write-Trace {
        param([Parameter(Mandatory)][string] $Message)
        Write-Information $Message -Tags 'Trace'
    }

    $FunctionName = $MyInvocation.MyCommand.Name
    $tokens = $null
    $parseErrors = $null

    if ($PSCmdlet.ParameterSetName -eq 'Path') {
        Write-Trace "${FunctionName}: parsing file '$Path'"
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $Path, [ref] $tokens, [ref] $parseErrors)
    }
    else {
        Write-Trace "${FunctionName}: parsing text input"
        $ast = [System.Management.Automation.Language.Parser]::ParseInput(
            $Text, [ref] $tokens, [ref] $parseErrors)
    }

    if ($parseErrors) {
        Write-Trace "${FunctionName}: $($parseErrors.Count) parse error(s)"
    }

    $isCommand = {
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst]
    }
    $commandAsts = $ast.FindAll($isCommand, $true)

    # Collect every function defined in the parsed code, including functions
    # nested inside other functions. Nested helpers never reach module scope,
    # so callers cannot discover them any other way.
    $localFunctions = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    if ($ExcludeLocalFunctions) {
        $isFunction = {
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
        }
        foreach ($definition in $ast.FindAll($isFunction, $true)) {
            [void] $localFunctions.Add($definition.Name)
        }
    }

    $names = foreach ($command in $commandAsts) {
        $name = $command.GetCommandName()
        if (-not $name) {
            Write-Trace "${FunctionName}: skipped dynamic call (no static name)"
        }
        elseif ($localFunctions.Contains($name)) {
            Write-Trace "${FunctionName}: skipped locally defined function '$name'"
        }
        else {
            Write-Trace "${FunctionName}: found '$name'"
            $name
        }
    }

    $names | Sort-Object -Unique
}
