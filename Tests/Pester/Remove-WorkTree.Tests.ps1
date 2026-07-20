<#
.SYNOPSIS
    Pester tests for Scripts\Remove-WorkTree.ps1.

.DESCRIPTION
    The script now guards its main body with `if ($MyInvocation.InvocationName
    -eq '.') { return }` (added alongside this test), so it can be dot-sourced
    to reach its pure helper functions (Test-SamePath, Get-WorktreeEntry,
    Get-OpenWorktreeSlug) without running the interactive/destructive flow.
    Those are covered here as NonLive unit tests.

    The actual teardown flow (git worktree remove --force, git branch -D, git
    fetch --prune) is destructive and needs a real repo/cwd, since the script
    has no -RepoPath parameter. It is exercised here against a throwaway repo
    (with a local bare repo standing in for "origin") as a destructive,local
    integration test gated on DISPOSABLE_ENVIRONMENT=1, per AGENTS.TESTING.md.
    This was written but could not be executed in this session
    (DISPOSABLE_ENVIRONMENT was unset) -- treat it as unverified until it has
    been run at least once.
#>

BeforeAll {
    $SutParams = @{
        Path      = $PSScriptRoot
        ChildPath = '..\..\Scripts\Remove-WorkTree.ps1'
    }
    $script:Sut = (Resolve-Path (Join-Path @SutParams)).Path

    $ScratchParams = @{
        Path      = [System.IO.Path]::GetTempPath()
        ChildPath = [System.IO.Path]::GetRandomFileName()
    }
    $script:ScratchDir = Join-Path @ScratchParams
    New-Item -ItemType Directory -Path $script:ScratchDir -Force | Out-Null

    # Dot-source with a harmless -Yes/-Slug combo: the guard returns before
    # anything else is touched.
    . $script:Sut -Slug 'dot-source-probe' -Yes
}

AfterAll {
    Remove-Item -LiteralPath $script:ScratchDir -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Remove-WorkTree helpers' -Tag 'unit', 'functional' {

    Context 'Test-SamePath' {
        It 'treats forward and back slashes as equal' {
            Test-SamePath 'C:/repo/wt/issue-1' 'C:\repo\wt\issue-1' | Should -BeTrue
        }

        It 'ignores a trailing separator' {
            Test-SamePath 'C:\repo\wt\issue-1\' 'C:\repo\wt\issue-1' | Should -BeTrue
        }

        It 'is case-insensitive' {
            Test-SamePath 'C:\Repo\WT\Issue-1' 'c:\repo\wt\issue-1' | Should -BeTrue
        }

        It 'returns false for genuinely different paths' {
            Test-SamePath 'C:\repo\wt\issue-1' 'C:\repo\wt\issue-2' | Should -BeFalse
        }
    }

    Context 'Get-WorktreeEntry' {
        It 'parses porcelain output into Path/Branch pairs' {
            $Porcelain = @(
                'worktree C:/repo'
                'HEAD abc123'
                'branch refs/heads/develop'
                ''
                'worktree C:/repo-wt/issue-1'
                'HEAD def456'
                'branch refs/heads/wt/issue-1'
                ''
            )
            $Result = Get-WorktreeEntry -Porcelain $Porcelain
            $Result.Count | Should -Be 2
            $Result[0].Path | Should -Be 'C:/repo'
            $Result[0].Branch | Should -Be 'refs/heads/develop'
            $Result[1].Path | Should -Be 'C:/repo-wt/issue-1'
            $Result[1].Branch | Should -Be 'refs/heads/wt/issue-1'
        }

        It 'reports a null branch for a detached HEAD worktree' {
            $Porcelain = @('worktree C:/repo-wt/detached', 'HEAD abc123', 'detached', '')
            $Result = Get-WorktreeEntry -Porcelain $Porcelain
            $Result[0].Branch | Should -BeNullOrEmpty
        }
    }

    Context 'Get-OpenWorktreeSlug' {
        It 'skips the main worktree and returns only wt/-prefixed branches' {
            $Worktrees = @(
                [pscustomobject]@{ Path = 'C:/repo'; Branch = 'refs/heads/develop' }
                [pscustomobject]@{ Path = 'C:/repo-wt/issue-1'; Branch = 'refs/heads/wt/issue-1' }
                [pscustomobject]@{ Path = 'C:/repo-wt/other'; Branch = 'refs/heads/other' }
            )
            $Result = Get-OpenWorktreeSlug -Worktrees $Worktrees -Prefix 'wt/'
            $Result.Count | Should -Be 1
            $Result[0].Slug | Should -Be 'issue-1'
            $Result[0].Path | Should -Be 'C:/repo-wt/issue-1'
        }

        It 'returns nothing when no linked worktree has the wt/ prefix' {
            $Worktrees = @(
                [pscustomobject]@{ Path = 'C:/repo'; Branch = 'refs/heads/develop' }
                [pscustomobject]@{ Path = 'C:/repo-wt/other'; Branch = 'refs/heads/other' }
            )
            $Result = @(Get-OpenWorktreeSlug -Worktrees $Worktrees -Prefix 'wt/')
            $Result.Count | Should -Be 0
        }
    }
}

# Computed at discovery time (outside BeforeAll) because Pester evaluates
# -Skip: expressions during discovery, before any BeforeAll block has run.
$script:DisposableOk = $env:DISPOSABLE_ENVIRONMENT -eq '1'

Describe 'Remove-WorkTree' -Tag 'integration', 'functional', 'destructive', 'local' {
    BeforeAll {
        if ($script:DisposableOk) {
            $FixtureParams = @{
                Path      = $script:ScratchDir
                ChildPath = "rwt-fixture-$([guid]::NewGuid().ToString('N'))"
            }
            $script:FixtureRoot = Join-Path @FixtureParams
            $script:OriginPath = Join-Path -Path $script:FixtureRoot -ChildPath 'origin.git'
            $script:RepoPath = Join-Path -Path $script:FixtureRoot -ChildPath 'repo'
            New-Item -ItemType Directory -Path $script:FixtureRoot -Force | Out-Null

            & git init --bare --initial-branch=develop $script:OriginPath *> $null
            & git clone $script:OriginPath $script:RepoPath *> $null

            Push-Location -LiteralPath $script:RepoPath
            try {
                & git config user.email 'test@example.invalid'
                & git config user.name 'Test'
                $ReadmeParams = @{
                    LiteralPath = Join-Path -Path $script:RepoPath -ChildPath 'README.md'
                    Value       = '# fixture'
                }
                Set-Content @ReadmeParams
                & git add -A
                & git commit -m 'Initial commit' *> $null
                & git push origin develop *> $null

                $WtHome = Join-Path -Path $script:FixtureRoot -ChildPath 'repo-wt'
                $WtPath = Join-Path -Path $WtHome -ChildPath 'issue-1'
                New-Item -ItemType Directory -Path $WtHome -Force | Out-Null
                & git worktree add -b wt/issue-1 $WtPath develop *> $null
            }
            finally {
                Pop-Location
            }

            $script:OriginalLocation = Get-Location
            Set-Location -LiteralPath $script:RepoPath
        }
    }

    AfterAll {
        if ($script:DisposableOk) {
            Set-Location -LiteralPath $script:OriginalLocation
            $CleanupParams = @{
                LiteralPath = $script:FixtureRoot
                Recurse     = $true
                Force       = $true
                ErrorAction = 'SilentlyContinue'
            }
            Remove-Item @CleanupParams
        }
    }

    It 'removes the worktree and deletes its branch' -Skip:(-not $script:DisposableOk) {
        $Params = @{
            FilePath         = 'pwsh'
            ArgumentList     = @(
                '-NoProfile', '-NonInteractive', '-File', $script:Sut,
                'issue-1', 'develop', '-Yes'
            )
            WorkingDirectory = $script:RepoPath
            NoNewWindow      = $true
            Wait             = $true
            PassThru         = $true
        }
        $Proc = Start-Process @Params
        $Proc.ExitCode | Should -Be 0

        $Worktrees = & git -C $script:RepoPath worktree list --porcelain
        ($Worktrees -join "`n") | Should -Not -Match 'issue-1'
        $Branches = & git -C $script:RepoPath branch --list 'wt/issue-1'
        $Branches | Should -BeNullOrEmpty
    }
}
