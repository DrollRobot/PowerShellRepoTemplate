<#
.SYNOPSIS
    Pester tests for Tests\Test-ExplicitModuleImport.ps1.

.DESCRIPTION
    The checker calls `exit` at top level, so it is invoked as a child pwsh
    process (via a generated wrapper script) rather than dot-sourced -- dot-
    sourcing would terminate the Pester run itself.

    The checker requires its own host module to be imported (it errors out
    otherwise) and classifies commands as "Installed" only when they come from
    a module outside $PSHOME. Rather than depend on whatever happens to be
    installed in the CI/dev environment, a throwaway fixture module is built
    on disk and added to the child process's PSModulePath, giving a hermetic,
    always-"Installed" command to check the explicit-reference rule against.
    NotLive; no tag.
#>

BeforeAll {
    $SutParams = @{
        Path      = $PSScriptRoot
        ChildPath = '..\..\Tests\Test-ExplicitModuleImport.ps1'
    }
    $script:Sut = (Resolve-Path (Join-Path @SutParams)).Path

    $RepoRootParams = @{
        Path      = $PSScriptRoot
        ChildPath = '..\..'
    }
    $script:RepoRoot = (Resolve-Path (Join-Path @RepoRootParams)).Path
    $ManifestParams = @{
        Path      = $script:RepoRoot
        ChildPath = 'source\PowershellRepoTemplate.psd1'
    }
    $script:HostManifest = (Resolve-Path (Join-Path @ManifestParams)).Path

    $ScratchParams = @{
        Path      = [System.IO.Path]::GetTempPath()
        ChildPath = [System.IO.Path]::GetRandomFileName()
    }
    $script:ScratchDir = Join-Path @ScratchParams
    New-Item -ItemType Directory -Path $script:ScratchDir -Force | Out-Null

    # Throwaway module living outside $PSHOME, so Resolve-CommandModule always
    # classifies its command as "Installed" regardless of the host environment.
    $FixtureModDirParams = @{
        Path      = $script:ScratchDir
        ChildPath = 'FixtureModule'
    }
    $script:FixtureModuleDir = Join-Path @FixtureModDirParams
    New-Item -ItemType Directory -Path $script:FixtureModuleDir -Force | Out-Null
    $FixtureModPathParams = @{
        Path      = $script:FixtureModuleDir
        ChildPath = 'FixtureModule.psm1'
    }
    $script:FixtureModulePath = Join-Path @FixtureModPathParams
    $FixtureModuleContent = @(
        'function Get-FixtureThing {'
        '    param()'
        "    'thing'"
        '}'
        'Export-ModuleMember -Function Get-FixtureThing'
    )
    Set-Content -LiteralPath $script:FixtureModulePath -Value $FixtureModuleContent

    # Common prelude: import the host module (required by the checker) and
    # the fixture module (so Get-FixtureThing resolves as "Installed").
    $PathLine = "`$env:PSModulePath = '$($script:ScratchDir)' + " +
    "[IO.Path]::PathSeparator + `$env:PSModulePath"
    $script:BasePrelude = @(
        $PathLine
        "Import-Module '$($script:HostManifest)' -Force"
        "Import-Module '$($script:FixtureModulePath)' -Force"
    )

    function script:Invoke-Checker {
        param(
            [Parameter(Mandatory)][string[]] $ScriptArgs,
            [string[]] $ExtraPrelude
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
        $Lines.AddRange([string[]] $script:BasePrelude)
        if ($ExtraPrelude) { $Lines.AddRange([string[]] $ExtraPrelude) }
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

    # Fixture *target* files live in their own subfolder, separate from the
    # fixture module, so a folder scan never picks up FixtureModule.psm1 itself.
    function script:New-TargetDir {
        $DirParams = @{
            Path      = $script:ScratchDir
            ChildPath = "targets-$([guid]::NewGuid().ToString('N'))"
        }
        $Dir = Join-Path @DirParams
        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
        return $Dir
    }
}

AfterAll {
    Remove-Item -LiteralPath $script:ScratchDir -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Test-ExplicitModuleImport' -Tag 'unit', 'functional' {

    It 'passes when the module name is not required (no external commands)' {
        $Dir = New-TargetDir
        Set-Content -LiteralPath (Join-Path -Path $Dir -ChildPath 'clean.ps1') -Value '$x = 1'
        $Result = Invoke-Checker -ScriptArgs @('-Path', $Dir, '-Recurse')
        $Result.ExitCode | Should -Be 0
        $Result.Output | Should -Match '0 missing module reference'
    }

    It 'flags a file that uses an Installed command without naming its module' {
        $Dir = New-TargetDir
        $BadParams = @{
            LiteralPath = Join-Path -Path $Dir -ChildPath 'bad.ps1'
            Value       = 'Get-FixtureThing'
        }
        Set-Content @BadParams
        $Result = Invoke-Checker -ScriptArgs @('-Path', $Dir, '-Recurse')
        $Result.ExitCode | Should -Be 1
        $Result.Output | Should -Match '1 missing module reference'
        $Result.Output | Should -Match 'FixtureModule'
    }

    It 'passes when the module name is literally present in the file' {
        $Dir = New-TargetDir
        $Content = @('# Requires the FixtureModule module', 'Get-FixtureThing')
        Set-Content -LiteralPath (Join-Path -Path $Dir -ChildPath 'good.ps1') -Value $Content
        $Result = Invoke-Checker -ScriptArgs @('-Path', $Dir, '-Recurse')
        $Result.ExitCode | Should -Be 0
        $Result.Output | Should -Match '0 missing module reference'
    }

    It 'suppresses a file carrying the noqa marker' {
        $Dir = New-TargetDir
        $Content = @('# noqa: Test-ExplicitModuleImport', 'Get-FixtureThing')
        Set-Content -LiteralPath (Join-Path -Path $Dir -ChildPath 'noqa.ps1') -Value $Content
        $Result = Invoke-Checker -ScriptArgs @('-Path', $Dir, '-Recurse')
        $Result.ExitCode | Should -Be 0
    }

    It 'errors out when the host module is not imported' {
        $Dir = New-TargetDir
        Set-Content -LiteralPath (Join-Path -Path $Dir -ChildPath 'clean.ps1') -Value '$x = 1'
        $NoImportPathLine = "`$env:PSModulePath = '$($script:ScratchDir)' + " +
        "[IO.Path]::PathSeparator + `$env:PSModulePath"
        $NoImportPrelude = @($NoImportPathLine)
        $Lines = [System.Collections.Generic.List[string]]::new()
        $Lines.AddRange([string[]] $NoImportPrelude)
        $CatchBody = 'Write-Host $_.Exception.Message; exit 1'
        $Lines.Add("try { & '$script:Sut' -Path '$Dir' -Recurse } catch { $CatchBody }")
        $Lines.Add('exit 0')
        $WrapperParams = @{
            Path      = $script:ScratchDir
            ChildPath = "wrapper-$([guid]::NewGuid().ToString('N')).ps1"
        }
        $WrapperPath = Join-Path @WrapperParams
        Set-Content -LiteralPath $WrapperPath -Value $Lines
        $ArgList = @('-NoProfile', '-NonInteractive', '-File', $WrapperPath)
        $Output = & pwsh @ArgList 2>&1
        $ExitCode = $LASTEXITCODE
        Remove-Item -LiteralPath $WrapperPath -Force -ErrorAction SilentlyContinue

        $ExitCode | Should -Be 1
        ($Output | Out-String) | Should -Match 'is not imported'
    }
}
