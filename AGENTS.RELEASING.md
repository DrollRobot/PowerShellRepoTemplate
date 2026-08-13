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

- If the user asked you to read this file, treat that as them asking you to
  perform the procedure described below.

In-domain: All code in Source/, except functions in Lib/ folders and Build.psd1.
Non-domain: Scripts/, Tests/, **/Lib/, Build/, Output/, `Docs/<ModuleName>/`, and any
built artifacts in module root.


## Commit
- Review before writing commit messages: [AGENTS.COMMITTING.md](AGENTS.COMMITTING.md).
- Commit any untracked files.

## Build
Build the module/scripts:
```powershell
.\Build.ps1
```

Run pester tests again on the built module:
```powershell
.\Tests.ps1 NotLive,Live -Built
```

## Update docs
- Rebuild Docs/<ModuleName>/
   ```powershell
   .\Docs.ps1
   ```

- Review the documents in the root of the Docs folder for accuracy or any new features
   that should be added. Don't review or modify files in `Docs/<ModuleName>/`. (built
   by PlatyPS)


## Update CHANGELOG.md
`CHANGELOG.md` in the repo root is the authoritative changelog, in
[Keep a Changelog](https://keepachangelog.com) format. Fetch that page for the
current format rules; do not rely on training data.

1. **Collect commits** since the previous tag:
   ```powershell
   $prevTag = git describe --tags --abbrev=0
   git log "$prevTag..HEAD" --oneline
   ```

2. Select from commits. Keep only:
- Features -- functionality a user can invoke (Added, Changed, Deprecated, Removed).
- User-facing bug fixes (Fixed).
- Security changes (Security).
- Performance improvements.
Do not mention: refactors, tests, lint, building docs, build tooling.

3. Write each entry as a BRIEF overview, not an explanation.
- Fixed: Name what broke and where.
- Added/Changed: one or two sentences describing the new behavior.
- Detailed explanations belong in the commit message and the code, not the
   changelog.

4. Prepend the new section immediately after the # Changelog heading,
with today's date and the version about to be tagged. Don't rewrite or
delete existing sections unless directly requested.

## Hand off to user
- The user will update manifest version, merge, tag, and push.
