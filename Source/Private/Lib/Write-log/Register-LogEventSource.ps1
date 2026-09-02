[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseDeclaredVarsMoreThanAssignments', 'ScriptVersion')]
$ScriptVersion = '1.0.0'

function Register-LogEventSource {
    <#
    .SYNOPSIS
        Ensures a Windows event source exists and is bound to the given log.

    .DESCRIPTION
        Setup probe for the event log target, called by Set-LogConfig when the
        target is enabled or repointed. Checks whether the source is
        registered; registers it in the requested log when missing (an HKLM
        registry write, which requires administrator rights); reports a
        mismatch when the source is already bound to a different log (a
        source's log binding cannot be changed here).

        Wraps the [System.Diagnostics.EventLog] statics so callers and tests
        have a mockable seam -- Pester cannot mock static .NET methods.

        Never throws: returns $null on success or a failure-description
        string, matching Set-LogConfig's probe style where an environmental
        failure is reported by the caller without aborting the command.

    .PARAMETER Source
        The event source name to check or register.

    .PARAMETER LogName
        The event log the source must be registered in (e.g. 'Application').

    .EXAMPLE
        Register-LogEventSource -Source 'MyModule' -LogName 'Application'

        Returns $null when 'MyModule' is (now) registered in the Application
        log, or a description of why it could not be.

    .OUTPUTS
        System.String describing the failure, or $null on success.
    #>
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Source,

        [Parameter(Mandatory)]
        [string]$LogName
    )

    try {
        if ([System.Diagnostics.EventLog]::SourceExists($Source)) {
            $boundLog = [System.Diagnostics.EventLog]::LogNameFromSourceName($Source, '.')
            if ($boundLog -ne $LogName) {
                return ("Event source '$Source' is already registered to log " +
                    "'$boundLog', not '$LogName'. Use that log, another " +
                    "source name, or remove the existing registration.")
            }
            return $null
        }
        [System.Diagnostics.EventLog]::CreateEventSource($Source, $LogName)
        return $null
    }
    catch {
        return ("Cannot register event source '$Source' in log '$LogName': " +
            "$($_.Exception.Message)")
    }
}
