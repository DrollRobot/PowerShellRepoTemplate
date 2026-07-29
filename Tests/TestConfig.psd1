<#
Per-project test configuration consumed by Tests.ps1.

Each top-level key matches a Tests.ps1 category (lowercase); its value is the
-Data table merged into that category's Pester containers. Keys inside a value
must match test-file parameter names -- Tests\Invoke-Lint.ps1 drops any key a
given test file does not declare, so category-wide settings and file-specific
settings can share one table.

Relative ExcludePath entries resolve against the repo root. Invoke-Lint.ps1
appends computed build-artifact exclusions (the built module files at the repo
root and the CopyPaths folders from Build.psd1) at runtime.
#>
@{
    lint = @{
        # LineLength: longest allowed line, in characters.
        MaxLength   = 100

        # FixmeComments: $false reports open FIXMEs and passes; $true fails the
        # run on any of them. Leave it false while a project still carries the
        # template's own FIXME markers.
        FailOnFixme = $false

        ExcludePath = @(
            '.local'
            'Output'
            '.staging'
        )

        # NonASCIICharacters: characters to allow anywhere, e.g. @('-').
        # ExemptCharacter = @()

        # UnwantedStrings: patterns this project must not ship, and the lines
        # exempt from them. Both default to empty (the check then generates no
        # tests). Set Features.UnwantedStringsLocal in Scripts\setup.psd1 to
        # keep them out of source control instead.
        # UnwantedPattern = @(
        #     @{ Tag = 'TODO'; Pattern = '#.*\bTODO\b' }
        # )
        # UnwantedException = @(
        #     '\bSuppressMessageAttribute\b'
        # )
    }
}
