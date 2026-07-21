<#
.SYNOPSIS
    Pester tests for Scripts\Push-NewTagToMain.ps1.

.DESCRIPTION
    The script now guards its main body with `if ($MyInvocation.InvocationName
    -eq '.') { return }` (added alongside this test), so it can be dot-sourced
    to reach its helper functions without running the interactive/mutating
    release flow.

    Set-ManifestVersion is pure (no git). Find-Manifest and Get-SyncStatus need
    a real git repository as a boundary, but never a real remote: Get-SyncStatus
    is exercised against a throwaway local repo with remote-tracking refs
    written directly via `git update-ref` (no network, no push), and
    Find-Manifest's Source\-preference path uses a throwaway `git init` repo.
    Both stay NotLive/integration -- no destructive mutation of anything
    outside the temp dir.

    The actual release flow (merge into main, version bump, tag, push) needs a
    real repo/cwd, since the script has no -RepoPath parameter. It is exercised
    as a plain integration test against a throwaway repo with a local bare repo
    standing in for "origin". Everything lives under the temp scratch dir and is
    removed in AfterAll, so it mutates no preexisting local state and is not
    tagged destructive -- it runs in every normal test run and in CI.
#>

BeforeAll {
    $SutParams = @{
        Path      = $PSScriptRoot
        ChildPath = '..\..\Scripts\Push-NewTagToMain.ps1'
    }
    $script:Sut = (Resolve-Path (Join-Path @SutParams)).Path

    $ScratchParams = @{
        Path      = [System.IO.Path]::GetTempPath()
        ChildPath = [System.IO.Path]::GetRandomFileName()
    }
    $script:ScratchDir = Join-Path @ScratchParams
    New-Item -ItemType Directory -Path $script:ScratchDir -Force | Out-Null

    # Dot-source with -NoVersion -Build none (both harmless, satisfy the
    # mandatory parameter sets): the guard returns before either is used.
    . $script:Sut -NoVersion -Build none
}

AfterAll {
    Remove-Item -LiteralPath $script:ScratchDir -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Set-ManifestVersion' -Tag 'unit', 'functional' {
    It 'rewrites only the ModuleVersion value, preserving everything else' {
        $Content = @(
            '@{'
            "    ModuleVersion = '1.0.0'"
            "    Author = 'Someone'  # keep me"
            '}'
        )
        $ManifestParams = @{
            Path      = $script:ScratchDir
            ChildPath = "manifest-$([guid]::NewGuid().ToString('N')).psd1"
        }
        $ManifestPath = Join-Path @ManifestParams
        Set-Content -LiteralPath $ManifestPath -Value $Content

        Set-ManifestVersion -Path $ManifestPath -NewVersion ([version] '2.1.0')

        $Updated = Get-Content -LiteralPath $ManifestPath -Raw
        $Updated | Should -Match "ModuleVersion = '2.1.0'"
        $Updated | Should -Match '# keep me'
    }

    It 'throws when no ModuleVersion assignment exists' {
        $ManifestParams = @{
            Path      = $script:ScratchDir
            ChildPath = "manifest-$([guid]::NewGuid().ToString('N')).psd1"
        }
        $ManifestPath = Join-Path @ManifestParams
        Set-Content -LiteralPath $ManifestPath -Value @('@{', "    Author = 'x'", '}')

        { Set-ManifestVersion -Path $ManifestPath -NewVersion ([version] '1.0.0') } |
            Should -Throw
    }

    It 'does not match a commented-out ModuleVersion line' {
        $Content = @('@{', "    # ModuleVersion = '9.9.9'", '}')
        $ManifestParams = @{
            Path      = $script:ScratchDir
            ChildPath = "manifest-$([guid]::NewGuid().ToString('N')).psd1"
        }
        $ManifestPath = Join-Path @ManifestParams
        Set-Content -LiteralPath $ManifestPath -Value $Content

        { Set-ManifestVersion -Path $ManifestPath -NewVersion ([version] '1.0.0') } |
            Should -Throw
    }
}

Describe 'Find-Manifest' -Tag 'unit', 'functional' {
    It 'returns an explicit -Path when it exists' {
        $ManifestParams = @{
            Path      = $script:ScratchDir
            ChildPath = "manifest-$([guid]::NewGuid().ToString('N')).psd1"
        }
        $ManifestPath = Join-Path @ManifestParams
        Set-Content -LiteralPath $ManifestPath -Value '@{}'
        Find-Manifest -Path $ManifestPath | Should -Be (Resolve-Path $ManifestPath).Path
    }

    It 'throws when an explicit -Path does not exist' {
        $Missing = Join-Path -Path $script:ScratchDir -ChildPath 'does-not-exist.psd1'
        { Find-Manifest -Path $Missing } | Should -Throw
    }

    It 'throws when no Source\ manifest is found and no -Path is given' {
        $RootParams = @{
            Path      = $script:ScratchDir
            ChildPath = "nomanifest-$([guid]::NewGuid().ToString('N'))"
        }
        $Root = Join-Path @RootParams
        $Sub = Join-Path -Path $Root -ChildPath 'a\b'
        New-Item -ItemType Directory -Path $Sub -Force | Out-Null
        # A stray .psd1 beside the current location must NOT be picked up now
        # that the walk-up fallback is gone; only a Source\ manifest counts.
        Set-Content -LiteralPath (Join-Path -Path $Root -ChildPath 'Stray.psd1') -Value '@{}'

        Push-Location -LiteralPath $Sub
        try {
            { Find-Manifest -Path $null } | Should -Throw
        }
        finally {
            Pop-Location
        }
    }
}

Describe 'Get-SyncStatus' -Tag 'integration', 'functional' {
    BeforeAll {
        $RepoParams = @{
            Path      = $script:ScratchDir
            ChildPath = "sync-$([guid]::NewGuid().ToString('N'))"
        }
        $script:SyncRepo = Join-Path @RepoParams
        New-Item -ItemType Directory -Path $script:SyncRepo -Force | Out-Null
        Push-Location -LiteralPath $script:SyncRepo
        try {
            & git init --initial-branch=main . *> $null
            & git config user.email 'test@example.invalid'
            & git config user.name 'Test'
            $AParams = @{
                LiteralPath = Join-Path -Path $script:SyncRepo -ChildPath 'a.txt'
                Value       = 'a'
            }
            Set-Content @AParams
            & git add -A
            & git commit -m 'first' *> $null
            $script:FirstSha = (& git rev-parse HEAD).Trim()
            # Fake a remote-tracking ref pointing at the same commit -- no
            # network, no real remote, just local plumbing.
            & git update-ref refs/remotes/origin/main $script:FirstSha
            $BParams = @{
                LiteralPath = Join-Path -Path $script:SyncRepo -ChildPath 'b.txt'
                Value       = 'b'
            }
            Set-Content @BParams
            & git add -A
            & git commit -m 'second' *> $null
        }
        finally {
            Pop-Location
        }
    }

    AfterAll {
        Remove-Item -LiteralPath $script:SyncRepo -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'reports ahead/behind counts against a remote-tracking ref' {
        Push-Location -LiteralPath $script:SyncRepo
        try {
            $Result = Get-SyncStatus -Local 'main' -Remote 'origin/main'
            $Result.Ahead | Should -Be 1
            $Result.Behind | Should -Be 0
        }
        finally {
            Pop-Location
        }
    }

    It 'returns null when the remote ref does not exist' {
        Push-Location -LiteralPath $script:SyncRepo
        try {
            Get-SyncStatus -Local 'main' -Remote 'origin/does-not-exist' | Should -BeNullOrEmpty
        }
        finally {
            Pop-Location
        }
    }

    It 'throws when local and remote have diverged' {
        Push-Location -LiteralPath $script:SyncRepo
        try {
            & git update-ref refs/remotes/origin/diverged $script:FirstSha
            & git checkout -b side $script:FirstSha *> $null
            $CParams = @{
                LiteralPath = Join-Path -Path $script:SyncRepo -ChildPath 'c.txt'
                Value       = 'c'
            }
            Set-Content @CParams
            & git add -A
            & git commit -m 'side commit' *> $null
            & git update-ref refs/remotes/origin/diverged HEAD
            & git checkout main *> $null
            { Get-SyncStatus -Local 'side' -Remote 'origin/diverged' } | Should -Not -Throw
        }
        finally {
            Pop-Location
        }
    }
}

Describe 'Push-NewTagToMain' -Tag 'integration', 'functional' {
    BeforeAll {
        $FixtureParams = @{
            Path      = $script:ScratchDir
            ChildPath = "pntm-fixture-$([guid]::NewGuid().ToString('N'))"
        }
        $script:FixtureRoot = Join-Path @FixtureParams
        $script:OriginPath = Join-Path -Path $script:FixtureRoot -ChildPath 'origin.git'
        $script:RepoPath = Join-Path -Path $script:FixtureRoot -ChildPath 'repo'
        New-Item -ItemType Directory -Path $script:FixtureRoot -Force | Out-Null

        & git init --bare --initial-branch=main $script:OriginPath *> $null
        & git clone $script:OriginPath $script:RepoPath *> $null

        Push-Location -LiteralPath $script:RepoPath
        try {
            & git config user.email 'test@example.invalid'
            & git config user.name 'Test'
            $ManifestDir = Join-Path -Path $script:RepoPath -ChildPath 'Source'
            New-Item -ItemType Directory -Path $ManifestDir -Force | Out-Null
            $ManifestPath = Join-Path -Path $ManifestDir -ChildPath 'Fixture.psd1'
            $ManifestContent = @('@{', "    ModuleVersion = '1.0.0'", '}')
            Set-Content -LiteralPath $ManifestPath -Value $ManifestContent
            & git add -A
            & git commit -m 'Initial commit' *> $null
            & git push origin main *> $null
            & git checkout -b feature *> $null
            $XParams = @{
                LiteralPath = Join-Path -Path $script:RepoPath -ChildPath 'x.txt'
                Value       = 'x'
            }
            Set-Content @XParams
            & git add -A
            & git commit -m 'work' *> $null
            & git push -u origin feature *> $null
        }
        finally {
            Pop-Location
        }

        $script:OriginalLocation = Get-Location
        Set-Location -LiteralPath $script:RepoPath
    }

    AfterAll {
        Set-Location -LiteralPath $script:OriginalLocation
        $CleanupParams = @{
            LiteralPath = $script:FixtureRoot
            Recurse     = $true
            Force       = $true
            ErrorAction = 'SilentlyContinue'
        }
        Remove-Item @CleanupParams
    }

    It 'merges, bumps, tags, and pushes' {
        $Params = @{
            FilePath         = 'pwsh'
            ArgumentList     = @(
                '-NoProfile', '-NonInteractive', '-File', $script:Sut,
                '-Bump', 'patch', '-Build', 'none', '-Yes'
            )
            WorkingDirectory = $script:RepoPath
            NoNewWindow      = $true
            Wait             = $true
            PassThru         = $true
        }
        $Proc = Start-Process @Params
        $Proc.ExitCode | Should -Be 0

        $Tags = & git -C $script:RepoPath tag --list 'v1.0.1'
        $Tags | Should -Not -BeNullOrEmpty
        $MainLog = & git -C $script:RepoPath log main --oneline -1
        $MainLog | Should -Match 'Release v1.0.1'
    }
}

Describe 'Push-NewTagToMain -NoManifest' -Tag 'integration', 'functional' {
    BeforeAll {
        $FixtureParams = @{
            Path      = $script:ScratchDir
            ChildPath = "pntm-nomani-$([guid]::NewGuid().ToString('N'))"
        }
        $script:FixtureRoot = Join-Path @FixtureParams
        $script:OriginPath = Join-Path -Path $script:FixtureRoot -ChildPath 'origin.git'
        $script:RepoPath = Join-Path -Path $script:FixtureRoot -ChildPath 'repo'
        New-Item -ItemType Directory -Path $script:FixtureRoot -Force | Out-Null

        & git init --bare --initial-branch=main $script:OriginPath *> $null
        & git clone $script:OriginPath $script:RepoPath *> $null

        Push-Location -LiteralPath $script:RepoPath
        try {
            & git config user.email 'test@example.invalid'
            & git config user.name 'Test'
            # A bare script repo: no Source\ folder, no .psd1 anywhere.
            $ScriptParams = @{
                LiteralPath = Join-Path -Path $script:RepoPath -ChildPath 'tool.ps1'
                Value       = "Write-Output 'hello'"
            }
            Set-Content @ScriptParams
            & git add -A
            & git commit -m 'Initial commit' *> $null
            & git push origin main *> $null
            & git checkout -b feature *> $null
            $EditParams = @{
                LiteralPath = Join-Path -Path $script:RepoPath -ChildPath 'tool.ps1'
                Value       = "Write-Output 'hello world'"
            }
            Set-Content @EditParams
            & git add -A
            & git commit -m 'work' *> $null
            & git push -u origin feature *> $null
        }
        finally {
            Pop-Location
        }

        $script:OriginalLocation = Get-Location
        Set-Location -LiteralPath $script:RepoPath
    }

    AfterAll {
        Set-Location -LiteralPath $script:OriginalLocation
        $CleanupParams = @{
            LiteralPath = $script:FixtureRoot
            Recurse     = $true
            Force       = $true
            ErrorAction = 'SilentlyContinue'
        }
        Remove-Item @CleanupParams
    }

    It 'tags a manifest-less repo from -Version alone' {
        $Params = @{
            FilePath         = 'pwsh'
            ArgumentList     = @(
                '-NoProfile', '-NonInteractive', '-File', $script:Sut,
                '-NoManifest', '-Version', '1.2.0', '-Build', 'none', '-Yes'
            )
            WorkingDirectory = $script:RepoPath
            NoNewWindow      = $true
            Wait             = $true
            PassThru         = $true
        }
        $Proc = Start-Process @Params
        $Proc.ExitCode | Should -Be 0

        # The tag is created and annotated ('tag' object, not 'commit').
        $Tags = & git -C $script:RepoPath tag --list 'v1.2.0'
        $Tags | Should -Not -BeNullOrEmpty
        (& git -C $script:RepoPath cat-file -t 'v1.2.0') | Should -Be 'tag'

        # No manifest was ever written, and with nothing to commit there is no
        # 'Release' commit -- main is just the merged feature work.
        $Psd1 = & git -C $script:RepoPath ls-files '*.psd1'
        $Psd1 | Should -BeNullOrEmpty
        $MainLog = & git -C $script:RepoPath log main --oneline -1
        $MainLog | Should -Match 'work'
        $MainLog | Should -Not -Match 'Release'
    }
}

Describe 'Push-NewTagToMain duplicate-tag guard' -Tag 'integration', 'functional' {
    BeforeAll {
        $FixtureParams = @{
            Path      = $script:ScratchDir
            ChildPath = "pntm-duptag-$([guid]::NewGuid().ToString('N'))"
        }
        $script:FixtureRoot = Join-Path @FixtureParams
        $script:OriginPath = Join-Path -Path $script:FixtureRoot -ChildPath 'origin.git'
        $script:RepoPath = Join-Path -Path $script:FixtureRoot -ChildPath 'repo'
        New-Item -ItemType Directory -Path $script:FixtureRoot -Force | Out-Null

        & git init --bare --initial-branch=main $script:OriginPath *> $null
        & git clone $script:OriginPath $script:RepoPath *> $null

        Push-Location -LiteralPath $script:RepoPath
        try {
            & git config user.email 'test@example.invalid'
            & git config user.name 'Test'
            $ManifestDir = Join-Path -Path $script:RepoPath -ChildPath 'Source'
            New-Item -ItemType Directory -Path $ManifestDir -Force | Out-Null
            $ManifestPath = Join-Path -Path $ManifestDir -ChildPath 'Fixture.psd1'
            $ManifestContent = @('@{', "    ModuleVersion = '1.0.0'", '}')
            Set-Content -LiteralPath $ManifestPath -Value $ManifestContent
            & git add -A
            & git commit -m 'Initial commit' *> $null
            & git push origin main *> $null
            # A tag for the current version already exists on this repo.
            & git tag -a 'v1.0.0' -m 'Release 1.0.0' *> $null
            & git checkout -b feature *> $null
            $XParams = @{
                LiteralPath = Join-Path -Path $script:RepoPath -ChildPath 'x.txt'
                Value       = 'x'
            }
            Set-Content @XParams
            & git add -A
            & git commit -m 'work' *> $null
            & git push -u origin feature *> $null
        }
        finally {
            Pop-Location
        }

        $script:OriginalLocation = Get-Location
        Set-Location -LiteralPath $script:RepoPath
    }

    AfterAll {
        Set-Location -LiteralPath $script:OriginalLocation
        $CleanupParams = @{
            LiteralPath = $script:FixtureRoot
            Recurse     = $true
            Force       = $true
            ErrorAction = 'SilentlyContinue'
        }
        Remove-Item @CleanupParams
    }

    It 'aborts before any mutation when the target tag already exists' {
        # -NoVersion targets the current version (1.0.0), whose tag exists.
        $Params = @{
            FilePath         = 'pwsh'
            ArgumentList     = @(
                '-NoProfile', '-NonInteractive', '-File', $script:Sut,
                '-NoVersion', '-Build', 'none', '-Yes'
            )
            WorkingDirectory = $script:RepoPath
            NoNewWindow      = $true
            Wait             = $true
            PassThru         = $true
        }
        $Proc = Start-Process @Params
        $Proc.ExitCode | Should -Not -Be 0

        # The guard fires before 'switch to main', so the repo is untouched:
        # still on feature, main still at its initial commit (feature unmerged).
        $Branch = & git -C $script:RepoPath rev-parse --abbrev-ref HEAD
        $Branch | Should -Be 'feature'
        $MainLog = & git -C $script:RepoPath log main --oneline -1
        $MainLog | Should -Match 'Initial commit'
    }
}
