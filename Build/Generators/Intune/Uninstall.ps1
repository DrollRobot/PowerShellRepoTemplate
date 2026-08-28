<#
.SYNOPSIS
    Removes a scheduled-script package (Intune Win32 app).

.DESCRIPTION
    Removal template consumed by ConvertTo-IntuneWinPackage; do not edit a
    generated copy, edit this template or the generator entry in
    Source\Build.psd1 and rebuild. Unregisters the scheduled task, removes the
    install directory, and deletes the registry stamp, then drops the org
    task folder, org directory, and org registry key when nothing else
    remains in them.
    Absent items are tolerated, so re-running is safe. Refuses to run as a
    32-bit process on a 64-bit OS, where the registry stamp would be
    invisible.

    Each step is recorded in the package's deployment log (LogPath in the
    generated constants) through the injected Write-PackageLog function, and
    the first line of each run carries the build id. A failure is logged at
    Error level, repeated on stderr for the Intune Management Extension, and
    the script exits 1. The log outlives the uninstall: it sits outside the
    install directory this script removes.

    This template is valid Windows PowerShell so it can be reviewed and lint
    checked directly. Before packaging, the generator replaces the marked
    comment lines with the generated constants and the log function. Run
    this script 64-bit: from the 32-bit Intune Management Extension, that
    means invoking it through
    %windir%\sysnative\WindowsPowerShell\v1.0\powershell.exe.

.EXAMPLE
    %windir%\sysnative\WindowsPowerShell\v1.0\powershell.exe
        -NoProfile -ExecutionPolicy Bypass -File .\Uninstall.ps1

    Runs the removal, as Intune's Win32 app uninstall command (shown wrapped;
    enter it as one line).

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

Write-PackageLog -Message ("Uninstall started. Build $BuildId, package version " +
    "$PackageVersion, 64-bit process: $([Environment]::Is64BitProcess).")

try {
    #region Host bitness
    # A 32-bit host redirects HKLM:\SOFTWARE to WOW6432Node, so the version
    # stamp Install.ps1 wrote would look absent and survive the uninstall.
    if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
        throw ('Running 32-bit on a 64-bit OS. Launch this script with ' +
            '%windir%\sysnative\WindowsPowerShell\v1.0\powershell.exe.')
    }
    Write-PackageLog -Message 'Host is a 64-bit process.'
    #endregion

    #region Scheduled task
    $GetTaskParams = @{
        TaskName    = $TaskName
        TaskPath    = $TaskPath
        ErrorAction = 'SilentlyContinue'
    }
    $Task = Get-ScheduledTask @GetTaskParams
    if ($Task) {
        $UnregisterParams = @{
            TaskName = $TaskName
            TaskPath = $TaskPath
            Confirm  = $false
        }
        Unregister-ScheduledTask @UnregisterParams
        Write-PackageLog -Message "Removed scheduled task $TaskPath$TaskName."
    } else {
        Write-PackageLog -Message "No scheduled task $TaskPath$TaskName to remove."
    }

    # Drop the org task folder once nothing else lives in it.
    $Scheduler = New-Object -ComObject 'Schedule.Service'
    $Scheduler.Connect()
    $FolderPath = $TaskPath.TrimEnd('\')
    $TaskFolder = $null
    try { $TaskFolder = $Scheduler.GetFolder($FolderPath) } catch { $TaskFolder = $null }
    if ($TaskFolder -and $FolderPath -and $FolderPath -ne '\') {
        $Remaining = $TaskFolder.GetTasks(1).Count + $TaskFolder.GetFolders(0).Count
        if ($Remaining -eq 0) {
            $Scheduler.GetFolder((Split-Path -Path $FolderPath -Parent)).DeleteFolder(
                (Split-Path -Path $FolderPath -Leaf), 0)
            Write-PackageLog -Message "Removed empty task folder $FolderPath."
        } else {
            Write-PackageLog -Message ("Kept task folder $FolderPath; " +
                "$Remaining item(s) remain in it.")
        }
    } else {
        Write-PackageLog -Message "No task folder $FolderPath to remove."
    }
    #endregion

    #region Install directory
    if (Test-Path -Path $InstallDir) {
        Remove-Item -Path $InstallDir -Recurse -Force
        Write-PackageLog -Message "Removed install directory $InstallDir."
    } else {
        Write-PackageLog -Message "No install directory $InstallDir to remove."
    }

    # Drop the org directory once it is empty.
    $OrgDir = Split-Path -Path $InstallDir -Parent
    if ($OrgDir -and (Test-Path -Path $OrgDir)) {
        $OrgEntries = @(Get-ChildItem -Path $OrgDir -Force)
        if ($OrgEntries.Count -eq 0) {
            Remove-Item -Path $OrgDir -Force
            Write-PackageLog -Message "Removed empty org directory $OrgDir."
        } else {
            $Names = ($OrgEntries | ForEach-Object { $_.Name }) -join ', '
            Write-PackageLog -Message ("Kept org directory $OrgDir; it still " +
                "holds: $Names.")
        }
    } else {
        Write-PackageLog -Message "No org directory $OrgDir to remove."
    }
    #endregion

    #region Version stamp
    if (Test-Path -Path $VersionRegKey) {
        Remove-Item -Path $VersionRegKey -Recurse -Force
        Write-PackageLog -Message "Removed registry key $VersionRegKey."
    } else {
        Write-PackageLog -Message "No registry key $VersionRegKey to remove."
    }

    # Drop the org key once no package stamp remains under it.
    $OrgKey = Split-Path -Path $VersionRegKey -Parent
    if ($OrgKey -and (Test-Path -Path $OrgKey)) {
        $OrgItem = Get-Item -Path $OrgKey
        if ($OrgItem.SubKeyCount -eq 0 -and $OrgItem.ValueCount -eq 0) {
            Remove-Item -Path $OrgKey -Force
            Write-PackageLog -Message "Removed empty org registry key $OrgKey."
        } else {
            Write-PackageLog -Message ("Kept org registry key $OrgKey; other " +
                'package stamps remain under it.')
        }
    } else {
        Write-PackageLog -Message "No org registry key $OrgKey to remove."
    }
    #endregion

    Write-PackageLog -Message ("Uninstall completed: $PackageName, " +
        "build $BuildId.")
    exit 0
} catch {
    Write-PackageLog -Level Error -Message ("Uninstall failed: " +
        "$($_.Exception.Message)")
    $FailureParams = @{
        Message     = "Uninstall failed for $PackageName. $($_.Exception.Message)"
        ErrorAction = 'Continue'
    }
    Write-Error @FailureParams
    exit 1
}
