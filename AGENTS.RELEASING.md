# Releasing

In-domain: All code in Source/, except functions in Lib/ folders and Build.psd1.
Non-domain: Dev/Test/Build/Debug/Lib code.

Ignore built code, such as *.psm1 and *.psd1, ScriptsToProcess/, Data/, Build/, in
the module root.

## Build
```powershell
.\Build.ps1
```
Test built module
Run pester tests again on the built module:
```powershell
.\Tests.ps1 Offline,Online -Built
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

