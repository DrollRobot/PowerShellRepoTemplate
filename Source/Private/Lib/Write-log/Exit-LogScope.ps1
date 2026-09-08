[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseDeclaredVarsMoreThanAssignments', 'ScriptVersion')]
$ScriptVersion = '1.0.0'

function Exit-LogScope {
    <#
    .SYNOPSIS
        Closes a log scope, flushing the run to the Windows event log when the
        outermost one closes.

    .DESCRIPTION
        The other half of the Enter-LogScope pair. Belongs in a finally block
        so it runs on every exit path -- success, early return, and throw:

            process {
                Enter-LogScope -LogPath $LogPath -HostMinimumLevel $LogLevel
                try {
                    # command body
                }
                finally {
                    Exit-LogScope
                }
            }

        Decrements the scope depth. Only the return to zero -- the outermost
        command finishing -- calls Write-LogEventBuffer, so a run that spans
        several commands produces one event containing all of their log lines.
        A nested close does nothing but decrement.

        Error contract: this runs inside a finally that may be unwinding an
        exception, so it must never mask one. Calling it with no scope open is
        an unbalanced pair, which is a caller bug, but it is reported as a
        Warning log line rather than a throw and does not flush -- emitting
        there would duplicate an event the matching Exit-LogScope already
        wrote. Calling it before Set-LogConfig has created the context throws,
        matching Enter-LogScope and Write-LogEventBuffer; in a built module
        that cannot happen. Write-LogEventBuffer reports a failed event write
        as a non-terminating error for the same reason.

    .EXAMPLE
        Enter-LogScope
        try { Invoke-MainWork } finally { Exit-LogScope }

        Flushes the run to the event log on every exit path, including a throw.

    .EXAMPLE
        (Get-LogConfig).ScopeDepth

        Returns 0 once every scope has closed. A non-zero value after a command
        returns means an Enter-LogScope had no matching Exit-LogScope, and
        nothing will flush for the rest of the session.

    .OUTPUTS
        None. This function does not return a value.
    #>
    [CmdletBinding()]
    param()

    # Closing a scope before configuration is a programmer error that must
    # fail loud, the same as Enter-LogScope.
    $ctxVar = Get-Variable -Name 'LogContext' -Scope Script -ErrorAction SilentlyContinue
    if (-not $ctxVar) {
        throw ('Exit-LogScope: no logging context exists. ' +
            'Call Set-LogConfig before any other logging function.')
    }
    $ctx = $ctxVar.Value

    # Older contexts (created before scopes existed) have no depth key.
    if (-not $ctx.ContainsKey('ScopeDepth')) { $ctx.ScopeDepth = 0 }

    if ($ctx.ScopeDepth -le 0) {
        # Unbalanced pair. Never flush here: the scope that opened this run has
        # already closed and written its event, so a second dump would repeat
        # every line of it.
        $ctx.ScopeDepth = 0
        $msg = 'Exit-LogScope: called with no log scope open. ' +
        'Every Enter-LogScope needs a matching Exit-LogScope in a finally block.'
        Write-Log -Level Warning -Message $msg
        return
    }

    $ctx.ScopeDepth--

    $msg = "Exit-LogScope: log scope depth is now $($ctx.ScopeDepth)."
    Write-Log -Level Trace -Message $msg

    if ($ctx.ScopeDepth -eq 0) {
        Write-LogEventBuffer
        # The run is over; the next Enter-LogScope records its own command.
        $ctx.ScopeCommand = $null
    }
}
