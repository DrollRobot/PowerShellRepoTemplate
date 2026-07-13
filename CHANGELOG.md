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

[Unreleased]: https://github.com/FIXME/FIXME/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/FIXME/FIXME/releases/tag/v1.0.0
