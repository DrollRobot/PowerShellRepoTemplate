# ScriptsToProcess/

Scripts that PowerShell runs in the caller's session scope before the module 
itself is loaded. Listed in the `ScriptsToProcess` key of the module manifest.

ModuleBuilder copies this folder verbatim to the output directory (configured
via `CopyPaths` in `Build.psd1`). The scripts are NOT merged into the `.psm1`.

## Use cases

- Setting up environment variables or global state the module depends on.
- Importing type accelerators or assemblies into the caller's session.
- Running dependency checks at import time.

## Conventions

- Keep scripts small and side-effect-minimal; they run in the caller's scope.
- Do NOT export functions or define module-level helpers here -- use `Private/`.

## Conventions (continued)

- File names here must also appear in the manifest's `ScriptsToProcess` array
  to take effect at import time.
