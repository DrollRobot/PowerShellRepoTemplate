<#
.SYNOPSIS
    Pester tests for the private Get-LogMessage function.

.DESCRIPTION
    Runs inside the module scope, so Tests.ps1 must have imported the module
    first. Every test recreates the logging context it needs.
#>
# Template file version, read by Scripts\Compare-Template.ps1, which keeps a
# child repo's copy of this test in sync by version.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseDeclaredVarsMoreThanAssignments', 'ScriptVersion')]
$ScriptVersion = '1.0.0'

InModuleScope 'PowershellRepoTemplate' {

    Describe 'Get-LogMessage' -Tag 'unit' {

        BeforeEach {
            Remove-Variable -Name LogContext -Scope Script -ErrorAction SilentlyContinue
            Set-LogConfig -HostEnabled $false

            # Clear Set-LogConfig's own trace entries so each test only sees
            # the entries it writes itself.
            $null = Get-LogMessage -Clear
        }
        AfterEach {
            # Recreate a default context: later suites log through the real
            # Write-Log, which requires one (there is no lazy fallback).
            Remove-Variable -Name LogContext -Scope Script -ErrorAction SilentlyContinue
            Set-LogConfig
        }

        It 'returns entries oldest first' {
            Write-Log -Level Trace -Message 'first'
            Write-Log -Level Trace -Message 'second'
            $m = @(Get-LogMessage)
            $m[0].Message | Should -Be 'first'
            $m[-1].Message | Should -Be 'second'
        }

        It 'limits to the most recent N with -Last' {
            1..5 | ForEach-Object { Write-Log -Level Trace -Message "m$_" }
            $m = @(Get-LogMessage -Last 2)
            $m.Count | Should -Be 2
            $m[0].Message | Should -Be 'm4'
            $m[-1].Message | Should -Be 'm5'
        }

        It 'filters by level' {
            Write-Log -Level Trace -Message 't'
            Write-Log -Level Error -Message 'e'
            $m = @(Get-LogMessage -Level Error)
            $m.Count | Should -Be 1
            $m[0].Message | Should -Be 'e'
        }

        It 'empties the buffer with -Clear after returning the snapshot' {
            Write-Log -Level Trace -Message 'x'
            $m = @(Get-LogMessage -Clear)
            $m.Count | Should -Be 1
            Get-LogMessage | Should -BeNullOrEmpty
        }
    }
}
