# =============================================================================
# TEMPLATE SETUP NOTES -- remove this block - FIXME
# =============================================================================
# This file lives in Source/ next to the module manifest. Build-Module
# reads it automatically when pointed at the manifest via -SourcePath.
# Every key here is a default override for a Build-Module parameter.
#
# Typical invocation:
#   Build-Module -SourcePath ./Source/<ModuleName>.psd1
#   (or just: Build-Module  -- if run from the Source/ folder)
# ============================================================================

# Source\Build.psd1

@{
    Path = 'PowershellRepoTemplate.psd1'

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

    # Output location for versioned builds. Relative paths are resolved
    # against this Source/ folder. Build.ps1 reads these values too (for its
    # clean step). Both are ignored when BuildToRoot is $true.
    OutputDirectory          = '../Output'
    VersionedOutputDirectory = $true

    # CUSTOM PROPERTY -- read only by Build.ps1, not by ModuleBuilder, which
    # ignores keys that do not match a Build-Module parameter.
    # $true  = flat, unversioned build to the repo root, for repos distributed
    #          by git clone; the artifacts are committed.
    # $false = versioned build to OutputDirectory above, for Gallery publishing.
    BuildToRoot              = $false

    # Optional: text injected at the very top / bottom of the generated .psm1.
    Prefix = 'Prefix.ps1'
    Suffix = 'Suffix.ps1'
}
