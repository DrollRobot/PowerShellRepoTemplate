#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath '..\..\source\Private\Lib\ConvertTo-TimeSpan.ps1')
}

Describe 'ConvertTo-TimeSpan' {

    Context 'Valid durations' {
        It 'parses hours' {
            (ConvertTo-TimeSpan '3 hours').TotalHours | Should -Be 3
        }
        It 'parses days' {
            (ConvertTo-TimeSpan '5 days').TotalDays | Should -Be 5
        }
        It 'parses minutes' {
            (ConvertTo-TimeSpan '90 minutes').TotalMinutes | Should -Be 90
        }
        It 'parses seconds' {
            (ConvertTo-TimeSpan '45 seconds').TotalSeconds | Should -Be 45
        }
        It 'parses weeks as 7 days each' {
            (ConvertTo-TimeSpan '2 weeks').TotalDays | Should -Be 14
        }
        It 'accepts abbreviations (hr)' {
            (ConvertTo-TimeSpan '6 hr').TotalHours | Should -Be 6
        }
        It 'accepts single-letter units (d)' {
            (ConvertTo-TimeSpan '2 d').TotalDays | Should -Be 2
        }
        It 'tolerates a trailing ago' {
            (ConvertTo-TimeSpan '3 days ago').TotalDays | Should -Be 3
        }
        It 'is case-insensitive' {
            (ConvertTo-TimeSpan '3 DAYS').TotalDays | Should -Be 3
        }
        It 'tolerates no space between number and unit' {
            (ConvertTo-TimeSpan '3d').TotalDays | Should -Be 3
        }
        It 'returns a TimeSpan' {
            ConvertTo-TimeSpan '1 hour' | Should -BeOfType [timespan]
        }
    }

    Context 'Invalid input' {
        It 'throws on whitespace-only input' {
            { ConvertTo-TimeSpan '   ' } | Should -Throw
        }
        It 'throws on an unknown unit' {
            { ConvertTo-TimeSpan '3 fortnights' } | Should -Throw
        }
        It 'throws on months (not a fixed-length span)' {
            { ConvertTo-TimeSpan '2 months' } | Should -Throw
        }
        It 'throws on years (not a fixed-length span)' {
            { ConvertTo-TimeSpan '1 year' } | Should -Throw
        }
        It 'throws on non-duration text' {
            { ConvertTo-TimeSpan 'tomorrow' } | Should -Throw
        }
        It 'throws when there is no leading number' {
            { ConvertTo-TimeSpan 'hours' } | Should -Throw
        }
    }
}
