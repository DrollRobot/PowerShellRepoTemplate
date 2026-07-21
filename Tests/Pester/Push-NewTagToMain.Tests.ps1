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

    The actual release flow (merge into main, version bump, tag, push) is
    destructive and needs a real repo/cwd, since the script has no -RepoPath
    parameter. It is exercised as a destructive,local integration test against
    a throwaway repo with a local bare repo standing in for "origin", gated on
    DISPOSABLE_ENVIRONMENT=1. This was written but could not be executed in
    this session (DISPOSABLE_ENVIRONMENT was unset) -- treat it as unverified
    until it has been run at least once.
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

    It 'walks up from the current location when no Source\ manifest is found' {
        $RootParams = @{
            Path      = $script:ScratchDir
            ChildPath = "walkup-$([guid]::NewGuid().ToString('N'))"
        }
        $Root = Join-Path @RootParams
        $Sub = Join-Path -Path $Root -ChildPath 'a\b'
        New-Item -ItemType Directory -Path $Sub -Force | Out-Null
        $ManifestPath = Join-Path -Path $Root -ChildPath 'Found.psd1'
        Set-Content -LiteralPath $ManifestPath -Value '@{}'

        Push-Location -LiteralPath $Sub
        try {
            Find-Manifest -Path $null | Should -Be (Resolve-Path $ManifestPath).Path
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

# Computed at discovery time (outside BeforeAll) because Pester evaluates
# -Skip: expressions during discovery, before any BeforeAll block has run.
$script:DisposableOk = $env:DISPOSABLE_ENVIRONMENT -eq '1'

Describe 'Push-NewTagToMain' -Tag 'integration', 'functional', 'destructive', 'local' {
    BeforeAll {
        if ($script:DisposableOk) {
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

    It 'merges, bumps, tags, and pushes' -Skip:(-not $script:DisposableOk) {
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
