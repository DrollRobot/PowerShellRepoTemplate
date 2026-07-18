<#
.SYNOPSIS
    Pester tests for the Get-Greeting sample function.

.DESCRIPTION
    Demonstrates the testing conventions in AGENTS.TESTING.md: NonLive tests
    carry no tag; tests that need a live external session are tagged 'live'.
    The module is imported by Tests.ps1 before Pester runs.

.NOTES
    Delete this file together with Source\Public\Get-Greeting.ps1.
#>

Describe 'Get-Greeting' {

    It 'greets the world by default' {
        Get-Greeting | Should -Be 'Hello, World!'
    }

    It 'greets the supplied name' {
        Get-Greeting -Name 'PowerShell' | Should -Be 'Hello, PowerShell!'
    }

    It 'returns a string' {
        Get-Greeting | Should -BeOfType [string]
    }
}
