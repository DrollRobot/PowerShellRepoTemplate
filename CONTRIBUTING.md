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

<!--
Instructions for setting up dev environment
-->


## Project conventions

Code style, naming, output, and testing conventions live in
[AGENTS.md](AGENTS.md).

## Dev environment setup


### Docs
```powershell
# install mkdocs
uv tool install mkdocs --with mkdocs-material --force

# build docs
.\Docs.ps1

# build site
uv run mkdocs build --strict

# launch local site
mkdocs serve

# open in browser
edge/chrome/firefox "http://127.0.0.1:8000"

# deploy to GitHub Pages
uv run mkdocs gh-deploy --force
```

## Pull requests

1. Branch from `develop` and open a PR against `develop`.
2. Follow the testing procedure in [AGENTS.TESTING.md](AGENTS.TESTING.md).
4. Update `CHANGELOG.md` under `## [Unreleased]`.
5. Update help and `Docs\` if the public API changed.

## Reporting issues

Use the GitHub issue templates for bugs and feature requests.
