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

    # The fixture repos below must inherit nothing from the developer's own git
    # config: point global config at a file that does not exist and switch
    # system config off. A global commit.gpgsign or tag.gpgsign whose signing
    # key arrives from a conditional include is the case that broke them, since
    # the fixture path never matches the include and git then refuses to commit
    # or tag at all. Child pwsh processes started by these tests inherit the
    # setting too.
    $script:PriorConfigGlobal = $env:GIT_CONFIG_GLOBAL
    $script:PriorConfigNoSystem = $env:GIT_CONFIG_NOSYSTEM
    $env:GIT_CONFIG_GLOBAL = Join-Path -Path $script:ScratchDir -ChildPath 'no-global.gitconfig'
    $env:GIT_CONFIG_NOSYSTEM = '1'

    # Dot-source with -NoVersion (harmless, satisfies the mandatory parameter
    # sets): the guard returns before it is used.
    . $script:Sut -NoVersion
}

AfterAll {
    $env:GIT_CONFIG_GLOBAL = $script:PriorConfigGlobal
    $env:GIT_CONFIG_NOSYSTEM = $script:PriorConfigNoSystem
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
            $Result = Get-SyncStatus -Local 'main' -Remote 'origin/main' 6>$null
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
            $Result = Get-SyncStatus -Local 'main' -Remote 'origin/does-not-exist' 6>$null
            $Result | Should -BeNullOrEmpty
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
            { Get-SyncStatus -Local 'side' -Remote 'origin/diverged' 6>$null } | Should -Not -Throw
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
        $OutFile = Join-Path -Path $script:FixtureRoot -ChildPath 'child-out.txt'
        $ErrFile = Join-Path -Path $script:FixtureRoot -ChildPath 'child-err.txt'
        $Params = @{
            FilePath               = 'pwsh'
            ArgumentList           = @(
                '-NoProfile', '-NonInteractive', '-File', $script:Sut,
                '-Bump', 'patch', '-Yes'
            )
            WorkingDirectory       = $script:RepoPath
            NoNewWindow            = $true
            Wait                   = $true
            PassThru               = $true
            RedirectStandardOutput = $OutFile
            RedirectStandardError  = $ErrFile
        }
        $Proc = Start-Process @Params
        $StdErr = Get-Content -LiteralPath $ErrFile -Raw
        $Proc.ExitCode | Should -Be 0 -Because "the child wrote: $StdErr"

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
        $OutFile = Join-Path -Path $script:FixtureRoot -ChildPath 'child-out.txt'
        $ErrFile = Join-Path -Path $script:FixtureRoot -ChildPath 'child-err.txt'
        $Params = @{
            FilePath               = 'pwsh'
            ArgumentList           = @(
                '-NoProfile', '-NonInteractive', '-File', $script:Sut,
                '-NoManifest', '-Version', '1.2.0', '-Yes'
            )
            WorkingDirectory       = $script:RepoPath
            NoNewWindow            = $true
            Wait                   = $true
            PassThru               = $true
            RedirectStandardOutput = $OutFile
            RedirectStandardError  = $ErrFile
        }
        $Proc = Start-Process @Params
        $StdErr = Get-Content -LiteralPath $ErrFile -Raw
        $Proc.ExitCode | Should -Be 0 -Because "the child wrote: $StdErr"

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
        $OutFile = Join-Path -Path $script:FixtureRoot -ChildPath 'child-out.txt'
        $ErrFile = Join-Path -Path $script:FixtureRoot -ChildPath 'child-err.txt'
        $Params = @{
            FilePath               = 'pwsh'
            ArgumentList           = @(
                '-NoProfile', '-NonInteractive', '-File', $script:Sut,
                '-NoVersion', '-Yes'
            )
            WorkingDirectory       = $script:RepoPath
            NoNewWindow            = $true
            Wait                   = $true
            PassThru               = $true
            RedirectStandardOutput = $OutFile
            RedirectStandardError  = $ErrFile
        }
        $Proc = Start-Process @Params
        $Proc.ExitCode | Should -Not -Be 0

        # Assert on the guard's own message, so an unrelated failure that also
        # exits nonzero cannot masquerade as the duplicate-tag refusal.
        $StdErr = Get-Content -LiteralPath $ErrFile -Raw
        $StdErr | Should -Match "Tag 'v1\.0\.0' already exists"

        # The guard fires before 'switch to main', so the repo is untouched:
        # still on feature, main still at its initial commit (feature unmerged).
        $Branch = & git -C $script:RepoPath rev-parse --abbrev-ref HEAD
        $Branch | Should -Be 'feature'
        $MainLog = & git -C $script:RepoPath log main --oneline -1
        $MainLog | Should -Match 'Initial commit'
    }
}

Describe 'Test-TreeDirty' -Tag 'integration', 'functional' {
    BeforeAll {
        $RepoParams = @{
            Path      = $script:ScratchDir
            ChildPath = "dirty-$([guid]::NewGuid().ToString('N'))"
        }
        $script:DirtyRepo = Join-Path @RepoParams
        $script:DirtyFile = Join-Path -Path $script:DirtyRepo -ChildPath 'artifact.txt'
        New-Item -ItemType Directory -Path $script:DirtyRepo -Force | Out-Null
        Push-Location -LiteralPath $script:DirtyRepo
        try {
            & git init --initial-branch=main . *> $null
            & git config user.email 'test@example.invalid'
            & git config user.name 'Test'
            Set-Content -LiteralPath $script:DirtyFile -Value 'built'
            & git add -A
            & git commit -m 'first' *> $null
        }
        finally {
            Pop-Location
        }
    }

    AfterAll {
        Remove-Item -LiteralPath $script:DirtyRepo -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'treats a tracked file regenerated with the same content as clean' -Tag 'regression' {
        Push-Location -LiteralPath $script:DirtyRepo
        try {
            # Delete and regenerate the file as a root build does, then backdate
            # it so its stat data differs from the index for certain, rather
            # than only when the rewrite lands in a later second.
            Remove-Item -LiteralPath $script:DirtyFile
            Set-Content -LiteralPath $script:DirtyFile -Value 'built'
            (Get-Item -LiteralPath $script:DirtyFile).LastWriteTime = (Get-Date).AddHours(-1)
            Test-TreeDirty | Should -BeFalse
        }
        finally {
            Pop-Location
        }
    }

    It 'reports a tracked file with changed content as dirty' {
        Push-Location -LiteralPath $script:DirtyRepo
        try {
            Set-Content -LiteralPath $script:DirtyFile -Value 'rebuilt'
            Test-TreeDirty | Should -BeTrue
        }
        finally {
            Pop-Location
        }
    }
}

Describe 'Find-TagHook' -Tag 'unit', 'functional' {
    BeforeAll {
        $RootParams = @{
            Path      = $script:ScratchDir
            ChildPath = "findhook-$([guid]::NewGuid().ToString('N'))"
        }
        $script:HookRepo = Join-Path @RootParams
        $BuildDir = Join-Path -Path $script:HookRepo -ChildPath 'Build'
        New-Item -ItemType Directory -Path $BuildDir -Force | Out-Null
        $script:PreTagPath = Join-Path -Path $BuildDir -ChildPath 'PreTag.ps1'
        Set-Content -LiteralPath $script:PreTagPath -Value '# hook'
    }

    It 'returns the path of a hook in the Build folder' {
        Find-TagHook -RepoRoot $script:HookRepo -Name 'PreTag' | Should -Be $script:PreTagPath
    }

    It 'returns nothing when the repo does not have the hook' {
        Find-TagHook -RepoRoot $script:HookRepo -Name 'PostTag' | Should -BeNullOrEmpty
    }
}

Describe 'Invoke-TagHook' -Tag 'unit', 'functional' {
    BeforeAll {
        function Write-HookScript {
            param([string[]]$Body)
            $HookParams = @{
                Path      = $script:ScratchDir
                ChildPath = "hook-$([guid]::NewGuid().ToString('N')).ps1"
            }
            $HookPath = Join-Path @HookParams
            Set-Content -LiteralPath $HookPath -Value $Body
            return $HookPath
        }
    }

    AfterEach {
        $global:LASTEXITCODE = 0
    }

    It 'passes the version to the hook' {
        $Hook = Write-HookScript -Body @('param([string]$Version)', 'Write-Output "got $Version"')
        Invoke-TagHook -Path $Hook -Version '1.2.3' 6>$null | Should -Be 'got 1.2.3'
    }

    It 'throws naming the exit code when the hook exits non-zero' {
        $Hook = Write-HookScript -Body @('param([string]$Version)', 'exit 3')
        { Invoke-TagHook -Path $Hook -Version '1.2.3' 6>$null } |
            Should -Throw '*exited with code 3*'
    }

    It 'lets an exception thrown by the hook through' {
        $Hook = Write-HookScript -Body @('param([string]$Version)', "throw 'hook broke'")
        { Invoke-TagHook -Path $Hook -Version '1.2.3' 6>$null } | Should -Throw '*hook broke*'
    }

    It 'ignores an exit code left over from an earlier command' {
        $Hook = Write-HookScript -Body @('param([string]$Version)')
        $global:LASTEXITCODE = 9
        { Invoke-TagHook -Path $Hook -Version '1.2.3' 6>$null } | Should -Not -Throw
    }
}

Describe 'Push-NewTagToMain hooks' -Tag 'integration', 'functional' {
    BeforeAll {
        # A hook that records what the repo looks like when it runs, in a file
        # outside the repo so the release's clean-tree handling never sees it.
        $script:RecordingHook = @(
            'param([string]$Version)'
            '$Record = @{'
            '    Version      = $Version'
            '    Branch       = git branch --show-current'
            '    Head         = git rev-parse HEAD'
            '    LocalTag     = git tag --list "v$Version"'
            '    RemoteTag    = git ls-remote --tags origin "v$Version"'
            '    RemoteSource = (git ls-remote origin refs/heads/feature) -replace "\s.*", ""'
            '    MergedToMain = git branch --merged main --list feature'
            '}'
            '$Name = [System.IO.Path]::GetFileNameWithoutExtension($PSCommandPath)'
            '$OutPath = Join-Path -Path $PSScriptRoot -ChildPath "..\..\$Name.json"'
            '$Record | ConvertTo-Json | Set-Content -LiteralPath $OutPath'
        )

        # Builds a throwaway repo with a local bare repo as origin, and the given
        # hooks committed to its 'feature' branch. Returns the repo's path.
        function Initialize-HookFixture {
            param([string[]]$PreTag, [string[]]$PostTag)
            $FixtureParams = @{
                Path      = $script:ScratchDir
                ChildPath = "pntm-hooks-$([guid]::NewGuid().ToString('N'))"
            }
            $Root = Join-Path @FixtureParams
            $Origin = Join-Path -Path $Root -ChildPath 'origin.git'
            $Repo = Join-Path -Path $Root -ChildPath 'repo'
            New-Item -ItemType Directory -Path $Root -Force | Out-Null

            & git init --bare --initial-branch=main $Origin *> $null
            & git clone $Origin $Repo *> $null

            Push-Location -LiteralPath $Repo
            try {
                & git config user.email 'test@example.invalid'
                & git config user.name 'Test'
                $ManifestDir = Join-Path -Path $Repo -ChildPath 'Source'
                New-Item -ItemType Directory -Path $ManifestDir -Force | Out-Null
                $ManifestPath = Join-Path -Path $ManifestDir -ChildPath 'Fixture.psd1'
                $ManifestContent = @('@{', "    ModuleVersion = '1.0.0'", '}')
                Set-Content -LiteralPath $ManifestPath -Value $ManifestContent
                & git add -A
                & git commit -m 'Initial commit' *> $null
                & git push origin main *> $null
                & git checkout -b feature *> $null

                $BuildDir = Join-Path -Path $Repo -ChildPath 'Build'
                New-Item -ItemType Directory -Path $BuildDir -Force | Out-Null
                if ($PreTag) {
                    $PreTagPath = Join-Path -Path $BuildDir -ChildPath 'PreTag.ps1'
                    Set-Content -LiteralPath $PreTagPath -Value $PreTag
                }
                if ($PostTag) {
                    $PostTagPath = Join-Path -Path $BuildDir -ChildPath 'PostTag.ps1'
                    Set-Content -LiteralPath $PostTagPath -Value $PostTag
                }
                $XPath = Join-Path -Path $Repo -ChildPath 'x.txt'
                Set-Content -LiteralPath $XPath -Value 'x'
                & git add -A
                & git commit -m 'work' *> $null
                & git push -u origin feature *> $null
            }
            finally {
                Pop-Location
            }
            return $Repo
        }

        # Runs a patch release of the fixture repo in a child pwsh.
        function Invoke-HookRelease {
            param([Parameter(Mandatory)][string]$RepoPath)
            $Root = Split-Path -Path $RepoPath -Parent
            $OutFile = Join-Path -Path $Root -ChildPath 'child-out.txt'
            $ErrFile = Join-Path -Path $Root -ChildPath 'child-err.txt'
            $Params = @{
                FilePath               = 'pwsh'
                ArgumentList           = @(
                    '-NoProfile', '-NonInteractive', '-File', $script:Sut,
                    '-Bump', 'patch', '-Yes'
                )
                WorkingDirectory       = $RepoPath
                NoNewWindow            = $true
                Wait                   = $true
                PassThru               = $true
                RedirectStandardOutput = $OutFile
                RedirectStandardError  = $ErrFile
            }
            $Proc = Start-Process @Params
            return [pscustomobject]@{
                ExitCode = $Proc.ExitCode
                StdOut   = Get-Content -LiteralPath $OutFile -Raw
                StdErr   = Get-Content -LiteralPath $ErrFile -Raw
            }
        }

        function Read-HookRecord {
            param(
                [Parameter(Mandatory)][string]$RepoPath,
                [Parameter(Mandatory)][string]$Name
            )
            $Root = Split-Path -Path $RepoPath -Parent
            $RecordPath = Join-Path -Path $Root -ChildPath "$Name.json"
            return Get-Content -LiteralPath $RecordPath -Raw | ConvertFrom-Json
        }
    }

    It 'runs PreTag before the merge and PostTag after every push, with the new version' {
        $HookParams = @{
            PreTag  = $script:RecordingHook
            PostTag = $script:RecordingHook
        }
        $Repo = Initialize-HookFixture @HookParams
        $Result = Invoke-HookRelease -RepoPath $Repo
        $Result.ExitCode | Should -Be 0 -Because "the child wrote: $($Result.StdErr)"

        $Pre = Read-HookRecord -RepoPath $Repo -Name 'PreTag'
        $Pre.Version | Should -Be '1.0.1'
        $Pre.Branch | Should -Be 'feature'
        $Pre.LocalTag | Should -BeNullOrEmpty
        $Pre.MergedToMain | Should -BeNullOrEmpty

        # The source branch has fast-forwarded to the tag, so a hook that builds
        # from its checkout builds exactly what was released.
        $TagCommit = & git -C $Repo rev-parse 'v1.0.1^{commit}'
        $Post = Read-HookRecord -RepoPath $Repo -Name 'PostTag'
        $Post.Version | Should -Be '1.0.1'
        $Post.Branch | Should -Be 'feature'
        $Post.RemoteTag | Should -Not -BeNullOrEmpty
        $Post.Head | Should -Be $TagCommit
        $Post.RemoteSource | Should -Be $TagCommit
    }

    It 'runs no hook step in a repo without hooks' {
        $Repo = Initialize-HookFixture
        $Result = Invoke-HookRelease -RepoPath $Repo
        $Result.ExitCode | Should -Be 0 -Because "the child wrote: $($Result.StdErr)"
        $Result.StdOut | Should -Not -Match 'Step: (PreTag|PostTag) hook'
    }

    It 'stops the release with nothing merged or tagged when PreTag <Kind>' -ForEach @(
        @{ Kind = 'throws'; Line = "throw 'pretag broke'"; Message = 'pretag broke' }
        @{ Kind = 'exits non-zero'; Line = 'exit 3'; Message = 'exited with code 3' }
    ) {
        $Repo = Initialize-HookFixture -PreTag @('param([string]$Version)', $Line)
        $Result = Invoke-HookRelease -RepoPath $Repo
        $Result.ExitCode | Should -Not -Be 0
        $Result.StdErr | Should -Match $Message

        & git -C $Repo rev-parse --abbrev-ref HEAD | Should -Be 'feature'
        & git -C $Repo log main --oneline -1 | Should -Match 'Initial commit'
        & git -C $Repo tag --list 'v1.0.1' | Should -BeNullOrEmpty
    }

    It 'reports a failed PostTag with the release already pushed' {
        $Repo = Initialize-HookFixture -PostTag @('param([string]$Version)', 'exit 3')
        $Result = Invoke-HookRelease -RepoPath $Repo
        $Result.ExitCode | Should -Not -Be 0
        $Result.StdErr | Should -Match 'exited with code 3'

        & git -C $Repo ls-remote --tags origin 'v1.0.1' | Should -Not -BeNullOrEmpty
        & git -C $Repo rev-parse --abbrev-ref HEAD | Should -Be 'feature'
    }
}

Describe 'Push-NewTagToMain unchanged build' -Tag 'integration', 'functional', 'regression' {
    BeforeAll {
        $FixtureParams = @{
            Path      = $script:ScratchDir
            ChildPath = "pntm-samebuild-$([guid]::NewGuid().ToString('N'))"
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
            # A committed build artifact, and a Build.ps1 that deletes and
            # regenerates it with the same content, backdated so its stat data
            # is guaranteed to differ from the index.
            $ArtifactPath = Join-Path -Path $script:RepoPath -ChildPath 'artifact.txt'
            Set-Content -LiteralPath $ArtifactPath -Value 'built'
            $BuildLines = @(
                '$Artifact = Join-Path -Path $PSScriptRoot -ChildPath ''artifact.txt'''
                'Remove-Item -LiteralPath $Artifact'
                'Set-Content -LiteralPath $Artifact -Value ''built'''
                '(Get-Item -LiteralPath $Artifact).LastWriteTime = (Get-Date).AddHours(-1)'
            )
            $BuildPath = Join-Path -Path $script:RepoPath -ChildPath 'Build.ps1'
            Set-Content -LiteralPath $BuildPath -Value $BuildLines
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

    It 'skips the release commit and still tags when the build changes nothing' {
        # -Version names the current version, so only the build could dirty the
        # tree -- and it regenerates the artifact unchanged.
        $OutFile = Join-Path -Path $script:FixtureRoot -ChildPath 'child-out.txt'
        $ErrFile = Join-Path -Path $script:FixtureRoot -ChildPath 'child-err.txt'
        $Params = @{
            FilePath               = 'pwsh'
            ArgumentList           = @(
                '-NoProfile', '-NonInteractive', '-File', $script:Sut,
                '-Version', '1.0.0', '-Yes'
            )
            WorkingDirectory       = $script:RepoPath
            NoNewWindow            = $true
            Wait                   = $true
            PassThru               = $true
            RedirectStandardOutput = $OutFile
            RedirectStandardError  = $ErrFile
        }
        $Proc = Start-Process @Params
        $StdErr = Get-Content -LiteralPath $ErrFile -Raw
        $Proc.ExitCode | Should -Be 0 -Because "the child wrote: $StdErr"

        $StdOut = Get-Content -LiteralPath $OutFile -Raw
        $StdOut | Should -Match 'Nothing to commit; skipping'
        $Tags = & git -C $script:RepoPath tag --list 'v1.0.0'
        $Tags | Should -Not -BeNullOrEmpty
        $MainLog = & git -C $script:RepoPath log main --oneline -1
        $MainLog | Should -Match 'work'
        $MainLog | Should -Not -Match 'Release'
    }
}
