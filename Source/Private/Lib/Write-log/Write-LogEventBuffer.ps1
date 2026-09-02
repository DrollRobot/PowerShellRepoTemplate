[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseDeclaredVarsMoreThanAssignments', 'ScriptVersion')]
$ScriptVersion = '1.3.0'

function Write-LogEventBuffer {
    <#
    .SYNOPSIS
        Dumps the in-memory log buffer to the Windows event log as one or more
        JSON events.

    .DESCRIPTION
        Message format note: the output format is designed to feed a log parser
        that extracts fields from a series of 'property:value' pairs -- colon
        with no space after the property name -- separated by newlines, and
        that expects 'action' as the first property, e.g.:

            action:<value>
            some_property:<value>
            another_property:<value>
            script_log:{"Json":"envelope"}

        The JSON envelope rides on the final line as the value of the
        script_log property. The prefix properties are duplicated inside the
        JSON payload so the parsed fields and the archived document carry the
        same data.

        Error contract: calling with no logging context is a programmer error
        and throws. A failed event write is environmental and must not mask
        the exception a surrounding finally block may be unwinding: it is
        reported as a non-terminating error on the error stream, remaining
        chunks are skipped, and control returns to the caller.

    .EXAMPLE
        try {
            Invoke-MainWork
        }
        finally {
            Write-LogEventBuffer
        }

        Flushes the memory log to the event log on every exit path; a no-op
        unless Set-LogConfig has enabled the event log target.

    .OUTPUTS
        None. This function does not return a value.
    #>
    [CmdletBinding()]
    param()

    # Flushing before configuration is a programmer error that must fail loud.
    $ctxVar = Get-Variable -Name 'LogContext' -Scope Script -ErrorAction SilentlyContinue
    if (-not $ctxVar) {
        throw ('Write-LogEventBuffer: no logging context exists. ' +
            'Call Set-LogConfig before the first logging call.')
    }
    $ctx = $ctxVar.Value

    if (-not $ctx.EventLog.Enabled) {
        return
    }

    # Snapshot the buffer, filter by the target's minimum level, and track the
    # worst included level for the event entry type in one pass.
    $minIndex = [Array]::IndexOf($ctx.LevelNames, $ctx.EventLog.MinimumLevel)
    $entries = New-Object -TypeName 'System.Collections.Generic.List[object]'
    $worstIndex = -1
    foreach ($entry in $ctx.Buffer.ToArray()) {
        $levelIndex = [Array]::IndexOf($ctx.LevelNames, $entry.Level)
        if ($levelIndex -lt $minIndex) { continue }
        $entries.Add($entry)
        if ($levelIndex -gt $worstIndex) { $worstIndex = $levelIndex }
    }

    $entryType = 'Information'
    if ($worstIndex -ge [Array]::IndexOf($ctx.LevelNames, 'Error')) {
        $entryType = 'Error'
    }
    elseif ($worstIndex -ge [Array]::IndexOf($ctx.LevelNames, 'Warning')) {
        $entryType = 'Warning'
    }

    # Best-effort caller name for the action/script_name prefix properties,
    # the same way Write-Log resolves an entry's Source. The caller is the
    # command whose finally block is flushing (e.g. the deployed script's
    # public function).
    $caller = '<unknown>'
    try {
        $stack = Get-PSCallStack
        if ($stack.Count -gt 1) {
            $caller = $stack[1].Command
        }
    }
    catch {
        $caller = '<unknown>'
    }

    # Action is the verb of the calling command (Install-Adlumin -> Install);
    # the full command name travels in script_name.
    $action = $caller
    if ($caller -match '^([^-]+)-') { $action = $Matches[1] }

    $worstLevel = 'Information'
    if ($worstIndex -ge 0) { $worstLevel = $ctx.LevelNames[$worstIndex] }

    $flushId = [guid]::NewGuid().ToString()

    # Parser prefix: 'property:value' pairs, no space after the colon, one
    # per line, 'action' first (see the message format note above). The
    # chunk numbers are stamped per event in the loop below; the budget
    # reserves room for the largest values they can take.
    $nl = "`r`n"
    $prefixBase = "action:$action$nl" + "script_name:$caller$nl" +
    "highest_log_level:$worstLevel$nl" + "run_id:$flushId$nl"
    $prefixMax = $prefixBase + "chunk:99999$nl" + "chunk_count:99999$nl" +
    'script_log:'

    # The event log rejects messages over 32766 characters; budget below that
    # so the prefix and envelope always fit around the entries.
    $chunkBudget = 30000 - $prefixMax.Length

    # Serialize each entry on its own: chunk boundaries must fall between
    # entries, so per-entry JSON is the unit of packing. Timestamps are
    # rendered as ISO-8601 strings up front -- Windows PowerShell 5.1's
    # ConvertTo-Json turns raw DateTime values into '\/Date(n)\/'.
    $entryJsonList = New-Object -TypeName 'System.Collections.Generic.List[string]'
    foreach ($entry in $entries) {
        $obj = [ordered]@{
            Timestamp = $entry.Timestamp.ToString('o')
            Level     = $entry.Level
            Source    = $entry.Source
            Message   = $entry.Message
        }
        $json = ConvertTo-Json -InputObject $obj -Compress
        # An entry bigger than a whole chunk cannot be split across events;
        # shrink its message until it fits. The only place anything is
        # dropped. Halving converges: each pass halves the message, then adds
        # the fixed-size marker.
        while ($json.Length -gt $chunkBudget -and $obj.Message.Length -gt 1) {
            $keep = [int][Math]::Floor($obj.Message.Length / 2)
            $obj.Message = $obj.Message.Substring(0, $keep) + '...[truncated]'
            $json = ConvertTo-Json -InputObject $obj -Compress
        }
        $entryJsonList.Add($json)
    }

    # Pack the serialized entries into chunks. An empty buffer still yields
    # one (empty) chunk: an enabled target always writes evidence of the run.
    $chunkList = New-Object -TypeName 'System.Collections.Generic.List[object]'
    $current = New-Object -TypeName 'System.Collections.Generic.List[string]'
    $currentSize = 0
    foreach ($json in $entryJsonList) {
        if ($current.Count -gt 0 -and ($currentSize + $json.Length + 1) -gt $chunkBudget) {
            $chunkList.Add($current)
            $current = New-Object -TypeName 'System.Collections.Generic.List[string]'
            $currentSize = 0
        }
        $current.Add($json)
        $currentSize += $json.Length + 1
    }
    if ($current.Count -gt 0 -or $chunkList.Count -eq 0) {
        $chunkList.Add($current)
    }

    $runStart = $ctx.RunStart.ToString('o')
    $chunkCount = $chunkList.Count

    for ($i = 0; $i -lt $chunkCount; $i++) {
        $prefix = $prefixBase + "chunk:$($i + 1)$nl" +
        "chunk_count:$chunkCount$nl"

        # The envelope is assembled by hand: the entries are already JSON,
        # and every envelope value (command name, level name, GUID, ISO-8601
        # stamp, integers) is JSON-safe without escaping.
        $payload = '{"Action":"' + $action + '","ScriptName":"' + $caller +
        '","HighestLogLevel":"' + $worstLevel +
        '","RunId":"' + $flushId + '","RunStart":"' + $runStart +
        '","Chunk":' + ($i + 1) + ',"ChunkCount":' + $chunkCount +
        ',"TotalEntries":' + $entries.Count +
        ',"Entries":[' + ($chunkList[$i] -join ',') + ']}'

        $eventParams = @{
            Source    = $ctx.EventLog.Source
            EventId   = $ctx.EventLog.EventId
            EntryType = $entryType
            Message   = $prefix + 'script_log:' + $payload
        }
        try {
            Write-LogEvent @eventParams
        }
        catch {
            # Often running inside a finally during exception unwind: report,
            # never throw, and stop -- later chunks would fail the same way.
            Write-Error -Message ("Failed to write log buffer chunk " +
                "$($i + 1) of $chunkCount to event log " +
                "'$($ctx.EventLog.LogName)' (source " +
                "'$($ctx.EventLog.Source)', event id " +
                "$($ctx.EventLog.EventId)): $($_.Exception.Message)")
            return
        }
    }
}
