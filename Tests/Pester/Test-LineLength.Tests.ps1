<#
.SYNOPSIS
    Pester tests for Tests\Test-LineLength.ps1.

.DESCRIPTION
    The checker calls `exit` at top level, so it is invoked as a child pwsh
    process (via a generated wrapper script) rather than dot-sourced -- dot-
    sourcing would terminate the Pester run itself. NonLive; no tag.
#>

BeforeAll {
    $SutParams = @{
        Path      = $PSScriptRoot
        ChildPath = '..\..\Tests\Test-LineLength.ps1'
    }
    $script:Sut = (Resolve-Path (Join-Path @SutParams)).Path

    $ScratchParams = @{
        Path      = [System.IO.Path]::GetTempPath()
        ChildPath = [System.IO.Path]::GetRandomFileName()
    }
    $script:ScratchDir = Join-Path @ScratchParams
    New-Item -ItemType Directory -Path $script:ScratchDir -Force | Out-Null

    # Runs the checker in an isolated child pwsh process via a generated wrapper
    # script. The checker throws (not `exit`s) to report a failure, so the
    # wrapper catches that and turns it into this scratch subprocess's own
    # exit code -- fine here since this wrapper is a throwaway launcher only
    # ever run via -File from this test, never interactively. -Prelude lines
    # (if any) run before the checker is invoked, e.g. to set a global.
    function script:Invoke-Checker {
        param(
            [Parameter(Mandatory)][string[]] $ScriptArgs,
            [string[]] $Prelude
        )
        # Parameter-name tokens (-Path, -Recurse, ...) must stay unquoted so the
        # generated script parses them as switches/names rather than string
        # values; only actual values are quoted (and quote-escaped).
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

    # Writes fixture content (one array element per line) to a uniquely named
    # scratch file and returns its path.
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

Describe 'Test-LineLength' -Tag 'unit', 'functional' {

    Context 'long line detection' {
        It 'passes a file with no long lines' {
            $File = New-ScratchFile -Content @('short line', 'another short line')
            $Result = Invoke-Checker -ScriptArgs @('-Path', $File)
            $Result.ExitCode | Should -Be 0
            $Result.Output | Should -Match '0 long line'
        }

        It 'flags a line exceeding the default max length' {
            $File = New-ScratchFile -Content @('#' * 110)
            $Result = Invoke-Checker -ScriptArgs @('-Path', $File)
            $Result.ExitCode | Should -Be 1
            $Result.Output | Should -Match '1 long line'
        }
    }

    Context 'noqa suppression' {
        It 'suppresses a long line carrying the noqa marker' {
            $LongLine = ('x' * 110) + '  # noqa: Test-LineLength'
            $File = New-ScratchFile -Content @($LongLine)
            $Result = Invoke-Checker -ScriptArgs @('-Path', $File)
            $Result.ExitCode | Should -Be 0
            $Result.Output | Should -Match '0 long line'
        }
    }

    Context '-MaxLength override' {
        It 'does not flag a line under the default max length' {
            $File = New-ScratchFile -Content @('y' * 60)
            $Result = Invoke-Checker -ScriptArgs @('-Path', $File)
            $Result.ExitCode | Should -Be 0
        }

        It 'flags the same line when -MaxLength is lowered below it' {
            $File = New-ScratchFile -Content @('y' * 60)
            $Result = Invoke-Checker -ScriptArgs @('-Path', $File, '-MaxLength', '50')
            $Result.ExitCode | Should -Be 1
            $Result.Output | Should -Match '1 long line'
        }
    }

    Context '-Quiet' {
        It 'suppresses the detail table and remediation note' {
            $File = New-ScratchFile -Content @('#' * 110)
            $Result = Invoke-Checker -ScriptArgs @('-Path', $File, '-Quiet')
            $Result.ExitCode | Should -Be 1
            $Result.Output | Should -Not -Match 'NOTE FOR AI AGENTS'
            $Result.Output | Should -Match '1 long line'
        }

        It 'shows the detail table and remediation note without -Quiet' {
            $File = New-ScratchFile -Content @('#' * 110)
            $Result = Invoke-Checker -ScriptArgs @('-Path', $File)
            $Result.Output | Should -Match 'NOTE FOR AI AGENTS'
            $Result.Output | Should -Match 'LineNumber'
        }
    }
}

Describe 'Test-LineLength exclusions' -Tag 'unit', 'functional' {
    BeforeAll {
        # Isolated subtree, separate from the flat scratch dir other Describe
        # blocks write into -- a recursive scan here must see only this fixture.
        $RootParams = @{
            Path      = $script:ScratchDir
            ChildPath = "excl-root-$([guid]::NewGuid().ToString('N'))"
        }
        $script:ExclRoot = Join-Path @RootParams
        New-Item -ItemType Directory -Path $script:ExclRoot -Force | Out-Null
        $ExcludedDirParams = @{
            Path      = $script:ExclRoot
            ChildPath = 'excluded_dir'
        }
        $script:ExcludedDir = Join-Path @ExcludedDirParams
        New-Item -ItemType Directory -Path $script:ExcludedDir -Force | Out-Null
        $BadFileParams = @{
            Path      = $script:ExcludedDir
            ChildPath = 'bad.ps1'
        }
        $BadFilePath = Join-Path @BadFileParams
        Set-Content -LiteralPath $BadFilePath -Value ('#' * 110)
    }

    It 'still flags the excluded folder when no exclusions are set' {
        $Result = Invoke-Checker -ScriptArgs @('-Path', $script:ExclRoot, '-Recurse')
        $Result.ExitCode | Should -Be 1
    }

    It 'skips files under a folder named in $Global:Dev_FormattingExclusions' {
        $Prelude = @(
            "`$Global:Dev_FormattingExclusions = @{"
            "    ExcludeFiles = @()"
            "    ExcludeFolders = @('excluded_dir')"
            '}'
        )
        $ScriptArgs = @('-Path', $script:ExclRoot, '-Recurse')
        $Result = Invoke-Checker -ScriptArgs $ScriptArgs -Prelude $Prelude
        $Result.ExitCode | Should -Be 0
        $Result.Output | Should -Match '0 long line'
    }
}
