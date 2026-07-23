<!--
=============================================================================
TEMPLATE SETUP NOTES -- remove this block - FIXME
=============================================================================
Releasing the template itself: run every release step below EXCEPT the Build
section. The template is published as a template, not built or packaged as a
module; everything else (docs, changelog, hand-off) still applies. A real module
made from this template runs the full process, Build included, and removes this
block.
=============================================================================
-->

# Releasing

In-domain: All code in Source/, except functions in Lib/ folders and Build.psd1.
Non-domain: Scripts/, Tests/, **/Lib/, Build/, Output/, Docs/Commands/, and any
built artifacts in module root.


## Commit
- Review before writing commit messages: [AGENTS.COMMITTING.md](AGENTS.COMMITTING.md).
- Commit any untracked files.

## Build
```powershell
# default: versioned build to Output\<ModuleName>\<version>\ (Gallery layout)
.\Build.ps1

# alternative: flat build to the repo root, for repos distributed by git clone
.\Build.ps1 -BuildToRoot
```
Test built module
Run pester tests again on the built module (-Built prefers a root build,
then falls back to the newest versioned build under Output\):
```powershell
.\Tests.ps1 NotLive,Live -Built
```

## Update docs
```powershell
.\Docs.ps1 -DeleteOrphaned
```

Review the documents in the root of the Docs folder for accuracy or any new features
that should be added. Don't review or modify files in Docs/Commands. (built by PlatyPS)

## Update CHANGELOG.md
`CHANGELOG.md` in the repo root is the authoritative changelog.
Before proceeding, fetch and review <https://keepachangelog.com> to get the
current format rules. Do not rely on training data -- request a fresh copy every time.

**How to update the changelog before tagging a new release**

1. **Find the previous tag** and collect every commit since then:
   ```powershell
   $prevTag = git describe --tags --abbrev=0   # most recent tag
   git log "$prevTag..HEAD" --oneline
   ```

2. **Break each commit message into individual details**, then evaluate each detail
   against the three changelog categories:
   - **Features** -- new or changed functionality a user can invoke (maps to Added,
     Changed, Deprecated, Removed).
   - **User-facing bugs** -- something that was broken and is now fixed (maps to Fixed).
   - **Security** -- vulnerabilities or security-relevant changes (maps to Security).

   If a detail does not clearly fit one of those three categories, discard it.
   Implementation details, refactors, test changes, linting fixes, and documentation
   updates are never included, even if they appear in the same commit as something that is.

   Collect all surviving details, grouped by category, then use them to build the
   changelog section.

3. **Prepend** the new release section to `CHANGELOG.md` immediately after the
   `# Changelog` heading. Use today's date and the version about to be tagged.
   Do not rewrite or delete any existing sections.

## Hand off to user
- The user will update manifest version, merge, tag, and push.
- `.github\workflows\release.yml` only builds and publishes a GitHub release
  when `Scripts\setup.psd1`'s `Release.Enabled` is true (default `$false`).
  Run `Scripts\Enable-Release.ps1` once, ahead of the first real tag, or the
  push is a no-op.
