<#
.SYNOPSIS
    Pester tests for Scripts\TemplateSetup\Set-GitHubUser.ps1.

.DESCRIPTION
    Set-GitHubUser takes an explicit -RepoRoot, so -- unlike the orchestrator --
    its apply path is safe to exercise for real against a throwaway scratch
    tree. The script guards its parameter-driven body with
    `if ($MyInvocation.InvocationName -eq '.') { return }`, so dot-sourcing it
    reaches the Set-GitHubUser function (and the shared helpers it dot-sources)
    without running the standalone entrypoint.
#>

BeforeAll {
    $SutParams = @{
        Path      = $PSScriptRoot
        ChildPath = '..\..\Scripts\TemplateSetup\Set-GitHubUser.ps1'
    }
    $script:Sut = (Resolve-Path (Join-Path @SutParams)).Path
    . $script:Sut
}

Describe 'Set-GitHubUser' -Tag 'unit', 'functional' {
    BeforeEach {
        $ScratchParams = @{
            Path      = [System.IO.Path]::GetTempPath()
            ChildPath = "setghu-$([guid]::NewGuid().ToString('N'))"
        }
        $script:Scratch = Join-Path @ScratchParams
        New-Item -ItemType Directory -Path $script:Scratch -Force | Out-Null

        $script:ReadmePath = Join-Path -Path $script:Scratch -ChildPath 'README.md'
        $Content = @(
            'clone https://github.com/FIXME/FIXME.git'
            'site https://FIXME.github.io/FIXME/'
        ) -join "`n"
        Set-Content -LiteralPath $script:ReadmePath -Value $Content -NoNewline
    }

    AfterEach {
        Remove-Item -LiteralPath $script:Scratch -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'fills in both owner/repo and github.io placeholders' {
        $Params = @{
            RepoRoot   = $script:Scratch
            Name       = 'MyModule'
            GitHubUser = 'octocat'
            DryRun     = $false
        }
        Set-GitHubUser @Params | Should -BeTrue

        $Result = Get-Content -LiteralPath $script:ReadmePath -Raw
        $Result | Should -Match 'github.com/octocat/MyModule'
        $Result | Should -Match 'octocat.github.io/MyModule'
        $Result | Should -Not -Match 'FIXME'
    }

    It 'writes nothing under -DryRun' {
        $Before = Get-Content -LiteralPath $script:ReadmePath -Raw
        $Params = @{
            RepoRoot   = $script:Scratch
            Name       = 'MyModule'
            GitHubUser = 'octocat'
            DryRun     = $true
        }
        Set-GitHubUser @Params | Should -BeTrue

        (Get-Content -LiteralPath $script:ReadmePath -Raw) | Should -Be $Before
    }

    It 'is a no-op when GitHubUser is blank' {
        $Before = Get-Content -LiteralPath $script:ReadmePath -Raw
        $Params = @{
            RepoRoot   = $script:Scratch
            Name       = 'MyModule'
            GitHubUser = ''
            DryRun     = $false
        }
        Set-GitHubUser @Params | Should -BeTrue

        (Get-Content -LiteralPath $script:ReadmePath -Raw) | Should -Be $Before
    }

    It 'is idempotent: a second run changes nothing more' {
        $Params = @{
            RepoRoot   = $script:Scratch
            Name       = 'MyModule'
            GitHubUser = 'octocat'
            DryRun     = $false
        }
        Set-GitHubUser @Params | Should -BeTrue
        $AfterFirst = Get-Content -LiteralPath $script:ReadmePath -Raw
        Set-GitHubUser @Params | Should -BeTrue

        (Get-Content -LiteralPath $script:ReadmePath -Raw) | Should -Be $AfterFirst
    }
}
