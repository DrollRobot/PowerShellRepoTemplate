function Write-PackageLog {
    <#
    .SYNOPSIS
        Appends one line to the package's deployment log.

    .DESCRIPTION
        Injected verbatim into the generated Install.ps1, Uninstall.ps1, and
        Detect.ps1, so all three write one human-readable log with the same
        format. The log path, the script tag, and the size cap come from the
        generated constants block.

        Each line is "<UTC timestamp> [<script>] <LEVEL> <message>". The
        first line of every run records the build id, so the log answers
        which build a device actually executed.

        Size is bounded by rename, not by rewriting: when the log exceeds
        LogMaxBytes the current file is moved over "<name>.1<ext>", replacing
        the previous generation, and a fresh file starts. Peak disk use is
        twice the cap and rotation costs one metadata operation.

        The log path is baked into the constants block as a literal, so a
        %Name% environment variable reference in it arrives here unexpanded.
        It is expanded before any file work, so a path written against the
        endpoint's environment resolves there rather than on the machine that
        built the package.

        Logging never fails the deployment: a write that cannot land is
        reported on stderr and execution continues, because the deployment's
        own success does not depend on the record of it. Every other write in
        these scripts stays strict.

    .PARAMETER Message
        The text to log. Written as given, on one line.

    .PARAMETER Level
        Severity tag: Info (default), Warn, or Error.

    .EXAMPLE
        Write-PackageLog -Message 'Registered scheduled task as SYSTEM.'

        Appends an Info line.

    .EXAMPLE
        Write-PackageLog -Level Error -Message "Task missing after register."

        Appends an Error line before the caller throws.

    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Message,

        [ValidateSet('Info', 'Warn', 'Error')]
        [string]$Level = 'Info'
    )

    # Template file version, read by Scripts\Compare-Template.ps1, which keeps a
    # child repo's copy of this file in sync by version. Declared inside the
    # function so the copy injected into a generated package stays scoped to it.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseDeclaredVarsMoreThanAssignments', 'ScriptVersion')]
    $ScriptVersion = '1.1.0'

    $Stamp = [DateTime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ss')
    $Line = "$Stamp [$LogScript] $($Level.ToUpper()) $Message"
    $ResolvedPath = [Environment]::ExpandEnvironmentVariables($LogPath)
    try {
        $LogDir = Split-Path -Path $ResolvedPath -Parent
        if (-not (Test-Path -Path $LogDir -PathType Container)) {
            $null = New-Item -Path $LogDir -ItemType Directory -Force
        }
        $Existing = Get-Item -Path $ResolvedPath -ErrorAction SilentlyContinue
        if ($Existing -and $Existing.Length -gt $LogMaxBytes) {
            $Rotated = Join-Path -Path $LogDir -ChildPath (
                "$([System.IO.Path]::GetFileNameWithoutExtension($ResolvedPath)).1" +
                [System.IO.Path]::GetExtension($ResolvedPath))
            Move-Item -Path $ResolvedPath -Destination $Rotated -Force
        }
        Add-Content -Path $ResolvedPath -Value $Line -Encoding UTF8
    } catch {
        $FailureParams = @{
            Message     = "Log write to $ResolvedPath failed: $($_.Exception.Message)"
            ErrorAction = 'Continue'
        }
        Write-Error @FailureParams
    }
}
