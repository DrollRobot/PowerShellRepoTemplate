<!--
=============================================================================
TEMPLATE SETUP NOTES -- remove this block - FIXME
=============================================================================
This CONTRIBUTING.md is part of PowershellRepoTemplate, a starter repo
scaffold.

Purpose: CONTRIBUTING.md is recognized automatically by GitHub. It is linked
in the sidebar when someone opens a new issue or pull request, prompting them
to read your guidelines before submitting. It tells contributors how to set
up a dev environment, run checks, follow your code conventions, and submit
changes in a way that is easy for you to review and merge.
=============================================================================
-->

# Contributing to PowershellRepoTemplate

Thank you for your interest in contributing!

## Setting up a development environment

Requires PowerShell 7.5+, Pester 5+, and PSScriptAnalyzer.

```powershell
git clone https://github.com/FIXME/PowershellRepoTemplate.git
cd PowershellRepoTemplate
Install-Module Pester, PSScriptAnalyzer, ModuleBuilder, PlatyPS -Scope CurrentUser

# optional: hygiene + secret-scanning commit hooks (requires uv -- https://docs.astral.sh/uv/)
uv tool install pre-commit
pre-commit install
```

## Running checks

```powershell
# NonLive Pester tests (no credentials needed)
.\Tests.ps1 NonLive

# Live Pester tests (requires a live session -- see AGENTS.TESTING.md)
.\Tests.ps1 Live

# Auto-fix formatting, then run every house-style check
.\Tests.ps1 AutoFormat
.\Tests.ps1 Formatting

# Build the module (versioned, to Output\)
.\Build.ps1

# Regenerate command docs
.\Docs.ps1

# Docs site (live preview at http://127.0.0.1:8000; requires mkdocs-material)
mkdocs serve
```

## Project conventions

Code style, naming, output, and testing conventions live in
[AGENTS.md](AGENTS.md) -- they apply to humans and AI agents alike. The
short version:

- One function per file; file name matches function name.
- Approved verbs; public functions use the module prefix as an infix.
- Full comment-based help on every function.
- 100-character lines, 4-space indent, splatting over backticks, ASCII only.
- Every public function gets a Pester test in `Tests\Pester\`.

## Pull requests

1. Branch from `main` and open a PR against `main`.
2. Ensure `.\Tests.ps1 NonLive` passes.
3. Ensure `.\Tests.ps1 Formatting` reports no findings.
4. Update `CHANGELOG.md` under `## [Unreleased]`.
5. Update comment-based help and `Docs\` if the public API changed.

## Reporting issues

Use the GitHub issue templates for bugs and feature requests.
