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

    # EXAMPLE -- Script Generators. Uncomment and edit to turn the built module
    # into extra deliverables. Build.ps1 dot-sources Build\Generators\*.ps1
    # before the ModuleBuilder step, then ModuleBuilder runs the entries below
    # in declared order. Delete this block if the project ships only a module.
    #
    # Generators = @(
    #     # Emits <Function>.ps1: a standalone script with the whole built
    #     # module inlined, exposing the function's own parameters and help.
    #     # Defaults are baked into the hoisted param block; EnvResolver names
    #     # a command in the module that finds injected env_<Name> values, so
    #     # precedence is argument > env > baked. Omit both for a plain script.
    #     @{
    #         Generator   = 'ConvertTo-StandaloneScript'
    #         Function    = 'Repair-Sysmon'
    #         GUID        = '350d7c58-6a19-48e6-84f2-63f315fb0f15'
    #         Destination = '..'
    #         Defaults    = @{
    #             LogPath = 'C:\ProgramData\Contoso\Repair-Sysmon.ps1.log'
    #         }
    #         EnvResolver = 'Resolve-EnvParameter'
    #     }
    #
    #     # Packages a payload .ps1 as a self-healing Intune Win32 app. List it
    #     # after the entry that emits its payload. The payload runs with no
    #     # arguments, so everything it needs must be baked in above.
    #     @{
    #         Generator          = 'ConvertTo-IntuneWinPackage'
    #         PayloadPath        = '../Repair-Sysmon.ps1'
    #         OrgName            = 'Contoso'
    #         PackageName        = 'Repair-Sysmon.ps1-Intune'
    #         IntuneLogPath      = 'C:\ProgramData\Contoso\Repair-Sysmon.ps1-Intune.log'
    #         ScheduleType       = 'Daily'
    #         ScheduleAt         = '10:00'
    #         RandomDelayMinutes = 30
    #         Destination        = '..'
    #     }
    # )
    #
    # ConvertTo-ScriptVariant is NOT listed here: it takes no [Ast] parameter,
    # so ModuleBuilder ignores it. Call it from Build\PostBuild.ps1 once per
    # variant, after the standalone script above exists.
}
