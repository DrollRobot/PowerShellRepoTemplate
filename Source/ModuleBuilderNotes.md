# Source/ (module source root)

The source root for the ModuleBuilder project. `Build-Module` is pointed at the
manifest here to produce the final module in the output directory.

## Key files

| File | Purpose |
|------|---------|
| `<ModuleName>.psd1` | Source manifest -- the metadata source of truth. Edit this, not the built copy. |
| `Build.psd1` | ModuleBuilder configuration (overrides for `Build-Module` parameters). |
| `Prefix.ps1` | Code injected at the very top of the generated `.psm1`. |
| `Suffix.ps1` | Code injected at the very bottom of the generated `.psm1`. |
| `<ModuleName>.psm1` | Optional hand-written root module. Usually omitted; ModuleBuilder generates one. |

## Source directories (merged into .psm1)

Configured via `SourceDirectories` in `Build.psd1`:

- `Classes/` -- PowerShell class definitions (load-order sensitive)
- `Private/` -- Internal helper functions (not exported)
- `Public/`  -- Exported functions

## Copied paths (not merged)

Configured via `CopyPaths` in `Build.psd1`. Copied verbatim to the output folder:

- `ScriptsToProcess/` -- Scripts referenced in the manifest `ScriptsToProcess` key
- `Data/` -- Static data files (CSV, JSON, etc.)
- `en-US/` -- Localized help files (add to `CopyPaths` when MAML help is adopted)
