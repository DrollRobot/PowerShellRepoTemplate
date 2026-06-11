#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath '..\..\source\Private\Graph\Resolve-DateRange.ps1')
}

Describe 'Resolve-DateRange' {

    Context 'Relative range (-Days)' {
        It 'returns RangeType of Relative' {
            $Result = Resolve-DateRange -Days 7
            $Result.RangeType | Should -Be 'Relative'
        }
        It 'stores the specified Days value' {
            $Result = Resolve-DateRange -Days 14
            $Result.Days | Should -Be 14
        }
        It 'applies DefaultDays when no date arguments are given' {
            $Result = Resolve-DateRange -DefaultDays 30
            $Result.Days | Should -Be 30
        }
        It 'StartUtc is before EndUtc' {
            $Result = Resolve-DateRange -Days 7
            $Result.StartUtc | Should -BeLessThan $Result.EndUtc
        }
        It 'formats StartString as ISO 8601 UTC' {
            $Result = Resolve-DateRange -Days 1
            $Result.StartString | Should -Match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$'
        }
        It 'formats EndString as ISO 8601 UTC' {
            $Result = Resolve-DateRange -Days 1
            $Result.EndString | Should -Match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$'
        }
    }

    Context 'Absolute range (-Start and -End)' {
        It 'returns RangeType of Absolute' {
            $Result = Resolve-DateRange -Start '01/01/2024' -End '01/10/2024'
            $Result.RangeType | Should -Be 'Absolute'
        }
        It 'calculates the correct number of Days from the span' {
            $Result = Resolve-DateRange -Start '01/01/2024' -End '01/10/2024'
            $Result.Days | Should -Be 9
        }
        It 'StartUtc is before EndUtc' {
            $Result = Resolve-DateRange -Start '01/01/2024' -End '01/10/2024'
            $Result.StartUtc | Should -BeLessThan $Result.EndUtc
        }
        It 'swaps start and end when start is after end' {
            $Result = Resolve-DateRange -Start '01/10/2024' -End '01/01/2024'
            $Result.StartUtc | Should -BeLessThan $Result.EndUtc
        }
    }

    Context 'Input validation' {
        It 'throws when -Days is combined with -Start and -End' {
            { Resolve-DateRange -Days 7 -Start '01/01/2024' -End '01/10/2024' } | Should -Throw
        }
        It 'throws when -Start is given without -End' {
            { Resolve-DateRange -Start '01/01/2024' } | Should -Throw
        }
        It 'throws when -End is given without -Start' {
            { Resolve-DateRange -End '01/10/2024' } | Should -Throw
        }
        It 'throws when -Days is combined with -Start only' {
            { Resolve-DateRange -Days 7 -Start '01/01/2024' } | Should -Throw
        }
    }
}
