#Requires -Version 7.5
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Runs selected test categories for M365IncidentResponseTools.

.DESCRIPTION
    Selects and runs one or more test categories by name. Nothing runs by
    default -- you must pass at least one value.

    Individual formatting checks (LineLength, PSSA, etc.) run in isolation,
    with the same orchestrator setup (module load, exclusion globals) as a
    full Formatting run.

.PARAMETER Test
    One or more test categories to run. Accepted values:

      Offline              -- Pester tests that do not require connectivity.
      Online               -- Pester tests tagged Online. Requires an active
                             Microsoft 365 session; Connect-IRT is called
                             automatically.
      AutoFormat           -- Trailing-whitespace fix followed by PSScriptAnalyzer
                             auto-fix and format; suppresses lint findings output.
      LineLength           -- Check lines exceeding 100 characters.
      BacktickContinuation -- Check for backtick line-continuation escapes.
      FormatOperator       -- Check for -f string format operator usage.
      JoinPath             -- Check for path-building anti-patterns.
      ModuleSyntax         -- Parse all files for syntax errors.
      NonASCIICharacters   -- Check for non-ASCII characters.
      FindUnwantedStrings  -- Scan for user-defined unwanted patterns.
      FixmeComments        -- Report FIXME comments.
      WriteVerboseDebug    -- Check for Write-Verbose and Write-Debug calls.
      ExplicitModuleImport -- Check that each source file names every external module
                             it uses, so Import-IRTModule calls are explicit.
      PSSA                 -- PSScriptAnalyzer detection only; reports issues without
                             modifying any files.

      Formatting           -- All formatting checks in order: auto-fixers,
                             linters, then PSSA. Equivalent to passing every
                             individual formatting value at once. Intended for
                             Human use. Agents should run individual checks.
      TrailingWhitespace   -- Remove trailing whitespace (auto-fixes in place).
                             Included in AutoFormat.


.PARAMETER InteractiveAuth
    Used with Online. Deletes the test token cache and prompts for interactive
    sign-in, then immediately reconnects silently to verify the cache
    round-trip.

    When omitted (default), Connect-IRT runs in silent-only mode: MSAL
    attempts a token refresh from the test cache and fails immediately if no
    cached credentials exist. This is the default for non-interactive runs.

    Requires Online; rejected without it.

.PARAMETER Built
    Load the module from the built artifact at the repo root instead of the
    source manifest. Only valid with Offline and Online.

.PARAMETER Quiet
    Forward -Quiet to the individual formatting checks so each prints only its
    one-line summary (files scanned + findings), suppressing detail tables and
    finding notes. Intended for agents that just need a quick pass/fail. Applies
    to individual checks, not the Formatting aggregate or Pester runs.

.EXAMPLE
    .\Tests.ps1 Offline
    Runs Pester offline tests only.

.EXAMPLE
    .\Tests.ps1 LineLength -Quiet
    Runs the line-length check and prints only its one-line summary.

.EXAMPLE
    .\Tests.ps1 Offline Online
    Runs all Pester tests (offline and online).

.EXAMPLE
    .\Tests.ps1 Formatting
    Runs all formatting checks and auto-fixes.

.EXAMPLE
    .\Tests.ps1 LineLength JoinPath
    Runs only the line-length and path-building checks.

.EXAMPLE
    .\Tests.ps1 AutoFormat
    Fixes trailing whitespace then runs PSSA auto-fix and formatting; suppresses lint findings.

.EXAMPLE
    .\Tests.ps1 Online -InteractiveAuth
    Runs online tests with interactive sign-in.

.EXAMPLE
    .\Tests.ps1 Offline Online -Built
    Runs Pester tests against the compiled module artifact.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '')]
[CmdletBinding()]
param(
    [Parameter(Position = 0, Mandatory)]
    [ValidateSet(
        'Offline', 'Online', 'Formatting',
        'LineLength', 'BacktickContinuation', 'FormatOperator', 'JoinPath',
        'ModuleSyntax', 'NonASCIICharacters', 'WriteVerboseDebug', 'TrailingWhitespace',
        'FindUnwantedStrings', 'FixmeComments', 'ExplicitModuleImport', 'PSSA', 'AutoFormat'
    )]
    [string[]] $Test,

    [Parameter()]
    [switch] $InteractiveAuth,

    [Parameter()]
    [switch] $Built,

    [Parameter()]
    [switch] $Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($InteractiveAuth -and 'Online' -notin $Test) {
    Write-Host '-InteractiveAuth requires -Test Online.' -ForegroundColor Yellow
    exit 1
}

# error when requesting formatting tests on built module
$FormattingOnlyValues = @(
    'Formatting', 'LineLength', 'BacktickContinuation', 'FormatOperator', 'JoinPath',
    'ModuleSyntax', 'NonASCIICharacters', 'WriteVerboseDebug', 'TrailingWhitespace',
    'FindUnwantedStrings', 'FixmeComments', 'ExplicitModuleImport', 'PSSA', 'AutoFormat'
)
if ($Built -and ($Test | Where-Object { $_ -in $FormattingOnlyValues })) {
    $BadList = ($Test | Where-Object { $_ -in $FormattingOnlyValues }) -join ', '
    Write-Host "-Built cannot be used with: $BadList" -ForegroundColor Yellow
    exit 1
}

# Import the module under test so Pester tests and PSScriptAnalyzer both have
# access to full parameter metadata for all IRT functions and cmdlets.
$ModuleName = Split-Path -Path $PSScriptRoot -Leaf
$ManifestPath = if ($Built) {
    Join-Path -Path $PSScriptRoot -ChildPath "$ModuleName.psd1"
} else {
    Join-Path -Path $PSScriptRoot -ChildPath "source\$ModuleName.psd1"
}
if (Test-Path $ManifestPath) {
    $ModuleStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $RelManifestPath = [System.IO.Path]::GetRelativePath($PSScriptRoot, $ManifestPath)
    Write-Host "Loading module from: $RelManifestPath" -ForegroundColor Cyan
    Import-Module $ManifestPath -Force
    $ModuleStopwatch.Stop()
    Write-Host "Module loaded in $($ModuleStopwatch.Elapsed.TotalSeconds)s." -ForegroundColor Cyan

    # Import-IRTConfig runs automatically on module load (via suffix.ps1) and always
    # populates $Global:IRT_Config -- either from the user's config file in $env:APPDATA
    # or, on first run, by creating that file from the bundled template. If the variable
    # is still unset after module import, something is wrong with the installation and
    # tests should not proceed with silent defaults.
    $IrtConfigVar = Get-Variable -Name 'IRT_Config' -Scope Global -ErrorAction SilentlyContinue
    if (-not $IrtConfigVar -or -not $IrtConfigVar.Value) {
        $ErrMsg = '$Global:IRT_Config not found. ' +
        "If you've never run the module before, try importing to create the user config file."
        Write-Error $ErrMsg
        exit 1
    }
    $KeyCount = ($Global:IRT_Config.PSObject.Properties.Name).Count
    Write-Host "Config loaded ($KeyCount keys)." -ForegroundColor Cyan
}
else {
    $ErrMsg = "Module manifest not found at $ManifestPath. " +
    "Make sure you're running this from the repo root and the manifest file is present."
    Write-Error $ErrMsg
    exit 1
}

$TestsFolder = Join-Path -Path $PSScriptRoot -ChildPath 'tests'
$PesterTestsFolder = Join-Path -Path $PSScriptRoot -ChildPath 'tests\pester'
$LocalTestsFolder = Join-Path -Path $PSScriptRoot -ChildPath '.local\tests'

# Compute build-artifact exclusions once; formatting scripts merge these at runtime.
# CopyPaths in Build.psd1 land at the repo root after a build, alongside the built psm1/psd1.
$BuildPsd1Path = Join-Path -Path $PSScriptRoot -ChildPath 'source\Build.psd1'
$BuildConfig = Import-PowerShellDataFile -Path $BuildPsd1Path
$CopiedFolderNames = @($BuildConfig.CopyPaths | ForEach-Object { Split-Path -Path $_ -Leaf })
$Global:Dev_FormattingExclusions = @{
    ExcludeFiles   = @(
        "$ModuleName.psd1"
        "$ModuleName.psm1"
    )
    ExcludeFolders = $CopiedFolderNames
}

# Map each individual formatting test name to its script file.
$FormattingScriptMap = @{
    'TrailingWhitespace'   = 'Format-TrailingWhitespace.ps1'
    'BacktickContinuation' = 'Test-BacktickContinuation.ps1'
    'ExplicitModuleImport' = 'Test-ExplicitModuleImport.ps1'
    'FindUnwantedStrings'  = 'Test-FindUnwantedStrings.ps1'
    'FixmeComments'        = 'Test-FixmeComments.ps1'
    'FormatOperator'       = 'Test-FormatOperator.ps1'
    'JoinPath'             = 'Test-JoinPath.ps1'
    'LineLength'           = 'Test-LineLength.ps1'
    'ModuleSyntax'         = 'Test-ModuleSyntax.ps1'
    'NonASCIICharacters'   = 'Test-NonASCIICharacters.ps1'
    'WriteVerboseDebug'    = 'Test-WriteVerboseDebug.ps1'
    'PSSA'                 = 'Test-PSSA.ps1'
    'AutoFormat'           = 'Test-PSSA.ps1'
}

$IndividualTests = @($Test | Where-Object { $FormattingScriptMap.ContainsKey($_) })

# --- Offline ---
if ('Offline' -in $Test) {
    Write-Host "`n=== Invoke-Pester (Offline) ===" -ForegroundColor Cyan
    Invoke-Pester -Path $PesterTestsFolder -ExcludeTagFilter 'Online'
}

# --- Individual formatting tests ---
foreach ($IndividualTest in $IndividualTests) {
    foreach ($ScriptsDir in @($TestsFolder, $LocalTestsFolder)) {
        $ScriptPath = Join-Path -Path $ScriptsDir -ChildPath $FormattingScriptMap[$IndividualTest]
        if (-not (Test-Path $ScriptPath)) { continue }
        $RelPath = [System.IO.Path]::GetRelativePath($PSScriptRoot, $ScriptPath)
        Write-Host "`n=== $RelPath ===" -ForegroundColor Cyan
        # Forward -Quiet only to scripts that declare it (auto-fixers may not).
        $SupportsQuiet = (Get-Command $ScriptPath).Parameters.ContainsKey('Quiet')
        $QuietSplat = if ($Quiet -and $SupportsQuiet) { @{ Quiet = $true } } else { @{} }
        switch ($IndividualTest) {
            'PSSA' { & $ScriptPath -Path $PSScriptRoot -Recurse @QuietSplat }
            'AutoFormat' {
                $TwsPath = Join-Path -Path $ScriptsDir -ChildPath 'Format-TrailingWhitespace.ps1'
                if (Test-Path $TwsPath) {
                    $TwsRel = [System.IO.Path]::GetRelativePath($PSScriptRoot, $TwsPath)
                    Write-Host "`n=== $TwsRel ===" -ForegroundColor Cyan
                    & $TwsPath -Path $PSScriptRoot -Recurse
                }
                & $ScriptPath -Path $PSScriptRoot -Recurse -AutoFormat -Quiet
            }
            default { & $ScriptPath -Path $PSScriptRoot -Recurse @QuietSplat }
        }
    }
}

# --- Formatting ---
if ('Formatting' -in $Test) {

    # collect all Format-*.ps1 scripts from tests/ and .local/tests/
    $FormatScripts = [System.Collections.Generic.List[System.IO.FileInfo]](
        Get-ChildItem -Path $TestsFolder -Filter 'Format-*.ps1' |
            Where-Object { $_.Name -notlike '*.Tests.ps1' }
    )
    if (Test-Path $LocalTestsFolder) {
        Get-ChildItem -Path $LocalTestsFolder -Filter 'Format-*.ps1' |
            Where-Object { $_.Name -notlike '*.Tests.ps1' } |
            ForEach-Object { $FormatScripts.Add($_) }
    }
    $FormatScripts = $FormatScripts | Sort-Object Name

    # run each Format-*.ps1 script first, before any of the Test-*.ps1 scripts
    foreach ($Script in $FormatScripts) {
        $RelPath = [System.IO.Path]::GetRelativePath($PSScriptRoot, $Script.FullName)
        Write-Host "`n=== $RelPath ===" -ForegroundColor Cyan
        & $Script.FullName -Path $PSScriptRoot -Recurse
    }

    # collect all Test-*.ps1 scripts from tests/ and .local/tests/, exempting Test-PSSA
    $TestScripts = [System.Collections.Generic.List[System.IO.FileInfo]](
        Get-ChildItem -Path $TestsFolder -Filter 'Test-*.ps1' |
            Where-Object {
                $_.BaseName -ne 'Test-PSSA' -and
                $_.Name -notlike '*.Tests.ps1'
            }
    )
    if (Test-Path $LocalTestsFolder) {
        Get-ChildItem -Path $LocalTestsFolder -Filter 'Test-*.ps1' |
            Where-Object { $_.Name -notlike '*.Tests.ps1' } |
            ForEach-Object { $TestScripts.Add($_) }
    }
    $TestScripts = $TestScripts | Sort-Object Name

    # run each Test-*.ps1 script
    foreach ($Script in $TestScripts) {
        $RelPath = [System.IO.Path]::GetRelativePath($PSScriptRoot, $Script.FullName)
        Write-Host "`n=== $RelPath ===" -ForegroundColor Cyan
        & $Script.FullName -Path $PSScriptRoot -Recurse
    }

    Write-Host "`n=== Test-PSSA ===" -ForegroundColor Cyan
    $AnalyzerScript = Join-Path -Path $TestsFolder -ChildPath 'Test-PSSA.ps1'
    & $AnalyzerScript -Path $PSScriptRoot -Recurse -AutoFormat
}

# --- Online ---
if ('Online' -in $Test) {
    # Derive the test cache path alongside the primary cache.
    $PrimaryCache = $Global:IRT_Config.MsalCachePath
    $CacheParentDir = Split-Path $PrimaryCache -Parent
    $TestCachePath = Join-Path -Path $CacheParentDir -ChildPath 'irt-testing-cache.bin'

    # Override config for this run: always use the test cache with caching forced on.
    $OriginalCachePath = $Global:IRT_Config.MsalCachePath
    $OriginalCacheEnable = $Global:IRT_Config.EnableTokenCache
    $Global:IRT_Config.MsalCachePath = $TestCachePath
    $Global:IRT_Config.EnableTokenCache = $true

    if (-not $OriginalCacheEnable) {
        Write-Host ''
        Write-Host '  WARNING: Online tests override the token cache config.' -ForegroundColor Red
        Write-Host "           Test cache : $TestCachePath" -ForegroundColor Red
        Write-Host '         EnableTokenCache has been forced on for this run.' -ForegroundColor Red
    }

    if ($InteractiveAuth) {
        $env:IRT_TEST_SILENT_AUTH = '0'
        if (Test-Path $TestCachePath) {
            Remove-Item -Path $TestCachePath -Force
            Write-Host ''
            $Msg = '  Deleted existing test token cache. Interactive sign-in will be required.'
            Write-Host $Msg -ForegroundColor Cyan
        }
    }
    else {
        $env:IRT_TEST_SILENT_AUTH = '1'
    }

    # Pass 1: Connect-IRT.Tests.ps1 runs first. Its BeforeAll genuinely tests
    # Connect-IRT by clearing $Global:IRT_Session and calling it from scratch.
    # On success the session is populated and available to all subsequent files.
    $ConnectTestFile = Join-Path -Path $PesterTestsFolder -ChildPath 'Connect-IRT.Tests.ps1'
    try {
        Write-Host "`n=== Invoke-Pester (Online: Connect-IRT) ===" -ForegroundColor Cyan
        $ConnectResult = Invoke-Pester -Path $ConnectTestFile -TagFilter 'Online' -PassThru

        # Pass 2: remaining online tests, only if the connection is now active.
        # Skipping when the connection tests failed avoids a cascade of misleading
        # failures in every downstream test file that relies on the session.
        if ($ConnectResult.FailedCount -gt 0 -or -not $Global:IRT_Session) {
            Write-Host ''
            $Msg = '  Connect-IRT online tests failed or no session was established.'
            Write-Host $Msg -ForegroundColor Red
            Write-Host '  Skipping remaining online tests.' -ForegroundColor Red
        }
        else {
            $RemainingTests = Get-ChildItem -Path $PesterTestsFolder -Filter '*.Tests.ps1' |
                Where-Object { $_.Name -ne 'Connect-IRT.Tests.ps1' } |
                Select-Object -ExpandProperty FullName

            if ($RemainingTests) {
                Write-Host "`n=== Invoke-Pester (Online: remaining) ===" -ForegroundColor Cyan
                Invoke-Pester -Path $RemainingTests -TagFilter 'Online'
            }
        }
    }
    finally {
        # Always restore the original config, even if Pester throws.
        $Global:IRT_Config.MsalCachePath = $OriginalCachePath
        $Global:IRT_Config.EnableTokenCache = $OriginalCacheEnable
        $env:IRT_TEST_SILENT_AUTH = $null
    }
}
