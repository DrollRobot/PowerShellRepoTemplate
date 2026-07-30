# Source\ScriptsToProcess\RequiredModules.psd1

# Read by both Confirm-Dependency.ps1 and Install-Dependency.ps1

@{
    ModuleVersion = '0' # ModuleVersion required to prevent PSSA PSMissingModuleManifestField error

    RequiredModules = @(
        # FIXME: declare this module's dependencies here, e.g.
        # 'PSFramework'
        # @{ ModuleName = 'PSFramework'; ModuleVersion = '1.13.0' }

        # Dev/Test dependencies
        @{ModuleName = 'Pester'; ModuleVersion = '6.0.0' }
        @{ModuleName = 'PSScriptAnalyzer'; ModuleVersion = '1.25.0' }
        @{ModuleName = 'ModuleBuilder'; ModuleVersion = '3.2.16' }
        @{ModuleName = 'PlatyPS'; ModuleVersion = '0.14.0' }
    )
}
