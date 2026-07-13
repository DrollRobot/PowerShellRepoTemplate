#Requires -Version 7.5
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Runs selected test categories for the PowerShell module in this repo.

.DESCRIPTION
    Selects and runs one or more test categories by name. Nothing runs by
    default -- you must pass at least one value.

    Individual formatting checks (LineLength, PSSA, etc.) run in isolation,
    with the same orchestrator setup (module load, exclusion globals) as a
    full Formatting run.

    This orchestrator is project-agnostic: the module name is taken from the
    source manifest (not the folder name, so it works in git worktrees), and
    any project-specific setup/teardown lives in optional hook scripts in the
    tests folder -- PreTests.ps1 (run after module load, before the test
    sections) and PostTests.ps1 (always run afterward, even on failure). Both
    are dot-sourced and receive a $TestContext hashtable (ModuleName, RepoRoot,
    TestsFolder, PesterTestsFolder, the bound parameters, and OnlineHandled). A
    hook owning the Online run sets $TestContext.OnlineHandled to suppress the
    generic Online Pester run.

.PARAMETER Test
    One or more test categories to run. Accepted values:

      Offline              -- Pester tests that do not require connectivity.
      Online               -- Pester tests tagged Online. Connectivity/auth
                             setup is provided by the project's PreTests.ps1
                             hook; without one, the Online-tagged tests run as-is.
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


.PARAMETER Path
    Scope the run to a single file or folder instead of the whole repo. The
    formatting/lint checks run against this path (a file checks just that file;
    a folder checks everything matching under it, recursively). For Offline and
    Online, this path is what Invoke-Pester scans -- e.g. point it at a single
    *.Tests.ps1 file. Defaults to the repo root, so omitting it is unchanged.

.PARAMETER InteractiveAuth
    Passed through to the project's PreTests.ps1 hook via $TestContext for use
    with Online runs. Projects whose Online tests need an interactive sign-in
    (or other interactive setup) read this from $TestContext; when omitted
    (default) setup stays non-interactive. Projects without an Online hook
    ignore it.

    Requires Online; rejected without it.

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
    .\Tests.ps1 LineLength -Path .\Source\Public\Get-Script.ps1
    Runs the line-length check against a single file.

.EXAMPLE
    .\Tests.ps1 PSSA -Path .\Source\Public
    Runs PSScriptAnalyzer against just the Source\Public folder.

.EXAMPLE
    .\Tests.ps1 Offline -Path .\tests\pester\Get-Script.Tests.ps1
    Runs one offline Pester test file.

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
    [Parameter(Position = 0, Mandatory, ValueFromRemainingArguments)]
    [ValidateSet(
        'Offline', 'Online', 'Formatting',
        'LineLength', 'BacktickContinuation', 'FormatOperator', 'JoinPath',
        'ModuleSyntax', 'NonASCIICharacters', 'WriteVerboseDebug', 'TrailingWhitespace',
        'FindUnwantedStrings', 'FixmeComments', 'ExplicitModuleImport', 'PSSA', 'AutoFormat'
    )]
    [string[]] $Test,

    [Parameter()]
    [string] $Path,

    [Parameter()]
    [switch] $InteractiveAuth,

    [Parameter()]
    [switch] $Built,

    [Parameter()]
    [switch] $Quiet
)

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseDeclaredVarsMoreThanAssignments', 'ScriptVersion')]
$ScriptVersion = '1.0.0'

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

# Optional: scope the run to a single file or folder instead of the whole repo.
# $TargetPath feeds the formatting checks' -Path; defaults to the repo root so
# behavior is unchanged when -Path is omitted.
if ($PSBoundParameters.ContainsKey('Path')) {
    $ResolvedTarget = Resolve-Path -Path $Path -ErrorAction SilentlyContinue
    if (-not $ResolvedTarget) {
        Write-Host "Path not found: $Path" -ForegroundColor Yellow
        exit 1
    }
    $TargetPath = $ResolvedTarget.Path
}
else {
    $TargetPath = $PSScriptRoot
}

# Import the module under test so Pester tests and PSScriptAnalyzer both have
# access to full parameter metadata for all of the module's functions and cmdlets.
#
# Module name comes from the source manifest, not the folder name, so the script
# works in git worktrees (folder named after the branch) and ports to other
# projects. Mirrors Build.ps1's manifest-glob approach.
# Search Source\ first, then the repo root (built/flat layouts); fall back to the
# folder leaf only if no manifest exists at all.
$ManifestSearchDirs = @((Join-Path -Path $PSScriptRoot -ChildPath 'Source'), $PSScriptRoot)
$SrcManifest = $null
foreach ($Dir in $ManifestSearchDirs) {
    $SrcManifest = Get-ChildItem -Path $Dir -Filter '*.psd1' -ErrorAction SilentlyContinue |
        Where-Object Name -ne 'Build.psd1' | Select-Object -First 1
    if ($SrcManifest) { break }
}
$ModuleName = if ($SrcManifest) {
    $SrcManifest.BaseName
} else {
    Split-Path -Path $PSScriptRoot -Leaf
}
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

# Where Pester looks: the whole pester folder by default, or the -Path target
# (e.g. a single *.Tests.ps1 file) when one was given.
$PesterTarget = if ($PSBoundParameters.ContainsKey('Path')) {
    $TargetPath
} else {
    $PesterTestsFolder
}

# Compute build-artifact exclusions once; formatting scripts merge these at runtime.
# CopyPaths in Build.psd1 (e.g. ScriptsToProcess, Data) are copied to the repo root
# by a -BuildToRoot build alongside the built psm1/psd1; versioned builds land under
# Output\. The checks match these names ROOT-ANCHORED, so excluding the built copies
# at the root never also hides the authoritative source under Source\ (which shares
# those folder names).
$BuildPsd1Path = Join-Path -Path $PSScriptRoot -ChildPath 'source\Build.psd1'
$BuildConfig = Import-PowerShellDataFile -Path $BuildPsd1Path
$CopiedFolderNames = @($BuildConfig.CopyPaths | ForEach-Object { Split-Path -Path $_ -Leaf })

# Exposed as a global (not just via $TestContext) because the formatting/lint
# scripts run as separate invocations and can only see globals. Test-Explicit-
# ModuleImport prefers this over folder-name detection, so the module name stays
# correct in a git worktree (where the folder is the branch, not the module name).
$Global:Dev_ModuleName = $ModuleName

$Global:Dev_FormattingExclusions = @{
    ExcludeFiles   = @(
        "$ModuleName.psd1"
        "$ModuleName.psm1"
    )
    # Built copies at the repo root (CopiedFolderNames) plus the versioned-build
    # Output\ tree and the .staging temp dir. All matched root-anchored.
    ExcludeFolders = $CopiedFolderNames + @('Output', '.staging')
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

# --- Project hooks: optional per-project setup/teardown ----------------------
# PreTests.ps1 runs after module load, before the test sections; PostTests.ps1
# always runs afterward (even on failure) for cleanup. Both are dot-sourced so
# they can read and restore this script's variables and share state with each
# other. They receive run details via $TestContext. A throw from PreTests aborts
# the run, but PostTests still runs. Keeping the project-specific setup/teardown
# in these hooks lets this orchestrator stay portable across PowerShell projects.
$TestContext = @{
    ModuleName        = $ModuleName
    RepoRoot          = $PSScriptRoot
    TestsFolder       = $TestsFolder
    PesterTestsFolder = $PesterTestsFolder
    # Run target: $TargetPath is a single file/folder (or the repo root by
    # default); $PesterTarget is what Invoke-Pester should scan.
    TargetPath        = $TargetPath
    PesterTarget      = $PesterTarget
    Test              = $Test
    InteractiveAuth   = [bool] $InteractiveAuth
    Built             = [bool] $Built
    Quiet             = [bool] $Quiet
    # A hook may set this true to signal it owns the Online run (auth, gating,
    # multi-pass); the generic Online run below is then skipped.
    OnlineHandled     = $false
}
$PreTestsHook = Join-Path -Path $TestsFolder -ChildPath 'PreTests.ps1'
$PostTestsHook = Join-Path -Path $TestsFolder -ChildPath 'PostTests.ps1'

# Track Pester failures across sections so the script can exit nonzero for CI.
$PesterFailedCount = 0

# Track formatting/lint check failures (a nonzero exit from an individual check)
# so a multi-check run gates on ALL requested checks, not just the last one that
# happened to run. Without this, the process exit code would reflect only the
# final check invoked.
$FormattingFailedCount = 0

try {
    if (Test-Path $PreTestsHook) {
        Write-Host "`n=== PreTests.ps1 ===" -ForegroundColor Cyan
        . $PreTestsHook
    }

    # --- Offline ---
    if ('Offline' -in $Test) {
        Write-Host "`n=== Invoke-Pester (Offline) ===" -ForegroundColor Cyan
        $OfflineResult = Invoke-Pester -Path $PesterTarget -ExcludeTagFilter 'Online' -PassThru
        $PesterFailedCount += $OfflineResult.FailedCount
    }

    # --- Individual formatting tests ---
    foreach ($IndividualTest in $IndividualTests) {
        foreach ($ScriptsDir in @($TestsFolder, $LocalTestsFolder)) {
            $ScriptFile = $FormattingScriptMap[$IndividualTest]
            $ScriptPath = Join-Path -Path $ScriptsDir -ChildPath $ScriptFile
            if (-not (Test-Path $ScriptPath)) { continue }
            $RelPath = [System.IO.Path]::GetRelativePath($PSScriptRoot, $ScriptPath)
            Write-Host "`n=== $RelPath ===" -ForegroundColor Cyan
            # Forward -Quiet only to scripts that declare it (auto-fixers may not).
            $SupportsQuiet = (Get-Command $ScriptPath).Parameters.ContainsKey('Quiet')
            $QuietSplat = if ($Quiet -and $SupportsQuiet) { @{ Quiet = $true } } else { @{} }
            # Test-PSSA also takes -RepoRoot so repo-anchored suppressions resolve
            # when -Path targets a subfolder/file.
            $PssaSplat = @{ Path = $TargetPath; RepoRoot = $PSScriptRoot; Recurse = $true }
            switch ($IndividualTest) {
                'PSSA' { & $ScriptPath @PssaSplat @QuietSplat }
                'AutoFormat' {
                    $TwsFile = 'Format-TrailingWhitespace.ps1'
                    $TwsPath = Join-Path -Path $ScriptsDir -ChildPath $TwsFile
                    if (Test-Path $TwsPath) {
                        $TwsRel = [System.IO.Path]::GetRelativePath($PSScriptRoot, $TwsPath)
                        Write-Host "`n=== $TwsRel ===" -ForegroundColor Cyan
                        & $TwsPath -Path $TargetPath -Recurse
                    }
                    & $ScriptPath @PssaSplat -AutoFormat -Quiet
                }
                default { & $ScriptPath -Path $TargetPath -Recurse @QuietSplat }
            }
            # Tally detection-check failures for the final exit code. The fixers
            # (AutoFormat, TrailingWhitespace) mutate files rather than report, so
            # their exit code does not gate the run.
            if ($IndividualTest -notin @('AutoFormat', 'TrailingWhitespace') -and
                $LASTEXITCODE -ne 0) {
                $FormattingFailedCount++
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
            & $Script.FullName -Path $TargetPath -Recurse
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
            & $Script.FullName -Path $TargetPath -Recurse
        }

        Write-Host "`n=== Test-PSSA ===" -ForegroundColor Cyan
        $AnalyzerScript = Join-Path -Path $TestsFolder -ChildPath 'Test-PSSA.ps1'
        & $AnalyzerScript -Path $TargetPath -RepoRoot $PSScriptRoot -Recurse -AutoFormat
    }

    # --- Online ---
    # Generic run: any Pester tests tagged Online. Projects needing auth, a token
    # cache, or connect-gating provide that in PreTests.ps1, which sets
    # $TestContext.OnlineHandled to take over the Online run entirely.
    if ('Online' -in $Test -and -not $TestContext.OnlineHandled) {
        Write-Host "`n=== Invoke-Pester (Online) ===" -ForegroundColor Cyan
        $OnlineResult = Invoke-Pester -Path $PesterTarget -TagFilter 'Online' -PassThru
        $PesterFailedCount += $OnlineResult.FailedCount
    }
}
finally {
    if (Test-Path $PostTestsHook) {
        Write-Host "`n=== PostTests.ps1 ===" -ForegroundColor Cyan
        . $PostTestsHook
    }
}

# Nonzero exit so CI and callers can gate on Pester and formatting results.
if ($PesterFailedCount -gt 0 -or $FormattingFailedCount -gt 0) { exit 1 }
