[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseDeclaredVarsMoreThanAssignments', 'ScriptVersion')]
$ScriptVersion = '2.1.0'

function Get-LogConfig {
    <#
    .SYNOPSIS
        Returns a snapshot of the current logging configuration.

    .DESCRIPTION
        Reads the module-scoped logging context and returns a copy of its
        settings for the memory, host, file, and event log targets, plus the
        current in-memory buffer count. The returned object is a snapshot:
        mutating it does not change the live configuration. Use Set-LogConfig
        to make changes. Throws if called before Set-LogConfig has created the
        context.

    .EXAMPLE
        Get-LogConfig

        Returns the current memory/host/file settings and buffer count.

    .EXAMPLE
        (Get-LogConfig).File.Path

        Returns the configured log file path (or $null when file logging is
        off).

    .OUTPUTS
        System.Management.Automation.PSCustomObject with Memory, Host, File,
        EventLog, and BufferCount members.
    #>
    [OutputType([pscustomobject])]
    param()

    $ctxVar = Get-Variable -Name 'LogContext' -Scope Script -ErrorAction SilentlyContinue
    if (-not $ctxVar) {
        throw ('Get-LogConfig: no logging context exists. ' +
            'Call Set-LogConfig before any other logging function.')
    }
    $ctx = $ctxVar.Value

    [pscustomobject]@{
        Memory      = [pscustomobject]@{
            Enabled      = $ctx.Memory.Enabled
            MinimumLevel = $ctx.Memory.MinimumLevel
            MaxEntries   = $ctx.Memory.MaxEntries
        }
        Host        = [pscustomobject]@{
            Enabled      = $ctx.Host.Enabled
            MinimumLevel = $ctx.Host.MinimumLevel
        }
        File        = [pscustomobject]@{
            Enabled      = $ctx.File.Enabled
            MinimumLevel = $ctx.File.MinimumLevel
            Path         = $ctx.File.Path
            MaxSizeKB    = $ctx.File.MaxSizeKB
            RetainSizeKB = $ctx.File.RetainSizeKB
        }
        EventLog    = [pscustomobject]@{
            Enabled      = $ctx.EventLog.Enabled
            MinimumLevel = $ctx.EventLog.MinimumLevel
            LogName      = $ctx.EventLog.LogName
            Source       = $ctx.EventLog.Source
            EventId      = $ctx.EventLog.EventId
        }
        BufferCount = $ctx.Buffer.Count
    }
}
