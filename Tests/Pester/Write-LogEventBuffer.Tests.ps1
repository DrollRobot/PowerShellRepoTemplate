<#
.SYNOPSIS
    Pester tests for the private Write-LogEventBuffer function (event log dump).

.DESCRIPTION
    Unit tests only: Write-LogEvent and Register-LogEventSource are mocked, so
    nothing touches the real Windows event log or its registry. The mock
    records every event Write-LogEventBuffer would have written; the tests parse
    those JSON payloads to assert the envelope, chunking, filtering, and
    entry-type behavior. The real event log write is covered by the
    destructive integration suite.
#>
# Template file version, read by Scripts\Compare-Template.ps1, which keeps a
# child repo's copy of this test in sync by version.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseDeclaredVarsMoreThanAssignments', 'ScriptVersion')]
$ScriptVersion = '1.0.0'

InModuleScope 'PowershellRepoTemplate' {

    Describe 'Write-LogEventBuffer' -Tag 'unit' {

        BeforeAll {
            # Every event message is parser prefix lines followed by the JSON
            # envelope as the script_log property on the final line; take
            # that line and strip the property name.
            function Get-DumpPayload {
                param([string]$Message)
                (($Message -split "`r`n")[-1] -replace '^script_log:', '') |
                    ConvertFrom-Json
            }
        }

        BeforeEach {
            Remove-Variable -Name LogContext -Scope Script -ErrorAction SilentlyContinue
            Mock Write-Host { }
            Mock Register-LogEventSource { $null }

            # capture every would-be event; tests assert against this list
            $script:SentEvents = New-Object -TypeName 'System.Collections.Generic.List[object]'
            Mock Write-LogEvent {
                $script:SentEvents.Add([pscustomobject]@{
                        Source    = $Source
                        EventId   = $EventId
                        EntryType = $EntryType
                        Message   = $Message
                    })
            }

            Set-LogConfig
            $null = Get-LogMessage -Clear
        }
        AfterEach {
            Remove-Variable -Name SentEvents -Scope Script -ErrorAction SilentlyContinue
            # Recreate a default context: later suites log through the real
            # Write-Log, which requires one (there is no lazy fallback).
            Remove-Variable -Name LogContext -Scope Script -ErrorAction SilentlyContinue
            Set-LogConfig
        }

        It 'throws when called before Set-LogConfig' {
            Remove-Variable -Name LogContext -Scope Script -ErrorAction SilentlyContinue
            { Write-LogEventBuffer } | Should -Throw '*Set-LogConfig*'
        }

        It 'writes nothing while the event target is disabled' {
            Write-Log -Level Error -Message 'boom'
            Write-LogEventBuffer
            Should -Invoke Write-LogEvent -Times 0 -Exactly
        }

        It 'writes one JSON event holding every buffered entry, oldest first' {
            Set-LogConfig -EventLogEnabled $true -HostEnabled $false
            $null = Get-LogMessage -Clear
            Write-Log -Level Information -Message 'first'
            Write-Log -Level Information -Message 'second'
            Write-LogEventBuffer
            Should -Invoke Write-LogEvent -Times 1 -Exactly
            $doc = Get-DumpPayload -Message $script:SentEvents[0].Message
            $doc.Chunk | Should -Be 1
            $doc.ChunkCount | Should -Be 1
            $doc.TotalEntries | Should -Be 2
            @($doc.Entries).Count | Should -Be 2
            $doc.Entries[0].Message | Should -Be 'first'
            $doc.Entries[1].Message | Should -Be 'second'
            $doc.Entries[0].Level | Should -Be 'Information'
            ($doc.RunId -as [guid]) | Should -Not -BeNullOrEmpty
            ($doc.RunStart -as [datetime]) | Should -Not -BeNullOrEmpty
        }

        It 'stamps the configured source and event id on the event' {
            Set-LogConfig -EventLogEnabled $true -EventLogId 4242 -HostEnabled $false
            Write-LogEventBuffer
            $script:SentEvents[0].Source | Should -Be 'PowershellRepoTemplate'
            $script:SentEvents[0].EventId | Should -Be 4242
        }

        It 'splits a large buffer into chunks that reassemble by RunId' {
            Set-LogConfig -EventLogEnabled $true -HostEnabled $false
            $null = Get-LogMessage -Clear
            $big = 'x' * 3000
            1..15 | ForEach-Object { Write-Log -Level Information -Message "$_-$big" }
            Write-LogEventBuffer

            $docs = @($script:SentEvents |
                    ForEach-Object { Get-DumpPayload -Message $_.Message })
            $docs.Count | Should -BeGreaterThan 1
            @($docs.RunId | Select-Object -Unique).Count | Should -Be 1
            @($docs | ForEach-Object { $_.ChunkCount } | Select-Object -Unique) |
                Should -Be $docs.Count
            @($docs | ForEach-Object { $_.Chunk }) | Should -Be @(1..$docs.Count)

            # reassembled entries cover the whole buffer in order
            $all = @($docs | ForEach-Object { $_.Entries })
            $all.Count | Should -Be 15
            $all[0].Message | Should -BeLike '1-*'
            $all[-1].Message | Should -BeLike '15-*'

            # every chunk respects the event log's hard message cap
            foreach ($sent in $script:SentEvents) {
                $sent.Message.Length | Should -BeLessOrEqual 32766
            }
        }

        It 'includes only entries at or above the event minimum level' {
            $configParams = @{
                EventLogEnabled      = $true
                EventLogMinimumLevel = 'Warning'
                HostEnabled          = $false
            }
            Set-LogConfig @configParams
            $null = Get-LogMessage -Clear
            Write-Log -Level Information -Message 'kept out'
            Write-Log -Level Warning -Message 'kept in'
            Write-LogEventBuffer
            $doc = Get-DumpPayload -Message $script:SentEvents[0].Message
            $doc.TotalEntries | Should -Be 1
            $doc.Entries[0].Message | Should -Be 'kept in'
        }

        It 'maps the worst buffered level to the event entry type' {
            Set-LogConfig -EventLogEnabled $true -HostEnabled $false
            $null = Get-LogMessage -Clear
            Write-Log -Level Information -Message 'calm'
            Write-LogEventBuffer
            Write-Log -Level Warning -Message 'wobbly'
            Write-LogEventBuffer
            Write-Log -Level Error -Message 'broken'
            Write-LogEventBuffer
            $script:SentEvents[0].EntryType | Should -Be 'Information'
            $script:SentEvents[1].EntryType | Should -Be 'Warning'
            $script:SentEvents[2].EntryType | Should -Be 'Error'
        }

        It 'truncates a single oversized entry instead of dropping it' {
            Set-LogConfig -EventLogEnabled $true -HostEnabled $false
            $null = Get-LogMessage -Clear
            Write-Log -Level Information -Message ('y' * 40000)
            Write-LogEventBuffer
            Should -Invoke Write-LogEvent -Times 1 -Exactly
            $script:SentEvents[0].Message.Length | Should -BeLessOrEqual 32766
            $doc = Get-DumpPayload -Message $script:SentEvents[0].Message
            $doc.TotalEntries | Should -Be 1
            $doc.Entries[0].Message | Should -Match '\.\.\.\[truncated\]$'
        }

        It 'writes an event even when the buffer is empty' {
            Set-LogConfig -EventLogEnabled $true -HostEnabled $false
            $null = Get-LogMessage -Clear
            Write-LogEventBuffer
            Should -Invoke Write-LogEvent -Times 1 -Exactly
            $doc = Get-DumpPayload -Message $script:SentEvents[0].Message
            $doc.TotalEntries | Should -Be 0
            @($doc.Entries).Count | Should -Be 0
        }

        It 'leads each event with newline-separated parser properties, action first' {
            Set-LogConfig -EventLogEnabled $true -HostEnabled $false
            $null = Get-LogMessage -Clear
            Write-Log -Level Warning -Message 'wobbly'
            Write-LogEventBuffer
            $lines = $script:SentEvents[0].Message -split "`r`n"
            $lines[0] | Should -Match '^action:\S+$'
            $lines[1] | Should -Match '^script_name:\S+$'
            $lines[2] | Should -Be 'highest_log_level:Warning'
            $lines[3] | Should -Match '^run_id:[0-9a-f-]{36}$'
            $lines[4] | Should -Be 'chunk:1'
            $lines[5] | Should -Be 'chunk_count:1'
            $lines[6] | Should -Match '^script_log:\{'
        }

        It 'duplicates the prefix properties inside the JSON payload' {
            Set-LogConfig -EventLogEnabled $true -HostEnabled $false
            $null = Get-LogMessage -Clear
            Write-Log -Level Warning -Message 'wobbly'
            Write-LogEventBuffer
            $lines = $script:SentEvents[0].Message -split "`r`n"
            $doc = Get-DumpPayload -Message $script:SentEvents[0].Message
            $lines[0] | Should -Be "action:$($doc.Action)"
            $lines[1] | Should -Be "script_name:$($doc.ScriptName)"
            $lines[2] | Should -Be "highest_log_level:$($doc.HighestLogLevel)"
            $lines[3] | Should -Be "run_id:$($doc.RunId)"
            $lines[4] | Should -Be "chunk:$($doc.Chunk)"
            $lines[5] | Should -Be "chunk_count:$($doc.ChunkCount)"
        }

        It 'reports a failed event write without throwing' {
            Mock Write-LogEvent { throw 'event log down' }
            Set-LogConfig -EventLogEnabled $true -HostEnabled $false
            $null = Get-LogMessage -Clear
            Write-Log -Level Information -Message 'x'
            $bufferParams = @{
                ErrorAction   = 'SilentlyContinue'
                ErrorVariable = 'ev'
            }
            # Called directly (not inside a Should scriptblock) so
            # ErrorVariable lands in this scope; a terminating error would
            # fail the test.
            Write-LogEventBuffer @bufferParams
            $ev[-1].ToString() | Should -BeLike '*Failed to write log buffer chunk*'
        }

        It 'stops after the first failed chunk' {
            Mock Write-LogEvent { throw 'event log down' }
            Set-LogConfig -EventLogEnabled $true -HostEnabled $false
            $null = Get-LogMessage -Clear
            $big = 'x' * 3000
            1..15 | ForEach-Object { Write-Log -Level Information -Message "$_-$big" }
            Write-LogEventBuffer -ErrorAction SilentlyContinue
            Should -Invoke Write-LogEvent -Times 1 -Exactly
        }
    }
}
