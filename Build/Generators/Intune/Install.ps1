<#
.SYNOPSIS
    Installs a scheduled-script package (Intune Win32 app).

.DESCRIPTION
    Bootloader template consumed by ConvertTo-IntuneWinPackage; do not edit a
    generated copy, edit this template or the generator entry in
    Source\Build.psd1 and rebuild. Deploys the payload script to a hardened
    directory, registers a SYSTEM scheduled task that runs it, and stamps the
    package version, payload hash, and build id into the registry for the
    paired Detect.ps1 to verify. Every write is read back; the script exits 0
    only after all read-backs pass, and 1 on any failure.

    Every step is recorded in the package's own deployment log (LogPath in
    the generated constants) through the injected Write-PackageLog function.
    The first line of each run carries the build id, so the log states which
    build the device executed. A failure is logged at Error level with the
    expected and actual values, then repeated on stderr for the Intune
    Management Extension, and the script exits 1.

    The log is bounded by rotation, not by trimming: past LogMaxBytes the
    current file is renamed over "<name>.1.log" and a fresh file starts.

    This template is valid Windows PowerShell so it can be reviewed, syntax
    highlighted, and lint/syntax checked directly. Before packaging, the
    generator replaces the marked comment lines with the generated constants
    (package name, paths, task, registry key, build id, log settings, install
    settings), the log function, and the scheduled-task trigger. The
    variables those blocks define are what the body below consumes. Run this
    script 64-bit: from the 32-bit Intune Management Extension, that means
    invoking it through
    %windir%\sysnative\WindowsPowerShell\v1.0\powershell.exe.

.EXAMPLE
    %windir%\sysnative\WindowsPowerShell\v1.0\powershell.exe
        -NoProfile -ExecutionPolicy Bypass -File Install.ps1

    Intune's Win32 app install command (shown wrapped; enter it as one line).

.OUTPUTS
    None on stdout. Progress goes to the deployment log; a failure is also
    written to stderr. The exit code is 0 on success and 1 on failure.
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

Write-PackageLog -Message ("Install started. Build $BuildId, package version " +
    "$PackageVersion, 64-bit process: $([Environment]::Is64BitProcess).")

try {
    #region Host bitness
    # A 32-bit host redirects HKLM:\SOFTWARE to WOW6432Node, so the version
    # stamp would land where the 64-bit Detect.ps1 never looks and the app
    # would reinstall forever. Fail here instead of installing crooked.
    if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
        throw ('Running 32-bit on a 64-bit OS. Launch this script with ' +
            '%windir%\sysnative\WindowsPowerShell\v1.0\powershell.exe.')
    }
    Write-PackageLog -Message 'Host is a 64-bit process.'
    #endregion

    #region Install directory and ACL hardening
    $null = New-Item -Path $InstallDir -ItemType Directory -Force

    # SYSTEM executes the payload from this directory on a schedule, so a
    # user-writable ACE here is a local privilege escalation. Replace the
    # inherited DACL with SYSTEM and Administrators only.
    $Acl = New-Object -TypeName System.Security.AccessControl.DirectorySecurity
    $Acl.SetAccessRuleProtection($true, $false)
    $InheritFlags = 'ContainerInherit, ObjectInherit'
    $Inherit = [System.Security.AccessControl.InheritanceFlags]$InheritFlags
    foreach ($Identity in @('NT AUTHORITY\SYSTEM', 'BUILTIN\Administrators')) {
        $NewRuleParams = @{
            TypeName     = 'System.Security.AccessControl.FileSystemAccessRule'
            ArgumentList = @($Identity, 'FullControl', $Inherit, 'None', 'Allow')
        }
        $Rule = New-Object @NewRuleParams
        $Acl.AddAccessRule($Rule)
    }
    Set-Acl -Path $InstallDir -AclObject $Acl

    # Read back: no broad principal may hold an Allow ACE with write rights.
    $AppliedAcl = Get-Acl -Path $InstallDir
    $WriteRights = 'Write, Modify, FullControl'
    $WriteMask = [System.Security.AccessControl.FileSystemRights]$WriteRights
    $BroadPrincipals = @(
        'BUILTIN\Users'
        'Everyone'
        'NT AUTHORITY\Authenticated Users'
    )
    foreach ($AclRule in @($AppliedAcl.Access)) {
        $RuleId = $AclRule.IdentityReference.Value
        if ($BroadPrincipals -contains $RuleId -and
            $AclRule.AccessControlType -eq 'Allow' -and
            ($AclRule.FileSystemRights -band $WriteMask)) {
            throw ("Install directory $InstallDir grants write access to " +
                "$RuleId; refusing to deploy a payload SYSTEM will execute.")
        }
    }
    Write-PackageLog -Message ("Install directory $InstallDir created and " +
        'restricted to SYSTEM and Administrators.')
    #endregion

    #region Payload deployment
    $SourcePayload = Join-Path -Path $PSScriptRoot -ChildPath $PayloadFile
    Copy-Item -Path $SourcePayload -Destination $PayloadPath -Force
    $SourceHash = (Get-FileHash -Path $SourcePayload -Algorithm SHA256).Hash
    $DeployedHash = (Get-FileHash -Path $PayloadPath -Algorithm SHA256).Hash
    if ($SourceHash -ne $DeployedHash) {
        throw ("Deployed payload hash $DeployedHash does not match the " +
            "package's $SourceHash.")
    }
    Write-PackageLog -Message ("Deployed $PayloadFile to $PayloadPath, " +
        "SHA256 $DeployedHash.")
    #endregion

    #region Scheduled task
    $PayloadCommand = '-NoProfile -ExecutionPolicy Bypass -File "' +
    $PayloadPath + '"'
    $ActionParams = @{
        Execute  = 'powershell.exe'
        Argument = $PayloadCommand
    }
    $Action = New-ScheduledTaskAction @ActionParams

    #{{TRIGGER}}

    $PrincipalParams = @{
        UserId    = 'NT AUTHORITY\SYSTEM'
        LogonType = 'ServiceAccount'
        RunLevel  = 'Highest'
    }
    $Principal = New-ScheduledTaskPrincipal @PrincipalParams

    $SettingsParams = @{
        StartWhenAvailable = $true
        ExecutionTimeLimit = (New-TimeSpan -Hours $ExecutionTimeLimitHours)
        MultipleInstances  = 'IgnoreNew'
    }
    $Settings = New-ScheduledTaskSettingsSet @SettingsParams

    $RegisterParams = @{
        TaskName  = $TaskName
        TaskPath  = $TaskPath
        Action    = $Action
        Trigger   = $Trigger
        Principal = $Principal
        Settings  = $Settings
        Force     = $true
    }
    $null = Register-ScheduledTask @RegisterParams

    # Read back: the task must exist, run as SYSTEM, and point at the payload.
    $GetTaskParams = @{
        TaskName    = $TaskName
        TaskPath    = $TaskPath
        ErrorAction = 'Stop'
    }
    $Task = Get-ScheduledTask @GetTaskParams
    if ($Task.Principal.UserId -ne 'SYSTEM') {
        throw ("Registered task runs as $($Task.Principal.UserId), " +
            'expected SYSTEM.')
    }
    $TaskArguments = @($Task.Actions)[0].Arguments
    if ($TaskArguments -cne $PayloadCommand) {
        throw ("Registered task arguments are [$TaskArguments], expected " +
            "[$PayloadCommand].")
    }
    Write-PackageLog -Message ("Registered task $TaskPath$TaskName as SYSTEM " +
        "with arguments [$PayloadCommand].")
    #endregion

    #region Version stamp
    if (-not (Test-Path -Path $VersionRegKey)) {
        $null = New-Item -Path $VersionRegKey -Force
    }
    Set-ItemProperty -Path $VersionRegKey -Name 'Version' -Value $PackageVersion
    Set-ItemProperty -Path $VersionRegKey -Name 'PayloadHash' -Value $DeployedHash
    Set-ItemProperty -Path $VersionRegKey -Name 'BuildId' -Value $BuildId
    $Stamp = Get-ItemProperty -Path $VersionRegKey
    if ($Stamp.Version -ne $PackageVersion) {
        throw ("Registry version reads $($Stamp.Version), expected " +
            "$PackageVersion.")
    }
    if ($Stamp.PayloadHash -ne $DeployedHash) {
        throw ("Registry payload hash reads $($Stamp.PayloadHash), expected " +
            "$DeployedHash.")
    }
    if ($Stamp.BuildId -ne $BuildId) {
        throw "Registry build id reads $($Stamp.BuildId), expected $BuildId."
    }
    Write-PackageLog -Message ("Stamped $VersionRegKey with version " +
        "$PackageVersion, payload hash, and build id.")
    #endregion

    Write-PackageLog -Message ("Install completed: $PackageName " +
        "$PackageVersion, build $BuildId.")
    exit 0
} catch {
    Write-PackageLog -Level Error -Message ("Install failed: " +
        "$($_.Exception.Message)")
    $FailureParams = @{
        Message     = "Install failed for $PackageName. $($_.Exception.Message)"
        ErrorAction = 'Continue'
    }
    Write-Error @FailureParams
    exit 1
}
