# global: so ModuleBuilder's Invoke-ScriptGenerator can find it after Build.ps1
# dot-sources this file.
function global:ConvertTo-IntuneWinPackage {
    <#
    .SYNOPSIS
        A ModuleBuilder Script Generator that packages any PowerShell payload
        script as a self-healing Intune Win32 app (.intunewin).

    .DESCRIPTION
        Packages a payload .ps1 (usually a standalone script emitted earlier
        in the same build by ConvertTo-StandaloneScript) as a Win32 app:

            <Destination>\<PackageName>\
                Source\
                    Install.ps1         deploys the payload to a locked-down
                                        ProgramData directory and registers
                                        a SYSTEM scheduled task
                    Uninstall.ps1       removes them
                    <Payload>.ps1       the payload, copied verbatim
                Detect.ps1              Intune custom detection script,
                                        uploaded separately
                <PackageName>.intunewin Source\ packaged by the Content Prep
                                        Tool

        Install, Uninstall, and Detect are templates under
        Build\Generators\Intune\; the generator replaces their #{{...}}
        marker lines with the generated constants, the shared Write-PackageLog
        function, and (Install only) the scheduled-task trigger.

        The generated Install/Uninstall/Detect scripts must run 64-bit: the
        Intune Install Command must start with:
        %windir%\sysnative\WindowsPowerShell\v1.0\powershell.exe, and under
        Detection rules, "Run script as 32-bit process on 64-bit clients"
        must be set to no.

        Every build gets a build id, <Version>-<12 hex characters>, baked into
        all three scripts. Install.ps1 stamps it in the registry; Detect.ps1
        reports the app installed only while that stamp matches its own build
        id, the deployed payload's SHA256 matches the hash baked in at build
        time, and the scheduled task exists, is enabled, and runs as SYSTEM.
        Every package setting is baked in at build time, so any change means a
        rebuild, a new build id, and a reinstall on every device once the new
        package and Detect.ps1 are uploaded. The hex suffix comes from
        $env:MODULEBUILD_ID, which Build.ps1 sets once per run so every package
        from one run shares it; a fresh GUID is used when it is unset.

        All package settings come from the generator entry in
        Source\Build.psd1. Version defaults to the built module's version.

        IntuneWinAppUtil.exe is resolved from IntuneWinAppUtilPath, then
        PATH, then Build\Tools\, then a pinned release downloaded to a
        gitignored cache under .local\Build and verified against a baked
        SHA256. -NoToolDownload disables the download. Only the download is
        hash-verified.

        ModuleBuilder Build.psd1 generator entries run in declared order; list
        this one after the ConvertTo-StandaloneScript entry whose output it
        packages.

    .PARAMETER ScriptModule
        The AST of the built script module, bound from the ParseResults
        object that Invoke-ScriptGenerator pipes to every generator. Not used
        directly; required by the generator discovery contract.

    .PARAMETER Path
        Path to the built .psm1, bound from the piped ParseResults object.
        The module manifest is expected next to it; relative PayloadPath and
        Destination values resolve against its directory.

    .PARAMETER PayloadPath
        Path to the payload .ps1 to package. Relative paths resolve against
        the built module directory, so '../Repair-Sysmon.ps1' points at a
        standalone script emitted into the output root earlier in the same
        build. The payload ships inside the package and is never downloaded
        at runtime, so every argument it needs must be baked into it. It must
        not be named Install.ps1 or Uninstall.ps1.

    .PARAMETER OrgName
        Organization name used for the default install directory, log
        directory, task name, task folder, and registry key.

    .PARAMETER PackageName
        Name of the package; also the default basis for the task name and
        registry key, and the base name of the emitted .intunewin. Defaults
        to the payload file's base name.

    .PARAMETER Version
        Version stamped into the package and prefixed to the build id.
        Defaults to the built module's ModuleVersion.

    .PARAMETER InstallDir
        Absolute directory the payload is deployed to on the endpoint.
        Defaults to <ProgramData>\<OrgName>\<PackageName>, resolved on the
        endpoint via the ProgramData environment variable.

    .PARAMETER TaskName
        Name of the scheduled task. Defaults to <OrgName>-<PackageName>.

    .PARAMETER TaskPath
        Task Scheduler folder for the task. Defaults to \<OrgName>\. Leading
        and trailing backslashes are added if missing.

    .PARAMETER VersionRegKey
        HKLM registry key holding the Version, PayloadHash, and BuildId
        stamps.
        Defaults to HKLM:\SOFTWARE\<OrgName>\<PackageName>. Must be under
        HKLM:.

    .PARAMETER ScheduleType
        Trigger shape for the scheduled task: Daily (at ScheduleAt), Weekly
        (at ScheduleAt on ScheduleDaysOfWeek), Hourly (every
        ScheduleIntervalHours, anchored at ScheduleAt), AtStartup, or
        AtLogon. Defaults to Daily.

    .PARAMETER ScheduleAt
        Local time of day ('HH:mm') for Daily/Weekly triggers and the anchor
        for Hourly repetition. Defaults to 09:00.

    .PARAMETER ScheduleDaysOfWeek
        Days for a Weekly trigger. Defaults to Monday.

    .PARAMETER ScheduleIntervalHours
        Repetition interval in hours for an Hourly trigger. Defaults to 1.

    .PARAMETER RandomDelayMinutes
        Random delay added to each trigger firing, in minutes. Defaults to 0.
        Daily, Weekly, and Hourly only; a non-zero value with AtStartup or
        AtLogon fails the build.

    .PARAMETER ExecutionTimeLimitHours
        Scheduled task execution time limit in hours; 0 means no limit.
        Defaults to 1.

    .PARAMETER IntuneLogPath
        Full path of the log written by the generated Install, Uninstall, and
        Detect scripts. Defaults to
        <ProgramData>\<OrgName>\Logs\<PackageName>.log, resolved on the
        endpoint. Kept outside InstallDir so the uninstall's own record
        survives the directory it removes.

    .PARAMETER LogMaxBytes
        Size at which the log rotates. The current file is renamed over
        <name>.1.log, replacing the previous generation, and a fresh file
        starts, so peak disk use is twice this value. Defaults to 1 MB.

    .PARAMETER Destination
        Directory the <PackageName> package folder is created under. A
        relative path resolves against the built module directory; a rooted
        path is used as-is. Defaults to '.' (the module directory); set it
        to '..' in Build.psd1 to emit into the output root. The package
        folder is recreated on every build.

    .PARAMETER IntuneWinAppUtilPath
        Explicit path to IntuneWinAppUtil.exe (Microsoft Win32 Content Prep
        Tool). When omitted, the tool is resolved from PATH, then from
        Build\Tools\IntuneWinAppUtil.exe, then from the pinned download cache
        under .local\Build (fetched and hash-verified if absent). A tool given
        here is used as-is and not hash-checked.

    .PARAMETER NoToolDownload
        Disable the pinned download fallback. With it set, the tool must be
        found via IntuneWinAppUtilPath, PATH, or Build\Tools, or the build
        fails. Defaults to off.

    .PARAMETER Encoding
        File encoding for the generated scripts. Defaults to UTF8 with a BOM.

    .EXAMPLE
        # Source/Build.psd1, after the generator that emits the payload:
        Generators = @(
            @{
                Generator   = 'ConvertTo-StandaloneScript'
                Function    = 'Repair-Sysmon'
                GUID        = 'ae3274bc-01bf-4f1f-871e-a8a3e60300a0'
                Destination = '..'
            }
            @{
                Generator   = 'ConvertTo-IntuneWinPackage'
                PayloadPath = '../Repair-Sysmon.ps1'
                OrgName     = 'Contoso'
                Destination = '..'
            }
        )

    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    [OutputType('TextReplacement')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSReviewUnusedParameter', 'ScriptModule',
        Justification = 'Required by the generator discovery contract.')]
    param(
        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [Alias('Ast')]
        [System.Management.Automation.Language.Ast]$ScriptModule,

        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$PayloadPath,

        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9 ._-]*$')]
        [string]$OrgName,

        [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]*$')]
        [string]$PackageName,

        [ValidatePattern('^\d+(\.\d+){1,3}$')]
        [string]$Version,

        [string]$InstallDir,

        [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9 ._-]*$')]
        [string]$TaskName,

        [string]$TaskPath,

        [ValidatePattern('^(?i)HKLM:\\')]
        [string]$VersionRegKey,

        [ValidateSet('Daily', 'Weekly', 'Hourly', 'AtStartup', 'AtLogon')]
        [string]$ScheduleType = 'Daily',

        [ValidatePattern('^([01]?[0-9]|2[0-3]):[0-5][0-9]$')]
        [string]$ScheduleAt = '09:00',

        [ValidateSet('Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday',
            'Friday', 'Saturday')]
        [string[]]$ScheduleDaysOfWeek = @('Monday'),

        [ValidateRange(1, 24)]
        [int]$ScheduleIntervalHours = 1,

        [ValidateRange(0, 1440)]
        [int]$RandomDelayMinutes = 0,

        [ValidateRange(0, 168)]
        [int]$ExecutionTimeLimitHours = 1,

        [string]$IntuneLogPath,

        [ValidateRange(4096, 104857600)]
        [int]$LogMaxBytes = 1048576,

        [string]$Destination = '.',

        [string]$IntuneWinAppUtilPath,

        [switch]$NoToolDownload,

        [ValidateSet('UTF8', 'UTF8Bom', 'UTF8NoBom', 'UTF7', 'ASCII', 'Unicode', 'UTF32')]
        [string]$Encoding = $(
            if ($PSVersionTable.PSEdition -eq 'Core') { 'UTF8Bom' } else { 'UTF8' })
    )

    process {
        # --- Resolve inputs against the built module ------------------------
        $ModuleManifest = [System.IO.Path]::ChangeExtension($Path, '.psd1')
        $ModuleDirectory = Split-Path -Path $ModuleManifest -Parent

        $ResolvedPayload = if ([System.IO.Path]::IsPathRooted($PayloadPath)) {
            [System.IO.Path]::GetFullPath($PayloadPath)
        } else {
            [System.IO.Path]::GetFullPath(
                (Join-Path -Path $ModuleDirectory -ChildPath $PayloadPath))
        }
        if (-not (Test-Path -Path $ResolvedPayload -PathType Leaf)) {
            throw ("ConvertTo-IntuneWinPackage: payload '$ResolvedPayload' was not " +
                'found. When the payload is emitted by another generator, list that ' +
                'generator first in Build.psd1.')
        }
        $PayloadFile = Split-Path -Path $ResolvedPayload -Leaf
        if ($PayloadFile -notmatch '\.ps1$') {
            throw ("ConvertTo-IntuneWinPackage: payload '$PayloadFile' must be a " +
                '.ps1 script.')
        }
        if ($PayloadFile -in @('Install.ps1', 'Uninstall.ps1')) {
            throw ("ConvertTo-IntuneWinPackage: payload '$PayloadFile' collides with " +
                'a generated script name; rename the payload.')
        }

        $PayloadParseErrors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile(
            $ResolvedPayload, [ref]$null, [ref]$PayloadParseErrors)
        if ($PayloadParseErrors) {
            throw ("ConvertTo-IntuneWinPackage: payload '$ResolvedPayload' has parse " +
                "errors: $($PayloadParseErrors[0].Message)")
        }

        if (-not $PackageName) {
            $PackageName = [System.IO.Path]::GetFileNameWithoutExtension($PayloadFile)
        }
        if (-not $Version) {
            $Manifest = Import-PowerShellDataFile -Path $ModuleManifest
            $Version = "$($Manifest['ModuleVersion'])"
        }
        if (-not $TaskName) { $TaskName = "$OrgName-$PackageName" }
        if (-not $TaskPath) { $TaskPath = "\$OrgName\" }
        if (-not $TaskPath.StartsWith('\')) { $TaskPath = "\$TaskPath" }
        if (-not $TaskPath.EndsWith('\')) { $TaskPath = "$TaskPath\" }
        if (-not $VersionRegKey) {
            $VersionRegKey = "HKLM:\SOFTWARE\$OrgName\$PackageName"
        }

        Write-Host "   Generating Intune package $PackageName $Version" -ForegroundColor Cyan

        # --- Resolve the Win32 Content Prep Tool ----------------------------
        $ToolVersion = 'v1.8.7'
        $ToolUrl = 'https://raw.githubusercontent.com/microsoft/' +
        "Microsoft-Win32-Content-Prep-Tool/$ToolVersion/IntuneWinAppUtil.exe"
        $ToolSha256 = 'C1BA45B5CB939E84AF064BB7FF4B38FB3DFE33C8DC1078FD9B157672EAE671F6'

        $CommittedCache = [System.IO.Path]::GetFullPath(
            (Join-Path -Path $PSScriptRoot -ChildPath '..\Tools\IntuneWinAppUtil.exe'))
        $DownloadCacheDir = [System.IO.Path]::GetFullPath(
            (Join-Path -Path $PSScriptRoot -ChildPath '..\..\.local\Build'))
        $DownloadCache = Join-Path -Path $DownloadCacheDir -ChildPath 'IntuneWinAppUtil.exe'

        # True only when the file exists and its SHA256 equals the pin.
        $MatchesPin = {
            param($FilePath)
            (Test-Path -Path $FilePath -PathType Leaf) -and
            (Get-FileHash -Path $FilePath -Algorithm SHA256).Hash -eq $ToolSha256
        }

        $ResolvedTool = $null
        if ($IntuneWinAppUtilPath) {
            if (-not (Test-Path -Path $IntuneWinAppUtilPath -PathType Leaf)) {
                throw ("ConvertTo-IntuneWinPackage: IntuneWinAppUtilPath " +
                    "'$IntuneWinAppUtilPath' was not found.")
            }
            $ResolvedTool = (Resolve-Path -Path $IntuneWinAppUtilPath).ProviderPath
        } else {
            $ToolCommand = Get-Command -Name 'IntuneWinAppUtil.exe' -ErrorAction Ignore
            if ($ToolCommand) {
                $ResolvedTool = $ToolCommand.Source
            } elseif (Test-Path -Path $CommittedCache -PathType Leaf) {
                $ResolvedTool = $CommittedCache
            } elseif (& $MatchesPin $DownloadCache) {
                $ResolvedTool = $DownloadCache
            } elseif (-not $NoToolDownload) {
                $Msg = "   Downloading IntuneWinAppUtil.exe $ToolVersion"
                Write-Host $Msg -ForegroundColor Cyan
                if (-not (Test-Path -Path $DownloadCacheDir)) {
                    $null = New-Item -Path $DownloadCacheDir -ItemType Directory -Force
                }
                $OldProtocol = [Net.ServicePointManager]::SecurityProtocol
                try {
                    [Net.ServicePointManager]::SecurityProtocol =
                    $OldProtocol -bor [Net.SecurityProtocolType]::Tls12
                    $IwrParams = @{
                        Uri             = $ToolUrl
                        OutFile         = $DownloadCache
                        UseBasicParsing = $true
                        ErrorAction     = 'Stop'
                    }
                    Invoke-WebRequest @IwrParams
                } catch {
                    throw ("ConvertTo-IntuneWinPackage: failed to download " +
                        "IntuneWinAppUtil.exe from $ToolUrl -- $($_.Exception.Message)")
                } finally {
                    [Net.ServicePointManager]::SecurityProtocol = $OldProtocol
                }
                if (-not (& $MatchesPin $DownloadCache)) {
                    $Actual = if (Test-Path -Path $DownloadCache -PathType Leaf) {
                        (Get-FileHash -Path $DownloadCache -Algorithm SHA256).Hash
                    } else { '(no file written)' }
                    Remove-Item -Path $DownloadCache -Force -ErrorAction SilentlyContinue
                    throw ("ConvertTo-IntuneWinPackage: downloaded IntuneWinAppUtil.exe " +
                        "failed SHA256 verification (expected $ToolSha256, got $Actual).")
                }
                $ResolvedTool = $DownloadCache
            }
        }
        if (-not $ResolvedTool) {
            throw ('ConvertTo-IntuneWinPackage: IntuneWinAppUtil.exe was not found. ' +
                'Provide it via IntuneWinAppUtilPath, PATH, or ' +
                "$CommittedCache; or drop -NoToolDownload to let the build fetch the " +
                "pinned $ToolVersion from the official Microsoft repository " +
                '(https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool).')
        }

        # --- Lay out the package folder -------------------------------------
        $DestinationBase = if ([System.IO.Path]::IsPathRooted($Destination)) {
            [System.IO.Path]::GetFullPath($Destination)
        } else {
            [System.IO.Path]::GetFullPath(
                (Join-Path -Path $ModuleDirectory -ChildPath $Destination))
        }
        $PackageRoot = Join-Path -Path $DestinationBase -ChildPath $PackageName
        if (Test-Path -Path $PackageRoot) {
            Remove-Item -Path $PackageRoot -Recurse -Force
        }
        $SourceDir = Join-Path -Path $PackageRoot -ChildPath 'Source'
        $null = New-Item -Path $SourceDir -ItemType Directory -Force

        Copy-Item -Path $ResolvedPayload -Destination $SourceDir -Force
        $PackagedPayload = Join-Path -Path $SourceDir -ChildPath $PayloadFile
        $PayloadHash = (Get-FileHash -Path $PackagedPayload -Algorithm SHA256).Hash

        # --- Generated-script building blocks -------------------------------
        # Value fragments are single-quote escaped.
        $InstallDirLine = if ($InstallDir) {
            '$InstallDir = ' + "'$($InstallDir -replace "'", "''")'"
        } else {
            '$InstallDir = Join-Path -Path $env:ProgramData -ChildPath ' +
            "'$OrgName\$PackageName'"
        }

        $LogPathLine = if ($IntuneLogPath) {
            '$LogPath = ' + "'$($IntuneLogPath -replace "'", "''")'"
        } else {
            '$LogPath = Join-Path -Path $env:ProgramData -ChildPath ' +
            "'$OrgName\Logs\$PackageName.log'"
        }

        # Every build gets an id no other build shares; Detect keys on it. The
        # suffix is shared across one Build.ps1 run so all of its packages carry
        # the same id, and minted here when the generator runs on its own.
        $BuildSuffix = if ($env:MODULEBUILD_ID) {
            $env:MODULEBUILD_ID
        } else {
            [guid]::NewGuid().ToString('N').Substring(0, 12)
        }
        $BuildId = "$Version-$BuildSuffix"

        $ConstantsTemplate = @'
#region Generated constants -- edit Source\Build.psd1 and rebuild to change
$PackageName = '{{PACKAGE_NAME}}'
{{INSTALL_DIR_LINE}}
$PayloadFile = '{{PAYLOAD_FILE}}'
$PayloadPath = Join-Path -Path $InstallDir -ChildPath $PayloadFile
$TaskName = '{{TASK_NAME}}'
$TaskPath = '{{TASK_PATH}}'
$PackageVersion = '{{VERSION}}'
$VersionRegKey = '{{REG_KEY}}'
$BuildId = '{{BUILD_ID}}'
{{LOG_PATH_LINE}}
$LogMaxBytes = {{LOG_MAX_BYTES}}
$LogScript = '{{LOG_SCRIPT}}'
#endregion
'@
        $Constants = $ConstantsTemplate.
        Replace('{{PACKAGE_NAME}}', ($PackageName -replace "'", "''")).
        Replace('{{INSTALL_DIR_LINE}}', $InstallDirLine).
        Replace('{{PAYLOAD_FILE}}', ($PayloadFile -replace "'", "''")).
        Replace('{{TASK_NAME}}', ($TaskName -replace "'", "''")).
        Replace('{{TASK_PATH}}', ($TaskPath -replace "'", "''")).
        Replace('{{VERSION}}', $Version).
        Replace('{{REG_KEY}}', ($VersionRegKey -replace "'", "''")).
        Replace('{{BUILD_ID}}', $BuildId).
        Replace('{{LOG_PATH_LINE}}', $LogPathLine).
        Replace('{{LOG_MAX_BYTES}}', $LogMaxBytes)

        $InstallSettings = @(
            ''
            '#region Generated install settings'
            "`$ExecutionTimeLimitHours = $ExecutionTimeLimitHours"
            '#endregion'
        ) -join "`n"
        $InstallConstants = $Constants + "`n" + $InstallSettings

        # The log function is injected verbatim into all three scripts.
        $TemplateDir = Join-Path -Path $PSScriptRoot -ChildPath 'Intune'
        $ReadFunction = {
            param($Name)
            $FunctionPath = Join-Path -Path $TemplateDir -ChildPath $Name
            if (-not (Test-Path -Path $FunctionPath -PathType Leaf)) {
                throw ("ConvertTo-IntuneWinPackage: template '$FunctionPath' was " +
                    'not found next to the generator.')
            }
            (Get-Content -Path $FunctionPath -Raw -Encoding UTF8).TrimEnd()
        }
        $LoggerContent = & $ReadFunction 'Write-PackageLog.ps1'

        # Detect bakes the expected payload hash into its constants region.
        $DetectConstants = @(
            $Constants
            "`$ExpectedPayloadHash = '$PayloadHash'"
        ) -join "`n"

        # A random start delay staggers the task across a fleet. Only the
        # time-based triggers carry a RandomDelay; New-ScheduledTaskTrigger
        # accepts -RandomDelay on AtStartup/AtLogon but silently drops it, so
        # reject that here rather than emit a task that ignores the setting.
        if ($RandomDelayMinutes -gt 0 -and
            $ScheduleType -in @('AtStartup', 'AtLogon')) {
            throw ("ConvertTo-IntuneWinPackage: RandomDelayMinutes is not " +
                "supported for the '$ScheduleType' trigger; boot and logon " +
                'triggers cannot randomize their start. Use a Daily, Weekly, ' +
                'or Hourly schedule, or leave RandomDelayMinutes at 0.')
        }
        $RandomDelayArg = if ($RandomDelayMinutes -gt 0) {
            " -RandomDelay (New-TimeSpan -Minutes $RandomDelayMinutes)"
        } else { '' }
        $RandomDelayKey = if ($RandomDelayMinutes -gt 0) {
            "`n        RandomDelay = (New-TimeSpan -Minutes $RandomDelayMinutes)"
        } else { '' }

        $TriggerBlock = switch ($ScheduleType) {
            'Daily' {
                "    `$Trigger = New-ScheduledTaskTrigger -Daily -At " +
                "'$ScheduleAt'$RandomDelayArg"
            }
            'Weekly' {
                $DayList = "'" + ($ScheduleDaysOfWeek -join "', '") + "'"
                @(
                    '    $TriggerParams = @{'
                    '        Weekly     = $true'
                    "        DaysOfWeek = @($DayList)"
                    "        At         = '$ScheduleAt'$RandomDelayKey"
                    '    }'
                    '    $Trigger = New-ScheduledTaskTrigger @TriggerParams'
                ) -join "`n"
            }
            'Hourly' {
                @(
                    '    $TriggerParams = @{'
                    '        Once               = $true'
                    "        At                 = '$ScheduleAt'"
                    "        RepetitionInterval = (New-TimeSpan -Hours $ScheduleIntervalHours)"
                    "        RepetitionDuration = ([TimeSpan]::MaxValue)$RandomDelayKey"
                    '    }'
                    '    $Trigger = New-ScheduledTaskTrigger @TriggerParams'
                ) -join "`n"
            }
            'AtStartup' {
                '    $Trigger = New-ScheduledTaskTrigger -AtStartup'
            }
            'AtLogon' {
                '    $Trigger = New-ScheduledTaskTrigger -AtLogOn'
            }
        }

        # --- Fill the templates ---------------------------------------------
        $ReadTemplate = {
            param($Name)
            $TemplatePath = Join-Path -Path $TemplateDir -ChildPath $Name
            if (-not (Test-Path -Path $TemplatePath -PathType Leaf)) {
                throw ("ConvertTo-IntuneWinPackage: template '$TemplatePath' was " +
                    'not found next to the generator.')
            }
            Get-Content -Path $TemplatePath -Raw -Encoding UTF8
        }

        $InstallContent = (& $ReadTemplate 'Install.ps1').
        Replace('#{{CONSTANTS}}', $InstallConstants.Replace('{{LOG_SCRIPT}}', 'Install')).
        Replace('#{{FUNCTIONS}}', $LoggerContent).
        Replace('#{{TRIGGER}}', $TriggerBlock)

        $UninstallContent = (& $ReadTemplate 'Uninstall.ps1').
        Replace('#{{CONSTANTS}}', $Constants.Replace('{{LOG_SCRIPT}}', 'Uninstall')).
        Replace('#{{FUNCTIONS}}', $LoggerContent)

        $DetectContent = (& $ReadTemplate 'Detect.ps1').
        Replace('#{{CONSTANTS}}', $DetectConstants.Replace('{{LOG_SCRIPT}}', 'Detect')).
        Replace('#{{FUNCTIONS}}', $LoggerContent)

        # --- Write and validate the generated scripts -----------------------
        $InstallScript = Join-Path -Path $SourceDir -ChildPath 'Install.ps1'
        $UninstallScript = Join-Path -Path $SourceDir -ChildPath 'Uninstall.ps1'
        $DetectScript = Join-Path -Path $PackageRoot -ChildPath 'Detect.ps1'
        $Generated = @{
            $InstallScript   = $InstallContent
            $UninstallScript = $UninstallContent
            $DetectScript    = $DetectContent
        }
        foreach ($ScriptPath in $Generated.Keys) {
            $SetContentParams = @{
                Path     = $ScriptPath
                Value    = $Generated[$ScriptPath]
                Encoding = $Encoding
            }
            Microsoft.PowerShell.Management\Set-Content @SetContentParams

            # A generated script that does not parse must fail the build here,
            # not on the first endpoint that runs it.
            $ParseErrors = $null
            $null = [System.Management.Automation.Language.Parser]::ParseFile(
                $ScriptPath, [ref]$null, [ref]$ParseErrors)
            if ($ParseErrors) {
                throw ("ConvertTo-IntuneWinPackage: generated script '$ScriptPath' " +
                    "has parse errors: $($ParseErrors[0].Message)")
            }
        }

        # --- Package with the Win32 Content Prep Tool -----------------------
        $ToolArgs = @('-c', $SourceDir, '-s', $InstallScript, '-o', $PackageRoot, '-q')
        $ToolOutput = & $ResolvedTool @ToolArgs 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw ("ConvertTo-IntuneWinPackage: IntuneWinAppUtil exited with code " +
                "$LASTEXITCODE. Output: $($ToolOutput -join ' ')")
        }
        $RawPackage = Join-Path -Path $PackageRoot -ChildPath 'Install.intunewin'
        if (-not (Test-Path -Path $RawPackage -PathType Leaf)) {
            throw ("ConvertTo-IntuneWinPackage: IntuneWinAppUtil exited 0 but " +
                "produced no package at $RawPackage.")
        }
        $FinalPackage = Join-Path -Path $PackageRoot -ChildPath "$PackageName.intunewin"
        if ($FinalPackage -ne $RawPackage) {
            Move-Item -Path $RawPackage -Destination $FinalPackage -Force
        }

        Write-Host "   $PackageName $Version -> $FinalPackage" -ForegroundColor Cyan
    }
}
