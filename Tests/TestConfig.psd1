# Tests\TestConfig.psd1

@{
    lint = @{
        # Paths excluded from tests. Relative to repo root.
        ExcludePath = @(
            '.local'
            'Output'
            '.staging'
        )

        # LineLength: longest allowed line, in characters.
        MaxLength   = 100

        # FixmeComments: $false reports open FIXMEs and passes; $true fails the
        # run on any of them. Leave it false while a project still carries the
        # template's own FIXME markers.
        FailOnFixme = $false

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
