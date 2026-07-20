<#
.SYNOPSIS
    Pester tests for Tests\Test-FixmeComments.ps1.

.DESCRIPTION
    The checker calls `exit` at top level, so it is invoked as a child pwsh
    process (via a generated wrapper script) rather than dot-sourced -- dot-
    sourcing would terminate the Pester run itself. NonLive; no tag.
#>

BeforeAll {
    $SutParams = @{
        Path      = $PSScriptRoot
        ChildPath = '..\..\Tests\Test-FixmeComments.ps1'
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

Describe 'Test-FixmeComments' -Tag 'unit', 'functional' {

    It 'passes a file with no FIXME comments' {
        $File = New-ScratchFile -Content @('$x = 1')
        $Result = Invoke-Checker -ScriptArgs @('-Path', $File)
        $Result.ExitCode | Should -Be 0
        $Result.Output | Should -Match '0 FIXME comment'
    }

    It 'flags a FIXME comment' {
        $File = New-ScratchFile -Content @('# FIXME: replace this stub')
        $Result = Invoke-Checker -ScriptArgs @('-Path', $File)
        $Result.ExitCode | Should -Be 1
        $Result.Output | Should -Match '1 FIXME comment'
    }

    It 'suppresses the detail table with -Quiet' {
        $File = New-ScratchFile -Content @('# FIXME: replace this stub')
        $Result = Invoke-Checker -ScriptArgs @('-Path', $File, '-Quiet')
        $Result.ExitCode | Should -Be 1
        $Result.Output | Should -Not -Match 'NOTE FOR AI AGENTS'
        $Result.Output | Should -Match '1 FIXME comment'
    }

    It 'excludes its own copy when scanning a folder shaped like the repo' {
        # Regression: the hardcoded self-exclusion entry must match the exact
        # string System.IO.Path]::GetRelativePath produces (no leading '.\'),
        # or this checker flags itself for the FIXME mentions in its own help.
        $RepoRootParams = @{
            Path      = $script:ScratchDir
            ChildPath = "repo-$([guid]::NewGuid().ToString('N'))"
        }
        $RepoRoot = Join-Path @RepoRootParams
        $TestsDir = Join-Path -Path $RepoRoot -ChildPath 'Tests'
        New-Item -ItemType Directory -Path $TestsDir -Force | Out-Null
        $SelfPath = Join-Path -Path $TestsDir -ChildPath 'Test-FixmeComments.ps1'
        Set-Content -LiteralPath $SelfPath -Value @('# FIXME: this mention must not count')

        $Result = Invoke-Checker -ScriptArgs @('-Path', $RepoRoot, '-Recurse')
        $Result.ExitCode | Should -Be 0
        $Result.Output | Should -Match '0 FIXME comment'
    }
}
