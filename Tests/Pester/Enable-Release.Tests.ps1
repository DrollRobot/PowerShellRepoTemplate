<#
.SYNOPSIS
    Pester tests for Scripts\Enable-Release.ps1.

.DESCRIPTION
    Enable-Release takes an explicit -SetupPath, so its apply path is safe to
    exercise for real against a throwaway scratch copy of setup.psd1. The
    script guards its parameter-driven body with
    `if ($MyInvocation.InvocationName -eq '.') { return }`, so dot-sourcing it
    reaches the Enable-Release function without running the standalone
    entrypoint.
#>

BeforeAll {
    $SutParams = @{
        Path      = $PSScriptRoot
        ChildPath = '..\..\Scripts\Enable-Release.ps1'
    }
    $script:Sut = (Resolve-Path (Join-Path @SutParams)).Path
    . $script:Sut
}

Describe 'Enable-Release' -Tag 'unit', 'functional' {
    BeforeEach {
        $ScratchParams = @{
            Path      = [System.IO.Path]::GetTempPath()
            ChildPath = "enablerel-$([guid]::NewGuid().ToString('N')).psd1"
        }
        $script:Scratch = Join-Path @ScratchParams
        $Content = @(
            '@{'
            '    Release = @{'
            '        Enabled = $false'
            '    }'
            '}'
        ) -join "`n"
        Set-Content -LiteralPath $script:Scratch -Value $Content -NoNewline
    }

    AfterEach {
        Remove-Item -LiteralPath $script:Scratch -Force -ErrorAction SilentlyContinue
    }

    It 'flips Enabled from false to true' {
        $Params = @{ SetupPath = $script:Scratch; Target = $true; DryRun = $false }
        Enable-Release @Params | Should -BeTrue

        $Result = Get-Content -LiteralPath $script:Scratch -Raw
        $Result | Should -Match 'Enabled = \$true'
    }

    It 'flips Enabled from true back to false with -Disable' {
        $Params = @{ SetupPath = $script:Scratch; Target = $true; DryRun = $false }
        Enable-Release @Params | Should -BeTrue

        $Params.Target = $false
        Enable-Release @Params | Should -BeTrue

        $Result = Get-Content -LiteralPath $script:Scratch -Raw
        $Result | Should -Match 'Enabled = \$false'
    }

    It 'writes nothing under -DryRun' {
        $Before = Get-Content -LiteralPath $script:Scratch -Raw
        $Params = @{ SetupPath = $script:Scratch; Target = $true; DryRun = $true }
        Enable-Release @Params | Should -BeTrue

        (Get-Content -LiteralPath $script:Scratch -Raw) | Should -Be $Before
    }

    It 'returns false and changes nothing when already at the target value' {
        $Before = Get-Content -LiteralPath $script:Scratch -Raw
        $Params = @{ SetupPath = $script:Scratch; Target = $false; DryRun = $false }
        Enable-Release @Params | Should -BeFalse

        (Get-Content -LiteralPath $script:Scratch -Raw) | Should -Be $Before
    }

    It 'preserves the rest of the file untouched' {
        $Params = @{ SetupPath = $script:Scratch; Target = $true; DryRun = $false }
        Enable-Release @Params | Should -BeTrue

        $Result = Get-Content -LiteralPath $script:Scratch -Raw
        $Result | Should -Match '(?m)^@\{'
        $Result | Should -Match '(?m)^    Release = @\{'
    }

    It 'throws when the setup file has no Release.Enabled key' {
        Set-Content -LiteralPath $script:Scratch -Value '@{ }' -NoNewline
        $Params = @{ SetupPath = $script:Scratch; Target = $true; DryRun = $false }
        { Enable-Release @Params } | Should -Throw
    }

    It 'throws when the setup file does not exist' {
        $TempPath = [System.IO.Path]::GetTempPath()
        $Missing = Join-Path -Path $TempPath -ChildPath 'does-not-exist.psd1'
        $Params = @{ SetupPath = $Missing; Target = $true; DryRun = $false }
        { Enable-Release @Params } | Should -Throw
    }
}
