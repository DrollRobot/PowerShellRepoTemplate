<#
.SYNOPSIS
    Pester tests for the private Set-LogConfig function.

.DESCRIPTION
    Runs inside the module scope, so Tests.ps1 must have imported the module
    first. Register-LogEventSource is mocked throughout, so nothing here
    touches the real Windows event log registry.
#>
# Template file version, read by Scripts\Compare-Template.ps1, which keeps a
# child repo's copy of this test in sync by version.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseDeclaredVarsMoreThanAssignments', 'ScriptVersion')]
$ScriptVersion = '1.0.0'

InModuleScope 'PowershellRepoTemplate' {

    Describe 'Set-LogConfig' -Tag 'unit' {

        BeforeEach {
            Remove-Variable -Name LogContext -Scope Script -ErrorAction SilentlyContinue
            Mock Write-Host { }
            # keep event-target tests from touching the real event log registry
            Mock Register-LogEventSource { $null }
        }
        AfterEach {
            # Recreate a default context: later suites log through the real
            # Write-Log, which requires one (there is no lazy fallback).
            Remove-Variable -Name LogContext -Scope Script -ErrorAction SilentlyContinue
            Set-LogConfig
        }

        It 'round-trips values through Get-LogConfig' {
            Set-LogConfig -HostMinimumLevel Debug -MemoryMaxEntries 250
            $o = Get-LogConfig
            $o.Host.MinimumLevel | Should -Be 'Debug'
            $o.Memory.MaxEntries | Should -Be 250
        }

        It 'changes only the supplied options' {
            Set-LogConfig -HostEnabled $false
            $o = Get-LogConfig
            $o.Host.Enabled | Should -BeFalse
            $o.Memory.Enabled | Should -BeTrue
        }

        It 'keeps earlier settings across later calls' {
            Set-LogConfig -MemoryMaxEntries 250
            Set-LogConfig -HostEnabled $false
            (Get-LogConfig).Memory.MaxEntries | Should -Be 250
        }

        It 'commits a full file configuration from an exact file path' {
            $p = Join-Path -Path $TestDrive -ChildPath 'app.log'
            Set-LogConfig -LogPath $p -FileMinimumLevel Debug
            $o = Get-LogConfig
            $o.File.Enabled | Should -BeTrue
            $o.File.Path | Should -Be $p
            $o.File.MinimumLevel | Should -Be 'Debug'
        }

        It 'appends the module log file name to an existing directory' {
            Set-LogConfig -LogPath $TestDrive
            (Get-LogConfig).File.Path |
                Should -Be (Join-Path -Path $TestDrive -ChildPath 'PowershellRepoTemplate.log')
        }

        It 'treats a nonexistent extensionless path as a directory' {
            $dir = Join-Path -Path $TestDrive -ChildPath 'newdir'
            Set-LogConfig -LogPath $dir
            (Get-LogConfig).File.Path |
                Should -Be (Join-Path -Path $dir -ChildPath 'PowershellRepoTemplate.log')
        }

        It 'expands a cmd-style environment variable in the log path' {
            # How a deployed script's baked or injected log path arrives.
            $env:PowershellRepoTemplateTestLogDir = $TestDrive
            try {
                Set-LogConfig -LogPath '%PowershellRepoTemplateTestLogDir%\deployed.log'
            }
            finally {
                $EnvEntry = 'Env:\PowershellRepoTemplateTestLogDir'
                Remove-Item -LiteralPath $EnvEntry -ErrorAction SilentlyContinue
            }
            (Get-LogConfig).File.Path |
                Should -Be (Join-Path -Path $TestDrive -ChildPath 'deployed.log')
        }

        It 'treats a nonexistent path with an extension as a file' {
            $p = Join-Path -Path $TestDrive -ChildPath 'sub\custom.log'
            Set-LogConfig -LogPath $p
            (Get-LogConfig).File.Path | Should -Be $p
        }

        It 'resolves a relative path against the current location' {
            Push-Location -Path $TestDrive
            try {
                Set-LogConfig -LogPath '.'
            }
            finally {
                Pop-Location
            }
            (Get-LogConfig).File.Path |
                Should -Be (Join-Path -Path $TestDrive -ChildPath 'PowershellRepoTemplate.log')
        }

        It 'leaves the file target untouched for a blank LogPath' {
            $p = Join-Path -Path $TestDrive -ChildPath 'app.log'
            Set-LogConfig -LogPath $p
            Set-LogConfig -LogPath '   ' -HostEnabled $false
            $o = Get-LogConfig
            $o.File.Enabled | Should -BeTrue
            $o.File.Path | Should -Be $p
        }

        It 'creates the parent directory and the log file at setup' {
            $p = Join-Path -Path $TestDrive -ChildPath 'newdir\sub\app.log'
            Set-LogConfig -LogPath $p
            Test-Path -LiteralPath $p -PathType Leaf | Should -BeTrue
        }

        It 'allows disabling the file target without a path' {
            Set-LogConfig -FileEnabled $false
            (Get-LogConfig).File.Enabled | Should -BeFalse
        }

        It 'throws when enabling file logging without a path' {
            { Set-LogConfig -FileEnabled $true } | Should -Throw '*without a path*'
        }

        It 'reports arguments and merged state when the path is missing' -Tag 'regression' {
            { Set-LogConfig -FileEnabled $true } | Should -Throw (
                '*Arguments: FileEnabled=True, LogPath=False*' +
                "Final state after config merge: FileEnabled=True, Path=''*")
        }

        It 'throws when the retain size is not smaller than the max size' {
            { Set-LogConfig -FileMaxSizeKB 10 -FileRetainSizeKB 10 } |
                Should -Throw '*must be less than*'
        }

        It 'logs an Error and leaves the file target off for an unusable path' -Tag 'regression' {
            # A plain file sitting where the log's parent directory should be
            # makes the append probe fail deterministically.
            $blocker = Join-Path -Path $TestDrive -ChildPath 'blocker'
            Set-Content -Path $blocker -Value 'x'
            $p = Join-Path -Path $blocker -ChildPath 'x.log'
            { Set-LogConfig -LogPath $p -HostEnabled $false } | Should -Not -Throw
            (Get-LogConfig).File.Enabled | Should -BeFalse
            @(Get-LogMessage -Level Error).Count | Should -BeGreaterOrEqual 1
        }

        It 'still applies host and memory options when the file setup fails' -Tag 'regression' {
            $blocker = Join-Path -Path $TestDrive -ChildPath 'blocker2'
            Set-Content -Path $blocker -Value 'x'
            $p = Join-Path -Path $blocker -ChildPath 'x.log'
            Set-LogConfig -LogPath $p -HostMinimumLevel Debug -HostEnabled $false
            (Get-LogConfig).Host.MinimumLevel | Should -Be 'Debug'
        }

        It 'drops the oldest buffered entries when MaxEntries shrinks' {
            Set-LogConfig -HostEnabled $false
            $null = Get-LogMessage -Clear
            1..20 | ForEach-Object { Write-Log -Level Trace -Message "m$_" }
            Set-LogConfig -MemoryMaxEntries 5
            # Set-LogConfig's own Trace entry lands in this buffer too, so
            # assert the cap and the eviction it implies (oldest gone, newest
            # kept) rather than exact surviving positions.
            $msgs = @(Get-LogMessage)
            $msgs.Count | Should -Be 5
            $msgs.Message | Should -Not -Contain 'm1'
            $msgs.Message | Should -Contain 'm20'
        }

        It 'defaults the event source to the module name with the target off' {
            Set-LogConfig
            $o = (Get-LogConfig).EventLog
            $o.Enabled | Should -BeFalse
            $o.Source | Should -Be 'PowershellRepoTemplate'
        }

        It 'arms the event target and registers the module-name source' {
            Set-LogConfig -EventLogEnabled $true
            (Get-LogConfig).EventLog.Enabled | Should -BeTrue
            Should -Invoke Register-LogEventSource -Times 1 -Exactly -ParameterFilter {
                $Source -eq 'PowershellRepoTemplate' -and $LogName -eq 'Application'
            }
        }

        It 'commits id and level changes without probing the registration' {
            Set-LogConfig -EventLogMinimumLevel Warning -EventLogId 4242
            Should -Invoke Register-LogEventSource -Times 0 -Exactly
            $o = (Get-LogConfig).EventLog
            $o.Enabled | Should -BeFalse
            $o.MinimumLevel | Should -Be 'Warning'
            $o.EventId | Should -Be 4242
        }

        It 'keeps event settings across later calls' {
            Set-LogConfig -EventLogEnabled $true -EventLogId 4242
            Set-LogConfig -HostEnabled $false
            $o = (Get-LogConfig).EventLog
            $o.Enabled | Should -BeTrue
            $o.EventId | Should -Be 4242
        }

        It 'registers an overridden source in an overridden log' {
            $configParams = @{
                EventLogEnabled = $true
                EventLogSource  = 'CustomSource'
                EventLogName    = 'CustomLog'
            }
            Set-LogConfig @configParams
            Should -Invoke Register-LogEventSource -Times 1 -Exactly -ParameterFilter {
                $Source -eq 'CustomSource' -and $LogName -eq 'CustomLog'
            }
            $o = (Get-LogConfig).EventLog
            $o.Source | Should -Be 'CustomSource'
            $o.LogName | Should -Be 'CustomLog'
        }

        It 'leaves a blank source and log name untouched' {
            Set-LogConfig -EventLogSource '   ' -EventLogName ''
            Should -Invoke Register-LogEventSource -Times 0 -Exactly
            $o = (Get-LogConfig).EventLog
            $o.Source | Should -Be 'PowershellRepoTemplate'
            $o.LogName | Should -Be 'Application'
        }

        It 'logs an Error and leaves the event target off when registration fails' {
            Mock Register-LogEventSource { 'registration denied' }
            { Set-LogConfig -EventLogEnabled $true -HostEnabled $false } |
                Should -Not -Throw
            (Get-LogConfig).EventLog.Enabled | Should -BeFalse
            @(Get-LogMessage -Level Error).Count | Should -BeGreaterOrEqual 1
        }

        It 'still applies other options when event registration fails' {
            Mock Register-LogEventSource { 'registration denied' }
            Set-LogConfig -EventLogEnabled $true -MemoryMaxEntries 123 -HostEnabled $false
            (Get-LogConfig).Memory.MaxEntries | Should -Be 123
        }

        It 'disabling the event target never probes the registration' {
            Mock Register-LogEventSource { 'registration denied' }
            Set-LogConfig -EventLogEnabled $false
            Should -Invoke Register-LogEventSource -Times 0 -Exactly
            (Get-LogConfig).EventLog.Enabled | Should -BeFalse
        }
    }
}
