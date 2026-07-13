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

## [1.1.0] - 2026-07-13

### Added

- Pre-commit hooks that run the fast PowerShell formatting/lint checks (syntax,
  line length, backtick continuation, `-f` operator, `Join-Path`, non-ASCII,
  `Write-Verbose`/`Write-Debug`, unwanted strings) against staged files.
- CI runs that same check set plus PSScriptAnalyzer and fails the build on
  findings.

### Changed

- Formatting/lint check scripts (`Tests\Test-*.ps1`) now exit nonzero when they
  find an issue, so pre-commit and CI can gate on them. `Tests.ps1` tallies
  failures across a multi-check run and reports all failing checks, not just the
  last one invoked.

### Removed

- `Tests\Format-TrailingWhitespace.ps1`. Trailing whitespace is now handled by
  the pre-commit `trailing-whitespace` hook.

### Fixed

- `Tests.ps1` now accepts several space-separated check names in one run
  (e.g. `Tests.ps1 LineLength JoinPath`); previously only the first bound.
- Unresolved merge-conflict markers in the docs workflow (`docs.yml`) that left
  invalid YAML in the 1.0.0 release.

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
