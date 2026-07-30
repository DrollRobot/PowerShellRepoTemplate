<#
.SYNOPSIS
    Pester tests for Source\ScriptsToProcess\Confirm-Dependency.ps1.

.DESCRIPTION
    The script reads RequiredModules.psd1 from its own directory and checks each declared
    module against what is installed. A scratch copy of the script plus a generated
    RequiredModules.psd1 is placed in a fixture folder so this is exercised in isolation.
    Uses `return`/`throw`, not `exit`, so it is safe to invoke in-process via the call
    operator. It banners via Write-Host; Pester does not capture stream 6, so every
    invocation redirects it to keep the run output clean. NotLive; no tag.

    'Pester' is used as the stand-in for an installed module -- it is by definition
    present whenever these tests run.
#>

BeforeAll {
    $RealConfirmParams = @{
        Path      = $PSScriptRoot
        ChildPath = '..\..\Source\ScriptsToProcess\Confirm-Dependency.ps1'
    }
    $script:RealConfirm = (Resolve-Path (Join-Path @RealConfirmParams)).Path

    $ScratchParams = @{
        Path      = [System.IO.Path]::GetTempPath()
        ChildPath = [System.IO.Path]::GetRandomFileName()
    }
    $script:ScratchDir = Join-Path @ScratchParams
    New-Item -ItemType Directory -Path $script:ScratchDir -Force | Out-Null

    # Builds a fixture folder holding a copy of Confirm-Dependency.ps1 and, unless
    # -NoDataFile is passed, a RequiredModules.psd1 with the given body beside it --
    # the sibling layout the script expects in the built module.
    function script:New-DependencyFixture {
        param(
            [string] $DataBody = '@{ RequiredModules = @() }',
            [switch] $NoDataFile
        )
        $RootParams = @{
            Path      = $script:ScratchDir
            ChildPath = "mod-$([guid]::NewGuid().ToString('N'))"
        }
        $Root = Join-Path @RootParams
        New-Item -ItemType Directory -Path $Root -Force | Out-Null
        if (-not $NoDataFile) {
            $DataParams = @{
                LiteralPath = Join-Path -Path $Root -ChildPath 'RequiredModules.psd1'
                Value       = $DataBody
            }
            Set-Content @DataParams
        }
        $ConfirmCopy = Join-Path -Path $Root -ChildPath 'Confirm-Dependency.ps1'
        Copy-Item -LiteralPath $script:RealConfirm -Destination $ConfirmCopy
        return [pscustomobject]@{ Root = $Root; ConfirmScript = $ConfirmCopy }
    }

    $script:MissingModuleData = @'
@{
    RequiredModules = @(
        @{ ModuleName = 'DefinitelyNotARealModule12345'; ModuleVersion = '1.0.0' }
    )
}
'@
}

AfterAll {
    Remove-Item -LiteralPath $script:ScratchDir -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Confirm-Dependency' -Tag 'unit', 'functional' {

    AfterEach {
        # $Global:ModuleDependenciesChecked is keyed by the script's own directory, so
        # this only ever clears entries this test file itself created.
        if ($Global:ModuleDependenciesChecked -is [hashtable] -and $script:FixtureRoot) {
            $Global:ModuleDependenciesChecked.Remove($script:FixtureRoot)
        }
    }

    It 'succeeds when RequiredModules.psd1 declares nothing' {
        $Fixture = New-DependencyFixture
        $script:FixtureRoot = $Fixture.Root
        { & $Fixture.ConfirmScript 6>$null } | Should -Not -Throw
    }

    It 'returns quietly when RequiredModules.psd1 is absent' {
        $Fixture = New-DependencyFixture -NoDataFile
        $script:FixtureRoot = $Fixture.Root
        { & $Fixture.ConfirmScript 6>$null } | Should -Not -Throw
    }

    It 'succeeds when a declared module is installed at a satisfying version' {
        $DataBody = @'
@{
    RequiredModules = @(
        @{ ModuleName = 'Pester'; ModuleVersion = '0.0.1' }
    )
}
'@
        $Fixture = New-DependencyFixture -DataBody $DataBody
        $script:FixtureRoot = $Fixture.Root
        { & $Fixture.ConfirmScript 6>$null } | Should -Not -Throw
    }

    It 'records the script directory in $Global:ModuleDependenciesChecked on success' {
        $Fixture = New-DependencyFixture
        $script:FixtureRoot = $Fixture.Root
        & $Fixture.ConfirmScript 6>$null
        $Global:ModuleDependenciesChecked | Should -Not -BeNullOrEmpty
        $Global:ModuleDependenciesChecked[$Fixture.Root] | Should -BeTrue
    }

    It 'skips re-checking once the script directory is already recorded' {
        # Pre-seed the cache against a fixture whose dependency can never be
        # satisfied. Not throwing proves the cache short-circuited the scan.
        $Fixture = New-DependencyFixture -DataBody $script:MissingModuleData
        $script:FixtureRoot = $Fixture.Root
        if ($Global:ModuleDependenciesChecked -isnot [hashtable]) {
            $Global:ModuleDependenciesChecked = @{}
        }
        $Global:ModuleDependenciesChecked[$Fixture.Root] = $true
        { & $Fixture.ConfirmScript 6>$null } | Should -Not -Throw
    }

    It 'throws when a required module is missing and not yet cached' {
        $Fixture = New-DependencyFixture -DataBody $script:MissingModuleData
        $script:FixtureRoot = $Fixture.Root
        { & $Fixture.ConfirmScript 6>$null } | Should -Throw
    }

    It 'throws when a required module is installed but below the declared minimum' {
        $DataBody = @'
@{
    RequiredModules = @(
        @{ ModuleName = 'Pester'; ModuleVersion = '9999.0.0' }
    )
}
'@
        $Fixture = New-DependencyFixture -DataBody $DataBody
        $script:FixtureRoot = $Fixture.Root
        { & $Fixture.ConfirmScript 6>$null } | Should -Throw
    }

    It 'does not record the script directory when a required module is missing' {
        $Fixture = New-DependencyFixture -DataBody $script:MissingModuleData
        $script:FixtureRoot = $Fixture.Root
        try { & $Fixture.ConfirmScript 6>$null } catch { }
        if ($Global:ModuleDependenciesChecked -is [hashtable]) {
            $Global:ModuleDependenciesChecked[$Fixture.Root] | Should -Not -Be $true
        }
    }

    It 'does not leak its working variables into the calling scope' {
        # Dot-sourced, because that is how ScriptsToProcess runs it: in the caller's
        # scope, where anything the script assigns would land in the user's session.
        $Fixture = New-DependencyFixture
        $script:FixtureRoot = $Fixture.Root
        . $Fixture.ConfirmScript 6>$null
        $LeakParams = @{ Scope = 'Local'; ErrorAction = 'Ignore' }
        foreach ($Leak in 'DataPath', 'DepsChecked', 'RequiredModules', 'Unsatisfied') {
            Get-Variable @LeakParams -Name $Leak | Should -BeNullOrEmpty -Because $Leak
        }
    }
}
