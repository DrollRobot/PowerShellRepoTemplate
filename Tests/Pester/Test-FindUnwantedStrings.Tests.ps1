<#
.SYNOPSIS
    Pester tests for Tests\Test-FindUnwantedStrings.ps1.

.DESCRIPTION
    The checker calls `exit` at top level, so it is invoked as a child pwsh
    process (via a generated wrapper script) rather than dot-sourced -- dot-
    sourcing would terminate the Pester run itself.

    The repo copy ships with empty $UnwantedPatterns / $ExceptionPatterns (a
    project fills those in) -- against that copy, the only observable path is
    the "no patterns defined" skip. To exercise the matching and exception
    logic, a patched scratch copy is generated once, with the two empty array
    literals replaced by test patterns; everything else in the script is
    untouched. NotLive; no tag.
#>

BeforeAll {
    $SutParams = @{
        Path      = $PSScriptRoot
        ChildPath = '..\..\Tests\Test-FindUnwantedStrings.ps1'
    }
    $script:Sut = (Resolve-Path (Join-Path @SutParams)).Path

    $ScratchParams = @{
        Path      = [System.IO.Path]::GetTempPath()
        ChildPath = [System.IO.Path]::GetRandomFileName()
    }
    $script:ScratchDir = Join-Path @ScratchParams
    New-Item -ItemType Directory -Path $script:ScratchDir -Force | Out-Null

    # Patched copy: injects one unwanted pattern (TODO comments) and one
    # exception pattern (lines also carrying ALLOWED-TODO) in place of the
    # shipped-empty arrays, so the matching/exception logic is exercisable.
    $RawContent = Get-Content -LiteralPath $script:Sut -Raw
    $UnwantedReplacement = "`$UnwantedPatterns = @(`n" +
    "    [PSCustomObject]@{ Tag = 'TODO'; Pattern = '#.*\bTODO\b' }`n)"
    $ExceptionReplacement = "`$ExceptionPatterns = @(`n" +
    "    'ALLOWED-TODO'`n)"
    $Patched = $RawContent -replace '(?ms)^\$UnwantedPatterns = @\(.*?^\)', $UnwantedReplacement
    $Patched = $Patched -replace '(?ms)^\$ExceptionPatterns = @\(.*?^\)', $ExceptionReplacement
    if ($Patched -notmatch [regex]::Escape("Tag = 'TODO'")) {
        throw 'Failed to patch $UnwantedPatterns into the scratch copy -- source shape changed.'
    }
    if ($Patched -notmatch [regex]::Escape('ALLOWED-TODO')) {
        throw 'Failed to patch $ExceptionPatterns into the scratch copy -- source shape changed.'
    }
    $PatchedSutParams = @{
        Path      = $script:ScratchDir
        ChildPath = 'Test-FindUnwantedStrings.patched.ps1'
    }
    $script:PatchedSut = Join-Path @PatchedSutParams
    Set-Content -LiteralPath $script:PatchedSut -Value $Patched -NoNewline

    function script:Invoke-Checker {
        param(
            [Parameter(Mandatory)][string[]] $ScriptArgs,
            [string] $TargetSut = $script:Sut
        )
        $FormattedArgs = $ScriptArgs | ForEach-Object {
            if ($_ -match '^-[A-Za-z]') {
                $_
            }
            else {
                "'" + ($_ -replace "'", "''") + "'"
            }
        }
        $CatchBody = 'Write-Host $_.Exception.Message; exit 1'
        $CallLine = "try { & '$TargetSut' $($FormattedArgs -join ' ') } catch { $CatchBody }"
        $Lines = @($CallLine, 'exit 0')

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

Describe 'Test-FindUnwantedStrings' -Tag 'unit', 'functional' {

    Context 'shipped-empty pattern list (real script)' {
        It 'skips scanning entirely and exits 0 when no patterns are configured' {
            $File = New-ScratchFile -Content @('# TODO this would match if patterns were set')
            $Result = Invoke-Checker -ScriptArgs @('-Path', $File)
            $Result.ExitCode | Should -Be 0
            $Result.Output | Should -Match 'No patterns defined'
        }
    }

    Context 'pattern matching (patched copy)' {
        It 'passes a file with no matches' {
            $File = New-ScratchFile -Content @('$x = 1')
            $Result = Invoke-Checker -ScriptArgs @('-Path', $File) -TargetSut $script:PatchedSut
            $Result.ExitCode | Should -Be 0
            $Result.Output | Should -Match '0 match'
        }

        It 'flags a line matching an unwanted pattern' {
            $File = New-ScratchFile -Content @('# TODO fix this later')
            $Result = Invoke-Checker -ScriptArgs @('-Path', $File) -TargetSut $script:PatchedSut
            $Result.ExitCode | Should -Be 1
            $Result.Output | Should -Match '1 match'
            $Result.Output | Should -Match '0 exception'
        }

        It 'suppresses a match whose line also satisfies an exception pattern' {
            $File = New-ScratchFile -Content @('# TODO fix this later ALLOWED-TODO')
            $Result = Invoke-Checker -ScriptArgs @('-Path', $File) -TargetSut $script:PatchedSut
            $Result.ExitCode | Should -Be 0
            $Result.Output | Should -Match '0 match'
            $Result.Output | Should -Match '1 exception'
        }

        It 'counts real matches and suppressed exceptions independently' {
            $Content = @('# TODO real hit', '# TODO fix later ALLOWED-TODO')
            $File = New-ScratchFile -Content $Content
            $Result = Invoke-Checker -ScriptArgs @('-Path', $File) -TargetSut $script:PatchedSut
            $Result.ExitCode | Should -Be 1
            $Result.Output | Should -Match '1 match'
            $Result.Output | Should -Match '1 exception'
        }

        It 'suppresses the detail table with -Quiet' {
            $File = New-ScratchFile -Content @('# TODO fix this later')
            $ScriptArgs = @('-Path', $File, '-Quiet')
            $Result = Invoke-Checker -ScriptArgs $ScriptArgs -TargetSut $script:PatchedSut
            $Result.ExitCode | Should -Be 1
            $Result.Output | Should -Not -Match 'NOTE FOR AI AGENTS'
            $Result.Output | Should -Match '1 match'
        }
    }

    Context 'built-in exclusions (patched copy)' {
        It 'skips binary-extension files regardless of content' {
            $File = New-ScratchFile -Content @('# TODO fix this later') -Extension '.png'
            $Result = Invoke-Checker -ScriptArgs @('-Path', $File) -TargetSut $script:PatchedSut
            $Result.ExitCode | Should -Be 0
            $Result.Output | Should -Match '0 file'
        }

        It 'skips files under a .local folder by default' {
            $RootParams = @{
                Path      = $script:ScratchDir
                ChildPath = "local-root-$([guid]::NewGuid().ToString('N'))"
            }
            $Root = Join-Path @RootParams
            $LocalDir = Join-Path -Path $Root -ChildPath '.local'
            New-Item -ItemType Directory -Path $LocalDir -Force | Out-Null
            $LocalFile = Join-Path -Path $LocalDir -ChildPath 'notes.ps1'
            Set-Content -LiteralPath $LocalFile -Value @('# TODO fix this later')

            $CheckerArgs = @('-Path', $Root, '-Recurse')
            $Result = Invoke-Checker -ScriptArgs $CheckerArgs -TargetSut $script:PatchedSut
            $Result.ExitCode | Should -Be 0
            $Result.Output | Should -Match '0 match'
        }
    }
}
