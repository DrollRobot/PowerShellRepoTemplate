# Source/Classes/

PowerShell class definitions. ModuleBuilder merges all `.ps1` files here into
the generated `.psm1` before `Private/` and `Public/`, so classes are always
available to functions.

## Important: load order

PowerShell classes cannot be dot-sourced like functions -- they must appear in
the correct order in the final file. ModuleBuilder merges files alphabetically.
If a class depends on another, prefix the filenames with numbers to control
order (e.g., `01_BaseClass.ps1`, `02_DerivedClass.ps1`), or use a
`#Requires` comment at the top of the dependent file (ModuleBuilder respects
the `BuildOrder` key in the manifest for finer control).

## Standard files

One `.ps1` file per class. This folder is currently empty -- add class
definitions here when needed.
