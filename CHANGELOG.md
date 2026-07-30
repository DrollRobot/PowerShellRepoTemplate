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

- `Setup-NewProject.ps1` now removes `ModuleBuilderNotes.md` files.
- `Setup-NewProject.ps1` now removes the sample `Get-Greeting` function.
- `Tests.ps1`: a `Lint` category, plus one category per lint check.
- `Tests.ps1`: `-Path` accepts a list; `-ConfigPath` overrides `TestConfig.psd1`.
- `Read-LintFile.ps1`: shared file reader for the lint checks.
- `TestConfig.psd1`: a `FailOnFixme` setting (default `$false`).
- `setup.psd1`: a `Release.Enabled` item gating the release workflow.
- `RequiredModules.psd1`: one dependency list read by both dependency scripts.
- `Compare-Template.ps1`: tracks `RequiredModules.psd1` and `Confirm-Dependency.Tests.ps1`.

### Changed

- **BREAKING** `Tests.ps1`: multiple categories are comma-separated
  (`.\Tests.ps1 NotLive,PSSA`); bare arguments after the category are paths.
- **BREAKING** `Build.ps1`: build target declared by `BuildToRoot` in
  `Source\Build.psd1`, not the `-BuildToRoot` switch.
- The code-style checks are Pester lint tests now, matching parsed code instead
  of text. `# noqa:` markers are named after the check.
- `Tests.ps1`: `FindUnwantedStrings` renamed `UnwantedStrings`, `AutoFormat`
  renamed `PSSAAutoFormat`.
- `.pre-commit-config.yaml`: one `ps-lint` hook replaces six per-check hooks, and
  checks staged files only.
- `Compare-Template.ps1`: the lint checks and their helpers are `-BlindCopy`.
- `Setup-NewProject.ps1`: declining a formatting feature deletes its lint test.
- `setup.psd1`: `Features.Dependencies` renamed `Features.InstallDependenciesScript`.
- `Install-Dependencies.ps1` and `Confirm-Dependencies.ps1` renamed singular.
- **BREAKING** Both dependency scripts read `ScriptsToProcess\RequiredModules.psd1`
  instead of a manifest, and no longer call each other.
- `Confirm-Dependency.ps1`: runs its body in a scriptblock, so nothing leaks into the
  importing session; `$Global:ModuleDependenciesChecked` is keyed by the script's folder.
- `Compare-Template.ps1`: `Install-Dependency.ps1` is `-BlindCopy` now that its
  hand-edit FIXME block is gone.

### Removed

- **BREAKING** `Install-Dependency.ps1`: the `-Check` and `-Quiet` parameters and the
  hard-coded fallback module list.
- `Tests.ps1`: the `Formatting` and `TrailingWhitespace` categories.
- The standalone `Tests\Test-*.ps1` code-style checkers and their Pester
  harnesses, replaced by the lint checks.
- `Build.ps1`: the `-BuildToRoot` switch.
- `Push-NewTagToMain.ps1`: the `-Build` parameter.

### Fixed

- `Setup-NewProject.ps1`: declining `Features.InstallDependenciesScript` threw
  `CommandNotFoundException`.
- `Setup-NewProject.ps1`: the rename preview threw `PropertyNotFoundException` on
  a single matched file.
- `Docs.ps1`: regenerates every page instead of merging, so edits to a function's
  existing help now reach `Docs\Commands`.
- `Install-Dependency.ps1` never found the manifest once deployed under
  `ScriptsToProcess\`, so its module list was silently always empty.
- `Setup-NewProject.ps1`: declining `Features.InstallDependenciesScript` left
  `Confirm-Dependency.Tests.ps1` behind, failing the child repo's test run.
- `Confirm-Dependency.ps1` no longer scans the whole module tree at import, nor
  runs the entire check twice when a module is missing.
- Both dependency scripts: a `MaximumVersion`-only entry printed `(latest) <= x`.

## [1.2.0] - 2026-07-22

### Added

- `Set-GitHubUser.ps1`: fills in the GitHub owner/repo placeholders, driven by
  `Project.GitHubUser` in `setup.psd1`.
- `Test-LineLength.ps1`: an `-AnyType` switch to check files of any extension.
- `Build.ps1`: support for project-local Script Generators under
  `Build\Generators\`.
- `release.yml`: builds, zips `Output\`, and publishes a GitHub release on a `v*`
  tag.
- `Push-NewTagToMain.ps1`: a `-NoManifest` switch for tagging a manifest-less repo.
- `Compare-Template.ps1`: tracks `AGENTS.COMMITTING.md` and `Tests.ps1`.

### Changed

- **BREAKING** `Setup-NewProject.ps1` moved to `Scripts\TemplateSetup\`, with
  shared helpers in `_Common.ps1`. `setup.psd1` stays in `Scripts\`.
- `Compare-Template.ps1`: the versioned pre-flight compares itself first and ends
  the run if replaced, prints one summary line per file, compares `setup.psd1` by
  `ScriptVersion`, and sends a version match with differing content to the diff
  instead of offering to copy over it.
- `Docs.ps1`: generates from the source manifest under `Source\`, writing to
  `Docs\Commands`.
- `Push-NewTagToMain.ps1`: the manifest lookup no longer walks up the directory
  tree.

### Fixed

- `Tests.ps1 -Built` falls back to a flat `Output\<ModuleName>\` build layout.
- The TEMPLATE SETUP NOTES box is now stripped whole, and recognized in
  `Source\Build.psd1`, `ci.yml`, `dependabot.yml`, and the issue templates.
- `Build.ps1` no longer throws under strict mode when `Build.psd1` has no
  `CopyPaths` key.
- `Push-NewTagToMain.ps1` checks for a duplicate tag before any merge or commit.

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
