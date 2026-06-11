#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $RelPath = '..\..\source\Private\Utility\Format-PhoneNumber.ps1'
    . (Join-Path -Path $PSScriptRoot -ChildPath $RelPath)
}

Describe 'Format-PhoneNumber' {

    Context 'US/Canada numbers (+1)' {
        It 'formats +1 to 123-456-7890' {
            Format-PhoneNumber '+1 1234567890' | Should -Be '123-456-7890'
        }
        It 'formats another +1 number correctly' {
            Format-PhoneNumber '+1 9875550123' | Should -Be '987-555-0123'
        }
    }

    Context 'International numbers' {
        It 'formats a +44 number to 44 123-456-7890' {
            Format-PhoneNumber '+44 1234567890' | Should -Be '44 123-456-7890'
        }
        It 'formats a +61 (Australia) number correctly' {
            Format-PhoneNumber '+61 4001234567' | Should -Be '61 400-123-4567'
        }
    }

    Context 'Non-matching input (pass-through)' {
        It 'returns a plain string unchanged' {
            Format-PhoneNumber 'not a phone number' | Should -Be 'not a phone number'
        }
        It 'returns a number that lacks country code unchanged' {
            Format-PhoneNumber '1234567890' | Should -Be '1234567890'
        }
    }

    Context 'Pipeline input' {
        It 'processes multiple values from the pipeline' {
            $Result = '+1 1234567890', '+1 9875550000' | Format-PhoneNumber
            $Result | Should -Be @('123-456-7890', '987-555-0000')
        }
    }
}
