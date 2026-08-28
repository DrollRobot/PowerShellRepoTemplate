<#
.SYNOPSIS
    Offline Pester tests for the ConvertTo-IntuneWinPackage build generator.

.DESCRIPTION
    Exercises the generator against a fake built module, a trivial payload,
    and a stub packaging tool (a .cmd standing in for IntuneWinAppUtil.exe),
    so no scheduled task, registry, or Intune infrastructure is touched.
    Verifies the emitted package layout, that the generated Install,
    Uninstall, and Detect scripts parse and carry the expected baked-in
    constants (version, build id, task, registry key, payload hash), that
    parameter overrides and trigger shapes are honored, and that bad inputs
    or a failing packaging tool fail the build loudly.
#>
# Fixtures are assigned in BeforeAll and consumed inside It scriptblocks, which
# PSScriptAnalyzer does not connect to the assignment.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseDeclaredVarsMoreThanAssignments', '')]
param()

Describe 'ConvertTo-IntuneWinPackage' -Tag 'unit' {

    BeforeAll {
        $GeneratorRelative = Join-Path -Path '..\..\Build' -ChildPath 'Generators'
        $GeneratorDir = Join-Path -Path $PSScriptRoot -ChildPath $GeneratorRelative
        . (Join-Path -Path $GeneratorDir -ChildPath 'ConvertTo-IntuneWinPackage.ps1')

        $FixtureRoot = Join-Path -Path $TestDrive -ChildPath 'Fixture'
        $ModuleDir = Join-Path -Path $FixtureRoot -ChildPath 'Module'
        $null = New-Item -Path $ModuleDir -ItemType Directory -Force

        $PsmPath = Join-Path -Path $ModuleDir -ChildPath 'FakeModule.psm1'
        Set-Content -Path $PsmPath -Value "function Get-Fake { 'fake' }"

        $ManifestPath = Join-Path -Path $ModuleDir -ChildPath 'FakeModule.psd1'
        $ManifestLines = @(
            '@{'
            "    RootModule    = 'FakeModule.psm1'"
            "    ModuleVersion = '1.2.3'"
            "    GUID          = '11111111-2222-3333-4444-555555555555'"
            "    Author        = 'Tester'"
            "    CompanyName   = 'Contoso'"
            "    Copyright     = '(c) Contoso'"
            '}'
        )
        Set-Content -Path $ManifestPath -Value $ManifestLines

        $PayloadSource = Join-Path -Path $FixtureRoot -ChildPath 'MyPayload.ps1'
        Set-Content -Path $PayloadSource -Value @(
            'param()'
            "Write-Output 'payload ran'"
        )
        $PayloadSourceHash = (Get-FileHash -Path $PayloadSource -Algorithm SHA256).Hash

        # Stub Win32 Content Prep Tool: arg 6 is the -o output directory.
        $StubTool = Join-Path -Path $FixtureRoot -ChildPath 'IntuneWinStub.cmd'
        Set-Content -Path $StubTool -Value @(
            '@echo off'
            'echo stub-package > "%~6\Install.intunewin"'
            'exit /b 0'
        )
        $FailTool = Join-Path -Path $FixtureRoot -ChildPath 'IntuneWinFail.cmd'
        Set-Content -Path $FailTool -Value @(
            '@echo off'
            'exit /b 7'
        )
        $SilentTool = Join-Path -Path $FixtureRoot -ChildPath 'IntuneWinSilent.cmd'
        Set-Content -Path $SilentTool -Value @(
            '@echo off'
            'exit /b 0'
        )

        $ModuleAst = [System.Management.Automation.Language.Parser]::ParseFile(
            $PsmPath, [ref]$null, [ref]$null)

        function Invoke-IntunePackager {
            param([hashtable]$Override = @{})
            $Params = @{
                ScriptModule         = $ModuleAst
                Path                 = $PsmPath
                PayloadPath          = $PayloadSource
                OrgName              = 'Contoso'
                IntuneWinAppUtilPath = $StubTool
            }
            foreach ($Key in $Override.Keys) { $Params[$Key] = $Override[$Key] }
            ConvertTo-IntuneWinPackage @Params
        }

        function Test-GeneratedScriptSyntax {
            param([string]$ScriptPath)
            $ParseErrors = $null
            $null = [System.Management.Automation.Language.Parser]::ParseFile(
                $ScriptPath, [ref]$null, [ref]$ParseErrors)
            @($ParseErrors).Count
        }

        function Get-EmittedInstall {
            param(
                [string]$OutName,
                [string]$Package = 'MyPayload'
            )
            $RelPath = "$OutName\$Package\Source\Install.ps1"
            Get-Content -Raw -Path (Join-Path -Path $ModuleDir -ChildPath $RelPath)
        }

        function Get-EmittedDetect {
            param(
                [string]$OutName,
                [string]$Package = 'MyPayload'
            )
            $RelPath = "$OutName\$Package\Detect.ps1"
            Get-Content -Raw -Path (Join-Path -Path $ModuleDir -ChildPath $RelPath)
        }

        function Get-BakedBuildId {
            param([string]$Content)
            [regex]::Match($Content, "(?m)^\`$BuildId = '([^']+)'").Groups[1].Value
        }
    }

    AfterAll {
        $GeneratorFunction = 'Function:\ConvertTo-IntuneWinPackage'
        Remove-Item -Path $GeneratorFunction -ErrorAction SilentlyContinue
    }

    Context 'default package generation' {

        BeforeAll {
            Invoke-IntunePackager -Override @{ Destination = 'DefaultOut' }
            $PackageRoot = Join-Path -Path $ModuleDir -ChildPath 'DefaultOut\MyPayload'
            $SourceDir = Join-Path -Path $PackageRoot -ChildPath 'Source'
            $InstallPath = Join-Path -Path $SourceDir -ChildPath 'Install.ps1'
            $UninstallPath = Join-Path -Path $SourceDir -ChildPath 'Uninstall.ps1'
            $DetectPath = Join-Path -Path $PackageRoot -ChildPath 'Detect.ps1'
            $Install = Get-Content -Path $InstallPath -Raw
            $Uninstall = Get-Content -Path $UninstallPath -Raw
            $Detect = Get-Content -Path $DetectPath -Raw
        }

        It 'emits Install.ps1, Uninstall.ps1, and the payload into Source' {
            $InstallPath | Should -Exist
            $UninstallPath | Should -Exist
            Join-Path -Path $SourceDir -ChildPath 'MyPayload.ps1' | Should -Exist
        }

        It 'copies the payload byte-identical' {
            $Copied = Join-Path -Path $SourceDir -ChildPath 'MyPayload.ps1'
            (Get-FileHash -Path $Copied -Algorithm SHA256).Hash |
                Should -Be $PayloadSourceHash
        }

        It 'keeps Detect.ps1 outside the packaged Source folder' {
            $DetectPath | Should -Exist
            Join-Path -Path $SourceDir -ChildPath 'Detect.ps1' | Should -Not -Exist
        }

        It 'renames the tool output to the package name .intunewin' {
            Join-Path -Path $PackageRoot -ChildPath 'MyPayload.intunewin' |
                Should -Exist
            Join-Path -Path $PackageRoot -ChildPath 'Install.intunewin' |
                Should -Not -Exist
        }

        It 'does not emit a handoff markdown file' {
            Join-Path -Path $PackageRoot -ChildPath 'IntuneApp.md' | Should -Not -Exist
        }

        It 'emits scripts that parse cleanly: <_>' -ForEach @(
            'Install', 'Uninstall', 'Detect'
        ) {
            $ScriptPath = switch ($_) {
                'Install' { $InstallPath }
                'Uninstall' { $UninstallPath }
                'Detect' { $DetectPath }
            }
            Test-GeneratedScriptSyntax -ScriptPath $ScriptPath | Should -Be 0
        }

        It 'bakes the module manifest version into every script' {
            foreach ($Content in @($Install, $Uninstall, $Detect)) {
                $Content.Contains("`$PackageVersion = '1.2.3'") | Should -BeTrue
            }
        }

        It 'derives the default task name and task folder from org and package' {
            $Install.Contains("`$TaskName = 'Contoso-MyPayload'") | Should -BeTrue
            $Install.Contains("`$TaskPath = '\Contoso\'") | Should -BeTrue
        }

        It 'derives the default registry key from org and package' {
            $Install.Contains("`$VersionRegKey = 'HKLM:\SOFTWARE\Contoso\MyPayload'") |
                Should -BeTrue
        }

        It 'defaults the install directory to ProgramData at runtime' {
            $Expected = 'Join-Path -Path $env:ProgramData -ChildPath ' +
            "'Contoso\MyPayload'"
            $Install.Contains($Expected) | Should -BeTrue
        }

        It 'bakes the payload SHA256 into Detect.ps1' {
            $Detect.Contains("`$ExpectedPayloadHash = '$PayloadSourceHash'") |
                Should -BeTrue
        }

        It 'hardens the install directory ACL and verifies it' {
            $Install.Contains('SetAccessRuleProtection($true, $false)') | Should -BeTrue
            $Install.Contains('grants write access to ') | Should -BeTrue
        }

        It 'registers the task as SYSTEM with Force and read-back verification' {
            $Install.Contains("UserId    = 'NT AUTHORITY\SYSTEM'") | Should -BeTrue
            $Install | Should -Match 'Force\s+= \$true'
            $Install.Contains('Get-ScheduledTask @GetTaskParams') | Should -BeTrue
        }

        It 'defaults to a daily trigger at 09:00' {
            $Install.Contains("New-ScheduledTaskTrigger -Daily -At '09:00'") |
                Should -BeTrue
        }

        It 'stamps and reads back Version and PayloadHash in the registry' {
            $Install | Should -Match "-Name 'Version' -Value \`$PackageVersion"
            $Install | Should -Match "-Name 'PayloadHash' -Value \`$DeployedHash"
        }

        It 'keeps no schedule hash anywhere' {
            foreach ($Content in @($Install, $Uninstall, $Detect)) {
                $Content | Should -Not -Match 'ScheduleHash'
            }
        }

        It 'compares the registry build id in Detect.ps1' {
            $Detect.Contains('if ($Stamp.BuildId -ne $BuildId) {') | Should -BeTrue
            $Detect | Should -Not -Match '\$Stamp\.Version'
        }

        It 'uninstalls the task without confirmation and tolerates absence' {
            $Uninstall.Contains('Unregister-ScheduledTask @UnregisterParams') |
                Should -BeTrue
            $Uninstall | Should -Match 'Confirm\s+= \$false'
            $Uninstall | Should -Match "ErrorAction = 'SilentlyContinue'"
        }

        It 'emits the Detected marker and silent-failure contract in Detect.ps1' {
            $Detect.Contains("Write-Output 'Detected'") | Should -BeTrue
            $Detect | Should -Match '(?m)^\s*exit 0'
            $Detect | Should -Not -Match 'exit 1'
        }

        It 'logs every Install step in readable text, with the build id first' {
            $Install | Should -Match 'Write-PackageLog -Message \("Install started\. '
            $Install | Should -Match 'Build \$BuildId'
            foreach ($Fragment in @('Host is a 64-bit process.',
                    'created and ', 'Deployed $PayloadFile to $PayloadPath',
                    'as SYSTEM ', 'Install completed: ')) {
                $Install.Contains($Fragment) | Should -BeTrue
            }
            $Install | Should -Not -Match "Write-Output '[a-z]+:ok'"
        }

        It 'logs every Uninstall outcome in readable text' {
            foreach ($Fragment in @('Removed scheduled task ',
                    'No scheduled task ', 'Removed empty task folder ',
                    'Kept task folder ', 'Removed install directory ',
                    'Removed registry key ', 'Uninstall completed: ')) {
                $Uninstall.Contains($Fragment) | Should -BeTrue
            }
            $Uninstall |
                Should -Not -Match "Write-Output '[a-z]+:(ok|removed|absent|kept)'"
        }

        It 'logs each failed Detect check without printing to stdout' {
            foreach ($Fragment in @('Not detected: registry build id is ',
                    'Not detected: payload hash is ',
                    'Not detected: scheduled task ')) {
                $Detect.Contains($Fragment) | Should -BeTrue
            }
            # 'Detected' is the only thing Detect may write to stdout.
            $StdOut = [regex]::Matches($Detect, "(?m)^\s*Write-Output\s+(.+)$")
            @($StdOut).Count | Should -Be 1
            $StdOut[0].Groups[1].Value.Trim() | Should -Be "'Detected'"
        }

        It 'injects the log function into all three scripts' {
            foreach ($Content in @($Install, $Uninstall, $Detect)) {
                ([regex]::Matches($Content, 'function Write-PackageLog \{')).Count |
                    Should -Be 1
            }
        }

        It 'bakes one build id, shared by all three scripts' {
            $Ids = foreach ($Content in @($Install, $Uninstall, $Detect)) {
                $Id = Get-BakedBuildId -Content $Content
                $Id | Should -Not -BeNullOrEmpty
                $Id
            }
            @($Ids | Sort-Object -Unique).Count | Should -Be 1
            $Ids[0] | Should -Match '^1\.2\.3-[0-9a-f]{12}$'
        }

        It 'stamps the build id in the registry and reads it back' {
            $Install |
                Should -Match "Set-ItemProperty .* -Name 'BuildId' -Value \`$BuildId"
            $Install | Should -Match '\$Stamp\.BuildId -ne \$BuildId'
        }

        It 'tags log lines with the script that wrote them' {
            $Tagged = @{ Install = $Install; Uninstall = $Uninstall; Detect = $Detect }
            foreach ($Name in $Tagged.Keys) {
                $Tagged[$Name] | Should -Match "(?m)^\`$LogScript = '$Name'"
            }
        }

        It 'defaults the log path outside the install directory' {
            foreach ($Content in @($Install, $Uninstall, $Detect)) {
                $Content | Should -Match (
                    "\`$LogPath = Join-Path -Path \`$env:ProgramData -ChildPath " +
                    "'Contoso\\Logs\\")
            }
        }

        It 'bakes IntuneLogPath as the log path in every script' {
            Invoke-IntunePackager -Override @{
                Destination   = 'LogPathOut'
                IntuneLogPath = 'D:\Elsewhere\deploy.log'
            }
            foreach ($Content in @(
                    (Get-EmittedInstall -OutName 'LogPathOut'),
                    (Get-EmittedDetect -OutName 'LogPathOut'))) {
                $Content | Should -Match "(?m)^\`$LogPath = 'D:\\Elsewhere\\deploy\.log'"
            }
        }

        It 'rotates the log by rename at the size cap' {
            $Install | Should -Match "(?m)^\`$LogMaxBytes = 1048576"
            $Install | Should -Match '\$Existing\.Length -gt \$LogMaxBytes'
            $Install |
                Should -Match 'Move-Item -Path \$LogPath -Destination \$Rotated -Force'
            # Rotation must not read or rewrite the log it is bounding.
            $Install | Should -Not -Match 'Get-Content -Path \$LogPath'
        }

        It 'never lets a log write failure fail the deployment' {
            $Install | Should -Match 'Message     = "Log write to \$LogPath failed'
            $Install | Should -Not -Match 'throw .*Log write'
        }

        It 'refuses a 32-bit host in Install and Uninstall without relaunching' {
            $Guard = 'if ([Environment]::Is64BitOperatingSystem -and ' +
            '-not [Environment]::Is64BitProcess) {'
            $Throw = "'Running 32-bit on a 64-bit OS. Launch this script with ' +"
            foreach ($Content in @($Install, $Uninstall)) {
                $Content.Contains($Guard) | Should -BeTrue
                $Content.Contains($Throw) | Should -BeTrue
            }
            $Detect.Contains('Is64BitProcess') | Should -BeFalse
        }

        It 'removes empty org parents on uninstall' {
            $Uninstall.Contains('reg32:') | Should -BeFalse
            $Uninstall.Contains("New-Object -ComObject 'Schedule.Service'") |
                Should -BeTrue
            $Uninstall | Should -Match 'DeleteFolder\('
            $Uninstall | Should -Match 'SubKeyCount -eq 0 -and \$OrgItem\.ValueCount -eq 0'
        }

        It 'logs the failure, reports it on stderr, and exits 1' {
            foreach ($Content in @($Install, $Uninstall)) {
                $Content | Should -Match 'Write-PackageLog -Level Error -Message'
                $Content | Should -Match 'Message     = "(Install|Uninstall) failed for'
                $Content | Should -Match "ErrorAction = 'Continue'"
                $Content | Should -Match '(?m)^\s*exit 1'
            }
        }

        It 'throws readable sentences carrying expected and actual values' {
            foreach ($Fragment in @(
                    'grants write access to ',
                    'does not match the ',
                    'Registered task runs as ',
                    'Registered task arguments are ',
                    'Registry build id reads ')) {
                $Install.Contains($Fragment) | Should -BeTrue
            }
            $Install | Should -Not -Match 'throw "[a-z]+:[a-z-]+ '
        }

        It 'keeps no transcript machinery in the emitted scripts' {
            foreach ($Content in @($Install, $Uninstall, $Detect)) {
                $Content | Should -Not -Match 'Start-Transcript'
                $Content | Should -Not -Match 'Stop-Transcript'
            }
        }

        It 'emits no 64-bit relaunch guard in any script' {
            foreach ($Content in @($Install, $Uninstall, $Detect)) {
                $Content.Contains('$env:PROCESSOR_ARCHITEW6432') | Should -BeFalse
            }
        }
    }

    Context 'parameter overrides' {

        It 'uses a rooted Destination as-is' {
            $Rooted = Join-Path -Path $TestDrive -ChildPath 'RootedOut'
            Invoke-IntunePackager -Override @{ Destination = $Rooted }
            $Detect = Join-Path -Path $Rooted -ChildPath 'MyPayload\Detect.ps1'
            Test-Path -Path $Detect | Should -BeTrue
        }

        It 'honors an explicit Version over the manifest version' {
            Invoke-IntunePackager -Override @{
                Destination = 'VerOut'
                Version     = '9.9.9'
            }
            $Install = Get-EmittedInstall -OutName 'VerOut'
            $Install.Contains("`$PackageVersion = '9.9.9'") | Should -BeTrue
        }

        It 'bakes an explicit InstallDir as a literal path' {
            Invoke-IntunePackager -Override @{
                Destination = 'DirOut'
                InstallDir  = 'C:\Custom\Dir'
            }
            $Install = Get-EmittedInstall -OutName 'DirOut'
            $Install.Contains("`$InstallDir = 'C:\Custom\Dir'") | Should -BeTrue
        }

        It 'normalizes a TaskPath without surrounding backslashes' {
            Invoke-IntunePackager -Override @{
                Destination = 'TaskOut'
                TaskPath    = 'CustomFolder'
            }
            $Install = Get-EmittedInstall -OutName 'TaskOut'
            $Install.Contains("`$TaskPath = '\CustomFolder\'") | Should -BeTrue
        }

        It 'takes the build id suffix from MODULEBUILD_ID when set' {
            $Saved = $env:MODULEBUILD_ID
            try {
                $env:MODULEBUILD_ID = 'abcdef012345'
                Invoke-IntunePackager -Override @{ Destination = 'EnvIdOut' }
            } finally {
                $env:MODULEBUILD_ID = $Saved
            }
            $Install = Get-EmittedInstall -OutName 'EnvIdOut'
            Get-BakedBuildId -Content $Install | Should -Be '1.2.3-abcdef012345'
        }

        It 'mints a fresh build id per package when MODULEBUILD_ID is unset' {
            $Saved = $env:MODULEBUILD_ID
            try {
                $env:MODULEBUILD_ID = $null
                Invoke-IntunePackager -Override @{ Destination = 'FreshIdAOut' }
                Invoke-IntunePackager -Override @{ Destination = 'FreshIdBOut' }
            } finally {
                $env:MODULEBUILD_ID = $Saved
            }
            $IdA = Get-BakedBuildId -Content (Get-EmittedInstall -OutName 'FreshIdAOut')
            $IdB = Get-BakedBuildId -Content (Get-EmittedInstall -OutName 'FreshIdBOut')
            $IdA | Should -Match '^1\.2\.3-[0-9a-f]{12}$'
            $IdB | Should -Not -Be $IdA
        }

        It 'runs the payload with no arguments beyond its path' {
            Invoke-IntunePackager -Override @{ Destination = 'NoArgsOut' }
            $Install = Get-EmittedInstall -OutName 'NoArgsOut'
            $Detect = Get-EmittedDetect -OutName 'NoArgsOut'
            $Install | Should -Not -Match 'PayloadArguments'
            $Install.Contains(
                '$PayloadCommand = ''-NoProfile -ExecutionPolicy Bypass -File "'' +') |
                Should -BeTrue
            $Detect | Should -Not -Match 'PayloadArguments|InstallCommand'
            $Detect | Should -Not -Match 'Task\.Actions'
        }

        It 'names the package folder and .intunewin after PackageName' {
            Invoke-IntunePackager -Override @{
                Destination = 'NameOut'
                PackageName = 'CustomName'
            }
            $RelPackage = 'NameOut\CustomName\CustomName.intunewin'
            Join-Path -Path $ModuleDir -ChildPath $RelPackage | Should -Exist
        }

        It 'emits an hourly repetition trigger' {
            Invoke-IntunePackager -Override @{
                Destination           = 'HourOut'
                ScheduleType          = 'Hourly'
                ScheduleIntervalHours = 2
            }
            $Install = Get-EmittedInstall -OutName 'HourOut'
            $Install.Contains('RepetitionInterval = (New-TimeSpan -Hours 2)') |
                Should -BeTrue
            $Install.Contains('RepetitionDuration = ([TimeSpan]::MaxValue)') |
                Should -BeTrue
        }

        It 'emits a weekly trigger with the given days' {
            Invoke-IntunePackager -Override @{
                Destination        = 'WeekOut'
                ScheduleType       = 'Weekly'
                ScheduleDaysOfWeek = @('Monday', 'Friday')
                ScheduleAt         = '18:30'
            }
            $Install = Get-EmittedInstall -OutName 'WeekOut'
            $Install.Contains("DaysOfWeek = @('Monday', 'Friday')") | Should -BeTrue
            $Install.Contains("At         = '18:30'") | Should -BeTrue
        }

        It 'emits a startup trigger' {
            Invoke-IntunePackager -Override @{
                Destination  = 'BootOut'
                ScheduleType = 'AtStartup'
            }
            $Install = Get-EmittedInstall -OutName 'BootOut'
            $Install.Contains('New-ScheduledTaskTrigger -AtStartup') | Should -BeTrue
        }

        It 'omits RandomDelay by default' {
            Invoke-IntunePackager -Override @{ Destination = 'NoDelayOut' }
            $Install = Get-EmittedInstall -OutName 'NoDelayOut'
            $Install | Should -Not -Match 'RandomDelay'
        }

        It 'adds a random delay to a daily trigger' {
            Invoke-IntunePackager -Override @{
                Destination        = 'DelayDailyOut'
                RandomDelayMinutes = 45
            }
            $Install = Get-EmittedInstall -OutName 'DelayDailyOut'
            $Install.Contains(
                "-RandomDelay (New-TimeSpan -Minutes 45)") | Should -BeTrue
        }

        It 'adds a random delay to a weekly trigger' {
            Invoke-IntunePackager -Override @{
                Destination        = 'DelayWeekOut'
                ScheduleType       = 'Weekly'
                RandomDelayMinutes = 30
            }
            $Install = Get-EmittedInstall -OutName 'DelayWeekOut'
            $Install.Contains(
                'RandomDelay = (New-TimeSpan -Minutes 30)') | Should -BeTrue
        }

        It 'adds a random delay to an hourly trigger' {
            Invoke-IntunePackager -Override @{
                Destination        = 'DelayHourOut'
                ScheduleType       = 'Hourly'
                RandomDelayMinutes = 15
            }
            $Install = Get-EmittedInstall -OutName 'DelayHourOut'
            $Install.Contains(
                'RandomDelay = (New-TimeSpan -Minutes 15)') | Should -BeTrue
        }
    }

    Context 'failure modes' {

        It 'throws when the payload does not exist' {
            {
                Invoke-IntunePackager -Override @{
                    Destination = 'MissOut'
                    PayloadPath = 'Nope\Missing.ps1'
                }
            } | Should -Throw -ExpectedMessage '*was not found*'
        }

        It 'throws when the payload name collides with a generated script' {
            $Colliding = Join-Path -Path $FixtureRoot -ChildPath 'Install.ps1'
            Set-Content -Path $Colliding -Value 'param()'
            {
                Invoke-IntunePackager -Override @{
                    Destination = 'CollideOut'
                    PayloadPath = $Colliding
                }
            } | Should -Throw -ExpectedMessage '*collides*'
        }

        It 'throws when the payload does not parse' {
            $Broken = Join-Path -Path $FixtureRoot -ChildPath 'Broken.ps1'
            Set-Content -Path $Broken -Value 'if ($true) {'
            {
                Invoke-IntunePackager -Override @{
                    Destination = 'BrokenOut'
                    PayloadPath = $Broken
                }
            } | Should -Throw -ExpectedMessage '*parse errors*'
        }

        It 'throws when the explicit packaging tool path is missing' {
            {
                Invoke-IntunePackager -Override @{
                    Destination          = 'NoToolOut'
                    IntuneWinAppUtilPath = 'Q:\Nope\IntuneWinAppUtil.exe'
                }
            } | Should -Throw -ExpectedMessage '*IntuneWinAppUtilPath*'
        }

        It 'throws when the packaging tool exits nonzero' {
            {
                Invoke-IntunePackager -Override @{
                    Destination          = 'FailOut'
                    IntuneWinAppUtilPath = $FailTool
                }
            } | Should -Throw -ExpectedMessage '*exited with code 7*'
        }

        It 'throws when the packaging tool produces no package' {
            {
                Invoke-IntunePackager -Override @{
                    Destination          = 'SilentOut'
                    IntuneWinAppUtilPath = $SilentTool
                }
            } | Should -Throw -ExpectedMessage '*produced no package*'
        }

        It 'throws when RandomDelayMinutes is set for a <_> trigger' -ForEach @(
            'AtStartup', 'AtLogon'
        ) {
            $Type = $_
            {
                Invoke-IntunePackager -Override @{
                    Destination        = "DelayReject$Type"
                    ScheduleType       = $Type
                    RandomDelayMinutes = 20
                }
            } | Should -Throw -ExpectedMessage '*RandomDelayMinutes is not supported*'
        }
    }

    Context 'source templates' {

        BeforeAll {
            $TemplateDir = Join-Path -Path $GeneratorDir -ChildPath 'Intune'
        }

        It 'ships the <_> template as a parseable script' -ForEach @(
            'Install', 'Uninstall', 'Detect'
        ) {
            $TemplatePath = Join-Path -Path $TemplateDir -ChildPath "$_.ps1"
            $TemplatePath | Should -Exist
            Test-GeneratedScriptSyntax -ScriptPath $TemplatePath | Should -Be 0
        }


        It 'carries every injection marker Install.ps1 consumes' {
            $Content = Get-Content -Raw -Path (
                Join-Path -Path $TemplateDir -ChildPath 'Install.ps1')
            foreach ($Marker in @('CONSTANTS', 'FUNCTIONS', 'TRIGGER')) {
                $Content.Contains("#{{$Marker}}") | Should -BeTrue
            }
        }

        It 'carries the markers Uninstall.ps1 consumes and no trigger' {
            $Content = Get-Content -Raw -Path (
                Join-Path -Path $TemplateDir -ChildPath 'Uninstall.ps1')
            $Content.Contains('#{{CONSTANTS}}') | Should -BeTrue
            $Content.Contains('#{{FUNCTIONS}}') | Should -BeTrue
            $Content.Contains('#{{RELAUNCH}}') | Should -BeFalse
            $Content.Contains('#{{TRIGGER}}') | Should -BeFalse
        }

        It 'carries the markers Detect.ps1 consumes and no trigger' {
            $Content = Get-Content -Raw -Path (
                Join-Path -Path $TemplateDir -ChildPath 'Detect.ps1')
            $Content.Contains('#{{CONSTANTS}}') | Should -BeTrue
            $Content.Contains('#{{FUNCTIONS}}') | Should -BeTrue
            $Content.Contains('#{{RELAUNCH}}') | Should -BeFalse
            $Content.Contains('#{{TRIGGER}}') | Should -BeFalse
        }

        It 'leaves no transcript machinery in any template' {
            foreach ($Name in @('Install.ps1', 'Uninstall.ps1', 'Detect.ps1')) {
                $Body = Get-Content -Raw -Path (
                    Join-Path -Path $TemplateDir -ChildPath $Name)
                $Body | Should -Not -Match 'Start-Transcript'
                $Body | Should -Not -Match '#\{\{TRANSCRIPT\}\}'
            }
        }

        It 'leaves no injection marker in the emitted scripts' {
            Invoke-IntunePackager -Override @{ Destination = 'MarkerOut' }
            $PackageRoot = Join-Path -Path $ModuleDir -ChildPath 'MarkerOut\MyPayload'
            $Emitted = @(
                Join-Path -Path $PackageRoot -ChildPath 'Source\Install.ps1'
                Join-Path -Path $PackageRoot -ChildPath 'Detect.ps1'
                Join-Path -Path $PackageRoot -ChildPath 'Source\Uninstall.ps1'
            )
            foreach ($ScriptPath in $Emitted) {
                (Get-Content -Raw -Path $ScriptPath) | Should -Not -Match '#\{\{'
            }
        }
    }

    Context 'content prep tool download' {

        BeforeAll {
            $GeneratorSource = Get-Content -Raw -Path (
                Join-Path -Path $GeneratorDir -ChildPath 'ConvertTo-IntuneWinPackage.ps1')
            # The pinned version and hash the generator downloads and verifies.
            $PinnedVersion = 'v1.8.7'
            $PinnedSha256 =
            'C1BA45B5CB939E84AF064BB7FF4B38FB3DFE33C8DC1078FD9B157672EAE671F6'
            $PinnedUrl = 'https://raw.githubusercontent.com/microsoft/' +
            "Microsoft-Win32-Content-Prep-Tool/$PinnedVersion/IntuneWinAppUtil.exe"
        }

        It 'pins a fixed tool version and SHA256' {
            $GeneratorSource.Contains("`$ToolVersion = '$PinnedVersion'") | Should -BeTrue
            $GeneratorSource.Contains("`$ToolSha256 = '$PinnedSha256'") | Should -BeTrue
        }

        It 'downloads only from the official Microsoft repository' {
            # The URL is built by string concatenation, so assert its parts.
            $GeneratorSource.Contains('raw.githubusercontent.com/microsoft/') |
                Should -BeTrue
            $GeneratorSource.Contains('Microsoft-Win32-Content-Prep-Tool/') |
                Should -BeTrue
            $GeneratorSource.Contains('Invoke-WebRequest') | Should -BeTrue
        }

        It 'verifies the download against the pinned hash and caches under .local' {
            $GeneratorSource.Contains('.Hash -eq $ToolSha256') | Should -BeTrue
            $GeneratorSource | Should -Match 'failed SHA256 verification'
            $GeneratorSource | Should -Match ([regex]::Escape('..\..\.local\Build'))
        }

        It 'can be forced fail-closed with -NoToolDownload' {
            $GeneratorSource | Should -Match '(?m)^\s*\[switch\]\$NoToolDownload'
            $GeneratorSource.Contains('elseif (-not $NoToolDownload) {') | Should -BeTrue
        }

        It 'serves the pinned hash at the pinned URL' -Tag 'integration', 'live' {
            $Temp = Join-Path -Path $TestDrive -ChildPath 'iwau-live.exe'
            $OldProtocol = [Net.ServicePointManager]::SecurityProtocol
            try {
                [Net.ServicePointManager]::SecurityProtocol =
                $OldProtocol -bor [Net.SecurityProtocolType]::Tls12
                Invoke-WebRequest -Uri $PinnedUrl -OutFile $Temp -UseBasicParsing
            } finally {
                [Net.ServicePointManager]::SecurityProtocol = $OldProtocol
            }
            (Get-FileHash -Path $Temp -Algorithm SHA256).Hash | Should -Be $PinnedSha256
        }
    }
}
