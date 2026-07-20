<#
.SYNOPSIS
    Pester tests for Scripts\Resolve-CommandModule.ps1.

.DESCRIPTION
    Dot-sources the script to load Resolve-CommandModule -- a pure function
    with no top-level execution, so no child-process isolation is needed.

    Builtin/NotFound/None assertions are pinned to stable PowerShell built-ins
    rather than anything environment-dependent. HostPublic/HostPrivate
    assertions use a throwaway fixture module (built here, with one exported
    and one non-exported function) rather than this repo's own module, since
    the template ships with no Source\Private functions yet to probe; a
    lighter HostPublic check against the real host module is included too,
    since that combination is the checker's actual real-world use in
    Test-ExplicitModuleImport.ps1. NonLive; no tag.
#>

BeforeAll {
    $SutParams = @{
        Path      = $PSScriptRoot
        ChildPath = '..\..\Scripts\Resolve-CommandModule.ps1'
    }
    . (Resolve-Path (Join-Path @SutParams)).Path

    $ScratchParams = @{
        Path      = [System.IO.Path]::GetTempPath()
        ChildPath = [System.IO.Path]::GetRandomFileName()
    }
    $script:ScratchDir = Join-Path @ScratchParams
    New-Item -ItemType Directory -Path $script:ScratchDir -Force | Out-Null

    $FixtureModDirParams = @{
        Path      = $script:ScratchDir
        ChildPath = 'RcmFixtureModule'
    }
    $FixtureModuleDir = Join-Path @FixtureModDirParams
    New-Item -ItemType Directory -Path $FixtureModuleDir -Force | Out-Null
    $FixtureModPathParams = @{
        Path      = $FixtureModuleDir
        ChildPath = 'RcmFixtureModule.psm1'
    }
    $FixtureModulePath = Join-Path @FixtureModPathParams
    $FixtureModuleContent = @(
        'function Get-RcmFixturePublic { "public" }'
        'function Get-RcmFixturePrivate { "private" }'
        'Export-ModuleMember -Function Get-RcmFixturePublic'
    )
    Set-Content -LiteralPath $FixtureModulePath -Value $FixtureModuleContent
    Import-Module $FixtureModulePath -Force

    $RepoRootParams = @{
        Path      = $PSScriptRoot
        ChildPath = '..\..'
    }
    $RepoRoot = (Resolve-Path (Join-Path @RepoRootParams)).Path
    $HostManifestParams = @{
        Path      = $RepoRoot
        ChildPath = 'source\PowershellRepoTemplate.psd1'
    }
    $HostManifest = (Resolve-Path (Join-Path @HostManifestParams)).Path
    Import-Module $HostManifest -Force
}

AfterAll {
    Remove-Module -Name RcmFixtureModule -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $script:ScratchDir -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Resolve-CommandModule' -Tag 'unit', 'functional' {

    Context 'stable built-ins' {
        It 'classifies a shipped PowerShell cmdlet as Builtin' {
            $Result = Resolve-CommandModule -Name 'Get-ChildItem'
            $Result.Source | Should -Be 'Builtin'
            $Result.Module | Should -Be 'Microsoft.PowerShell.Management'
        }

        It 'classifies an unresolvable name as NotFound' {
            $Result = Resolve-CommandModule -Name 'Get-DefinitelyNotARealCommand12345'
            $Result.Source | Should -Be 'NotFound'
            $Result.Module | Should -BeNullOrEmpty
        }

        It 'classifies a command with no owning module as None' {
            try {
                function global:Get-RcmLooseFunction { 1 }
                $Result = Resolve-CommandModule -Name 'Get-RcmLooseFunction'
                $Result.Source | Should -Be 'None'
                $Result.Module | Should -BeNullOrEmpty
            }
            finally {
                Remove-Item -Path function:global:Get-RcmLooseFunction -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'alias following' {
        It 'resolves an alias to its underlying command''s module and classification' {
            $Result = Resolve-CommandModule -Name 'gci'
            $Result.Name | Should -Be 'gci'
            $Result.Module | Should -Be 'Microsoft.PowerShell.Management'
            $Result.Source | Should -Be 'Builtin'
        }
    }

    Context 'pipeline input' {
        It 'accepts multiple names from the pipeline' {
            $Results = @('Get-ChildItem', 'Get-DefinitelyNotARealCommand12345') |
                Resolve-CommandModule
            $Results.Count | Should -Be 2
            ($Results | Where-Object Name -EQ 'Get-ChildItem').Source | Should -Be 'Builtin'
            $NotFoundResult = $Results | Where-Object Name -EQ 'Get-DefinitelyNotARealCommand12345'
            $NotFoundResult.Source | Should -Be 'NotFound'
        }
    }

    Context '-HostModuleName classification' {
        It 'classifies an exported host-module command as HostPublic' {
            $Params = @{ Name = 'Get-Greeting'; HostModuleName = 'PowershellRepoTemplate' }
            $Result = Resolve-CommandModule @Params
            $Result.Source | Should -Be 'HostPublic'
            $Result.Module | Should -Be 'PowershellRepoTemplate'
        }

        It 'classifies an exported fixture-module command as HostPublic' {
            $Params = @{ Name = 'Get-RcmFixturePublic'; HostModuleName = 'RcmFixtureModule' }
            $Result = Resolve-CommandModule @Params
            $Result.Source | Should -Be 'HostPublic'
        }

        It 'classifies a non-exported fixture-module command as HostPrivate' {
            $Params = @{ Name = 'Get-RcmFixturePrivate'; HostModuleName = 'RcmFixtureModule' }
            $Result = Resolve-CommandModule @Params
            $Result.Source | Should -Be 'HostPrivate'
            $Result.Module | Should -Be 'RcmFixtureModule'
        }

        It 'still classifies external commands normally when -HostModuleName is set' {
            $Result = Resolve-CommandModule -Name 'Get-ChildItem' -HostModuleName 'RcmFixtureModule'
            $Result.Source | Should -Be 'Builtin'
        }
    }
}
