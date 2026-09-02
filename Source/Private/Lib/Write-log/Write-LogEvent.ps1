[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseDeclaredVarsMoreThanAssignments', 'ScriptVersion')]
$ScriptVersion = '1.0.0'

function Write-LogEvent {
    <#
    .SYNOPSIS
        Writes one entry to the Windows event log.

    .DESCRIPTION
        Thin wrapper over [System.Diagnostics.EventLog]::WriteEntry, used by
        Write-LogEventBuffer for each chunk it emits. The .NET API is used instead
        of the Write-EventLog cmdlet because the cmdlet does not exist in
        PowerShell 7; the static method works in both Windows PowerShell 5.1
        and PowerShell 7 on Windows. Exists as its own function so callers and
        tests have a mockable seam -- Pester cannot mock static .NET methods.

        The event lands in whichever log the source is registered to (see
        Register-LogEventSource); the log name is not passed per write.
        Throws on failure -- the caller decides how to guard.

    .PARAMETER Source
        The registered event source to write under.

    .PARAMETER EventId
        The event id to stamp on the entry (1-65535).

    .PARAMETER EntryType
        The entry type shown in the event log: Information, Warning, or Error.

    .PARAMETER Message
        The message body. The event log rejects messages over 32766
        characters; the caller is responsible for staying under that.

    .EXAMPLE
        $eventParams = @{
            Source    = 'MyModule'
            EventId   = 1000
            EntryType = 'Information'
            Message   = '{"RunId":"..."}'
        }
        Write-LogEvent @eventParams

        Writes one Information event under the MyModule source.

    .OUTPUTS
        None. This function does not return a value.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Source,

        [Parameter(Mandatory)]
        [ValidateRange(1, 65535)]
        [int]$EventId,

        [Parameter(Mandatory)]
        [ValidateSet('Information', 'Warning', 'Error')]
        [string]$EntryType,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Message
    )

    $type = [System.Diagnostics.EventLogEntryType]$EntryType
    [System.Diagnostics.EventLog]::WriteEntry($Source, $Message, $type, $EventId)
}
