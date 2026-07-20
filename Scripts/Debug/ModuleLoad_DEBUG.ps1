# Example debug launcher: imports the module from source with debug output on.
# Copy this pattern to make per-function debug scripts (see .vscode\launch.json).

# resolve the repo root via git so paths keep working if this folder moves
$global:LASTEXITCODE = 0
$ModuleRoot = git -C $PSScriptRoot rev-parse --show-toplevel
if ($LASTEXITCODE -ne 0) { throw 'Not inside a git repository.' }
$ModuleRoot = (Resolve-Path -LiteralPath $ModuleRoot).Path
$ModuleName = Split-Path -Path $ModuleRoot -Leaf

# debug output on (PSFramework levels; see AGENTS.md)
# Set-PSFConfig -FullName 'PSFramework.Message.Info.Maximum' -Value 8
$InformationPreference = 'Continue'

$Path = "$ModuleRoot\Source\$ModuleName.psd1" # source
# $Path = "$ModuleRoot\$ModuleName.psd1" # built
Write-Host "Importing from: $Path" -ForegroundColor Green
Import-Module $Path -Force
