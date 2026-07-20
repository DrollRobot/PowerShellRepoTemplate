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

## [1.1.0] - 2026-07-20

### Added

- Pre-commit hooks that run the fast PowerShell formatting/lint checks (syntax,
  line length, backtick continuation, `-f` operator, `Join-Path`, non-ASCII,
  `Write-Verbose`/`Write-Debug`, unwanted strings) against staged files.
- CI runs that same check set plus PSScriptAnalyzer and fails the build on
  findings.
- `Setup-NewProject.ps1`: `-License proprietary` and `-License none` options,
  plus a warning when a written LICENSE file still contains a FIXME placeholder.
- `Scripts\Compare-Template.ps1`: a new script, run from a child repo, that
  reports and reconciles drift against a template checkout -- version-checking
  versioned dev scripts and content-comparing non-versioned config/docs.
- `Compare-Template.ps1` can exclude specific versioned scripts (e.g.
  `Tests.ps1`) from the copy/diff workflow via a template-owned list, since
  children are expected to customize them.
- `Tests.ps1`: a `-Quiet` flag for the PowerShell lint checks.
- `Tests.ps1`: a `NonLive`/`Live`/`Destructive` Pester tag scheme, gating
  destructive tests behind the `DISPOSABLE_ENVIRONMENT` environment variable.
- `Setup-NewProject.ps1` and `Compare-Template.ps1` now read a shared
  `Scripts\setup.psd1` config (a file whitelist plus optional feature toggles)
  instead of requiring re-typed CLI flags on every run.

### Changed

- Formatting/lint check scripts (`Tests\Test-*.ps1`) now exit nonzero when they
  find an issue, so pre-commit and CI can gate on them. `Tests.ps1` tallies
  failures across a multi-check run and reports all failing checks, not just the
  last one invoked.
- `Push-NewTagToMain.ps1` resolves and bumps the module manifest from `Source\`
  (the ModuleBuilder source of truth) instead of a built root copy, and gained
  a `-Build` parameter to optionally build and commit artifacts as part of the
  release.
- `Push-NewTagToMain.ps1`'s `-Build` parameter no longer defaults; it must be
  specified explicitly.
- Pester dependency bumped to 6.0.0.

### Removed

- `Tests\Format-TrailingWhitespace.ps1`. Trailing whitespace is now handled by
  the pre-commit `trailing-whitespace` hook.

### Fixed

- `Tests.ps1` now accepts several space-separated check names in one run
  (e.g. `Tests.ps1 LineLength JoinPath`); previously only the first bound.
- Unresolved merge-conflict markers in the docs workflow (`docs.yml`) that left
  invalid YAML in the 1.0.0 release.
- Module version bumps now edit the `ModuleVersion` line surgically instead of
  via `Update-ModuleManifest`, which re-serialized and corrupted the curated
  source manifest (dropped comments, collapsed `FunctionsToExport`).
- `Tests.ps1` no longer aborts on a stale or unset `$LASTEXITCODE` left over
  from an earlier command.
- `Build.ps1` no longer fails with a `ConvertTo-Script` error.
- `Compare-Template.ps1` no longer reports `Install-Dependencies.ps1` as
  drifted from the template; it is expected to always differ per child.
- Module root resolution now works correctly inside a git worktree (it
  previously assumed the containing folder was named after the module, which
  a worktree folder is not).
- Dev scripts (`Tests.ps1`, the lint checkers, and the worktree/release/setup
  scripts) use `throw` instead of `exit` on failure, so running one
  dot-sourced or directly at an interactive prompt no longer kills the whole
  calling PowerShell session.
- `Tests.ps1`'s own final exit code now reflects failures across a multi-check
  run instead of silently staying zero once Pester had run at least once.
- Six lint checkers (`BacktickContinuation`, `JoinPath`, `FormatOperator`,
  `WriteVerboseDebug`, `FixmeComments`, `FindUnwantedStrings`) now correctly
  flag violations in single-line files.
- `Test-FixmeComments`'s self-exclusion now correctly matches its own file.
- A fresh build no longer fails outright due to a missing `Source/Data/`.
- A debug helper (`Scripts\Debug\ModuleLoad_DEBUG.ps1`) no longer risks reading
  a stale `$LASTEXITCODE` left over from an earlier command.

### Security

- `Tests.ps1`'s `Destructive` gate now honors tags inherited from an enclosing
  `Describe`/`Context`, restoring the safety net that refuses an ambiguous
  local/remote destructive test run.

## [1.0.0] - 2026-07-13

### Added

- Initial release: a ModuleBuilder scaffold for new PowerShell modules, with the
  `Source/` layout and a sample `Get-Greeting` public function.
- Test harness (`Tests.ps1`): Pester tests plus a suite of offline lint checks
  (line length, whitespace, non-ASCII, format operator, Join-Path, explicit
  module imports, and more) and PSScriptAnalyzer.
- Developer helper scripts for git worktrees, releases, dependency
  bootstrapping, and project setup.
- Build tooling (ModuleBuilder), PlatyPS docs generation, GitHub Actions CI, and
  pre-commit hooks.

[Unreleased]: https://github.com/FIXME/FIXME/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/FIXME/FIXME/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/FIXME/FIXME/releases/tag/v1.0.0
