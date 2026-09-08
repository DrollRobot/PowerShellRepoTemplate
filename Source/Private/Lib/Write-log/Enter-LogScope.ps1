[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseDeclaredVarsMoreThanAssignments', 'ScriptVersion')]
$ScriptVersion = '1.0.0'

function Enter-LogScope {
    <#
    .SYNOPSIS
        Opens a log scope: marks the start of a run so its log lines become one
        event log entry.

    .DESCRIPTION
        Paired with Exit-LogScope around the body of every public command:

            process {
                Enter-LogScope -LogPath $LogPath -HostMinimumLevel $LogLevel
                try {
                    # command body; early returns are fine
                }
                finally {
                    Exit-LogScope
                }
            }

        The pair is reference counted. A command that calls another command
        opens a nested scope, and only the outermost Exit-LogScope flushes, so
        one run produces one event no matter how deep the call graph goes. No
        command needs to know whether it is the outermost one.

        Opening the outermost scope (depth 0 -> 1) clears the memory buffer so
        the event carries only this run's lines, stamps RunStart, and then
        applies any supplied configuration. Clearing first is deliberate: it
        keeps Set-LogConfig's own output -- including an event source
        registration failure, which is reported as an Error -- inside the run
        it belongs to.

        A nested call ignores LogPath and HostMinimumLevel. That is what lets a
        command be called directly (where its own log settings apply) and from
        another command (where the caller's settings win) without a
        $PSBoundParameters guard at the call site. A nested command that must
        change some other setting has to call Set-LogConfig itself, and that
        call is not depth aware.

        Error contract: calling before Set-LogConfig has created the context is
        a programmer error and throws, matching Write-LogEventBuffer. In a
        built module Source/Suffix.ps1 configures logging at import, so this
        cannot happen; in a standalone script it means the generated setup is
        missing.

    .PARAMETER LogPath
        Path to a log directory or log file, forwarded to Set-LogConfig when
        this is the outermost scope. Blank or omitted leaves the file target
        untouched. Ignored when a scope is already open.

    .PARAMETER HostMinimumLevel
        Minimum level written to the console, forwarded to Set-LogConfig when
        this is the outermost scope. Blank or omitted leaves the console
        threshold untouched, so a command whose own -LogLevel parameter has no
        default can forward it unconditionally. Ignored when a scope is already
        open. Not validated here: Set-LogConfig owns the level names and
        rejects anything else.

    .EXAMPLE
        Enter-LogScope
        try { Invoke-MainWork } finally { Exit-LogScope }

        Wraps a run with no per-run logging options.

    .EXAMPLE
        Enter-LogScope -LogPath 'C:\Logs' -HostMinimumLevel Debug
        try { Invoke-MainWork } finally { Exit-LogScope }

        Wraps a run, enabling a log file and lowering the console threshold for
        the duration of the outermost scope.

    .OUTPUTS
        None. This function does not return a value.
    #>
    [CmdletBinding()]
    param(
        [string]$LogPath,

        [string]$HostMinimumLevel
    )

    # Entering a scope before configuration is a programmer error that must
    # fail loud; there is no lazy context creation anywhere in this library.
    $ctxVar = Get-Variable -Name 'LogContext' -Scope Script -ErrorAction SilentlyContinue
    if (-not $ctxVar) {
        throw ('Enter-LogScope: no logging context exists. ' +
            'Call Set-LogConfig before any other logging function.')
    }
    $ctx = $ctxVar.Value

    # Older contexts (created before scopes existed) have no depth key.
    if (-not $ctx.ContainsKey('ScopeDepth')) { $ctx.ScopeDepth = 0 }

    if ($ctx.ScopeDepth -eq 0) {
        # Outermost scope: this run starts here, so the buffer holds this run
        # and nothing else. Clear before configuring, so Set-LogConfig's own
        # log lines belong to this run rather than being wiped by it.
        $ctx.Buffer.Clear()
        $ctx.RunStart = Get-Date

        # Remember who opened the run. Write-LogEventBuffer cannot work this
        # out for itself at flush time: by then the stack shows Exit-LogScope,
        # not the command the operator invoked.
        $ctx.ScopeCommand = $null
        try {
            $stack = Get-PSCallStack
            if ($stack.Count -gt 1) { $ctx.ScopeCommand = $stack[1].Command }
        }
        catch {
            $ctx.ScopeCommand = $null
        }

        # Blank means "leave the current value", so a command whose own
        # -LogLevel/-LogPath went unbound can forward them unconditionally and
        # still not disturb anything.
        $configParams = @{}
        if (-not [string]::IsNullOrWhiteSpace($LogPath)) {
            $configParams['LogPath'] = $LogPath
        }
        if (-not [string]::IsNullOrWhiteSpace($HostMinimumLevel)) {
            $configParams['HostMinimumLevel'] = $HostMinimumLevel
        }
        if ($configParams.Count -gt 0) {
            Set-LogConfig @configParams
        }
    }

    $ctx.ScopeDepth++

    $msg = "Enter-LogScope: log scope depth is now $($ctx.ScopeDepth)."
    Write-Log -Level Trace -Message $msg
}
