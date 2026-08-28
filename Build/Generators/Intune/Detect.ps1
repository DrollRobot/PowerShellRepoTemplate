<#
.SYNOPSIS
    Intune custom detection script for a scheduled-script package.

.DESCRIPTION
    Detection template consumed by ConvertTo-IntuneWinPackage; do not edit a
    generated copy, edit this template or the generator entry in
    Source\Build.psd1 and rebuild. Uploaded separately in the Intune console
    (not packaged).

    Reports the app as installed only while the registry build id stamped by
    Install.ps1 equals the one baked into this script, the deployed payload's
    SHA256 equals the hash baked in at build time, and the scheduled task
    exists, is enabled, and runs as SYSTEM. Every package setting is baked in
    at build time and every build carries a new id, so uploading a new
    package and its Detect.ps1 reinstalls on every device. With a Required
    assignment, any failed check makes Intune reinstall the app on its next
    check-in: that is the self-healing loop, and it is eventual (roughly
    every 8 hours), not instant.

    Intune's contract: stdout plus exit 0 means detected; exit 0 with no
    output means not detected; a nonzero exit is a detection ERROR, not "not
    installed", so this script always exits 0.

    Which check failed is recorded in the package's deployment log (LogPath in
    the generated constants) through the injected Write-PackageLog function,
    never on stdout: 'Detected' is the only thing this script may print, since
    any other output would report the app as installed.

    This template is valid Windows PowerShell so it can be reviewed and lint
    checked directly. Before packaging, the generator replaces the marked
    comment lines with the generated constants (which include the build id
    and the expected payload hash) and the log function. Intune must run this
    script 64-bit: set "Run script as 32-bit process on 64-bit clients" to No
    in the detection rule.

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Detect.ps1

    Prints 'Detected' when the deployment is intact; prints nothing when it
    needs a reinstall.

.OUTPUTS
    System.String. 'Detected' when every check passes; no output otherwise.
#>
[CmdletBinding()]
param()

# Template file version, read by Scripts\Compare-Template.ps1, which keeps a
# child repo's copy of this template in sync by version.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseDeclaredVarsMoreThanAssignments', 'ScriptVersion')]
$ScriptVersion = '1.0.0'

$ErrorActionPreference = 'Stop'

#{{CONSTANTS}}

#{{FUNCTIONS}}

Write-PackageLog -Message "Detection started. Build $BuildId."

try {
    $Stamp = Get-ItemProperty -Path $VersionRegKey -ErrorAction Stop
    if ($Stamp.BuildId -ne $BuildId) {
        Write-PackageLog -Message ("Not detected: registry build id is " +
            "$($Stamp.BuildId), expected $BuildId.")
        exit 0
    }
    if (-not (Test-Path -Path $PayloadPath -PathType Leaf)) {
        Write-PackageLog -Message "Not detected: payload $PayloadPath is missing."
        exit 0
    }
    $PayloadHash = (Get-FileHash -Path $PayloadPath -Algorithm SHA256).Hash
    if ($PayloadHash -ne $ExpectedPayloadHash) {
        Write-PackageLog -Message ("Not detected: payload hash is " +
            "$PayloadHash, expected $ExpectedPayloadHash.")
        exit 0
    }
    $GetTaskParams = @{
        TaskName    = $TaskName
        TaskPath    = $TaskPath
        ErrorAction = 'SilentlyContinue'
    }
    $Task = Get-ScheduledTask @GetTaskParams
    if (-not $Task) {
        Write-PackageLog -Message ("Not detected: scheduled task " +
            "$TaskPath$TaskName does not exist.")
        exit 0
    }
    if ("$($Task.State)" -eq 'Disabled') {
        Write-PackageLog -Message ("Not detected: scheduled task " +
            "$TaskPath$TaskName is disabled.")
        exit 0
    }
    if ($Task.Principal.UserId -ne 'SYSTEM') {
        Write-PackageLog -Message ("Not detected: scheduled task runs as " +
            "$($Task.Principal.UserId), expected SYSTEM.")
        exit 0
    }
    Write-PackageLog -Message "Detected: $PackageName $PackageVersion is intact."
    Write-Output 'Detected'
    exit 0
} catch {
    # Any unexpected failure reads as "not detected", never as an error.
    Write-PackageLog -Level Error -Message ("Not detected: detection failed " +
        "with $($_.Exception.Message)")
    exit 0
}
