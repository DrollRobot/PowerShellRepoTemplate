# Data/

Non-code data files bundled with the module (e.g. JSON/CSV lookup tables,
templates, default config).

ModuleBuilder copies this folder verbatim to the output directory (configured
via `CopyPaths` in `Build.psd1`). Its contents are NOT merged into the
`.psm1`.

## Conventions

- Keep this folder for data the module reads at runtime, not source code.
- Reference files under it via `$PSScriptRoot\Data\<file>` (or the module's
  own resolved root) from module code, since the path moves with the build.
