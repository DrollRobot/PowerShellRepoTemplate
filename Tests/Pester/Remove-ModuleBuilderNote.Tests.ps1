<#
.SYNOPSIS
    Pester tests for Scripts\TemplateSetup\Remove-ModuleBuilderNote.ps1.

.DESCRIPTION
    Remove-ModuleBuilderNote takes an explicit -RepoRoot, so -- unlike the
    orchestrator -- its apply path is safe to exercise for real against a
    throwaway scratch tree. The script guards its parameter-driven body with
    `if ($MyInvocation.InvocationName -eq '.') { return }`, so dot-sourcing it
    reaches the Remove-ModuleBuilderNote function (and the shared helpers it
    dot-sources) without running the standalone entrypoint. The function reports
    progress via Write-Host; Pester does not capture stream 6, so every call
    redirects it to keep the run output clean.
#>

BeforeAll {
    $SutParams = @{
        Path      = $PSScriptRoot
        ChildPath = '..\..\Scripts\TemplateSetup\Remove-ModuleBuilderNote.ps1'
    }
    $script:Sut = (Resolve-Path (Join-Path @SutParams)).Path
    . $script:Sut
}

Describe 'Remove-ModuleBuilderNote' -Tag 'unit', 'functional' {
    BeforeEach {
        $ScratchParams = @{
            Path      = [System.IO.Path]::GetTempPath()
            ChildPath = "rmmbn-$([guid]::NewGuid().ToString('N'))"
        }
        $script:Scratch = Join-Path @ScratchParams
        # Source\ plus one subfolder mirrors the template's real layout: a notes
        # file at each level, next to a file that must survive.
        $script:SourceDir = Join-Path -Path $script:Scratch -ChildPath 'Source'
        $script:PublicDir = Join-Path -Path $script:SourceDir -ChildPath 'Public'
        New-Item -ItemType Directory -Path $script:PublicDir -Force | Out-Null

        $script:RootNotes = Join-Path -Path $script:SourceDir -ChildPath 'ModuleBuilderNotes.md'
        $script:PublicNotes = Join-Path -Path $script:PublicDir -ChildPath 'ModuleBuilderNotes.md'
        $script:Keeper = Join-Path -Path $script:PublicDir -ChildPath 'Get-Thing.ps1'
        Set-Content -LiteralPath $script:RootNotes -Value '# Source/' -NoNewline
        Set-Content -LiteralPath $script:PublicNotes -Value '# Public/' -NoNewline
        Set-Content -LiteralPath $script:Keeper -Value 'function Get-Thing {}' -NoNewline
    }

    AfterEach {
        Remove-Item -LiteralPath $script:Scratch -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'deletes every ModuleBuilderNotes.md under the repo root' {
        $Params = @{ RepoRoot = $script:Scratch; DryRun = $false }
        $Applied = Remove-ModuleBuilderNote @Params 6>$null
        $Applied | Should -BeTrue

        Test-Path -LiteralPath $script:RootNotes | Should -BeFalse
        Test-Path -LiteralPath $script:PublicNotes | Should -BeFalse
    }

    It 'leaves every other file alone' {
        $Params = @{ RepoRoot = $script:Scratch; DryRun = $false }
        $Applied = Remove-ModuleBuilderNote @Params 6>$null
        $Applied | Should -BeTrue

        Test-Path -LiteralPath $script:Keeper | Should -BeTrue
        Test-Path -LiteralPath $script:PublicDir | Should -BeTrue
    }

    It 'deletes nothing under -DryRun' {
        $Params = @{ RepoRoot = $script:Scratch; DryRun = $true }
        $Applied = Remove-ModuleBuilderNote @Params 6>$null
        $Applied | Should -BeTrue

        Test-Path -LiteralPath $script:RootNotes | Should -BeTrue
        Test-Path -LiteralPath $script:PublicNotes | Should -BeTrue
    }

    It 'skips excluded folders such as Output\' {
        $OutputDir = Join-Path -Path $script:Scratch -ChildPath 'Output'
        New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
        $BuiltNotes = Join-Path -Path $OutputDir -ChildPath 'ModuleBuilderNotes.md'
        Set-Content -LiteralPath $BuiltNotes -Value '# built copy' -NoNewline

        $Params = @{ RepoRoot = $script:Scratch; DryRun = $false }
        $Applied = Remove-ModuleBuilderNote @Params 6>$null
        $Applied | Should -BeTrue

        Test-Path -LiteralPath $BuiltNotes | Should -BeTrue
    }

    It 'is idempotent: a second run finds nothing and still succeeds' {
        $Params = @{ RepoRoot = $script:Scratch; DryRun = $false }
        $FirstApplied = Remove-ModuleBuilderNote @Params 6>$null
        $FirstApplied | Should -BeTrue
        $SecondApplied = Remove-ModuleBuilderNote @Params 6>$null
        $SecondApplied | Should -BeTrue

        Test-Path -LiteralPath $script:RootNotes | Should -BeFalse
    }
}
