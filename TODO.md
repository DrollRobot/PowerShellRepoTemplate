# TODO

Improvements identified while reviewing this template against
python_repo_template (2026-06-11). Roughly in priority order.

## High value

- [ ] **Add `ci.yml` workflow.** Run `Tests.ps1 ModuleSyntax`, `Tests.ps1 PSSA`,
  and `Tests.ps1 Offline` on `windows-latest` for every push/PR to main
  (install Pester/PSScriptAnalyzer via `Install-Module`). Mirror the Python
  template's header comments explaining the one-time branch-protection setup
  so CI actually blocks failing merges.
- [ ] **Fix `docs.yml` path filter.** It triggers on `paths: docs/**` but the
  folder is `Docs/`; GitHub path filters are case-sensitive, so docs pushes
  may never deploy. Also covers `mkdocs.yml` -- verify both.
- [ ] **Fix `CLAUDE.md`.** It contains the literal text `AGENTS.md`, which does
  not import the file. Use Claude Code's import syntax (`@AGENTS.md`) or a
  symlink (see python_repo_template README for the New-Item command).

## Template adoption experience

- [ ] **Setup automation script.** Port the idea of
  `scripts/template_setup/` from python_repo_template: a
  `Scripts\Setup-NewProject.ps1` that (1) renames
  PowershellRepoTemplate -> new module name across files and filenames,
  (2) sets the GitHub owner in URLs, (3) generates a fresh manifest GUID,
  (4) strips TEMPLATE SETUP NOTES blocks, (5) lists remaining FIXMEs
  (reuse `Tests\Test-FixmeComments.ps1`), (6) optionally reinits git.
  Preview changes and confirm before applying; support -DryRun and -Yes.
- [ ] **License chooser.** Replace the single LICENSE with
  `LICENSE.mit.FIXME` / `LICENSE.apache.FIXME` / `LICENSE.gnu.FIXME`
  variants like the Python template, plus a setup step (or script) to pick
  one and fill in the copyright line.
- [ ] **README "Tool choices" section.** Short rationale per tool, like the
  Python template: ModuleBuilder (build), Pester (tests), PSScriptAnalyzer
  (lint/format), PlatyPS (command docs), mkdocs-material (docs site),
  GitHub Actions (CI/docs deploy), VSCode (editor config included).
- [ ] **README badges.** CI / PowerShell Gallery / license badges with FIXME
  links.

## Repo hygiene

- [ ] **pre-commit + secret scanning.** pre-commit is language-agnostic:
  reuse the generic hygiene hooks (trailing whitespace, EOF, large files,
  line endings) and detect-secrets from the Python template's
  `.pre-commit-config.yaml`, plus a local hook running
  `Tests.ps1 AutoFormat -Quiet`. Include `.secrets.baseline` setup notes.
- [ ] **Community files.** Add CONTRIBUTING.md, SECURITY.md,
  `.github/dependabot.yml` (github-actions ecosystem at minimum), and
  `.github/ISSUE_TEMPLATE/` (bug report, feature request, config).
- [ ] **Add `.github/pull_request_template.md`.** AGENTS.WORKTREE.md already
  instructs agents to use it as the PR.md template, but it does not exist.
- [ ] **Decide on committed root build artifacts.** `Build.ps1` defaults to
  `-BuildToRoot $true` (see FIXME at the param) so a fresh clone is
  importable by name, at the cost of noisy diffs of generated files.
  Either commit to that default and document it in README, or flip the
  default to versioned `Output\` builds for Gallery publishing.
- [ ] **`.gitattributes`.** Normalize line endings explicitly (the Python
  template ships one; this repo relies on git defaults).

## Open questions

- [ ] Should AGENTS.md's PSFramework debug-output convention
  (`Write-PSFMessage`) stay, or be replaced with a dependency-free wrapper?
  `Tests.ps1 WriteVerboseDebug` enforces the no-Write-Verbose rule either
  way; the template currently has no PSFramework dependency declared.
- [ ] Online test pattern: Tests.ps1's Online section is now a plain
  `Invoke-Pester -TagFilter 'Online'` with a comment. Document (or
  scaffold) where session setup and `Tests\.env.ps1` loading should live
  for modules that talk to live services.
