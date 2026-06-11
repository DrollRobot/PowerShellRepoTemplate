@{
    # =========================================================================
    # ModuleBuilder Notes -- Build.psd1
    #
    # This file lives in Source/ next to the module manifest. Build-Module
    # reads it automatically when pointed at the manifest via -SourcePath.
    # Every key here is a default override for a Build-Module parameter.
    #
    # Typical invocation:
    #   Build-Module -SourcePath ./Source/<ModuleName>.psd1
    #   (or just: Build-Module  -- if run from the Source/ folder)
    # =========================================================================

    Path = 'M365IncidentResponseTools.psd1'

    SourceDirectories = @(
        'Classes'
        'Private'
        'Public'
    )

    PublicFilter = 'Public/*.ps1'

    CopyPaths = @(
        './ScriptsToProcess'
        './Data'
    )

    # OutputDirectory          = '../output'
    # VersionedOutputDirectory = $true

    # Optional: text injected at the very top / bottom of the generated .psm1.
    Prefix = 'Prefix.ps1'
    Suffix = 'Suffix.ps1'
}
