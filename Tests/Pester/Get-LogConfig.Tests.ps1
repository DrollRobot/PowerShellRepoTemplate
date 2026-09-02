<#
.SYNOPSIS
    Pester tests for the private Get-LogConfig function.

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

    Describe 'Get-LogConfig' -Tag 'unit' {

        BeforeEach {
            Remove-Variable -Name LogContext -Scope Script -ErrorAction SilentlyContinue
            Mock Write-Host { }
        }
        AfterEach {
            # Recreate a default context: later suites log through the real
            # Write-Log, which requires one (there is no lazy fallback).
            Remove-Variable -Name LogContext -Scope Script -ErrorAction SilentlyContinue
            Set-LogConfig
        }

        It 'throws when called before Set-LogConfig' {
            { Get-LogConfig } | Should -Throw '*Set-LogConfig*'
        }

        It 'reports the current buffer count' {
            Set-LogConfig -HostEnabled $false
            $null = Get-LogMessage -Clear

            $ctx = (Get-Variable -Name LogContext -Scope Script).Value
            $ctx.Buffer.Enqueue([pscustomobject]@{
                    Timestamp = Get-Date
                    Level     = 'Trace'
                    Source    = 'Pester'
                    Message   = 'a'
                })
            $ctx.Buffer.Enqueue([pscustomobject]@{
                    Timestamp = Get-Date
                    Level     = 'Trace'
                    Source    = 'Pester'
                    Message   = 'b'
                })
            (Get-LogConfig).BufferCount | Should -Be 2
        }

        It 'returns a snapshot that does not mutate the live config' {
            Set-LogConfig
            $o = Get-LogConfig
            $o.Host.Enabled = $false
            (Get-LogConfig).Host.Enabled | Should -BeTrue
        }

        It 'returns an event log snapshot that does not mutate the live config' {
            Set-LogConfig
            $o = Get-LogConfig
            $o.EventLog.Enabled | Should -BeFalse
            $o.EventLog.Enabled = $true
            (Get-LogConfig).EventLog.Enabled | Should -BeFalse
        }
    }
}
