#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $Dir = Join-Path -Path $PSScriptRoot -ChildPath '..\..\source\Private\Utility'
    . (Join-Path -Path $Dir -ChildPath 'Convert-DecimalToExcelColumn.ps1')
}

Describe 'Convert-DecimalToExcelColumn' {

    Context 'Single-letter columns (1-26)' {
        It 'converts 1 to A' {
            Convert-DecimalToExcelColumn 1 | Should -Be 'A'
        }
        It 'converts 26 to Z' {
            Convert-DecimalToExcelColumn 26 | Should -Be 'Z'
        }
    }

    Context 'Two-letter columns' {
        It 'converts 27 to AA' {
            Convert-DecimalToExcelColumn 27 | Should -Be 'AA'
        }
        It 'converts 28 to AB' {
            Convert-DecimalToExcelColumn 28 | Should -Be 'AB'
        }
        It 'converts 52 to AZ' {
            Convert-DecimalToExcelColumn 52 | Should -Be 'AZ'
        }
        It 'converts 702 to ZZ' {
            Convert-DecimalToExcelColumn 702 | Should -Be 'ZZ'
        }
    }

    Context 'Pipeline input' {
        It 'processes multiple values from the pipeline' {
            $Result = 1, 26, 27 | Convert-DecimalToExcelColumn
            $Result | Should -Be @('A', 'Z', 'AA')
        }
    }

    Context 'Input validation' {
        It 'throws on 0 (below minimum)' {
            { Convert-DecimalToExcelColumn 0 } | Should -Throw
        }
        It 'throws on a negative number' {
            { Convert-DecimalToExcelColumn -1 } | Should -Throw
        }
    }
}
