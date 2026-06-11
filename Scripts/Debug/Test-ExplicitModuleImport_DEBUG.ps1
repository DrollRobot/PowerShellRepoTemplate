# resolve the module root so paths keep working if this folder moves
. "$PSScriptRoot\Find-ModuleRoot.ps1"
$ModuleRoot = (Find-ModuleRoot -Path $PSScriptRoot).Path
$ModulePath = "$ModuleRoot\Source\M365IncidentResponseTools.psd1" # source
# $ModulePath = "$ModuleRoot\M365IncidentResponseTools.psd1" # built
Write-Host "Importing from: $ModulePath" -ForegroundColor Green
Import-Module $ModulePath -Force

# debug output on
# Set-PSFConfig -FullName 'PSFramework.Message.Info.Maximum' -Value 8
# $InformationPreference = 'Continue'

# debug output off
$InformationPreference = 'SilentlyContinue'

# scan source folder
# & "$ModuleRoot\Tests\Test-ExplicitModuleImport.ps1" -Path $ModuleRoot -Recurse

# scan specific files
# & "$ModuleRoot\Tests\Test-ExplicitModuleImport.ps1" `
#     -Path "$ModuleRoot\Source\Public\Email\Get-IRTMessageTrace.ps1"
# & "$ModuleRoot\Tests\Test-ExplicitModuleImport.ps1" -Path "$ModuleRoot\Source\Suffix.ps1"
$CheckPath = "$ModuleRoot\Source\Public\OnPremAd\Find-IRTDomainController.ps1"
& "$ModuleRoot\Tests\Test-ExplicitModuleImport.ps1" -Path $CheckPath
