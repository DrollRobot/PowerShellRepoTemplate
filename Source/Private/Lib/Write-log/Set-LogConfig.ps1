[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseDeclaredVarsMoreThanAssignments', 'ScriptVersion')]
$ScriptVersion = '2.2.0'

function Set-LogConfig {
    <#
    .SYNOPSIS
        Configures logging: creates the context on first call, then applies the
        supplied options to the memory, host, file, and event log targets.

    .DESCRIPTION
        The single configuration entry point for the Write-Log system, and the
        owner of its defaults. The first call creates the module-scoped logging
        context -- memory target on at Trace keeping 1000 entries; host target
        on at Information; file target off (Trace, 5120 KB cap trimmed to
        4096 KB once enabled); event log target off (Information, log
        'Application', event id 1000, source '<ModuleName>') -- and must
        happen before the
        first Write-Log call; there is no lazy initialization anywhere else.
        Every call, first or later, then applies only the options supplied on
        the command line; all others keep their current values.

        The event log target does not write during the run: enabling it arms
        Write-LogEventBuffer, which dumps the memory buffer to the Windows event
        log as chunked JSON events when the calling script ends. Enabling the
        target -- or repointing it with EventLogSource/EventLogName -- checks
        the event source registration immediately and creates it when missing,
        which requires administrator rights.

        LogPath accepts a directory or a file path, absolute or relative
        (relative paths resolve against the current location), and may hold
        cmd-style environment variable references ('%ProgramData%\App'), which
        are expanded before anything else looks at the path. A directory --
        an existing one, or a nonexistent path with no file extension -- gets a
        default '<ModuleName>.log' file name appended; a file path is used
        as-is. Supplying LogPath turns the file target on unless FileEnabled is
        explicitly $false in the same call. A blank or omitted LogPath leaves
        the file target untouched, so nested command-to-command calls that do
        not forward log settings cannot tear down a configured target.

        Error contract: invalid arguments -- a retain size at or above the max,
        enabling the file target with no path on record -- are caller bugs and
        throw. Environmental file-target failures -- an unresolvable path, an
        uncreatable directory, a file that will not open for append -- never
        throw: file logging is auxiliary, so the failure is logged as an Error
        to the remaining targets, the file target is left unchanged, and the
        calling command proceeds without a log file. The append probe exists
        because Write-Log swallows write errors by design; an unusable path
        must fail visibly here, at setup, or it never fails at all. The event
        log target follows the same pattern: an environmental registration
        failure -- no administrator rights, the source already bound to a
        different log -- is logged as an Error, the event target is left
        unchanged, and the calling command proceeds.

    .PARAMETER MemoryEnabled
        Turns the in-memory buffer on or off.

    .PARAMETER MemoryMinimumLevel
        Minimum level captured by the memory buffer.

    .PARAMETER MemoryMaxEntries
        Maximum number of entries retained in the memory buffer. Shrinking this
        drops the oldest entries immediately.

    .PARAMETER HostEnabled
        Turns console (host) output on or off.

    .PARAMETER HostMinimumLevel
        Minimum level written to the console.

    .PARAMETER FileEnabled
        Turns file logging on or off. Enabling it requires a path (supplied now
        via LogPath, or previously). Disabling never requires a path.

    .PARAMETER FileMinimumLevel
        Minimum level written to the log file.

    .PARAMETER LogPath
        Path to a log directory or a log file, absolute or relative, with
        %Name% references expanded before use. A directory gets
        '<ModuleName>.log' appended. Implies -FileEnabled $true unless
        FileEnabled is explicitly bound. Blank or omitted leaves the file
        target untouched.

    .PARAMETER FileMaxSizeKB
        Size cap in KB. When the file exceeds this after a write, it is
        trimmed.

    .PARAMETER FileRetainSizeKB
        Target size in KB to trim down to. Must be less than FileMaxSizeKB.

    .PARAMETER EventLogEnabled
        Turns the Windows event log target on or off. The target writes
        nothing during the run; it arms Write-LogEventBuffer, which dumps the
        memory buffer to the event log when the calling script ends. Enabling
        it verifies (and if needed creates) the event source registration,
        which requires administrator rights.

    .PARAMETER EventLogMinimumLevel
        Minimum level included in the Write-LogEventBuffer event log dump.

    .PARAMETER EventLogId
        Event id stamped on every event Write-LogEventBuffer writes. Pick the id
        the consuming log pipeline (e.g. a SIEM collector) filters on.

    .PARAMETER EventLogSource
        Event source name. Defaults to the module name. Blank or omitted
        leaves the current value.

    .PARAMETER EventLogName
        Name of the event log the source is registered in. Defaults to
        'Application'. Blank or omitted leaves the current value.

    .EXAMPLE
        Set-LogConfig

        First call at module load: creates the context with all defaults.

    .EXAMPLE
        Set-LogConfig -LogPath 'C:\Logs' -HostMinimumLevel Debug

        Enables a log file at 'C:\Logs\<ModuleName>.log' (creating the folder
        if needed) and lowers the console threshold to Debug, in one call.

    .EXAMPLE
        Set-LogConfig -MemoryMaxEntries 5000

        Raises the in-memory buffer cap; every other option keeps its value.

    .EXAMPLE
        Set-LogConfig -EventLogEnabled $true -EventLogId 4242

        Arms the end-of-run event log dump with event id 4242, registering the
        module-name event source in the Application log when missing.

    .OUTPUTS
        None. This function does not return a value.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Internal logging config setter; not a user-facing state-changer.')]
    param(
        [bool]$MemoryEnabled,

        [ValidateSet('Trace', 'Debug', 'Information', 'Warning', 'Error', 'Critical')]
        [string]$MemoryMinimumLevel,

        [ValidateRange(1, 1000000)]
        [int]$MemoryMaxEntries,

        [bool]$HostEnabled,

        [ValidateSet('Trace', 'Debug', 'Information', 'Warning', 'Error', 'Critical')]
        [string]$HostMinimumLevel,

        [bool]$FileEnabled,

        [ValidateSet('Trace', 'Debug', 'Information', 'Warning', 'Error', 'Critical')]
        [string]$FileMinimumLevel,

        [string]$LogPath,

        [ValidateRange(1, 1048576)]
        [int]$FileMaxSizeKB,

        [ValidateRange(1, 1048576)]
        [int]$FileRetainSizeKB,

        [bool]$EventLogEnabled,

        [ValidateSet('Trace', 'Debug', 'Information', 'Warning', 'Error', 'Critical')]
        [string]$EventLogMinimumLevel,

        [ValidateRange(1, 65535)]
        [int]$EventLogId,

        [string]$EventLogSource,

        [string]$EventLogName
    )

    # The module name doubles as the default log file name and the default
    # event source; resolve it once here.
    $moduleName = $MyInvocation.MyCommand.ModuleName
    if ([string]::IsNullOrWhiteSpace($moduleName)) { $moduleName = 'PowerShell' }

    # Context creation: the one place logging defaults are defined. This must
    # run before the first Write-Log call; there is no lazy fallback elsewhere.
    $existing = Get-Variable -Name 'LogContext' -Scope Script -ErrorAction SilentlyContinue
    if ($existing) {
        $ctx = $existing.Value
    }
    else {
        $ctx = @{
            LevelNames = @('Trace', 'Debug', 'Information', 'Warning', 'Error', 'Critical')
            Memory     = @{
                Enabled      = $true
                MinimumLevel = 'Trace'
                MaxEntries   = 1000
            }
            Host       = @{
                Enabled      = $true
                MinimumLevel = 'Information'
            }
            File       = @{
                Enabled      = $false
                MinimumLevel = 'Trace'
                Path         = $null
                MaxSizeKB    = 5120
                RetainSizeKB = 4096
            }
            EventLog   = @{
                Enabled      = $false
                MinimumLevel = 'Information'
                LogName      = 'Application'
                Source       = $moduleName
                EventId      = 1000
            }
            RunStart   = Get-Date
            Buffer     = New-Object -TypeName 'System.Collections.Generic.Queue[object]'
            HostColors = @{
                Trace    = 'DarkGray'
                Debug    = 'DarkGray'
                Warning  = 'Yellow'
                Error    = 'Red'
                Critical = 'Magenta'
            }
        }
        New-Variable -Name 'LogContext' -Value $ctx -Scope Script
    }

    $bound = $PSBoundParameters
    $boundDesc = ($bound.GetEnumerator() | Sort-Object -Property Key |
            ForEach-Object { "$($_.Key)=$($_.Value)" }) -join '; '
    Write-Log -Level Trace -Message "Set-LogConfig parameters: $boundDesc."

    # Merge bound file options over current state, then validate before
    # committing. Local names deliberately differ from the parameter names:
    # PowerShell variable names are case-insensitive, so a local $filePath
    # would alias a parameter and clobber it.
    $newEnabled = $ctx.File.Enabled
    if ($bound.ContainsKey('FileEnabled')) { $newEnabled = $FileEnabled }
    $newPath = $ctx.File.Path
    $newMax = $ctx.File.MaxSizeKB
    if ($bound.ContainsKey('FileMaxSizeKB')) { $newMax = $FileMaxSizeKB }
    $newRetain = $ctx.File.RetainSizeKB
    if ($bound.ContainsKey('FileRetainSizeKB')) { $newRetain = $FileRetainSizeKB }

    # Resolve LogPath to a full log file path. Failures from here down are
    # environmental, not caller bugs; record the first one and skip the
    # file-target commit below instead of aborting the calling command.
    $fileError = $null
    $suppliedPath = -not [string]::IsNullOrWhiteSpace($LogPath)
    if ($suppliedPath) {
        # A log path baked into a deployed script, or injected by the platform
        # that deployed it, carries %Name% references that nothing else
        # expands. Do it here, before the path is resolved, so every message
        # below reports the path the file target actually uses.
        $LogPath = [Environment]::ExpandEnvironmentVariables($LogPath)
        try {
            $pathIntrinsics = $ExecutionContext.SessionState.Path
            $full = $pathIntrinsics.GetUnresolvedProviderPathFromPSPath($LogPath)
            $defaultName = "$moduleName.log"

            if (Test-Path -LiteralPath $full -PathType Leaf) {
                $newPath = $full
            }
            elseif (Test-Path -LiteralPath $full -PathType Container) {
                $newPath = Join-Path -Path $full -ChildPath $defaultName
            }
            elseif ([System.IO.Path]::GetExtension($full)) {
                # Nonexistent with a file extension: treat as a file path.
                $newPath = $full
            }
            else {
                # Nonexistent with no extension: treat as a directory.
                $newPath = Join-Path -Path $full -ChildPath $defaultName
            }
            Write-Log -Level Debug -Message "LogPath '$LogPath' resolved to: $newPath."

            # Supplying a path implies turning the file target on, unless the
            # caller said otherwise in this same call.
            if (-not $bound.ContainsKey('FileEnabled')) { $newEnabled = $true }
        }
        catch {
            $fileError = "Cannot resolve log path '$LogPath' against current " +
            "location '$((Get-Location).Path)': $($_.Exception.Message)"
        }
    }

    # Invalid-argument validation: these are caller bugs and throw. A rejected
    # call leaves the configuration unchanged.
    if ($newRetain -ge $newMax) {
        throw ("FileRetainSizeKB ($newRetain) must be less than " +
            "FileMaxSizeKB ($newMax).")
    }
    if ($newEnabled -and -not $newPath -and -not $fileError) {
        throw ('Set-LogConfig: file logging cannot be enabled without a path. ' +
            "Arguments: FileEnabled=$($bound.ContainsKey('FileEnabled')), " +
            "LogPath=$($bound.ContainsKey('LogPath')). " +
            "Final state after config merge: FileEnabled=$newEnabled, Path='$newPath'.")
    }

    # Create the directory and probe the log file whenever this call touches
    # the file target. Write-Log swallows write errors by design (logging must
    # never disrupt the caller), so an unusable path -- reserved device name,
    # ACL denial, collision with a directory -- must fail visibly here or it
    # never fails at all.
    $touchesFile = $suppliedPath -or $bound.ContainsKey('FileEnabled')
    if (-not $fileError -and $newEnabled -and $newPath -and $touchesFile) {
        try {
            $dir = Split-Path -Path $newPath -Parent
            if ($dir -and -not (Test-Path -LiteralPath $dir)) {
                $newItemParams = @{
                    ItemType    = 'Directory'
                    Path        = $dir
                    Force       = $true
                    ErrorAction = 'Stop'
                }
                $null = New-Item @newItemParams
            }
            $stream = [System.IO.File]::Open(
                $newPath,
                [System.IO.FileMode]::Append,
                [System.IO.FileAccess]::Write,
                [System.IO.FileShare]::ReadWrite)
            $stream.Dispose()
        }
        catch {
            $fileError = "Cannot enable file logging at '$newPath': " +
            "$($_.Exception.Message)"
        }
    }

    # Commit memory options.
    if ($bound.ContainsKey('MemoryEnabled')) { $ctx.Memory.Enabled = $MemoryEnabled }
    if ($bound.ContainsKey('MemoryMinimumLevel')) { $ctx.Memory.MinimumLevel = $MemoryMinimumLevel }
    if ($bound.ContainsKey('MemoryMaxEntries')) {
        $ctx.Memory.MaxEntries = $MemoryMaxEntries
        while ($ctx.Buffer.Count -gt $ctx.Memory.MaxEntries) {
            $null = $ctx.Buffer.Dequeue()
        }
    }

    # Commit host options.
    if ($bound.ContainsKey('HostEnabled')) { $ctx.Host.Enabled = $HostEnabled }
    if ($bound.ContainsKey('HostMinimumLevel')) { $ctx.Host.MinimumLevel = $HostMinimumLevel }

    # Merge bound event-log options over current state; a blank source or log
    # name leaves the current value, like a blank LogPath does for the file
    # target. Enabling the target -- or repointing an enabled one -- checks
    # the source registration now, at setup: Write-LogEventBuffer runs at script
    # exit, where a broken target could no longer be reported usefully.
    $newEvtEnabled = $ctx.EventLog.Enabled
    if ($bound.ContainsKey('EventLogEnabled')) { $newEvtEnabled = $EventLogEnabled }
    $newEvtSource = $ctx.EventLog.Source
    $suppliedEvtSource = -not [string]::IsNullOrWhiteSpace($EventLogSource)
    if ($suppliedEvtSource) { $newEvtSource = $EventLogSource }
    $newEvtLog = $ctx.EventLog.LogName
    $suppliedEvtLog = -not [string]::IsNullOrWhiteSpace($EventLogName)
    if ($suppliedEvtLog) { $newEvtLog = $EventLogName }

    $eventError = $null
    $touchesEvent = $bound.ContainsKey('EventLogEnabled') -or
    $suppliedEvtSource -or $suppliedEvtLog
    if ($newEvtEnabled -and $touchesEvent) {
        $eventError = Register-LogEventSource -Source $newEvtSource -LogName $newEvtLog
    }

    # Commit event-log options, or report the environmental registration
    # failure and leave the event target exactly as it was.
    if ($eventError) {
        Write-Log -Level Error -Message $eventError
    }
    else {
        if ($bound.ContainsKey('EventLogMinimumLevel')) {
            $ctx.EventLog.MinimumLevel = $EventLogMinimumLevel
        }
        if ($bound.ContainsKey('EventLogId')) { $ctx.EventLog.EventId = $EventLogId }
        $ctx.EventLog.Source = $newEvtSource
        $ctx.EventLog.LogName = $newEvtLog
        $ctx.EventLog.Enabled = $newEvtEnabled
    }

    # Commit file options, or report the environmental failure and leave the
    # file target exactly as it was.
    if ($fileError) {
        Write-Log -Level Error -Message $fileError
        return
    }
    if ($bound.ContainsKey('FileMinimumLevel')) { $ctx.File.MinimumLevel = $FileMinimumLevel }
    $ctx.File.Path = $newPath
    $ctx.File.MaxSizeKB = $newMax
    $ctx.File.RetainSizeKB = $newRetain
    $ctx.File.Enabled = $newEnabled
    if ($suppliedPath -and $newEnabled) {
        Write-Log -Level Debug -Message "File logging enabled at: $newPath."
    }
}
