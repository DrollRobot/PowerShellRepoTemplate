<#
.SYNOPSIS
    Pester tests for Tests\Test-ModuleSyntax.ps1.

.DESCRIPTION
    The checker calls `exit` at top level, so it is invoked as a child pwsh
    process (via a generated wrapper script) rather than dot-sourced -- dot-
    sourcing would terminate the Pester run itself. NotLive; no tag.
#>

BeforeAll {
    $SutParams = @{
        Path      = $PSScriptRoot
        ChildPath = '..\..\Tests\Test-ModuleSyntax.ps1'
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

Describe 'Test-ModuleSyntax' -Tag 'unit', 'functional' {

    It 'passes a syntactically valid file' {
        $File = New-ScratchFile -Content @('function Get-Thing {', '    param()', '    1', '}')
        $Result = Invoke-Checker -ScriptArgs @('-Path', $File)
        $Result.ExitCode | Should -Be 0
        $Result.Output | Should -Match '0 syntax error'
    }

    It 'fails a file with a deliberately broken brace' {
        $File = New-ScratchFile -Content @('function Get-Thing {', '    param()')
        $Result = Invoke-Checker -ScriptArgs @('-Path', $File)
        $Result.ExitCode | Should -Be 1
        $Result.Output | Should -Match '1 syntax error'
    }

    It 'surfaces the parse error detail without -Quiet' {
        $File = New-ScratchFile -Content @('function Get-Thing {', '    param()')
        $Result = Invoke-Checker -ScriptArgs @('-Path', $File)
        $Result.Output | Should -Match 'Errors'
    }

    It 'suppresses parse error detail with -Quiet' {
        $File = New-ScratchFile -Content @('function Get-Thing {', '    param()')
        $Result = Invoke-Checker -ScriptArgs @('-Path', $File, '-Quiet')
        $Result.ExitCode | Should -Be 1
        $Result.Output | Should -Not -Match 'NOTE FOR AI AGENTS'
        $Result.Output | Should -Match '1 syntax error'
    }

    It 'counts syntax errors across multiple files in a folder' {
        $SubParams = @{
            Path      = $script:ScratchDir
            ChildPath = "multi-$([guid]::NewGuid().ToString('N'))"
        }
        $SubDir = Join-Path @SubParams
        New-Item -ItemType Directory -Path $SubDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path -Path $SubDir -ChildPath 'good.ps1') -Value '1 + 1'
        Set-Content -LiteralPath (Join-Path -Path $SubDir -ChildPath 'bad.ps1') -Value 'function ('
        $Result = Invoke-Checker -ScriptArgs @('-Path', $SubDir, '-Recurse')
        $Result.ExitCode | Should -Be 1
        $Result.Output | Should -Match '2 file'
    }
}
