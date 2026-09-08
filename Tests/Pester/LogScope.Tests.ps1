<#
.SYNOPSIS
    Pester tests for the private Enter-LogScope / Exit-LogScope pair.

.DESCRIPTION
    Unit tests only: Write-LogEvent and Register-LogEventSource are mocked, so
    nothing touches the real Windows event log or its registry. The mock
    records every event the flush would have written, which is how these tests
    tell an outermost scope (one event) from a nested one (none).

    The behaviour under test is the reference count: a command that calls
    another command opens a nested scope, and only the outermost close flushes,
    so one run produces one event however deep the call graph goes.
#>
# Template file version, read by Scripts\Compare-Template.ps1, which keeps a
# child repo's copy of this test in sync by version.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseDeclaredVarsMoreThanAssignments', 'ScriptVersion')]
$ScriptVersion = '1.0.0'

InModuleScope 'PowershellRepoTemplate' {

    Describe 'Enter-LogScope / Exit-LogScope' -Tag 'unit' {

        BeforeEach {
            Remove-Variable -Name LogContext -Scope Script -ErrorAction SilentlyContinue
            Mock Write-Host { }
            Mock Register-LogEventSource { $null }

            # capture every would-be event; tests assert against this list
            $script:SentEvents = New-Object -TypeName 'System.Collections.Generic.List[object]'
            Mock Write-LogEvent {
                $script:SentEvents.Add([pscustomobject]@{
                        EntryType = $EntryType
                        Message   = $Message
                    })
            }

            Set-LogConfig -EventLogEnabled $true
            $null = Get-LogMessage -Clear
        }
        AfterEach {
            Remove-Variable -Name SentEvents -Scope Script -ErrorAction SilentlyContinue
            # Recreate a default context: later suites log through the real
            # Write-Log, which requires one (there is no lazy fallback).
            Remove-Variable -Name LogContext -Scope Script -ErrorAction SilentlyContinue
            Set-LogConfig
        }

        It 'throws when entered before Set-LogConfig' {
            Remove-Variable -Name LogContext -Scope Script -ErrorAction SilentlyContinue
            { Enter-LogScope } | Should -Throw '*Set-LogConfig*'
        }

        It 'throws when exited before Set-LogConfig' {
            Remove-Variable -Name LogContext -Scope Script -ErrorAction SilentlyContinue
            { Exit-LogScope } | Should -Throw '*Set-LogConfig*'
        }

        It 'starts at depth zero' {
            (Get-LogConfig).ScopeDepth | Should -Be 0
        }

        It 'counts nested scopes and returns to zero' {
            Enter-LogScope
            (Get-LogConfig).ScopeDepth | Should -Be 1
            Enter-LogScope
            (Get-LogConfig).ScopeDepth | Should -Be 2
            Exit-LogScope
            (Get-LogConfig).ScopeDepth | Should -Be 1
            Exit-LogScope
            (Get-LogConfig).ScopeDepth | Should -Be 0
        }

        It 'flushes once when the outermost scope closes' {
            Enter-LogScope
            Write-Log -Level Information -Message 'outer'
            Exit-LogScope
            $script:SentEvents.Count | Should -Be 1
        }

        It 'does not flush when a nested scope closes' {
            Enter-LogScope
            Enter-LogScope
            Write-Log -Level Information -Message 'inner'
            Exit-LogScope
            $script:SentEvents.Count | Should -Be 0
        }

        It 'emits one event for a whole nested run, holding every line' {
            Enter-LogScope
            Write-Log -Level Information -Message 'parent-before'
            Enter-LogScope
            Write-Log -Level Information -Message 'child'
            Exit-LogScope
            Write-Log -Level Information -Message 'parent-after'
            Exit-LogScope

            $script:SentEvents.Count | Should -Be 1
            $script:SentEvents[0].Message | Should -BeLike '*parent-before*'
            $script:SentEvents[0].Message | Should -BeLike '*child*'
            $script:SentEvents[0].Message | Should -BeLike '*parent-after*'
        }

        It 'clears the buffer when the outermost scope opens' {
            Write-Log -Level Information -Message 'from-a-previous-run'
            Enter-LogScope
            Write-Log -Level Information -Message 'this-run'
            Exit-LogScope

            $script:SentEvents[0].Message | Should -Not -BeLike '*from-a-previous-run*'
            $script:SentEvents[0].Message | Should -BeLike '*this-run*'
        }

        It 'does not clear the buffer when a nested scope opens' {
            Enter-LogScope
            Write-Log -Level Information -Message 'parent-line'
            Enter-LogScope
            Exit-LogScope
            Exit-LogScope

            $script:SentEvents[0].Message | Should -BeLike '*parent-line*'
        }

        It 'restamps RunStart when the outermost scope opens' {
            $before = (Get-Date).AddMinutes(-5)
            $ctx = Get-Variable -Name LogContext -Scope Script -ValueOnly
            $ctx.RunStart = $before

            Enter-LogScope
            $ctx.RunStart | Should -BeGreaterThan $before
            Exit-LogScope
        }

        It 'leaves RunStart alone when a nested scope opens' {
            Enter-LogScope
            $ctx = Get-Variable -Name LogContext -Scope Script -ValueOnly
            $outerStart = $ctx.RunStart

            Enter-LogScope
            $ctx.RunStart | Should -Be $outerStart
            Exit-LogScope
            Exit-LogScope
        }

        It 'applies logging configuration when the outermost scope opens' {
            $dir = Join-Path -Path $TestDrive -ChildPath 'scope-config'
            Enter-LogScope -LogPath $dir -HostMinimumLevel 'Trace'
            try {
                $config = Get-LogConfig
                $config.Host.MinimumLevel | Should -Be 'Trace'
                $config.File.Enabled | Should -BeTrue
            }
            finally {
                Exit-LogScope
            }
        }

        It 'ignores logging configuration when a nested scope opens' {
            Enter-LogScope -HostMinimumLevel 'Warning'
            Enter-LogScope -HostMinimumLevel 'Trace'
            (Get-LogConfig).Host.MinimumLevel | Should -Be 'Warning'
            Exit-LogScope
            Exit-LogScope
        }

        It 'leaves configuration untouched when the arguments are blank' {
            $before = (Get-LogConfig).Host.MinimumLevel
            Enter-LogScope -LogPath '' -HostMinimumLevel ''
            (Get-LogConfig).Host.MinimumLevel | Should -Be $before
            (Get-LogConfig).File.Enabled | Should -BeFalse
            Exit-LogScope
        }

        It 'unwinds to zero and flushes once when the body throws' {
            {
                Enter-LogScope
                try {
                    Enter-LogScope
                    try { throw 'boom' }
                    finally { Exit-LogScope }
                }
                finally { Exit-LogScope }
            } | Should -Throw 'boom'

            (Get-LogConfig).ScopeDepth | Should -Be 0
            $script:SentEvents.Count | Should -Be 1
        }

        It 'reports the command that opened the run, not Exit-LogScope' {
            function Invoke-FakeCommand {
                Enter-LogScope
                try { Write-Log -Level Information -Message 'work' }
                finally { Exit-LogScope }
            }
            Invoke-FakeCommand

            $lines = $script:SentEvents[0].Message -split "`r`n"
            $lines[0] | Should -Be 'action:Invoke'
            $lines[1] | Should -Be 'script_name:Invoke-FakeCommand'
        }

        It 'does not flush on an unbalanced exit' {
            Enter-LogScope
            Exit-LogScope
            $script:SentEvents.Count | Should -Be 1

            Exit-LogScope
            $script:SentEvents.Count | Should -Be 1
            (Get-LogConfig).ScopeDepth | Should -Be 0
        }

        It 'writes nothing while the event target is disabled' {
            Set-LogConfig -EventLogEnabled $false
            Enter-LogScope
            Write-Log -Level Error -Message 'boom'
            Exit-LogScope
            Should -Invoke Write-LogEvent -Times 0 -Exactly
        }
    }
}
