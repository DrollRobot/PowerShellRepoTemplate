#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $RelPath = '..\..\source\Private\Utility\Get-RandomPassword.ps1'
    . (Join-Path -Path $PSScriptRoot -ChildPath $RelPath)
}

Describe 'Get-RandomPassword' {

    Context 'Length' {
        It 'returns a string of the requested length' {
            (Get-RandomPassword -Length 12).Length | Should -Be 12
        }
        It 'returns a string of the minimum allowed length (4)' {
            (Get-RandomPassword -Length 4).Length | Should -Be 4
        }
        It 'returns a string of a large requested length' {
            (Get-RandomPassword -Length 64).Length | Should -Be 64
        }
        It 'throws when length is below the minimum (3)' {
            { Get-RandomPassword -Length 3 } | Should -Throw
        }
    }

    Context 'Complexity requirements' {
        # Use a long password to make it statistically certain all character classes appear.
        BeforeAll {
            $script:Password = Get-RandomPassword -Length 32
        }
        It 'contains at least one uppercase letter' {
            $script:Password | Should -Match '[A-Z]'
        }
        It 'contains at least one lowercase letter' {
            $script:Password | Should -Match '[a-z]'
        }
        It 'contains at least one digit' {
            $script:Password | Should -Match '[2-9]'
        }
        It 'contains at least one symbol' {
            $script:Password | Should -Match '[^a-zA-Z0-9]'
        }
    }

    Context 'Randomness' {
        It 'produces different passwords on successive calls' {
            $A = Get-RandomPassword -Length 20
            $B = Get-RandomPassword -Length 20
            $A | Should -Not -Be $B
        }
    }
}
