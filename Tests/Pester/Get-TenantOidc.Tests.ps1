#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# $Table is assigned in BeforeAll and consumed by the It blocks via Pester
# scoping; PSSA analyses each scriptblock in isolation and cannot see that.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'Table',
    Justification = 'Assigned in BeforeAll, consumed by It blocks via Pester scoping.')]
param()

BeforeAll {
    $Dir = Join-Path -Path $PSScriptRoot -ChildPath '..\..\source\Public\Lib'
    . (Join-Path -Path $Dir -ChildPath 'Get-TenantOidc.ps1')
}

Describe 'Get-TenantOidc -CloudTable' {

    BeforeAll {
        $Table = Get-TenantOidc -CloudTable
    }

    It 'returns an ordered dictionary' {
        $Table | Should -BeOfType [System.Collections.Specialized.OrderedDictionary]
    }

    It 'contains exactly the four expected cloud keys' {
        $Table.Keys | Should -Be @('Commercial', 'USGov', 'USGovDoD', 'China')
    }

    It 'requires no -TenantId when -CloudTable is used' {
        { Get-TenantOidc -CloudTable } | Should -Not -Throw
    }

    Context 'Each cloud entry is well-formed' {
        It '<Cloud> has a non-empty LoginHost starting with https://' -ForEach @(
            @{ Cloud = 'Commercial' }
            @{ Cloud = 'USGov' }
            @{ Cloud = 'USGovDoD' }
            @{ Cloud = 'China' }
        ) {
            $Table[$Cloud].LoginHost | Should -Match '^https://'
        }

        It '<Cloud> has a non-empty Graph endpoint starting with https://' -ForEach @(
            @{ Cloud = 'Commercial' }
            @{ Cloud = 'USGov' }
            @{ Cloud = 'USGovDoD' }
            @{ Cloud = 'China' }
        ) {
            $Table[$Cloud].Graph | Should -Match '^https://'
        }

        It '<Cloud> has a non-empty GraphEnv string' -ForEach @(
            @{ Cloud = 'Commercial' }
            @{ Cloud = 'USGov' }
            @{ Cloud = 'USGovDoD' }
            @{ Cloud = 'China' }
        ) {
            $Table[$Cloud].GraphEnv | Should -Not -BeNullOrEmpty
        }

        It '<Cloud> has a non-empty ExchangeEnv string' -ForEach @(
            @{ Cloud = 'Commercial' }
            @{ Cloud = 'USGov' }
            @{ Cloud = 'USGovDoD' }
            @{ Cloud = 'China' }
        ) {
            $Table[$Cloud].ExchangeEnv | Should -Not -BeNullOrEmpty
        }
    }

    Context 'Parameter set wiring' {
        It '-TenantId and -CloudTable cannot be used together' {
            { Get-TenantOidc -TenantId 'contoso.com' -CloudTable } | Should -Throw
        }
    }
}
