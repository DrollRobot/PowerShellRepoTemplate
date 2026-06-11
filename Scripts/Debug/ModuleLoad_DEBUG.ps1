# Example debug launcher: imports the module from source with debug output on.
# Copy this pattern to make per-function debug scripts (see .vscode\launch.json).

# resolve the module root so paths keep working if this folder moves
. "$PSScriptRoot\Find-ModuleRoot.ps1"
$ModuleRoot = (Find-ModuleRoot -Path $PSScriptRoot).Path
$ModuleName = Split-Path -Path $ModuleRoot -Leaf

# debug output on (PSFramework levels; see AGENTS.md)
# Set-PSFConfig -FullName 'PSFramework.Message.Info.Maximum' -Value 8
$InformationPreference = 'Continue'

$Path = "$ModuleRoot\Source\$ModuleName.psd1" # source
# $Path = "$ModuleRoot\$ModuleName.psd1" # built
Write-Host "Importing from: $Path" -ForegroundColor Green
Import-Module $Path -Force
