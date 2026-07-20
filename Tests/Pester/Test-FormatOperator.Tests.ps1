<#
.SYNOPSIS
    Pester tests for Tests\Test-FormatOperator.ps1.

.DESCRIPTION
    The checker calls `exit` at top level, so it is invoked as a child pwsh
    process (via a generated wrapper script) rather than dot-sourced -- dot-
    sourcing would terminate the Pester run itself. NonLive; no tag.
#>

BeforeAll {
    $SutParams = @{
        Path      = $PSScriptRoot
        ChildPath = '..\..\Tests\Test-FormatOperator.ps1'
    }
    $script:Sut = (Resolve-Path (Join-Path @SutParams)).Path

    $ScratchParams = @{
        Path      = [System.IO.Path]::GetTempPath()
        ChildPath = [System.IO.Path]::GetRandomFileName()
    }
    $script:ScratchDir = Join-Path @ScratchParams
    New-Item -ItemType Directory -Path $script:ScratchDir -Force | Out-Null

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
        Set-Content -LiteralPath $WrapperPath -Value $Lines

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
        Set-Content -LiteralPath $Path -Value $Content
        return $Path
    }
}

AfterAll {
    Remove-Item -LiteralPath $script:ScratchDir -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Test-FormatOperator' -Tag 'unit', 'functional' {

    It 'passes a file with no format-operator usage' {
        $File = New-ScratchFile -Content @('$msg = "Hello $($name)!"')
        $Result = Invoke-Checker -ScriptArgs @('-Path', $File)
        $Result.ExitCode | Should -Be 0
        $Result.Output | Should -Match '0 format-operator usage'
    }

    It 'flags a line using the format operator (-f)' { # noqa: Test-FormatOperator
        $File = New-ScratchFile -Content @('"Hello {0}" -f $name') # noqa: Test-FormatOperator
        $Result = Invoke-Checker -ScriptArgs @('-Path', $File)
        $Result.ExitCode | Should -Be 1
        $Result.Output | Should -Match '1 format-operator usage'
    }

    It 'ignores a single-line comment mentioning the format operator' {
        $Fixture = '# example: "Hello {0}" -f $name' # noqa: Test-FormatOperator
        $File = New-ScratchFile -Content @($Fixture)
        $Result = Invoke-Checker -ScriptArgs @('-Path', $File)
        $Result.ExitCode | Should -Be 0
    }

    It 'ignores usage inside a block comment' {
        $Content = @('<#', 'example: "Hello {0}" -f $name', '#>', '$x = 1')
        $File = New-ScratchFile -Content $Content
        $Result = Invoke-Checker -ScriptArgs @('-Path', $File)
        $Result.ExitCode | Should -Be 0
    }

    It 'suppresses a flagged line carrying the noqa marker' {
        $Line = '"Hello {0}" -f $name  # noqa: Test-FormatOperator'
        $File = New-ScratchFile -Content @($Line)
        $Result = Invoke-Checker -ScriptArgs @('-Path', $File)
        $Result.ExitCode | Should -Be 0
    }

    It 'shows the detail table without -Quiet' {
        $File = New-ScratchFile -Content @('"Hello {0}" -f $name') # noqa: Test-FormatOperator
        $Result = Invoke-Checker -ScriptArgs @('-Path', $File)
        $Result.Output | Should -Match 'LineNumber'
    }

    It 'suppresses the detail table with -Quiet' {
        $File = New-ScratchFile -Content @('"Hello {0}" -f $name') # noqa: Test-FormatOperator
        $Result = Invoke-Checker -ScriptArgs @('-Path', $File, '-Quiet')
        $Result.ExitCode | Should -Be 1
        $Result.Output | Should -Not -Match 'LineNumber'
        $Result.Output | Should -Match '1 format-operator usage'
    }
}
