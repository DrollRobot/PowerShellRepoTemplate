# Source/Public/

All functions that are exported to module consumers live here.

ModuleBuilder merges all `.ps1` files from this folder (and subfolders) into
the generated `.psm1`, and automatically populates `FunctionsToExport` in the
manifest based on the `PublicFilter` pattern in `Build.psd1`
(currently `Public/*.ps1`, which also matches subfolders).

## Conventions

- One function per file; file name matches the function name.
- Use only approved PowerShell verbs (`Get-Verb` lists them).
- Use subfolders to group by category.
- Every function should have full comment-based help:
  `.SYNOPSIS`, `.DESCRIPTION`, `.PARAMETER`, at least one `.EXAMPLE`,
  `.OUTPUTS`, and `.NOTES`.

## Standard files

None required -- only `.ps1` function files and category subfolders.
