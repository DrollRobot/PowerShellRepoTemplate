#Requires -Version 7.5
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Runs selected test categories for this module.

.DESCRIPTION
    Selects and runs one or more test categories by name. Nothing runs by
    default -- you must pass at least one value.

    Individual formatting checks (LineLength, PSSA, etc.) run in isolation,
    with the same orchestrator setup (module load, exclusion globals) as a
    full Formatting run.

.PARAMETER Test
    One or more test categories to run. Accepted values:

      Offline              -- Pester tests that do not require connectivity.
      Online               -- Pester tests tagged Online. These require a live
                             connection to whatever external service the module
                             targets; establish the session before running.
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
                             it uses, so module imports are explicit.
      PSSA                 -- PSScriptAnalyzer detection only; reports issues without
                             modifying any files.

      Formatting           -- All formatting checks in order: auto-fixers,
                             linters, then PSSA. Equivalent to passing every
                             individual formatting value at once. Intended for
                             Human use. Agents should run individual checks.
      TrailingWhitespace   -- Remove trailing whitespace (auto-fixes in place).
                             Included in AutoFormat.


.PARAMETER Built
    Load the module from the built artifact instead of the source manifest.
    Looks for a root build first (Build.ps1 -BuildToRoot), then falls back to
    the newest versioned build under Output\. Only valid with Offline and
    Online.

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
    [switch] $Built,

    [Parameter()]
    [switch] $Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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
# access to full parameter metadata for all module functions and cmdlets.
$ModuleName = Split-Path -Path $PSScriptRoot -Leaf
$ManifestPath = if ($Built) {
    # Prefer a flat root build (Build.ps1 -BuildToRoot) when one exists.
    $RootManifest = Join-Path -Path $PSScriptRoot -ChildPath "$ModuleName.psd1"
    if (Test-Path $RootManifest) {
        $RootManifest
    } else {
        # Default build layout: Output\<ModuleName>\<version>\<ModuleName>.psd1
        $OutputRoot = Join-Path -Path $PSScriptRoot -ChildPath "Output\$ModuleName"
        Get-ChildItem -Path $OutputRoot -Directory -ErrorAction SilentlyContinue |
            Sort-Object { [version]$_.Name } -Descending |
            Select-Object -First 1 |
            ForEach-Object { Join-Path -Path $_.FullName -ChildPath "$ModuleName.psd1" }
    }
} else {
    Join-Path -Path $PSScriptRoot -ChildPath "source\$ModuleName.psd1"
}
if ($ManifestPath -and (Test-Path $ManifestPath)) {
    $ModuleStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $RelManifestPath = [System.IO.Path]::GetRelativePath($PSScriptRoot, $ManifestPath)
    Write-Host "Loading module from: $RelManifestPath" -ForegroundColor Cyan
    Import-Module $ManifestPath -Force
    $ModuleStopwatch.Stop()
    Write-Host "Module loaded in $($ModuleStopwatch.Elapsed.TotalSeconds)s." -ForegroundColor Cyan
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

# Track Pester failures across sections so the script can exit nonzero for CI.
$PesterFailedCount = 0

# --- Offline ---
if ('Offline' -in $Test) {
    Write-Host "`n=== Invoke-Pester (Offline) ===" -ForegroundColor Cyan
    $OfflineResult = Invoke-Pester -Path $PesterTestsFolder -ExcludeTagFilter 'Online' -PassThru
    $PesterFailedCount += $OfflineResult.FailedCount
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
    # Runs every Pester test tagged 'Online'. If your module needs a live session,
    # connection setup belongs here (establish it before invoking Pester, restore
    # any overridden state in a finally block). Test secrets belong in
    # Tests\.env.ps1 (gitignored) -- see Tests\.env.ps1.example.
    Write-Host "`n=== Invoke-Pester (Online) ===" -ForegroundColor Cyan
    $OnlineResult = Invoke-Pester -Path $PesterTestsFolder -TagFilter 'Online' -PassThru
    $PesterFailedCount += $OnlineResult.FailedCount
}

# Nonzero exit so CI and callers can gate on Pester results.
if ($PesterFailedCount -gt 0) { exit 1 }
