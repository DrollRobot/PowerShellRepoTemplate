<#
.SYNOPSIS
    Pester tests for Scripts\TemplateSetup\Remove-WriteLog.ps1.

.DESCRIPTION
    Remove-WriteLog takes an explicit -RepoRoot, so its apply path is safe to
    exercise for real against a throwaway scratch tree that mimics the
    template's Source\ and Tests\Pester\ layout. Nothing here ever points it at
    this repository, with one read-only exception: one test copies the real
    Source\Suffix.ps1 into the scratch tree, so the block-matching pattern is
    proven against the file exactly as the template ships it.

    The script guards its parameter-driven body with
    `if ($MyInvocation.InvocationName -eq '.') { return }`, so dot-sourcing it
    reaches the Remove-WriteLog and Get-WriteLogTarget functions (and the shared
    helpers it dot-sources) without running the standalone entrypoint.

    The function reports progress via Write-Host; Pester does not capture
    stream 6, so every call redirects it to keep the run output clean.
#>

BeforeAll {
    $SutParams = @{
        Path      = $PSScriptRoot
        ChildPath = '..\..\Scripts\TemplateSetup\Remove-WriteLog.ps1'
    }
    $script:Sut = (Resolve-Path (Join-Path @SutParams)).Path
    . $script:Sut

    $SuffixParams = @{ Path = $PSScriptRoot; ChildPath = '..\..\Source\Suffix.ps1' }
    $script:RealSuffix = (Resolve-Path (Join-Path @SuffixParams)).Path

    # A Suffix.ps1 in the template's shape: a note line, the shipped logging
    # block, then unrelated module init that must survive the edit untouched.
    $script:SuffixBefore = "# ModuleBuilder Notes: appended to the built .psm1.`n`n"
    $script:SuffixBlock = @'
# Configure internal logging first: Set-LogConfig owns the logging defaults and
# must run before anything in this module logs (there is no lazy fallback).
# Every value below restates a default.
$logConfigParams = @{
    MemoryMaxEntries     = 1000
    EventLogSource       = 'ScratchModule'
    EventLogId           = 1000
    EventLogMinimumLevel = 'Information'
}
Set-LogConfig @logConfigParams

'@
    $script:SuffixAfter = "# Other init.`n`$other = 1`nNew-Variable -Name Other -Value `$other`n"

    $script:LibFiles = @(
        'Get-LogConfig.ps1'
        'Get-LogMessage.ps1'
        'Register-LogEventSource.ps1'
        'Set-LogConfig.ps1'
        'Write-Log.ps1'
        'Write-LogEvent.ps1'
        'Write-LogEventBuffer.ps1'
    )
    $script:TestFiles = @(
        'Get-LogConfig.Tests.ps1'
        'Get-LogMessage.Tests.ps1'
        'Set-LogConfig.Tests.ps1'
        'Write-Log.Tests.ps1'
        'Write-LogEventBuffer.Tests.ps1'
    )

    # Build one scratch repo: the library, a sibling Lib\ helper and an
    # unrelated test that must both survive, and a Suffix.ps1 from the pieces.
    function script:New-ScratchRepo {
        param([string]$SuffixText)
        $ScratchParams = @{
            Path      = [System.IO.Path]::GetTempPath()
            ChildPath = "rmwl-$([guid]::NewGuid().ToString('N'))"
        }
        $Root = Join-Path @ScratchParams
        $LibDir = Join-Path -Path $Root -ChildPath 'Source\Private\Lib\Write-log'
        $PesterDir = Join-Path -Path $Root -ChildPath 'Tests\Pester'
        New-Item -ItemType Directory -Path $LibDir -Force | Out-Null
        New-Item -ItemType Directory -Path $PesterDir -Force | Out-Null
        foreach ($Leaf in $script:LibFiles) {
            $Path = Join-Path -Path $LibDir -ChildPath $Leaf
            Set-Content -LiteralPath $Path -Value '# lib' -NoNewline
        }
        foreach ($Leaf in $script:TestFiles) {
            $Path = Join-Path -Path $PesterDir -ChildPath $Leaf
            Set-Content -LiteralPath $Path -Value '# test' -NoNewline
        }
        $Resolver = Join-Path -Path $Root -ChildPath 'Source\Private\Lib\Resolve-EnvParameter.ps1'
        Set-Content -LiteralPath $Resolver -Value '# resolver' -NoNewline
        $OtherTest = Join-Path -Path $PesterDir -ChildPath 'Get-Greeting.Tests.ps1'
        Set-Content -LiteralPath $OtherTest -Value '# other test' -NoNewline
        if ($null -ne $SuffixText) {
            $Suffix = Join-Path -Path $Root -ChildPath 'Source\Suffix.ps1'
            Set-Content -LiteralPath $Suffix -Value $SuffixText -NoNewline
        }
        return $Root
    }
}

AfterAll {
    Remove-Item -Path function:script:New-ScratchRepo -ErrorAction SilentlyContinue
}

Describe 'Remove-WriteLog' -Tag 'unit', 'functional' {
    BeforeEach {
        $Text = $script:SuffixBefore + $script:SuffixBlock + $script:SuffixAfter
        $script:Scratch = New-ScratchRepo -SuffixText $Text
        $LibParams = @{ Path = $script:Scratch; ChildPath = 'Source\Private\Lib\Write-log' }
        $script:ScratchLibDir = Join-Path @LibParams
        $script:ScratchSuffix = Join-Path -Path $script:Scratch -ChildPath 'Source\Suffix.ps1'
        $script:ScratchPesterDir = Join-Path -Path $script:Scratch -ChildPath 'Tests\Pester'
    }

    AfterEach {
        Remove-Item -LiteralPath $script:Scratch -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'deletes the library folder and the tests that cover it' {
        $Applied = Remove-WriteLog -RepoRoot $script:Scratch -DryRun $false 6>$null
        $Applied | Should -BeTrue

        Test-Path -LiteralPath $script:ScratchLibDir | Should -BeFalse
        foreach ($Leaf in $script:TestFiles) {
            $Path = Join-Path -Path $script:ScratchPesterDir -ChildPath $Leaf
            Test-Path -LiteralPath $Path | Should -BeFalse -Because "$Leaf should be gone"
        }
    }

    It 'leaves the sibling Lib helper and unrelated tests alone' {
        $Applied = Remove-WriteLog -RepoRoot $script:Scratch -DryRun $false 6>$null
        $Applied | Should -BeTrue

        $ResolverParams = @{
            Path      = $script:Scratch
            ChildPath = 'Source\Private\Lib\Resolve-EnvParameter.ps1'
        }
        $Resolver = Join-Path @ResolverParams
        Test-Path -LiteralPath $Resolver | Should -BeTrue
        $OtherTest = Join-Path -Path $script:ScratchPesterDir -ChildPath 'Get-Greeting.Tests.ps1'
        Test-Path -LiteralPath $OtherTest | Should -BeTrue
    }

    It 'drops the Set-LogConfig block from Suffix.ps1 and keeps everything around it' {
        $Applied = Remove-WriteLog -RepoRoot $script:Scratch -DryRun $false 6>$null
        $Applied | Should -BeTrue

        $Suffix = Get-Content -LiteralPath $script:ScratchSuffix -Raw
        $Suffix | Should -Not -Match 'Set-LogConfig'
        $Suffix | Should -Not -Match 'logConfigParams'
        $Suffix | Should -Be ($script:SuffixBefore + $script:SuffixAfter)
    }

    It 'recognizes the block exactly as the template ships it in Source\Suffix.ps1' {
        # The real file, so a drift between Suffix.ps1 and the pattern fails here.
        Copy-Item -LiteralPath $script:RealSuffix -Destination $script:ScratchSuffix -Force
        $Applied = Remove-WriteLog -RepoRoot $script:Scratch -DryRun $false 6>$null
        $Applied | Should -BeTrue

        $Suffix = Get-Content -LiteralPath $script:ScratchSuffix -Raw
        $Suffix | Should -Not -Match '(?m)^[ \t]*Set-LogConfig\b'
        $Suffix | Should -Not -Match 'logConfigParams'
        # The rest of the shipped file (the ModuleBuilder note) survives.
        $Suffix | Should -Match 'ModuleBuilder Notes'
    }

    It 'writes nothing under -DryRun' {
        $Applied = Remove-WriteLog -RepoRoot $script:Scratch -DryRun $true 6>$null
        $Applied | Should -BeTrue

        Test-Path -LiteralPath $script:ScratchLibDir | Should -BeTrue
        foreach ($Leaf in $script:TestFiles) {
            $Path = Join-Path -Path $script:ScratchPesterDir -ChildPath $Leaf
            Test-Path -LiteralPath $Path | Should -BeTrue -Because "$Leaf should survive a dry run"
        }
        (Get-Content -LiteralPath $script:ScratchSuffix -Raw) | Should -Match 'Set-LogConfig'
    }

    It 'is idempotent: a second run finds nothing and still succeeds' {
        $First = Remove-WriteLog -RepoRoot $script:Scratch -DryRun $false 6>$null
        $First | Should -BeTrue
        $SuffixAfterFirst = Get-Content -LiteralPath $script:ScratchSuffix -Raw

        $Second = Remove-WriteLog -RepoRoot $script:Scratch -DryRun $false 6>$null
        $Second | Should -BeTrue
        (Get-Content -LiteralPath $script:ScratchSuffix -Raw) | Should -Be $SuffixAfterFirst
    }

    It 'reports a problem when Suffix.ps1 still calls Set-LogConfig afterward' {
        $Stray = "Set-LogConfig -HostEnabled `$false`n"
        $Text = $script:SuffixBefore + $script:SuffixBlock + $script:SuffixAfter + $Stray
        Set-Content -LiteralPath $script:ScratchSuffix -Value $Text -NoNewline

        $Applied = Remove-WriteLog -RepoRoot $script:Scratch -DryRun $false 6>$null
        $Applied | Should -BeFalse

        # The library and the shipped block still went; only the stray call remains.
        Test-Path -LiteralPath $script:ScratchLibDir | Should -BeFalse
        $Suffix = Get-Content -LiteralPath $script:ScratchSuffix -Raw
        $Suffix | Should -Not -Match 'logConfigParams'
        $Suffix | Should -Match '(?m)^Set-LogConfig -HostEnabled'
    }

    It 'succeeds when Suffix.ps1 is absent' {
        Remove-Item -LiteralPath $script:ScratchSuffix -Force
        $Applied = Remove-WriteLog -RepoRoot $script:Scratch -DryRun $false 6>$null
        $Applied | Should -BeTrue
        Test-Path -LiteralPath $script:ScratchLibDir | Should -BeFalse
    }

    It 'leaves a Suffix.ps1 with no logging block untouched' {
        $Text = $script:SuffixBefore + $script:SuffixAfter
        Set-Content -LiteralPath $script:ScratchSuffix -Value $Text -NoNewline
        $Applied = Remove-WriteLog -RepoRoot $script:Scratch -DryRun $false 6>$null
        $Applied | Should -BeTrue
        (Get-Content -LiteralPath $script:ScratchSuffix -Raw) | Should -Be $Text
    }
}

Describe 'Get-WriteLogTarget' -Tag 'unit', 'functional' {
    BeforeEach {
        $script:Scratch = New-ScratchRepo -SuffixText $null
    }

    AfterEach {
        Remove-Item -LiteralPath $script:Scratch -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'lists the library folder first, then every test file that exists' {
        $Targets = @(Get-WriteLogTarget -RepoRoot $script:Scratch)

        $Targets | Should -HaveCount 6
        $Targets[0] | Should -Be 'Source\Private\Lib\Write-log'
        foreach ($Leaf in $script:TestFiles) {
            $Targets | Should -Contain "Tests\Pester\$Leaf"
        }
    }

    It 'skips a test file that is already gone' {
        $Gone = Join-Path -Path $script:Scratch -ChildPath 'Tests\Pester\Write-Log.Tests.ps1'
        Remove-Item -LiteralPath $Gone -Force

        $Targets = @(Get-WriteLogTarget -RepoRoot $script:Scratch)

        $Targets | Should -HaveCount 5
        $Targets | Should -Not -Contain 'Tests\Pester\Write-Log.Tests.ps1'
    }

    It 'returns nothing once the library and its tests are gone' {
        $LibDir = Join-Path -Path $script:Scratch -ChildPath 'Source\Private\Lib\Write-log'
        Remove-Item -LiteralPath $LibDir -Recurse -Force
        foreach ($Leaf in $script:TestFiles) {
            $Path = Join-Path -Path $script:Scratch -ChildPath "Tests\Pester\$Leaf"
            Remove-Item -LiteralPath $Path -Force
        }

        $Targets = @(Get-WriteLogTarget -RepoRoot $script:Scratch)

        $Targets | Should -HaveCount 0
    }
}
