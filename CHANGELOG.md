<!--
=============================================================================
TEMPLATE SETUP NOTES -- remove this block - FIXME
=============================================================================
This CHANGELOG.md is part of PowershellRepoTemplate, a starter repo scaffold.
- Replace "FIXME/FIXME" in the comparison/release URLs with your GitHub
  owner/repo.
- Fill in the [1.0.0] release date and describe your initial release under
  ### Added.
=============================================================================
-->

# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `Source\Private\Lib\Write-log\`: an internal logging library -- `Set-LogConfig`,
  `Write-Log`, `Get-LogMessage`, `Get-LogConfig`, `Write-LogEvent`, `Write-LogEventBuffer`
  and `Register-LogEventSource` -- with memory, host, file and Windows event log targets.
  `Source\Suffix.ps1` creates its context at module load; five Pester files cover it; and
  `Compare-Template.ps1` tracks every file by version. Opt out with `Features.WriteLog` in
  `setup.psd1`, whose schema version is now 3.
- `Scripts\TemplateSetup\Remove-WriteLog.ps1`: the removal step behind that toggle. It
  deletes the library and its tests and drops the `Set-LogConfig` block from
  `Source\Suffix.ps1`, refusing to leave a stray call the module could no longer import
  with. Runnable on its own (`-DryRun` to preview).
- `Scripts\TemplateSetup\Set-ModuleManifest.ps1`: setup's manifest step, now its own
  runnable script. It stamps a fresh GUID, drops the placeholder note comments above the
  GUID key, and fills in Author, CompanyName and Copyright.
- `Scripts\TemplateSetup\Remove-TemplateSetup.ps1`: setup's own cleanup step. It offers
  to delete `Scripts\TemplateSetup\` along with the `Tests\Pester\` files covering the
  scripts in it -- tests that would otherwise cover scripts the project no longer ships.
  Setup runs it last; it is also runnable on its own (`-DryRun` to preview, `-Yes` to skip
  the prompt).

### Changed

- The Intune package logger (`Build\Generators\Intune\Write-PackageLog.ps1`) and
  `Set-LogConfig` expand cmd-style `%Name%` environment variable references in the log path,
  so a path baked in at build time resolves on the endpoint that runs the script.
- Setup ends by offering to remove itself: after the FIXME report, the new
  `remove_template_setup` step lists the setup folder and its tests, then asks. It is
  skipped when an earlier step reported a problem, so a failed run keeps the scripts
  available for a re-run. `-Yes` answers the offer, as it does for the git-reinit step.
- Setup fills in the module manifest as its own step (`set_module_manifest`) instead of
  stamping only the GUID inside the rename step. Author, CompanyName and Copyright come
  from the existing `[License]` fields (`Name`, `Company`, `Year`) in `setup.psd1`, which
  now documents that it feeds both the LICENSE file and the manifest.

## [1.2.0] - 2026-08-31

### Added

- Script Generators: a build step that renders standalone `.ps1` files from module
  source. Three ship with the template -- a standalone script, named per-customer
  variants, and a self-healing Intune Win32 package -- each opt-in in `setup.psd1`.
- Standalone scripts can bake in build-time defaults and read parameters a deployment
  platform injects as `env_<Name>` variables.
- A release workflow that builds, zips, and publishes a GitHub release on a `v*` tag,
  disarmed until `Release.Enabled` is set.
- One dependency list, `RequiredModules.psd1`, read by both dependency scripts.
- Setup fills in the GitHub owner/repo placeholders and removes the sample function
  and the ModuleBuilder notes.
- `Push-NewTagToMain.ps1`: `-NoManifest`, for tagging a repo with no module manifest.
- `New-Worktree.ps1`: `-NoOpenVSCode`, to skip the editor launch.

### Changed


- **BREAKING** `Tests.ps1` takes comma-separated categories, a list of paths, and an
  overriding `-ConfigPath`. The `NonLive` tag and category are named `NotLive`.
- **BREAKING** Docs are generated with Microsoft.PowerShell.PlatyPS 1.0.3, into
  `Docs\<ModuleName>\` rather than `Docs\Commands\`. Comment-based help needs the
  format described in `MIGRATING.PLATYPS.md`.
- **BREAKING** Both dependency scripts read `RequiredModules.psd1` instead of a
  manifest, and no longer call each other.
- **BREAKING** `Build.ps1` reads its build target from `Source\Build.psd1` instead of
  the `-BuildToRoot` switch, and mints a build id per run for the generators.
- **BREAKING** Setup moved to `Scripts\TemplateSetup\`, and `setup.psd1` carries an
  integer `SchemaVersion`.
- The code-style checks are Pester lint tests now, matching parsed code
  instead of text. They run as the `Lint` category or one category per check, and
  `# noqa:` markers are named after the check.
- `Compare-Template.ps1` compares template-owned files by version instead of content:
  matching versions are skipped, drift goes to a diff, and `setup.psd1` is never
  copied over.

### Removed

- The here-string inline module generator, superseded by the standalone generator: no
  here-string closer collisions, and PowerShell classes work natively.
- The standalone `Tests\Test-*.ps1` code-style checkers, replaced by the lint tests.

### Fixed

- Setup no longer aborts partway through. Declining the dependency feature, the FIXME
  report, and a single-file rename preview each threw.
- Importing a module no longer installs the build tooling, and a missing dependency
  reports what is missing instead of a bare `ScriptHalted`.
- Docs generation regenerates every page instead of merging, names the command behind
  a failure, and loads declared dependencies before importing the module.
- `Push-NewTagToMain.ps1` checks for a duplicate tag before any merge, and retries the
  release commit when an auto-fixing hook repairs the tree.
- The template setup notes box is stripped whole, from every file that carries one.

## [1.1.0] - 2026-07-20

### Added

- Pre-commit hooks running the lint checks against staged files, and CI running
  the same checks plus PSScriptAnalyzer.
- `Compare-Template.ps1`: a new script that reports and reconciles a child repo's
  drift against a template checkout, with a template-owned exclusion list.
- `Setup-NewProject.ps1` and `Compare-Template.ps1` read a shared
  `Scripts\setup.psd1` config instead of re-typed CLI flags.
- `Setup-NewProject.ps1`: `-License proprietary` and `-License none`.
- `Tests.ps1`: a `-Quiet` flag for the lint checks.
- `Tests.ps1`: the `NotLive`/`Live`/`Destructive` tag scheme, gating destructive
  tests on `DISPOSABLE_ENVIRONMENT`.

### Changed

- `Tests\Test-*.ps1` exit nonzero on findings so pre-commit and CI can gate on
  them; `Tests.ps1` tallies failures across a multi-check run.
- `Push-NewTagToMain.ps1` bumps the manifest under `Source\` instead of a built
  root copy, and gained a `-Build` parameter (no default).
- Pester dependency bumped to 6.0.0.

### Removed

- `Tests\Format-TrailingWhitespace.ps1`, replaced by the pre-commit
  `trailing-whitespace` hook.

### Fixed

- `Tests.ps1` accepts several space-separated check names in one run.
- `Tests.ps1` and the debug helpers no longer abort on a stale `$LASTEXITCODE`,
  and `Tests.ps1`'s exit code reflects failures across a multi-check run.
- Dev scripts `throw` instead of `exit`, so running one at an interactive prompt
  no longer kills the session.
- Version bumps edit the `ModuleVersion` line surgically instead of corrupting
  the source manifest through `Update-ModuleManifest`.
- Module root resolution works inside a git worktree.
- Six lint checkers flag violations in single-line files, and
  `Test-FixmeComments` excludes its own file correctly.
- `Build.ps1` no longer fails with a `ConvertTo-Script` error, or on a missing
  `Source\Data\`.
- `Compare-Template.ps1` no longer reports `Install-Dependencies.ps1` as drifted.
- Invalid YAML left in `docs.yml` by the 1.0.0 release.

### Security

- `Tests.ps1`'s `Destructive` gate honors tags inherited from an enclosing
  `Describe`/`Context`, restoring its refusal of an ambiguous local/remote run.

## [1.0.0] - 2026-07-13

### Added

- Initial release: a ModuleBuilder scaffold for new PowerShell modules, with the
  `Source\` layout and a sample `Get-Greeting` public function.
- `Tests.ps1`: Pester tests, offline lint checks, and PSScriptAnalyzer.
- Helper scripts for git worktrees, releases, dependency bootstrapping, and
  project setup.
- ModuleBuilder build tooling, PlatyPS docs, GitHub Actions CI, and pre-commit
  hooks.

[Unreleased]: https://github.com/FIXME/FIXME/compare/v1.2.0...HEAD
[1.2.0]: https://github.com/FIXME/FIXME/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/FIXME/FIXME/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/FIXME/FIXME/releases/tag/v1.0.0
