<#
.SYNOPSIS
    Pester tests for Tests\Test-NonASCIICharacters.ps1.

.DESCRIPTION
    The checker calls `exit` at top level, so it is invoked as a child pwsh
    process (via a generated wrapper script) rather than dot-sourced -- dot-
    sourcing would terminate the Pester run itself. Non-ASCII fixture
    characters are built from code points ([char] 0x00E9, ...) so this test
    file's own source stays pure ASCII. NonLive; no tag.
#>

BeforeAll {
    $SutParams = @{
        Path      = $PSScriptRoot
        ChildPath = '..\..\Tests\Test-NonASCIICharacters.ps1'
    }
    $script:Sut = (Resolve-Path (Join-Path @SutParams)).Path

    $ScratchParams = @{
        Path      = [System.IO.Path]::GetTempPath()
        ChildPath = [System.IO.Path]::GetRandomFileName()
    }
    $script:ScratchDir = Join-Path @ScratchParams
    New-Item -ItemType Directory -Path $script:ScratchDir -Force | Out-Null

    # U+00E9 (e-acute) -- a simple, unambiguous non-ASCII code point for fixtures.
    $script:NonAsciiChar = [char] 0x00E9

    function script:Invoke-Checker {
        param(
            [Parameter(Mandatory)][string[]] $ScriptArgs,
            [string[]] $Prelude
        )
        $FormattedArgs = $ScriptArgs | ForEach-Object {
            if ($_ -match '^-[A-Za-z]') {
                $_
            }
            else {
                "'" + ($_ -replace "'", "''") + "'"
            }
        }
        $Lines = [System.Collections.Generic.List[string]]::new()
        if ($Prelude) { $Lines.AddRange([string[]] $Prelude) }
        $CatchBody = 'Write-Host $_.Exception.Message; exit 1'
        $Lines.Add("try { & '$script:Sut' $($FormattedArgs -join ' ') } catch { $CatchBody }")
        $Lines.Add('exit 0')

        $WrapperParams = @{
            Path      = $script:ScratchDir
            ChildPath = "wrapper-$([guid]::NewGuid().ToString('N')).ps1"
        }
        $WrapperPath = Join-Path @WrapperParams
        Set-Content -LiteralPath $WrapperPath -Value $Lines -Encoding utf8

        $ArgList = @('-NoProfile', '-NonInteractive', '-File', $WrapperPath)
        $Output = & pwsh @ArgList 2>&1
        $Result = [PSCustomObject]@{
            Output   = ($Output | Out-String)
            ExitCode = $LASTEXITCODE
        }
        Remove-Item -LiteralPath $WrapperPath -Force -ErrorAction SilentlyContinue
        return $Result
    }

    function script:New-ScratchFile {
        param(
            [Parameter(Mandatory)][string[]] $Content,
            [string] $Extension = '.ps1'
        )
        $NameParams = @{
            Path      = $script:ScratchDir
            ChildPath = "case-$([guid]::NewGuid().ToString('N'))$Extension"
        }
        $Path = Join-Path @NameParams
        Set-Content -LiteralPath $Path -Value $Content -Encoding utf8
        return $Path
    }
}

AfterAll {
    Remove-Item -LiteralPath $script:ScratchDir -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Test-NonASCIICharacters' -Tag 'unit', 'functional' {

    It 'passes a file with only ASCII characters' {
        $File = New-ScratchFile -Content @('$msg = "hello world"')
        $Result = Invoke-Checker -ScriptArgs @('-Path', $File)
        $Result.ExitCode | Should -Be 0
        $Result.Output | Should -Match '0 non-ASCII occurrence'
    }

    It 'flags a line containing a non-ASCII character' {
        $Line = "`$msg = 'caf$($script:NonAsciiChar)'"
        $File = New-ScratchFile -Content @($Line)
        $Result = Invoke-Checker -ScriptArgs @('-Path', $File)
        $Result.ExitCode | Should -Be 1
        $Result.Output | Should -Match '1 non-ASCII occurrence'
    }

    It 'does not flag a character listed in -ExemptCharacters' {
        $Line = "`$msg = 'caf$($script:NonAsciiChar)'"
        $File = New-ScratchFile -Content @($Line)
        $ScriptArgs = @('-Path', $File, '-ExemptCharacters', [string] $script:NonAsciiChar)
        $Result = Invoke-Checker -ScriptArgs $ScriptArgs
        $Result.ExitCode | Should -Be 0
        $Result.Output | Should -Match '0 non-ASCII occurrence'
    }

    It 'suppresses a flagged line carrying the noqa marker' {
        $Line = "`$msg = 'caf$($script:NonAsciiChar)'  # noqa: Test-NonASCIICharacters"
        $File = New-ScratchFile -Content @($Line)
        $Result = Invoke-Checker -ScriptArgs @('-Path', $File)
        $Result.ExitCode | Should -Be 0
    }

    It 'suppresses the detail table and remediation note with -Quiet' {
        $Line = "`$msg = 'caf$($script:NonAsciiChar)'"
        $File = New-ScratchFile -Content @($Line)
        $Result = Invoke-Checker -ScriptArgs @('-Path', $File, '-Quiet')
        $Result.ExitCode | Should -Be 1
        $Result.Output | Should -Not -Match 'NOTE FOR AI AGENTS'
        $Result.Output | Should -Match '1 non-ASCII occurrence'
    }
}
