#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
    Tests for the interactive criteria builder. The console loop is driven by mocking
    Read-Host: each test sets $script:Inputs to the exact sequence of answers the panel
    will consume (menu choice, then any follow-up value). The mock throws once the
    sequence is exhausted so a wrong/short sequence fails fast instead of hanging the
    loop. Write-Host is mocked to keep the panel output out of the test results.

    Read-EmailSearchCriteria depends only on pure helpers, so they are dot-sourced
    directly rather than loaded through the module.
#>

BeforeAll {
    $Root = Join-Path -Path $PSScriptRoot -ChildPath '..\..'
    . (Join-Path -Path $Root -ChildPath 'source\Private\Lib\ConvertTo-TimeSpan.ps1')
    . (Join-Path -Path $Root -ChildPath 'source\Private\Email\Build-EmailSearchQuery.ps1')
    . (Join-Path -Path $Root -ChildPath 'source\Private\Email\Build-EmailSearchName.ps1')
    . (Join-Path -Path $Root -ChildPath 'source\Private\Email\Read-EmailSearchCriteria.ps1')
}

Describe 'Read-EmailSearchCriteria' {

    BeforeEach {
        $script:Index = 0
        Mock Write-Host { }
        Mock Read-Host {
            if ($script:Index -ge $script:Inputs.Count) {
                throw 'Panel requested more input than the test queued.'
            }
            $value = $script:Inputs[$script:Index]
            $script:Index++
            $value
        }
    }

    Context 'Quit and accept gating' {
        It 'returns null when the user quits immediately' {
            $script:Inputs = @('Q')
            Read-EmailSearchCriteria | Should -BeNullOrEmpty
        }
        It 'refuses to accept until a start date is set' {
            # first A is rejected (no start), then Q quits -> null
            $script:Inputs = @('A', 'Q')
            Read-EmailSearchCriteria | Should -BeNullOrEmpty
        }
    }

    Context 'Absolute start date' {
        It 'stores an absolute start as a UTC datetime and accepts' {
            $script:Inputs = @('1', '5/28/26 17:00', 'A')
            $result = Read-EmailSearchCriteria
            $result.Start | Should -BeOfType [datetime]
            $result.Start.Kind | Should -Be 'Utc'
        }
    }

    Context 'Relative start date shortcut' {
        It 'resolves a relative duration to an absolute UTC start' {
            $script:Inputs = @('2', '3 days', 'A')
            $result = Read-EmailSearchCriteria
            $expected = (Get-Date).ToUniversalTime().AddDays(-3)
            $result.Start.Kind | Should -Be 'Utc'
            [Math]::Abs(($result.Start - $expected).TotalMinutes) | Should -BeLessThan 1
        }
        It 'does not retain a relative span on the criteria' {
            $script:Inputs = @('2', '3 days', 'A')
            $result = Read-EmailSearchCriteria
            $result.Contains('StartRelative') | Should -BeFalse
        }
    }

    Context 'Text fields' {
        It 'stores a single From value as a one-element array' {
            $script:Inputs = @('1', '5/28/26', '5', 'sushacker', 'A')
            $result = Read-EmailSearchCriteria
            $result.From | Should -Be 'sushacker'
        }
        It 'produces a correctly quoted query for a single From value' {
            $script:Inputs = @('1', '5/28/26', '5', 'sushacker', 'A')
            $result = Read-EmailSearchCriteria
            $query = Build-EmailSearchQuery -Criteria $result
            $query | Should -BeLike '*(From:"sushacker")*'
        }
        It 'splits comma-separated input into multiple values' {
            $script:Inputs = @('1', '5/28/26', '5', 'a@x.com, b@y.com', 'A')
            $result = Read-EmailSearchCriteria
            $result.From | Should -Be @('a@x.com', 'b@y.com')
        }
    }

    Context 'Clear all' {
        It 'resets dates and text fields' {
            $script:Inputs = @('1', '5/28/26', '5', 'x', 'C', '1', '5/29/26', 'A')
            $result = Read-EmailSearchCriteria
            $result.Start | Should -Not -BeNullOrEmpty
            @($result.From).Count | Should -Be 0
        }
    }
}
