<#
.SYNOPSIS
    Pester tests for Scripts\New-Worktree.ps1.

.DESCRIPTION
    The script now guards its main body with `if ($MyInvocation.InvocationName
    -eq '.') { return }` (added alongside this test), so it can be dot-sourced
    to reach its pure helper functions without running the interactive/
    mutating flow. Get-SourceWorkspace is covered here as a NotLive unit test.

    The actual worktree-creation flow is destructive (creates a real git
    worktree, branch, and pushes to "origin") and needs a real repo/cwd since
    the script has no -RepoPath parameter -- it always resolves via
    `git rev-parse --show-toplevel` from the process's current directory. That
    flow is exercised here against a throwaway repo (with a local bare repo
    standing in for "origin", so nothing ever leaves disk) as a
    destructive,local integration test gated on DISPOSABLE_ENVIRONMENT=1, per
    AGENTS.TESTING.md. This was written but could not be executed in this
    session (DISPOSABLE_ENVIRONMENT was unset) -- treat it as unverified until
    it has been run at least once.
#>

BeforeAll {
    $SutParams = @{
        Path      = $PSScriptRoot
        ChildPath = '..\..\Scripts\New-Worktree.ps1'
    }
    $script:Sut = (Resolve-Path (Join-Path @SutParams)).Path

    $ScratchParams = @{
        Path      = [System.IO.Path]::GetTempPath()
        ChildPath = [System.IO.Path]::GetRandomFileName()
    }
    $script:ScratchDir = Join-Path @ScratchParams
    New-Item -ItemType Directory -Path $script:ScratchDir -Force | Out-Null

    # Dot-source with a bogus mandatory -Slug bound to something harmless: the
    # guard returns before -Slug (or anything else) is ever used.
    . $script:Sut -Slug 'dot-source-probe'
}

AfterAll {
    Remove-Item -LiteralPath $script:ScratchDir -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'New-Worktree helpers' -Tag 'unit', 'functional' {

    Context 'Get-SourceWorkspace' {
        It 'returns the first *.code-workspace file found, excluding the target name' {
            $DirParams = @{
                Path      = $script:ScratchDir
                ChildPath = "ws-$([guid]::NewGuid().ToString('N'))"
            }
            $Dir = Join-Path @DirParams
            New-Item -ItemType Directory -Path $Dir -Force | Out-Null
            $TargetName = 'target.code-workspace'
            Set-Content -LiteralPath (Join-Path -Path $Dir -ChildPath $TargetName) -Value '{}'
            $OtherPath = Join-Path -Path $Dir -ChildPath 'other.code-workspace'
            Set-Content -LiteralPath $OtherPath -Value '{ "folders": [] }'

            $Result = Get-SourceWorkspace -SearchDirs @($Dir) -ExcludeName $TargetName
            $Result | Should -Be $OtherPath
        }

        It 'returns null when no workspace file exists' {
            $DirParams = @{
                Path      = $script:ScratchDir
                ChildPath = "ws-empty-$([guid]::NewGuid().ToString('N'))"
            }
            $Dir = Join-Path @DirParams
            New-Item -ItemType Directory -Path $Dir -Force | Out-Null
            $Result = Get-SourceWorkspace -SearchDirs @($Dir) -ExcludeName 'target.code-workspace'
            $Result | Should -BeNullOrEmpty
        }

        It 'checks search directories in order and returns the first match' {
            $FirstParams = @{
                Path      = $script:ScratchDir
                ChildPath = "ws-first-$([guid]::NewGuid().ToString('N'))"
            }
            $First = Join-Path @FirstParams
            $SecondParams = @{
                Path      = $script:ScratchDir
                ChildPath = "ws-second-$([guid]::NewGuid().ToString('N'))"
            }
            $Second = Join-Path @SecondParams
            New-Item -ItemType Directory -Path $First -Force | Out-Null
            New-Item -ItemType Directory -Path $Second -Force | Out-Null
            $FirstFile = Join-Path -Path $First -ChildPath 'first.code-workspace'
            $SecondFile = Join-Path -Path $Second -ChildPath 'second.code-workspace'
            Set-Content -LiteralPath $FirstFile -Value '{}'
            Set-Content -LiteralPath $SecondFile -Value '{}'

            $Result = Get-SourceWorkspace -SearchDirs @($First, $Second) -ExcludeName 'x'
            $Result | Should -Be $FirstFile
        }
    }
}

# Computed at discovery time (outside BeforeAll) because Pester evaluates
# -Skip: expressions during discovery, before any BeforeAll block has run.
$script:DisposableOk = $env:DISPOSABLE_ENVIRONMENT -eq '1'

Describe 'New-Worktree' -Tag 'integration', 'functional', 'destructive', 'local' {
    BeforeAll {
        if ($script:DisposableOk) {
            $FixtureParams = @{
                Path      = $script:ScratchDir
                ChildPath = "nwt-fixture-$([guid]::NewGuid().ToString('N'))"
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

    It 'creates a worktree and branch from a fixture repo' -Skip:(-not $script:DisposableOk) {
        $Params = @{
            FilePath     = 'pwsh'
            ArgumentList = @(
                '-NoProfile', '-NonInteractive', '-File', $script:Sut,
                'fixture-slug', 'develop', '-NoBootstrap', '-Yes'
            )
            WorkingDirectory = $script:RepoPath
            NoNewWindow      = $true
            Wait             = $true
            PassThru         = $true
        }
        $Proc = Start-Process @Params
        $Proc.ExitCode | Should -Be 0

        $Branches = & git -C $script:RepoPath branch --list 'wt/fixture-slug'
        $Branches | Should -Not -BeNullOrEmpty
        $Worktrees = & git -C $script:RepoPath worktree list --porcelain
        ($Worktrees -join "`n") | Should -Match 'fixture-slug'
    }
}
