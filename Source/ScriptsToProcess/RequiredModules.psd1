# Source\ScriptsToProcess\RequiredModules.psd1

# Read by both Confirm-Dependency.ps1 and Install-Dependency.ps1

@{
    # ModuleVersion required to prevent PSSA PSMissingModuleManifestField error
    ModuleVersion = '0'

    RequiredModules = @(
        # FIXME: declare this module's dependencies here, e.g.
        # 'PSFramework'
        # @{ ModuleName = 'PSFramework'; ModuleVersion = '1.13.0' }
    )
}
