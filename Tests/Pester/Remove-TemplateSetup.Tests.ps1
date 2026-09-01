<#
.SYNOPSIS
    Pester tests for Scripts\TemplateSetup\Remove-TemplateSetup.ps1.

.DESCRIPTION
    Remove-TemplateSetup takes an explicit -RepoRoot, so -- unlike the
    orchestrator -- its apply path is safe to exercise for real against a
    throwaway scratch tree that mimics the template's Scripts\TemplateSetup\
    and Tests\Pester\ layout. Nothing here ever points it at this repository.

    The script guards its parameter-driven body with
    `if ($MyInvocation.InvocationName -eq '.') { return }`, so dot-sourcing it
    reaches the Remove-TemplateSetup and Get-TemplateSetupTarget functions (and
    the shared helpers it dot-sources) without running the standalone
    entrypoint. Every apply-path call passes -AssumeYes so no test blocks on
    Read-Host; the declined path is covered by mocking Confirm-Step, which the
    dot-sourced _Common.ps1 defines in this same scope.

    The function reports progress via Write-Host; Pester does not capture
    stream 6, so every call redirects it to keep the run output clean.
#>

BeforeAll {
    $SutParams = @{
        Path      = $PSScriptRoot
        ChildPath = '..\..\Scripts\TemplateSetup\Remove-TemplateSetup.ps1'
    }
    $script:Sut = (Resolve-Path (Join-Path @SutParams)).Path
    . $script:Sut
}

Describe 'Remove-TemplateSetup' -Tag 'unit', 'functional' {
    BeforeEach {
        $ScratchParams = @{
            Path      = [System.IO.Path]::GetTempPath()
            ChildPath = "rmts-$([guid]::NewGuid().ToString('N'))"
        }
        $script:Scratch = Join-Path @ScratchParams
        $ScratchSetupParams = @{
            Path      = $script:Scratch
            ChildPath = 'Scripts\TemplateSetup'
        }
        $script:ScratchSetupDir = Join-Path @ScratchSetupParams
        $ScratchPesterParams = @{
            Path      = $script:Scratch
            ChildPath = 'Tests\Pester'
        }
        $script:ScratchPesterDir = Join-Path @ScratchPesterParams
        New-Item -ItemType Directory -Path $script:ScratchSetupDir -Force | Out-Null
        New-Item -ItemType Directory -Path $script:ScratchPesterDir -Force | Out-Null

        # Two step scripts with a matching test, one (_Common.ps1) with none,
        # plus an unrelated test that must survive -- the template's real shape.
        foreach ($Leaf in @('Setup-NewProject.ps1', 'Set-GitHubUser.ps1', '_Common.ps1')) {
            $StepPath = Join-Path -Path $script:ScratchSetupDir -ChildPath $Leaf
            Set-Content -LiteralPath $StepPath -Value '# step' -NoNewline
        }
        $TestParams = @{ Path = $script:ScratchPesterDir; ChildPath = 'Setup-NewProject.Tests.ps1' }
        $script:SetupTest = Join-Path @TestParams
        $TestParams = @{ Path = $script:ScratchPesterDir; ChildPath = 'Set-GitHubUser.Tests.ps1' }
        $script:UserTest = Join-Path @TestParams
        $TestParams = @{ Path = $script:ScratchPesterDir; ChildPath = 'Get-Greeting.Tests.ps1' }
        $script:OtherTest = Join-Path @TestParams
        Set-Content -LiteralPath $script:SetupTest -Value '# setup test' -NoNewline
        Set-Content -LiteralPath $script:UserTest -Value '# user test' -NoNewline
        Set-Content -LiteralPath $script:OtherTest -Value '# other test' -NoNewline
    }

    AfterEach {
        Remove-Item -LiteralPath $script:Scratch -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'deletes the setup folder and the tests that cover its scripts' {
        $Params = @{ RepoRoot = $script:Scratch; DryRun = $false; AssumeYes = $true }
        $Applied = Remove-TemplateSetup @Params 6>$null
        $Applied | Should -BeTrue

        Test-Path -LiteralPath $script:ScratchSetupDir | Should -BeFalse
        Test-Path -LiteralPath $script:SetupTest | Should -BeFalse
        Test-Path -LiteralPath $script:UserTest | Should -BeFalse
    }

    It 'leaves tests that cover anything else alone' {
        $Params = @{ RepoRoot = $script:Scratch; DryRun = $false; AssumeYes = $true }
        $Applied = Remove-TemplateSetup @Params 6>$null
        $Applied | Should -BeTrue

        Test-Path -LiteralPath $script:OtherTest | Should -BeTrue
        Test-Path -LiteralPath $script:ScratchPesterDir | Should -BeTrue
    }

    It 'deletes nothing under -DryRun, and never prompts' {
        Mock Confirm-Step { throw 'Confirm-Step must not be called under -DryRun' }

        $Params = @{ RepoRoot = $script:Scratch; DryRun = $true; AssumeYes = $false }
        $Applied = Remove-TemplateSetup @Params 6>$null
        $Applied | Should -BeTrue

        Test-Path -LiteralPath $script:ScratchSetupDir | Should -BeTrue
        Test-Path -LiteralPath $script:SetupTest | Should -BeTrue
        Should -Invoke Confirm-Step -Times 0
    }

    It 'keeps everything, and still succeeds, when the offer is declined' {
        Mock Confirm-Step { return $false }

        $Params = @{ RepoRoot = $script:Scratch; DryRun = $false; AssumeYes = $false }
        $Applied = Remove-TemplateSetup @Params 6>$null
        $Applied | Should -BeTrue

        Should -Invoke Confirm-Step -Times 1
        Test-Path -LiteralPath $script:ScratchSetupDir | Should -BeTrue
        Test-Path -LiteralPath $script:SetupTest | Should -BeTrue
        Test-Path -LiteralPath $script:UserTest | Should -BeTrue
    }

    It 'is idempotent: a second run finds nothing and still succeeds' {
        $Params = @{ RepoRoot = $script:Scratch; DryRun = $false; AssumeYes = $true }
        $FirstApplied = Remove-TemplateSetup @Params 6>$null
        $FirstApplied | Should -BeTrue
        $SecondApplied = Remove-TemplateSetup @Params 6>$null
        $SecondApplied | Should -BeTrue

        Test-Path -LiteralPath $script:ScratchSetupDir | Should -BeFalse
    }
}

Describe 'Get-TemplateSetupTarget' -Tag 'unit', 'functional' {
    BeforeEach {
        $ScratchParams = @{
            Path      = [System.IO.Path]::GetTempPath()
            ChildPath = "rmts-$([guid]::NewGuid().ToString('N'))"
        }
        $script:Scratch = Join-Path @ScratchParams
        $ScratchSetupParams = @{
            Path      = $script:Scratch
            ChildPath = 'Scripts\TemplateSetup'
        }
        $script:ScratchSetupDir = Join-Path @ScratchSetupParams
        $ScratchPesterParams = @{
            Path      = $script:Scratch
            ChildPath = 'Tests\Pester'
        }
        $script:ScratchPesterDir = Join-Path @ScratchPesterParams
        New-Item -ItemType Directory -Path $script:ScratchSetupDir -Force | Out-Null
        New-Item -ItemType Directory -Path $script:ScratchPesterDir -Force | Out-Null
    }

    AfterEach {
        Remove-Item -LiteralPath $script:Scratch -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'pairs each step script with its test, and lists the folder last' {
        $StepPath = Join-Path -Path $script:ScratchSetupDir -ChildPath 'Set-ModuleManifest.ps1'
        Set-Content -LiteralPath $StepPath -Value '# step' -NoNewline
        $TestParams = @{
            Path      = $script:ScratchPesterDir
            ChildPath = 'Set-ModuleManifest.Tests.ps1'
        }
        $TestPath = Join-Path @TestParams
        Set-Content -LiteralPath $TestPath -Value '# test' -NoNewline

        $Targets = @(Get-TemplateSetupTarget -RepoRoot $script:Scratch)

        $Targets | Should -HaveCount 2
        $Targets[0] | Should -Be 'Tests\Pester\Set-ModuleManifest.Tests.ps1'
        $Targets[-1] | Should -Be 'Scripts\TemplateSetup'
    }

    It 'lists the folder alone when no step script has a test' {
        $StepPath = Join-Path -Path $script:ScratchSetupDir -ChildPath '_Common.ps1'
        Set-Content -LiteralPath $StepPath -Value '# helpers' -NoNewline

        $Targets = @(Get-TemplateSetupTarget -RepoRoot $script:Scratch)

        $Targets | Should -HaveCount 1
        $Targets[0] | Should -Be 'Scripts\TemplateSetup'
    }

    It 'returns nothing once the setup folder is gone' {
        Remove-Item -LiteralPath $script:ScratchSetupDir -Recurse -Force

        $Targets = @(Get-TemplateSetupTarget -RepoRoot $script:Scratch)

        $Targets | Should -HaveCount 0
    }
}
