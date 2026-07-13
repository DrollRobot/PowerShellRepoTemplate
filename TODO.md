# TODO

Improvements identified while reviewing this template against
python_repo_template (2026-06-11). Updated as items land.

## Open

- [ ] **PSFramework debug-output convention.** AGENTS.md documents
  `Write-PSFMessage` for in-domain debug output, but the template declares no
  PSFramework dependency. Decide: ship a dependency-free wrapper, or add
  PSFramework to RequiredModules, or leave as a documented option.
- [ ] **Online test scaffolding.** Tests.ps1's Online section is a plain
  `Invoke-Pester -TagFilter 'Online'` with a comment describing where session
  setup belongs. Consider a worked example (session setup + .env.ps1 loading
  in a Pester BeforeAll) once a real consumer module exists.

## Done

- [x] **Formatting checks exit nonzero on findings.** Each `Tests\Test-*.ps1`
  check now exits nonzero when it finds something. Tests.ps1 tallies these
  across a multi-check run so it gates on all requested checks. The fast checks
  run in pre-commit (`.pre-commit-config.yaml`) against staged files and in CI
  (`ci.yml`); PSSA gates in CI only. Fixers (AutoFormat, TrailingWhitespace) do
  not gate.
- [x] `ci.yml` workflow: syntax, PSSA, offline Pester on windows-latest, with
  branch-protection setup notes. Pester failures gate via Tests.ps1 exit code.
- [x] `docs.yml` path filter fixed (`Docs/**`; GitHub filters are
  case-sensitive).
- [x] `CLAUDE.md` now imports AGENTS.md via `@AGENTS.md`.
- [x] `Scripts\Setup-NewProject.ps1`: guided rename, GUID, GitHub URLs,
  license selection, template-header stripping, FIXME report, git reinit.
- [x] License chooser: `LICENSE.mit.FIXME` / `LICENSE.apache.FIXME` /
  `LICENSE.gnu.FIXME` (single LICENSE removed).
- [x] README: badges, tool-choices rationale, template adoption steps, layout
  overview.
- [x] `.pre-commit-config.yaml`: hygiene hooks + detect-secrets (PSSA
  intentionally excluded from commit hooks -- too slow; CI covers it).
- [x] Community files: CONTRIBUTING.md, SECURITY.md,
  `.github/dependabot.yml` (github-actions ecosystem),
  `.github/ISSUE_TEMPLATE/` (bug, feature, config),
  `.github/pull_request_template.md`.
- [x] `.gitattributes` with line-ending normalization.
- [x] Build default flipped: `Build.ps1` now builds versioned to `Output\`;
  `-BuildToRoot` remains as an option. `Tests.ps1 -Built` prefers a root
  build, then falls back to the newest versioned Output build.
