[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseDeclaredVarsMoreThanAssignments', 'ScriptVersion')]
$ScriptVersion = '2.0.0'

function Get-LogMessage {
    <#
    .SYNOPSIS
        Returns messages held in the in-memory log buffer.

    .DESCRIPTION
        Reads the module-scoped in-memory buffer and returns its entries oldest
        first. Results can be filtered by level and limited to the most recent N
        entries. This is a diagnostics aid for tests and for inspecting recent
        activity from within the module scope; users normally read log output from
        the console or the log file rather than calling this. Throws if called
        before Set-LogConfig has created the context.

    .PARAMETER Level
        One or more levels to include. When omitted, all buffered levels are
        returned.

    .PARAMETER Last
        Return only the most recent N entries (after any level filter).

    .PARAMETER Clear
        Empty the entire buffer after the snapshot is taken and returned.

    .EXAMPLE
        Get-LogMessage -Level Warning, Error

        Returns the buffered Warning and Error entries, oldest first.

    .EXAMPLE
        Get-LogMessage -Last 20 -Clear

        Returns the 20 most recent entries, then empties the buffer.

    .OUTPUTS
        System.Management.Automation.PSCustomObject with Timestamp, Level, Source,
        and Message members.
    #>
    [OutputType([pscustomobject])]
    param(
        [ValidateSet('Trace', 'Debug', 'Information', 'Warning', 'Error', 'Critical')]
        [string[]]$Level,

        [ValidateRange(1, 1000000)]
        [int]$Last,

        [switch]$Clear
    )

    $ctxVar = Get-Variable -Name 'LogContext' -Scope Script -ErrorAction SilentlyContinue
    if (-not $ctxVar) {
        throw ('Get-LogMessage: no logging context exists. ' +
            'Call Set-LogConfig before any other logging function.')
    }
    $ctx = $ctxVar.Value
    $entries = $ctx.Buffer.ToArray()

    if ($PSBoundParameters.ContainsKey('Level')) {
        $entries = $entries | Where-Object { $Level -contains $_.Level }
    }
    if ($PSBoundParameters.ContainsKey('Last')) {
        $entries = $entries | Select-Object -Last $Last
    }

    # Emit the snapshot before clearing so -Clear does not lose the returned rows.
    $entries

    if ($Clear) {
        $ctx.Buffer.Clear()
    }
}
