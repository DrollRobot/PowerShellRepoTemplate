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

@{
    # Version of THIS config file's shape (the sections and keys below), owned by
    # the template. Declared as a bare hashtable key so Scripts\Compare-Template.ps1
    # reads it with the same version parser it uses for $ScriptVersion in scripts.
    # It compares this against the template's copy: when the two disagree it flags
    # setup.psd1 for a manual diff so you can fold in new options -- it never copies
    # over your own choices. Bump only when the template changes the config's shape.
    ScriptVersion = '1.0.0'

    Project = @{
        # New module name (PascalCase recommended), e.g. 'MyModule'. Used for
        # file renames and as the replacement for 'PowershellRepoTemplate'
        # throughout the repo. Shipped as the template's own name -- a no-op
        # until you change it.
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

    Features = @{
        # Each false removes that feature. All default true ("keep everything")
        # so an unedited config changes nothing here.

        # Documentation site: mkdocs.yml, Docs.ps1, the Docs\ folder (including
        # the PlatyPS-generated command reference), and the docs CI workflow.
        Docs = $true

        # GitHub-recognized community-health files. Independent of each other
        # and of every other feature below.
        SecurityMd     = $true
        ContributingMd = $true

        # The explicit-module-import convention check and its two helper
        # scripts (Scripts\Find-ScriptCommand.ps1, Scripts\Resolve-CommandModule.ps1)
        # -- nothing else uses those helpers, so all three go together.
        ExplicitModuleImport = $true

        # The pre-import dependency check: Source\ScriptsToProcess\Confirm-Dependencies.ps1
        # and Install-Dependencies.ps1, plus the ScriptsToProcess entry in the module
        # manifest that wires the check in. false removes all three together.
        Dependencies = $true

        # Opinionated formatting checks some teams don't want enforced.
        # Removing one also drops its pre-commit hook entry, if present.
        NonASCIICharacters   = $true
        FormatOperator       = $true
        WriteVerboseDebug    = $true
        BacktickContinuation = $true

        # false (default): Tests\Test-FindUnwantedStrings.ps1 stays a shared,
        # tracked test (patterns get committed and reviewed like any other file).
        # true: moves it to .local\tests\ instead, so your patterns are personal
        # and never committed. Tests.ps1 already runs whichever copy it finds.
        UnwantedStringsLocal = $false
    }
}
