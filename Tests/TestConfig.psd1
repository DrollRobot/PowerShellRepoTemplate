<#
Per-project test configuration consumed by Tests.ps1.

Each top-level key matches a Tests.ps1 category (lowercase); its value is the
-Data table merged into that category's Pester containers. Keys inside a value
must match test-file parameter names -- Tests.ps1 drops any key a given test
file does not declare, so category-wide settings and file-specific settings
can share one table.

Relative ExcludePath entries resolve against the repo root. Tests.ps1 appends
computed build-artifact exclusions (the built module files at the repo root
and the CopyPaths folders from Build.psd1) at runtime.
#>
@{
    lint = @{
        MaxLength   = 100
        ExcludePath = @(
            '.local'
            'Output'
            '.staging'
        )
    }
}
