<#
.SYNOPSIS
    Pester tests for Tests.ps1's Destructive gating logic.

.DESCRIPTION
    The orchestrator itself has no other tests (meta: testing the test
    runner). This covers the ambiguous-tag refusal logic (Tests.ps1's
    Destructive discovery block) since it is non-trivial and worth locking
    down: a fixture Pester file is generated per case and the real Tests.ps1
    is invoked against just that fixture via -Path, so the real Tests\Pester
    folder's own destructive tests are never part of the discovery.

    Every case here is a REFUSAL path (ambiguous tags, or DISPOSABLE_ENVIRONMENT
    unset, or an unconfirmed remote target) -- none of them ever runs the
    fixture's destructive test body, so this needs no DISPOSABLE_ENVIRONMENT
    gating of its own. Integration; no tag.
#>

BeforeAll {
    $SutParams = @{
        Path      = $PSScriptRoot
        ChildPath = '..\..\Tests.ps1'
    }
    $script:Sut = (Resolve-Path (Join-Path @SutParams)).Path
    $RepoRootParams = @{
        Path      = $PSScriptRoot
        ChildPath = '..\..'
    }
    $script:RepoRoot = (Resolve-Path (Join-Path @RepoRootParams)).Path

    $ScratchParams = @{
        Path      = [System.IO.Path]::GetTempPath()
        ChildPath = [System.IO.Path]::GetRandomFileName()
    }
    $script:ScratchDir = Join-Path @ScratchParams
    New-Item -ItemType Directory -Path $script:ScratchDir -Force | Out-Null

    function script:New-FixtureTest {
        param([Parameter(Mandatory)][string[]] $Tags)
        $TagList = ($Tags | ForEach-Object { "'$_'" }) -join ', '
        $Content = @(
            "Describe 'Fixture' -Tag $TagList {"
            "    It 'does nothing' { `$true | Should -Be `$true }"
            '}'
        )
        $FileParams = @{
            Path      = $script:ScratchDir
            ChildPath = "fixture-$([guid]::NewGuid().ToString('N')).Tests.ps1"
        }
        $Path = Join-Path @FileParams
        Set-Content -LiteralPath $Path -Value $Content
        return $Path
    }

    function script:Invoke-DestructiveRun {
        param([Parameter(Mandatory)][string] $FixturePath)
        $ArgList = @(
            '-NoProfile', '-NonInteractive', '-File', $script:Sut,
            'Destructive', '-Path', $FixturePath
        )
        # Every case here is a refusal/no-op path; none should run a local
        # destructive body. Clear DISPOSABLE_ENVIRONMENT for the child so the
        # gate is exercised deterministically regardless of the ambient value
        # (a disposable host sets it to 1, which would otherwise pass the gate).
        $PriorDisposable = $env:DISPOSABLE_ENVIRONMENT
        Push-Location -LiteralPath $script:RepoRoot
        try {
            $env:DISPOSABLE_ENVIRONMENT = $null
            $Output = & pwsh @ArgList 2>&1
        }
        finally {
            $env:DISPOSABLE_ENVIRONMENT = $PriorDisposable
            Pop-Location
        }
        return [PSCustomObject]@{
            Output   = ($Output | Out-String)
            ExitCode = $LASTEXITCODE
        }
    }
}

AfterAll {
    Remove-Item -LiteralPath $script:ScratchDir -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Tests.ps1 Destructive gating' -Tag 'integration', 'functional' {

    It 'refuses the whole category when a destructive test has neither local nor remote' {
        $Fixture = New-FixtureTest -Tags @('destructive')
        $Result = Invoke-DestructiveRun -FixturePath $Fixture
        $Result.ExitCode | Should -Be 1
        $Result.Output | Should -Match 'Refusing Destructive: ambiguous scope tags'
    }

    It 'refuses the whole category when a destructive test has both local and remote' {
        $Fixture = New-FixtureTest -Tags @('destructive', 'local', 'remote')
        $Result = Invoke-DestructiveRun -FixturePath $Fixture
        $Result.ExitCode | Should -Be 1
        $Result.Output | Should -Match 'Refusing Destructive: ambiguous scope tags'
    }

    It 'refuses the local subset when DISPOSABLE_ENVIRONMENT is not 1' {
        $Fixture = New-FixtureTest -Tags @('destructive', 'local')
        $Result = Invoke-DestructiveRun -FixturePath $Fixture
        $Result.ExitCode | Should -Be 1
        $Result.Output | Should -Match 'Refusing: DISPOSABLE_ENVIRONMENT is not 1'
    }

    It 'refuses the remote subset when the target is unconfirmed' {
        $Fixture = New-FixtureTest -Tags @('destructive', 'remote')
        $Result = Invoke-DestructiveRun -FixturePath $Fixture
        $Result.ExitCode | Should -Be 1
        $Result.Output | Should -Match 'Refusing: remote target unconfirmed'
    }

    It 'reports nothing to refuse when no destructive-tagged tests exist' {
        $Fixture = New-FixtureTest -Tags @('unit')
        $Result = Invoke-DestructiveRun -FixturePath $Fixture
        $Result.ExitCode | Should -Be 0
        $Result.Output | Should -Match 'No destructive-tagged tests found'
    }
}
