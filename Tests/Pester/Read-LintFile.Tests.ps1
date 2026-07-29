<#
.SYNOPSIS
    Pester tests for Tests\Pester\Read-LintFile.ps1.

.DESCRIPTION
    The helper is a plain dot-sourced function pair, so these run in-process:
    write a fixture file, read it, assert on what came back. NotLive.
#>

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'Read-LintFile.ps1')

    $ScratchParams = @{
        Path      = [System.IO.Path]::GetTempPath()
        ChildPath = [System.IO.Path]::GetRandomFileName()
    }
    $script:ScratchDir = Join-Path @ScratchParams
    New-Item -ItemType Directory -Path $script:ScratchDir -Force | Out-Null

    # Writes fixture content (one array element per line) to a uniquely named
    # scratch file and returns its path.
    function script:New-ScratchFile {
        param(
            # A blank line is a legitimate fixture line, so allow empty entries.
            [Parameter(Mandatory)][AllowEmptyString()][string[]] $Content,
            [string] $Extension = '.ps1'
        )
        $NameParams = @{
            Path      = $script:ScratchDir
            ChildPath = "case-$([guid]::NewGuid().ToString('N'))$Extension"
        }
        $Path = Join-Path @NameParams
        Set-Content -LiteralPath $Path -Value $Content
        return $Path
    }
}

AfterAll {
    $RemoveParams = @{
        LiteralPath = $script:ScratchDir
        Recurse     = $true
        Force       = $true
        ErrorAction = 'SilentlyContinue'
    }
    Remove-Item @RemoveParams
}

Describe 'Read-LintFile' -Tag 'unit', 'functional' {

    Context 'PowerShell files' {
        It 'returns the raw lines, in order, unmodified' {
            $File = New-ScratchFile -Content @('', '$x = 1', '# two')
            $LintFile = Read-LintFile -Path $File
            $LintFile.Line.Count | Should -Be 3
            $LintFile.Line[1] | Should -Be '$x = 1'
        }

        It 'parses the file, exposing tokens and an AST' {
            $File = New-ScratchFile -Content @('$x = 1')
            $LintFile = Read-LintFile -Path $File
            $LintFile.Ast | Should -Not -BeNullOrEmpty
            $LintFile.Token.Count | Should -BeGreaterThan 0
            $LintFile.ParseError.Count | Should -Be 0
        }

        It 'reports parse errors without throwing' {
            $File = New-ScratchFile -Content @('function Broken {')
            $LintFile = Read-LintFile -Path $File
            $LintFile.ParseError.Count | Should -BeGreaterThan 0
        }
    }

    Context 'non-PowerShell files' {
        It 'reads the lines but does not parse' {
            $File = New-ScratchFile -Content @('plain text') -Extension '.txt'
            $LintFile = Read-LintFile -Path $File
            $LintFile.Line[0] | Should -Be 'plain text'
            $LintFile.Ast | Should -BeNullOrEmpty
            $LintFile.Token.Count | Should -Be 0
        }

        It 'still honors an exemption marker in the text' {
            $Content = @('anything  # noqa: LineLength')
            $File = New-ScratchFile -Content $Content -Extension '.txt'
            $LintFile = Read-LintFile -Path $File
            $LintFile.Exempt[1] | Should -Contain 'LineLength'
        }
    }

    Context 'exemption markers' {
        It 'records a marker against its own line number' {
            $File = New-ScratchFile -Content @('$x = 1', '$y = 2  # noqa: JoinPath')
            $LintFile = Read-LintFile -Path $File
            $LintFile.Exempt.ContainsKey(1) | Should -BeFalse
            $LintFile.Exempt[2] | Should -Contain 'JoinPath'
        }

        It 'records every rule named on one marker' {
            $File = New-ScratchFile -Content @('$x = 1  # noqa: JoinPath, LineLength')
            $LintFile = Read-LintFile -Path $File
            $LintFile.Exempt[1] | Should -Contain 'JoinPath'
            $LintFile.Exempt[1] | Should -Contain 'LineLength'
        }

        It 'ignores marker-shaped text inside a string, which is not a comment' {
            $File = New-ScratchFile -Content @('$x = ''# noqa: JoinPath''')
            $LintFile = Read-LintFile -Path $File
            $LintFile.Exempt.Count | Should -Be 0
        }

        It 'falls back to raw text when the file failed to parse' {
            # No trustworthy tokens here, so the marker must still be found.
            $Content = @('function Broken {', '$x = 1  # noqa: LineLength')
            $File = New-ScratchFile -Content $Content
            $LintFile = Read-LintFile -Path $File
            $LintFile.ParseError.Count | Should -BeGreaterThan 0
            $LintFile.Exempt[2] | Should -Contain 'LineLength'
        }

        It 'maps a marker inside a block comment to the line it sits on' {
            $Content = @('<#', 'unrelated', '# noqa: LineLength', '#>')
            $File = New-ScratchFile -Content $Content
            $LintFile = Read-LintFile -Path $File
            $LintFile.Exempt[3] | Should -Contain 'LineLength'
        }
    }
}

Describe 'Test-LintExempt' -Tag 'unit', 'functional' {

    BeforeAll {
        $Content = @('$x = 1', '$y = 2  # noqa: JoinPath', '$z = 3')
        $script:Fixture = Read-LintFile -Path (New-ScratchFile -Content $Content)
    }

    It 'is true for the marked line and rule' {
        $Params = @{ LintFile = $script:Fixture; Rule = 'JoinPath'; Line = 2 }
        Test-LintExempt @Params | Should -BeTrue
    }

    It 'is false for a different rule on the same line' {
        $Params = @{ LintFile = $script:Fixture; Rule = 'LineLength'; Line = 2 }
        Test-LintExempt @Params | Should -BeFalse
    }

    It 'is false for an unmarked line' {
        $Params = @{ LintFile = $script:Fixture; Rule = 'JoinPath'; Line = 1 }
        Test-LintExempt @Params | Should -BeFalse
    }

    It 'accepts a marker anywhere in a multi-line finding' {
        $Params = @{
            LintFile = $script:Fixture
            Rule     = 'JoinPath'
            Line     = 1
            EndLine  = 3
        }
        Test-LintExempt @Params | Should -BeTrue
    }
}
