[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseDeclaredVarsMoreThanAssignments', 'ScriptVersion')]
$ScriptVersion = '1.0.0'

function Find-ModuleRoot {
    <#
    .SYNOPSIS
        Locates the nearest PowerShell module root above a given path.

    .DESCRIPTION
        Walks up the directory tree from the given starting path, looking for a
        directory that contains a .psd1 manifest with the same name as the
        directory. That is the conventional layout for a PowerShell module root.

        Accepts either a file or directory path as the starting point. When a
        file path is given, the search begins from its parent directory.

    .PARAMETER Path
        The path to start searching from. Defaults to the current directory.

    .EXAMPLE
        Find-ModuleRoot -Path $PSScriptRoot

        Returns the module root above the calling script's directory.

    .OUTPUTS
        PSCustomObject with properties Name (string) and Path (string), or
        $null if no module root is found before reaching the filesystem root.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [string] $Path = (Get-Location).Path
    )

    $current = Get-Item -LiteralPath $Path
    if (-not $current.PSIsContainer) {
        $current = $current.Parent
    }

    while ($current) {
        $ManifestParams = @{
            Path     = Join-Path -Path $current.FullName -ChildPath "$($current.Name).psd1"
            PathType = 'Leaf'
        }
        if (Test-Path @ManifestParams) {
            return [PSCustomObject]@{
                Name = $current.Name
                Path = $current.FullName
            }
        }
        $current = $current.Parent
    }

    return $null
}
