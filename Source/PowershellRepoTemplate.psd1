#
# Module manifest for module 'PowershellRepoTemplate'
#
# FIXME: rename this file and the strings below to your module name, then set
# Author, Copyright, Description, and a fresh GUID (New-Guid).
#

@{

    # Script module or binary module file associated with this manifest.
    RootModule = 'PowershellRepoTemplate.psm1'

    # Version number of this module.
    ModuleVersion     = '1.0.0'

    # Supported PSEditions
    # CompatiblePSEditions = @()

    # ID used to uniquely identify this module
    # FIXME: generate a fresh GUID with New-Guid for your module.
    # Note: an all-zeros placeholder breaks ModuleBuilder, which treats
    # [Guid]::Empty as "manifest could not be parsed".
    GUID              = 'a5d1fa8d-6ab7-49b4-afd4-2f1d82dff055'

    # Author of this module
    Author            = 'FIXME'

    # Company or vendor of this module
    CompanyName       = 'Unknown'

    # Copyright statement for this module
    Copyright         = '(c) FIXME. All rights reserved.'

    # Description of the functionality provided by this module
    # Description = ''

    # Minimum version of the PowerShell engine required by this module
    PowerShellVersion = '5.1'

    # Name of the PowerShell host required by this module
    # PowerShellHostName = ''

    # Minimum version of the PowerShell host required by this module
    # PowerShellHostVersion = ''

    # Minimum version of Microsoft .NET Framework required by this module. This prerequisite is
    # valid for the PowerShell Desktop edition only.
    # DotNetFrameworkVersion = ''

    # Minimum version of the common language runtime (CLR) required by this module.
    # This prerequisite is valid for the PowerShell Desktop edition only.
    # ClrVersion = ''

    # Processor architecture (None, X86, Amd64) required by this module
    # ProcessorArchitecture = ''

    # Modules that must be imported into the global environment prior to importing this module
    RequiredModules   = @(
        # FIXME optionally use lazy loading with Confirm-Dependencies.ps1 and
        # Install-Dependencies.ps1. If lazy loading, put modules in
        # Install-Dependencies and here, but comment them out here.


        # Dev/test dependencies -- not required for most users
        @{ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
        @{ModuleName = 'PlatyPS'; ModuleVersion = '0.14.0' }
        @{ModuleName = 'ModuleBuilder'; ModuleVersion = '3.2.16' }
    )

    # Assemblies that must be loaded prior to importing this module
    # RequiredAssemblies = @()

    # Script files (.ps1) that are run in the caller's environment prior to importing this module.
    # Runs in caller scope (not module scope), so functions defined here are NOT tracked by
    # the module and survive Import-Module -Force reimports.
    ScriptsToProcess  = @(
        'ScriptsToProcess\Confirm-Dependencies.ps1'
    )

    # Type files (.ps1xml) to be loaded when importing this module
    # TypesToProcess = @()

    # Format files (.ps1xml) to be loaded when importing this module
    # FormatsToProcess = @()

    # Modules to import as nested modules of the module specified in RootModule/ModuleToProcess
    # Source files are dot-sourced dynamically by the dev loader .psm1 in Source/
    # NestedModules     = @()

    # ModuleBuilder Notes: FunctionsToExport must remain '*' in the source manifest.
    # Build-Module replaces it at build time with the actual list of public function
    # names it discovers via the PublicFilter pattern in Build.psd1.
    # Functions to export from this module, for best performance, do not use wildcards and
    # do not delete the entry, use an empty array if there are no functions to export.
    FunctionsToExport = '*'

    # Cmdlets to export from this module, for best performance, do not use wildcards and
    # do not delete the entry, use an empty array if there are no cmdlets to export.
    CmdletsToExport   = @()

    # Variables to export from this module
    VariablesToExport = @()

    # ModuleBuilder Notes: AliasesToExport must remain '@()' in the source manifest.
    # Build-Module replaces it with the aliases it discovers from [Alias()] attributes
    # on public functions in the Public/ directory.
    # Aliases to export from this module, for best performance, do not use wildcards and
    # do not delete the entry, use an empty array if there are no aliases to export.
    AliasesToExport   = @()

    # DSC resources to export from this module
    # DscResourcesToExport = @()

    # List of all modules packaged with this module
    # ModuleList = @()

    # List of all files packaged with this module
    # FileList = @()

    # Private data to pass to the module specified in RootModule/ModuleToProcess. This may also
    # contain a PSData hashtable with additional module metadata used by PowerShell.
    PrivateData       = @{

        PSData = @{

            # Tags applied to this module. These help with module discovery in online galleries.
            # Tags = @()

            # A URL to the license for this module.
            # LicenseUri = ''

            # A URL to the main website for this project.
            # ProjectUri = ''

            # A URL to an icon representing this module.
            # IconUri = ''

            # ReleaseNotes of this module
            # ReleaseNotes = ''

            # Prerelease string of this module
            # Prerelease = ''

            # Flag to indicate whether the module requires explicit user acceptance for
            # install/update/save
            # RequireLicenseAcceptance = $false

            # External dependent modules of this module
            # ExternalModuleDependencies = @()

        } # End of PSData hashtable

    } # End of PrivateData hashtable

    # HelpInfo URI of this module
    # HelpInfoURI = ''

    # Default prefix for commands exported from this module. Override the default prefix using
    # Import-Module -Prefix.
    # DefaultCommandPrefix = ''
}
