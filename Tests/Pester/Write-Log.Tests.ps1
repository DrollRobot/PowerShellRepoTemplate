<#
.SYNOPSIS
    Pester tests for the private Write-Log function (incl. its nested trim helper).

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

    Describe 'Write-Log' -Tag 'unit' {

        BeforeEach {
            Remove-Variable -Name LogContext -Scope Script -ErrorAction SilentlyContinue
            Mock Write-Host { }

            # Write-Log requires an existing context. Create it with defaults,
            # then clear Set-LogConfig's own trace entries so each test only
            # sees the entries it writes itself.
            Set-LogConfig
            $null = Get-LogMessage -Clear
        }
        AfterEach {
            # Recreate a default context: later suites log through the real
            # Write-Log, which requires one (there is no lazy fallback).
            Remove-Variable -Name LogContext -Scope Script -ErrorAction SilentlyContinue
            Set-LogConfig
        }

        It 'throws when called before Set-LogConfig' -Tag 'regression' {
            Remove-Variable -Name LogContext -Scope Script -ErrorAction SilentlyContinue
            { Write-Log -Level Information -Message 'x' } |
                Should -Throw '*Set-LogConfig*'
        }

        It 'buffers a message in memory' {
            Write-Log -Level Warning -Message 'hello'
            $msgs = @(Get-LogMessage)
            $msgs.Count | Should -Be 1
            $msgs[0].Level | Should -Be 'Warning'
            $msgs[0].Message | Should -Be 'hello'
        }

        It 'writes to the host at or above the host minimum level' {
            Write-Log -Level Warning -Message 'shown'
            Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter {
                $Object -match '\[Warning\] .+: shown$'
            }
        }

        It 'formats host output like the log file (stamp, level, source, message)' {
            Write-Log -Level Warning -Message 'shown'
            Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter {
                $Object -match '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3} \[Warning\] .+: shown$'
            }
        }

        It 'suppresses host output below the host minimum level but still buffers it' {
            Write-Log -Level Debug -Message 'hidden'
            Should -Invoke Write-Host -Times 0 -Exactly
            @(Get-LogMessage).Count | Should -Be 1
        }

        It 'colors the host output per level' {
            Write-Log -Level Error -Message 'boom'
            Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter {
                $ForegroundColor -eq 'Red'
            }
        }

        It 'bounds the memory buffer to MaxEntries, keeping the newest' {
            Set-LogConfig -MemoryMaxEntries 10 -HostEnabled $false
            $null = Get-LogMessage -Clear
            1..25 | ForEach-Object { Write-Log -Level Trace -Message "m$_" }
            $msgs = @(Get-LogMessage)
            $msgs.Count | Should -Be 10
            $msgs[0].Message | Should -Be 'm16'
            $msgs[-1].Message | Should -Be 'm25'
        }

        It 'captures the caller name in the Source field' {
            function Invoke-Caller { Write-Log -Level Information -Message 'from caller' }
            Invoke-Caller
            @(Get-LogMessage)[-1].Source | Should -Be 'Invoke-Caller'
        }

        It 'lets a host target failure surface' -Tag 'regression' {
            Mock Write-Host { throw 'host down' }
            { Write-Log -Level Warning -Message 'x' } | Should -Throw '*host down*'
        }

        It 'reports a failed file write without disrupting the caller' -Tag 'regression' {
            $ctx = (Get-Variable -Name LogContext -Scope Script).Value
            $ctx.File.Enabled = $true
            $ctx.File.Path = 'Z:\does\not\exist\x.log'
            $ctx.Host.Enabled = $false
            $writeParams = @{
                Level         = 'Error'
                Message       = 'x'
                ErrorAction   = 'SilentlyContinue'
                ErrorVariable = 'ev'
            }
            # Called directly (not inside a Should scriptblock) so ErrorVariable
            # lands in this scope; a terminating error would fail the test.
            # ErrorVariable records the caught .NET exception first and the
            # function's own Write-Error report last, so assert on the last.
            Write-Log @writeParams
            $ev[-1].ToString() | Should -BeLike '*Failed to write to log file*'
            # The memory target still captured the entry.
            @(Get-LogMessage).Count | Should -Be 1
        }

        It 'writes to the log file and auto-trims to the cap, keeping the newest lines' {
            $p = Join-Path -Path $TestDrive -ChildPath 'wl.log'
            $opt = @{
                LogPath          = $p
                FileMinimumLevel = 'Trace'
                FileMaxSizeKB    = 8
                FileRetainSizeKB = 4
                HostEnabled      = $false
            }
            Set-LogConfig @opt
            1..500 | ForEach-Object {
                Write-Log -Level Trace -Message "line $_ padding padding padding"
            }
            (Get-Item -LiteralPath $p).Length | Should -BeLessOrEqual (8 * 1KB)
            (Get-Content -LiteralPath $p -Tail 1) | Should -BeLike '*line 500*'
        }
    }
}
