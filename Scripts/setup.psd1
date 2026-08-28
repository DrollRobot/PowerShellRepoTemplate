# Scripts\setup.psd1
#
# Config-driven template setup. Edit the values below, then run:
#   .\Scripts\TemplateSetup\Setup-NewProject.ps1
# -DryRun previews every change with nothing applied; -Yes skips the single
# confirmation prompt (still previews first). Every field is documented
# inline below.
#
# This file is not deleted by setup and is not template-only tooling:
# Scripts\Compare-Template.ps1 keeps reading it afterward, so it stays in
# Scripts\ rather than inside the one-time Scripts\TemplateSetup\ folder.

# TODO: Separate new setup items from compare items.

@{
    # Version of THIS config file's shape (the sections and keys below), owned by
    # the template and independent of any script's version. A plain counter, not
    # semver: bump it by one whenever the template adds, removes, or renames a
    # setting here. Scripts\Compare-Template.ps1 compares this against the
    # template's copy -- equal schema versions mean the shapes agree and the
    # contents are not compared at all (your own choices are never drift). When
    # they differ it flags setup.psd1 for a manual diff so you can fold in the new
    # options by hand; it never copies over your values.
    SchemaVersion = 2

    Project = @{
        # New module name. Used for
        # file renames and as the replacement for 'PowershellRepoTemplate'
        # throughout the repo. Shipped as the template's own name -- a no-op
        # until you change it.
        # TODO: Remove template name from comments. Won't make sense in
        # downstream package.
        Name = 'PowershellRepoTemplate'

        # Your GitHub username or org, e.g. 'octocat'. Fills in the FIXME
        # owner/repo placeholders in clone URLs, CI badges, and the docs-site
        # URL: 'FIXME/FIXME' -> '<GitHubUser>/<Name>' and
        # 'FIXME.github.io/FIXME' -> '<GitHubUser>.github.io/<Name>'. Leave
        # blank (the shipped default) to skip and fill those in by hand later;
        # they show up in the closing FIXME report either way.
        GitHubUser = ''
    }

    License = @{
        # One of: 'mit', 'apache', 'gnu', 'proprietary', 'none'. No default is
        # a genuine no-op -- the template ships 4 unclaimed LICENSE.*.FIXME
        # candidates and a choice is mandatory. This section WILL fail
        # validation on an unedited config; that's deliberate, not a bug.
        Key     = ''

        # Copyright year. Required unless Key is 'gnu' (the GPL text carries
        # its own notice) or 'none'.
        Year    = ''

        # Copyright holder name. Required unless Key is 'gnu' or 'none'.
        Name    = ''

        # Owning company. Required only when Key is 'proprietary'.
        Company = ''
    }

    Git = @{
        # DESTRUCTIVE: deletes .git and runs `git init` for a fresh history.
        # Refused (as a validation error, before anything else runs) unless
        # the repo still looks like a pristine, un-reinitialized template
        # clone.
        Reinit = $false
        Branch = 'main'
    }

    Release = @{
        # Whether pushing a v* tag runs .github/workflows/release.yml's
        # build-and-publish job. Set this to $true by hand once ModuleBuilder
        # packaging applies to your project and you are ready to start cutting real
        # releases.
        Enabled = $false
    }

    Features = @{
        # Each false removes that feature. All default true ("keep everything")
        # so an unedited config changes nothing here.

        # Documentation site: mkdocs.yml, Docs.ps1, the Docs\ folder (including
        # the generated command reference), and the docs CI workflow.
        Docs = $true

        # GitHub-recognized community-health files. Independent of each other
        # and of every other feature below.
        SecurityMd     = $true
        ContributingMd = $true

        # The explicit-module-import convention check and its two helper
        # scripts (Scripts\Find-ScriptCommand.ps1, Scripts\Resolve-CommandModule.ps1)
        # -- nothing else uses those helpers, so all three go together.
        ExplicitModuleImport = $true

        # The standalone-script Script Generators: Build\Generators\
        # ConvertTo-StandaloneScript.ps1 (emits a single .ps1 with the whole
        # built module inlined) and ConvertTo-ScriptVariant.ps1 (re-bakes that
        # script once per variant), plus Source\Private\Lib\Resolve-EnvParameter.ps1,
        # the module half of their EnvResolver contract, and the three Pester
        # files covering them. false removes all six together. A project that
        # ships only a module does not need them.
        StandaloneScriptGenerator = $true

        # The Intune Win32 packaging generator:
        # Build\Generators\ConvertTo-IntuneWinPackage.ps1, the Install /
        # Uninstall / Detect / Write-PackageLog sources it renders under
        # Build\Generators\Intune\, and its Pester file. Independent of
        # StandaloneScriptGenerator above -- it packages any payload .ps1 --
        # though the two are usually taken together.
        IntunePackageGenerator = $true

        # The pre-import dependency check: Source\ScriptsToProcess\Confirm-Dependency.ps1,
        # Install-Dependency.ps1 and the RequiredModules.psd1 they both read, plus that
        # check's Pester test and the ScriptsToProcess entry in the module manifest that
        # wires the check in. false removes all of them together.
        InstallDependenciesScript = $true

        # Opinionated lint checks some teams don't want enforced. Removing one
        # deletes its Tests\Pester\<Name>.Lint.Tests.ps1 file; the shared
        # pre-commit lint hook stays and runs whichever checks remain.
        NonASCIICharacters   = $true
        FormatOperator       = $true
        WriteVerboseDebug    = $true
        BacktickContinuation = $true

        # false (default): Tests\Pester\UnwantedStrings.Lint.Tests.ps1 stays a
        # shared, tracked check (patterns get committed and reviewed like any
        # other file). true: moves it to .local\tests\ instead, so your patterns
        # are personal and never committed. Tests.ps1 already runs
        # whichever copy it finds.
        UnwantedStringsLocal = $false
    }
}
