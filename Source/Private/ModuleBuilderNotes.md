# Source/Private/

Internal helper functions that are NOT exported to module consumers.

ModuleBuilder merges all `.ps1` files from this folder (and subfolders) into
the generated `.psm1`. The files are included in alphabetical order by default.

## Conventions

- One function per file; file name matches the function name.
- Functions here never appear in `FunctionsToExport` in the manifest.

## Standard files

None required -- only `.ps1` helper files and category subfolders.
