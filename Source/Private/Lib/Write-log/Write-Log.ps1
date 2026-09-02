[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseDeclaredVarsMoreThanAssignments', 'ScriptVersion')]
$ScriptVersion = '2.1.1'

function Write-Log {
    <#
    .SYNOPSIS
        Writes a log message to the configured targets (memory, host, file).

    .DESCRIPTION
        The single logging entry point for the module. A message is routed to any
        of three independently configurable targets: an in-memory buffer, the
        console host, and an on-disk file. Each target has its own minimum level,
        so (for example) the host can show Information and above while the file
        captures everything.

        Levels follow the .NET standard order: Trace, Debug, Information, Warning,
        Error, Critical. Console output uses PowerShell's host stream directly
        (Write-Host); the warning/verbose/debug streams are intentionally not used.

        Set-LogConfig must have been called first (the module does so at load,
        before anything logs); calling Write-Log with no context is a
        programmer error and throws. Environmental file-target failures -- an
        append or trim that fails mid-run (full disk, deleted folder, a lock
        held by another process) -- are reported as non-terminating errors on
        the error stream and do not stop the calling command. Everything else
        is deliberately unguarded: a failure in the memory or host target is a
        genuine bug and surfaces. When the file target is enabled, the file
        size is checked after each write and trimmed in place once it exceeds
        its cap, keeping roughly the newest RetainSizeKB of content (see the
        nested Limit-LogFile helper).

    .PARAMETER Message
        The text to log. An empty string is permitted (writes a blank line to the
        enabled targets).

    .PARAMETER Level
        The severity: Trace, Debug, Information, Warning, Error, or Critical.
        Defaults to Information.

    .EXAMPLE
        Write-Log -Level Warning -Message 'Service did not stop cleanly.'

        Records a Warning to every enabled target whose minimum level allows it.

    .EXAMPLE
        Write-Log 'Elevation confirmed.' -Level Debug

        Records a Debug message. With default settings it is buffered in memory
        but not shown on the host.

    .OUTPUTS
        None. This function does not return a value.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSAvoidUsingWriteHost', '',
        Justification = 'Host is an explicit log target; PS streams are intentionally unused.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSAvoidOverwritingBuiltInCmdlets', '',
        Justification = 'Intentional: this module ships its own portable Write-Log.')]
    param(
        [Parameter(Mandatory, Position = 0)]
        [AllowEmptyString()]
        [string]$Message,

        [ValidateSet('Trace', 'Debug', 'Information', 'Warning', 'Error', 'Critical')]
        [string]$Level = 'Information'
    )

    # Nested helper: trims the log file in place once it grows past its cap,
    # keeping roughly the newest RetainSizeKB of lines. Only Write-Log needs it,
    # so it lives here rather than as its own command.
    function Limit-LogFile {
        param(
            [string]$Path,
            [int]$MaxSizeKB,
            [int]$RetainSizeKB
        )

        if (-not $Path -or -not (Test-Path -LiteralPath $Path)) {
            return
        }
        $info = Get-Item -LiteralPath $Path
        if ($info.Length -le ($MaxSizeKB * 1KB)) {
            return
        }
        $lines = [System.IO.File]::ReadAllLines($Path)
        if ($lines.Length -eq 0) {
            return
        }

        # Walk newest -> oldest, keeping lines until the retain budget is reached.
        $retainBytes = $RetainSizeKB * 1KB
        $accum = 0
        $startIndex = $lines.Length
        for ($i = $lines.Length - 1; $i -ge 0; $i--) {
            $lineBytes = [System.Text.Encoding]::UTF8.GetByteCount($lines[$i]) + 2
            if (($accum + $lineBytes) -gt $retainBytes) {
                break
            }
            $accum += $lineBytes
            $startIndex = $i
        }

        if ($startIndex -ge $lines.Length) {
            # Even the single newest line exceeds the retain budget; keep just it.
            $retained = @($lines[$lines.Length - 1])
        }
        else {
            $retained = $lines[$startIndex..($lines.Length - 1)]
        }

        $enc = New-Object -TypeName 'System.Text.UTF8Encoding' -ArgumentList $false
        $tmp = "$Path.tmp"
        try {
            [System.IO.File]::WriteAllLines($tmp, $retained, $enc)
            Move-Item -LiteralPath $tmp -Destination $Path -Force
        }
        finally {
            if (Test-Path -LiteralPath $tmp) {
                Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
            }
        }
    }

    # Logging before configuration is a programmer error that must fail loud.
    $ctxVar = Get-Variable -Name 'LogContext' -Scope Script -ErrorAction SilentlyContinue
    if (-not $ctxVar) {
        throw ('Write-Log: no logging context exists. ' +
            'Call Set-LogConfig before the first logging call.')
    }
    $ctx = $ctxVar.Value

    $levelIndex = [Array]::IndexOf($ctx.LevelNames, $Level)

    # Best-effort caller name for the Source field.
    $source = '<unknown>'
    try {
        $stack = Get-PSCallStack
        if ($stack.Count -gt 1) {
            $source = $stack[1].Command
        }
    }
    catch {
        $source = '<unknown>'
    }

    $entry = [pscustomobject]@{
        Timestamp = Get-Date
        Level     = $Level
        Source    = $source
        Message   = $Message
    }

    # Shared line format for the host and file targets so console output
    # matches the log file: "<stamp> [<Level>] <Source>: <Message>".
    $stamp = $entry.Timestamp.ToString('yyyy-MM-dd HH:mm:ss.fff')
    $formatted = "$stamp [$Level] $($source): $Message"

    # Memory target. Deliberately unguarded: an in-process queue insert does
    # not fail environmentally, so a failure here is a bug that must surface.
    if ($ctx.Memory.Enabled) {
        $memMin = [Array]::IndexOf($ctx.LevelNames, $ctx.Memory.MinimumLevel)
        if ($levelIndex -ge $memMin) {
            $ctx.Buffer.Enqueue($entry)
            while ($ctx.Buffer.Count -gt $ctx.Memory.MaxEntries) {
                $null = $ctx.Buffer.Dequeue()
            }
        }
    }

    # Host target. Deliberately unguarded, same reasoning as the memory target.
    if ($ctx.Host.Enabled) {
        $hostMin = [Array]::IndexOf($ctx.LevelNames, $ctx.Host.MinimumLevel)
        if ($levelIndex -ge $hostMin) {
            if ($ctx.HostColors.ContainsKey($Level)) {
                Write-Host -Object $formatted -ForegroundColor $ctx.HostColors[$Level]
            }
            else {
                Write-Host -Object $formatted
            }
        }
    }

    # File target. The one target with real environmental failure modes (full
    # disk, deleted folder, a lock held by another process), so append and trim
    # are guarded: a failure is reported as a non-terminating error on the
    # error stream and the calling command continues.
    if ($ctx.File.Enabled -and $ctx.File.Path) {
        $fileMin = [Array]::IndexOf($ctx.LevelNames, $ctx.File.MinimumLevel)
        if ($levelIndex -ge $fileMin) {
            $content = $formatted + [Environment]::NewLine
            $encoding = New-Object -TypeName 'System.Text.UTF8Encoding' -ArgumentList $false
            try {
                [System.IO.File]::AppendAllText($ctx.File.Path, $content, $encoding)
            }
            catch {
                Write-Error -Message ("Failed to write to log file " +
                    "'$($ctx.File.Path)': $($_.Exception.Message)")
                return
            }

            try {
                $info = Get-Item -LiteralPath $ctx.File.Path -ErrorAction Stop
                if ($info.Length -gt ($ctx.File.MaxSizeKB * 1KB)) {
                    $trimParams = @{
                        Path         = $ctx.File.Path
                        MaxSizeKB    = $ctx.File.MaxSizeKB
                        RetainSizeKB = $ctx.File.RetainSizeKB
                    }
                    Limit-LogFile @trimParams
                }
            }
            catch {
                Write-Error -Message ("Failed to trim log file " +
                    "'$($ctx.File.Path)': $($_.Exception.Message)")
            }
        }
    }
}
