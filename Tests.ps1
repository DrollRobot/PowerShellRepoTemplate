#Requires -Version 7.5
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.0.0' }

<#
.SYNOPSIS
    Runs selected test categories for the PowerShell module in this repo.

.DESCRIPTION
    Selects and runs one or more test categories by name. Nothing runs by
    default -- you must pass at least one value.

    Every category gets the same orchestrator setup -- module load, exclusion
    globals, project hooks -- so a single check (LineLength, PSSA, ...) runs in
    isolation but sees exactly what a full run would.

    This orchestrator is project-agnostic: the module name is taken from the
    source manifest (not the folder name, so it works in git worktrees), and
    any project-specific setup/teardown lives in optional hook scripts in the
    tests folder -- PreTests.ps1 (run after module load, before the test
    sections) and PostTests.ps1 (always run afterward, even on failure). Both
    are dot-sourced and receive a $TestContext hashtable (ModuleName, RepoRoot,
    TestsFolder, PesterTestsFolder, the bound parameters, and LiveHandled). A
    hook owning the Live run sets $TestContext.LiveHandled to suppress the
    generic Live Pester run.

.PARAMETER Test
    One or more test categories to run. Positional, so `.\Tests.ps1 NotLive`
    works; several categories are a comma-separated list, `.\Tests.ps1
    NotLive,PSSA`, because the space-separated arguments after the category
    belong to -Path (which a commit hook fills with its staged file names).
    Passing a category name where a path is expected is an error naming this
    rule rather than a confusing missing-path one.

    Accepted values:

      NotLive              -- Pester tests that are not tagged 'live',
                             'destructive', or 'lint'. No connectivity or
                             external resources required.
      Live                 -- Pester tests tagged 'live', excluding any also
                             tagged 'destructive'. Connectivity/auth setup is
                             provided by the project's PreTests.ps1 hook;
                             without one, the live-tagged tests run as-is.
      Lint                 -- All Pester-based lint checks: every
                             *.Lint.Tests.ps1 in Tests\Pester (and
                             .local\tests), tagged 'lint'. Each file runs via a
                             Pester container whose -Data merges
                             Tests\TestConfig.psd1's 'lint' table with the scan
                             target (-Path) and computed build-artifact
                             exclusions. Kept out of NotLive by tag so lint
                             findings never mix into functional test runs.
      Destructive          -- Pester tests tagged 'destructive'. Each such test
                             must also carry exactly one scope tag, 'local' or
                             'remote'; a test tagged 'destructive' with neither
                             (or a scope tag Pester cannot resolve) causes the
                             whole category to refuse, fail-closed. The 'local'
                             subset runs only when DISPOSABLE_ENVIRONMENT=1;
                             the 'remote' subset runs only when
                             Tests\Confirm-RemoteDisposable.ps1 exits 0. See
                             AGENTS.TESTING.md.
      PSSAAutoFormat       -- PSScriptAnalyzer auto-fix and format, applied in
                             place; suppresses findings output. The only
                             file-mutating category.

                             One lint check at a time -- same run as Lint, held
                             to a single *.Lint.Tests.ps1 file:
      LineLength           -- Check lines exceeding 100 characters.
      BacktickContinuation -- Check for backtick line-continuation escapes.
      FormatOperator       -- Check for string format operator usage.
      JoinPath             -- Check for path-building anti-patterns.
      NonASCIICharacters   -- Check for non-ASCII characters.
      UnwantedStrings      -- Scan for project-defined unwanted patterns.
      FixmeComments        -- Report FIXME comments.
      WriteVerboseDebug    -- Check for leftover verbose/debug output calls.

      ModuleSyntax         -- Parse all files for syntax errors.
      ExplicitModuleImport -- Check that each source file names every external module
                             it uses, so module imports are explicit.
      PSSA                 -- PSScriptAnalyzer detection only; reports issues without
                             modifying any files.

.PARAMETER Path
    Scope the run to given files/folders instead of the whole repo. The checks
    run against these paths (a file checks just that file; a folder checks
    everything matching under it, recursively). For NotLive, Live, and
    Destructive, this is what Invoke-Pester scans -- e.g. point it at a single
    *.Tests.ps1 file. Defaults to the repo root, so omitting it is unchanged.

    A list is accepted, so a commit hook can pass its staged files. The lint
    checks take the whole list at once; the script-based checks (ModuleSyntax,
    ExplicitModuleImport, PSSA) take one path each, so they run once per entry.

    This is the remaining-arguments parameter, so the bare arguments after the
    category bind here -- `Tests.ps1 Lint a.ps1 b.ps1` is the same as
    `Tests.ps1 Lint -Path a.ps1, b.ps1`. That is what lets pre-commit append its
    staged file names to the hook's command line with no wrapper script.

.PARAMETER ConfigPath
    Read per-category settings from this file instead of Tests\TestConfig.psd1
    -- e.g. a stricter profile for CI, or a fixture's own settings when testing
    a check. Same shape as Tests\TestConfig.psd1 (a hashtable keyed by category).
    A path that does not exist is an error.

.PARAMETER InteractiveAuth
    Passed through to the project's PreTests.ps1 hook via $TestContext for use
    with Live runs. Projects whose live-tagged tests need an interactive
    sign-in (or other interactive setup) read this from $TestContext; when
    omitted (default) setup stays non-interactive. Projects without a Live
    hook ignore it.

    Requires Live; rejected without it.

.PARAMETER Built
    Load the module from the built artifact instead of the source manifest.
    Looks for a root build first (Build.psd1 BuildToRoot), then a flat build
    at Output\<ModuleName>\, then falls back to the newest versioned build
    under Output\. Only valid with NotLive, Live, and Destructive.

.PARAMETER Quiet
    Forward -Quiet to the script-based checks so each prints only its one-line
    summary (files scanned + findings), suppressing detail tables and finding
    notes. For the lint categories, suppresses per-finding output and prints a
    one-line summary instead. Intended for agents that just need a quick
    pass/fail. Does not apply to the NotLive, Live, and Destructive Pester runs.

.EXAMPLE
    .\Tests.ps1 NotLive
    Runs Pester tests that need no connectivity or external resources.

.EXAMPLE
    .\Tests.ps1 LineLength -Quiet
    Runs the line-length check and prints only its one-line summary.

.EXAMPLE
    .\Tests.ps1 NotLive,Live
    Runs all non-destructive Pester tests (NotLive and Live). Several categories
    are comma-separated -- space-separated arguments bind to -Path.

.EXAMPLE
    .\Tests.ps1 Lint
    Runs the Pester-based lint checks with values from Tests\TestConfig.psd1.

.EXAMPLE
    .\Tests.ps1 Lint -Path .\Source\Public -Quiet
    Lints just Source\Public and prints a one-line summary.

.EXAMPLE
    .\Tests.ps1 Lint -ConfigPath .\Tests\TestConfig.CI.psd1
    Runs the lint checks with a different settings file.

.EXAMPLE
    .\Tests.ps1 LineLength,JoinPath
    Runs only the line-length and path-building checks.

.EXAMPLE
    .\Tests.ps1 LineLength -Path .\Source\Public\Get-Script.ps1
    Runs the line-length check against a single file.

.EXAMPLE
    .\Tests.ps1 PSSA -Path .\Source\Public
    Runs PSScriptAnalyzer against just the Source\Public folder.

.EXAMPLE
    .\Tests.ps1 NotLive -Path .\tests\pester\Get-Script.Tests.ps1
    Runs one NotLive Pester test file.

.EXAMPLE
    .\Tests.ps1 PSSAAutoFormat
    Applies PSScriptAnalyzer's auto-fixes and formatting in place.

.EXAMPLE
    .\Tests.ps1 Lint -Quiet .\Source\Public\Get-Script.ps1 .\Build.ps1
    Lints two files. -Path takes the remaining arguments, so a commit hook can
    append its staged file names directly; `-Path a.ps1, b.ps1` is equivalent.

.EXAMPLE
    .\Tests.ps1 Live -InteractiveAuth
    Runs live tests with interactive sign-in.

.EXAMPLE
    .\Tests.ps1 Destructive
    Runs destructive tests. The 'local' subset requires DISPOSABLE_ENVIRONMENT=1;
    the 'remote' subset requires Tests\Confirm-RemoteDisposable.ps1 to confirm it.

.EXAMPLE
    .\Tests.ps1 NotLive,Live -Built
    Runs Pester tests against the compiled module artifact.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '')]
[CmdletBinding()]
param(
    [Parameter(Position = 0, Mandatory)]
    [ValidateSet(
        'NotLive', 'Live', 'Destructive', 'Lint',
        'LineLength', 'BacktickContinuation', 'FormatOperator', 'JoinPath',
        'ModuleSyntax', 'NonASCIICharacters', 'WriteVerboseDebug',
        'UnwantedStrings', 'FixmeComments', 'ExplicitModuleImport', 'PSSA',
        'PSSAAutoFormat'
    )]
    [string[]] $Test,

    # Remaining arguments, not just -Path: pre-commit appends its staged file
    # names to the hook's command line as separate arguments, and this is where
    # they have to land. Only one parameter can claim them, which is why -Test
    # takes a comma-separated list rather than space-separated words.
    [Parameter(Position = 1, ValueFromRemainingArguments)]
    [string[]] $Path,

    [Parameter()]
    [string] $ConfigPath,

    [Parameter()]
    [switch] $InteractiveAuth,

    [Parameter()]
    [switch] $Built,

    [Parameter()]
    [switch] $Quiet
)

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseDeclaredVarsMoreThanAssignments', 'ScriptVersion')]
$ScriptVersion = '1.3.0'

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($InteractiveAuth -and 'Live' -notin $Test) {
    throw '-InteractiveAuth requires -Test Live.'
}

# error when requesting formatting tests on built module
$FormattingOnlyValues = @(
    'Lint', 'LineLength', 'BacktickContinuation', 'FormatOperator', 'JoinPath',
    'ModuleSyntax', 'NonASCIICharacters', 'WriteVerboseDebug',
    'UnwantedStrings', 'FixmeComments', 'ExplicitModuleImport', 'PSSA',
    'PSSAAutoFormat'
)
if ($Built -and ($Test | Where-Object { $_ -in $FormattingOnlyValues })) {
    $BadList = ($Test | Where-Object { $_ -in $FormattingOnlyValues }) -join ', '
    throw "-Built cannot be used with: $BadList"
}

# Optional: scope the run to files/folders instead of the whole repo.
# $TargetPath feeds the checks' -Path; defaults to the repo root so behavior is
# unchanged when -Path is omitted. A list is accepted so a commit hook can pass
# its staged files; every entry must exist, and all of them are reported at once
# rather than failing on the first.
if ($PSBoundParameters.ContainsKey('Path')) {
    # -Path holds the remaining arguments, so a space-separated category list
    # ('.\Tests.ps1 NotLive Live') silently lands here. Catch it by name and say
    # what to do instead, rather than reporting 'Live' as a missing path.
    $SetAttribute = $MyInvocation.MyCommand.Parameters['Test'].Attributes |
        Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] } |
        Select-Object -First 1
    $CategoryNames = @($SetAttribute.ValidValues)
    $CategoryInPath = @($Path | Where-Object { $_ -in $CategoryNames })
    if ($CategoryInPath.Count -gt 0) {
        $CategoryList = (@($Test) + $CategoryInPath) -join ','
        throw (
            "'$($CategoryInPath -join ', ')' is a test category, not a path. " +
            "Pass several categories as a comma-separated list: " +
            ".\Tests.ps1 $CategoryList"
        )
    }
    $MissingPaths = [System.Collections.Generic.List[string]]::new()
    $ResolvedPaths = [System.Collections.Generic.List[string]]::new()
    foreach ($Entry in $Path) {
        $Resolved = Resolve-Path -Path $Entry -ErrorAction SilentlyContinue
        if (-not $Resolved) {
            $MissingPaths.Add($Entry)
            continue
        }
        foreach ($Item in $Resolved) { $ResolvedPaths.Add($Item.Path) }
    }
    if ($MissingPaths.Count -gt 0) {
        throw "Path not found: $($MissingPaths -join ', ')"
    }
    $TargetPath = @($ResolvedPaths)
}
else {
    $TargetPath = @($PSScriptRoot)
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
    # Prefer a flat root build (Build.psd1 BuildToRoot) when one exists.
    $RootManifest = Join-Path -Path $PSScriptRoot -ChildPath "$ModuleName.psd1"
    if (Test-Path $RootManifest) {
        $RootManifest
    } else {
        # Flat build layout: Output\<ModuleName>\<ModuleName>.psd1
        # (UnversionedOutputDirectory in Build.psd1). Falls back to the
        # versioned layout Output\<ModuleName>\<version>\<ModuleName>.psd1.
        $OutputRoot = Join-Path -Path $PSScriptRoot -ChildPath "Output\$ModuleName"
        $FlatManifest = Join-Path -Path $OutputRoot -ChildPath "$ModuleName.psd1"
        if (Test-Path $FlatManifest) {
            $FlatManifest
        } else {
            Get-ChildItem -Path $OutputRoot -Directory -ErrorAction SilentlyContinue |
                Sort-Object { [version]$_.Name } -Descending |
                Select-Object -First 1 |
                ForEach-Object { Join-Path -Path $_.FullName -ChildPath "$ModuleName.psd1" }
        }
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
    throw $ErrMsg
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
# by a BuildToRoot build alongside the built psm1/psd1; versioned builds land under
# Output\. The checks match these names ROOT-ANCHORED, so excluding the built copies
# at the root never also hides the authoritative source under Source\ (which shares
# those folder names).
$BuildPsd1Path = Join-Path -Path $PSScriptRoot -ChildPath 'source\Build.psd1'
$BuildConfig = Import-PowerShellDataFile -Path $BuildPsd1Path
$CopyPaths = if ($BuildConfig.ContainsKey('CopyPaths')) { $BuildConfig.CopyPaths } else { @() }
$CopiedFolderNames = @($CopyPaths | ForEach-Object { Split-Path -Path $_ -Leaf })

# Optional per-project test configuration: a hashtable keyed by category
# (lowercase), each value the -Data table for that category's Pester
# containers. See Tests\TestConfig.psd1. -ConfigPath swaps in a different
# settings file (a stricter CI profile, or a test's own fixture settings); an
# explicit path that does not exist is an error rather than a silent default.
$TestConfigPath = if ($PSBoundParameters.ContainsKey('ConfigPath')) {
    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        throw "Config file not found: $ConfigPath"
    }
    (Resolve-Path -LiteralPath $ConfigPath).Path
}
else {
    Join-Path -Path $TestsFolder -ChildPath 'TestConfig.psd1'
}
$TestConfig = if (Test-Path $TestConfigPath) {
    Import-PowerShellDataFile -Path $TestConfigPath
}
else {
    @{}
}

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

# Map each script-based check name to its script file. The line-based code-style
# checks are Pester lint files instead; see $LintCheckValues below.
$FormattingScriptMap = @{
    'ExplicitModuleImport' = 'Test-ExplicitModuleImport.ps1'
    'ModuleSyntax'         = 'Test-ModuleSyntax.ps1'
    'PSSA'                 = 'Test-PSSA.ps1'
    'PSSAAutoFormat'       = 'Test-PSSA.ps1'
}

$IndividualTests = @($Test | Where-Object { $FormattingScriptMap.ContainsKey($_) })

# Categories naming a single lint check. Each matches a Tests\Pester\
# <Name>.Lint.Tests.ps1 file, which the Lint block resolves by name; passing
# Lint instead runs every check found.
$LintCheckValues = @(
    'LineLength', 'BacktickContinuation', 'FormatOperator', 'JoinPath',
    'NonASCIICharacters', 'WriteVerboseDebug', 'UnwantedStrings', 'FixmeComments'
)
$RequestedLintChecks = @($Test | Where-Object { $_ -in $LintCheckValues })
$RunAllLintChecks = 'Lint' -in $Test

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
    # A hook may set this true to signal it owns the Live run (auth, gating,
    # multi-pass); the generic Live run below is then skipped.
    LiveHandled       = $false
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

# Track Destructive refusals (an unsatisfied opt-in gate, or a destructive test
# missing its required 'local'/'remote' scope tag) so the run still exits nonzero
# even though no Pester test itself ran or failed.
$DestructiveGateFailedCount = 0

try {
    if (Test-Path $PreTestsHook) {
        Write-Host "`n=== PreTests.ps1 ===" -ForegroundColor Cyan
        . $PreTestsHook
    }

    # --- NotLive ---
    if ('NotLive' -in $Test) {
        Write-Host "`n=== Invoke-Pester (NotLive) ===" -ForegroundColor Cyan
        $NotLiveSplat = @{
            Path             = $PesterTarget
            ExcludeTagFilter = 'live', 'destructive', 'lint'
            PassThru         = $true
        }
        $NotLiveResult = Invoke-Pester @NotLiveSplat
        $PesterFailedCount += $NotLiveResult.FailedCount
    }

    # --- Script-based checks ---
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
            # Each check throws (not `exit`s) when it finds something to report,
            # so a check that fails still lets the rest of a multi-check run
            # continue and report -- catch it locally rather than letting it
            # unwind the whole script (which `throw` deliberately would do if
            # left uncaught, per AGENTS.TESTING.md's exit-safety note above).
            $CheckFailed = $false
            # One invocation per target path: these scripts take a single -Path
            # (only the lint checks accept a list), so a multi-path run -- e.g. a
            # commit hook's staged files -- calls each check once per path.
            foreach ($CheckPath in $TargetPath) {
                # Test-PSSA also takes -RepoRoot so repo-anchored suppressions
                # resolve when -Path targets a subfolder/file.
                $PssaSplat = @{ Path = $CheckPath; RepoRoot = $PSScriptRoot; Recurse = $true }
                try {
                    switch ($IndividualTest) {
                        'PSSA' { & $ScriptPath @PssaSplat @QuietSplat }
                        'PSSAAutoFormat' { & $ScriptPath @PssaSplat -AutoFormat -Quiet }
                        default { & $ScriptPath -Path $CheckPath -Recurse @QuietSplat }
                    }
                }
                catch {
                    Write-Host $_.Exception.Message -ForegroundColor Red
                    $CheckFailed = $true
                }
            }
            # Tally detection-check failures for the final exit code.
            # PSSAAutoFormat mutates files rather than reporting, so a failure
            # from it does not gate the run.
            if ($IndividualTest -ne 'PSSAAutoFormat' -and $CheckFailed) {
                $FormattingFailedCount++
            }
        }
    }

    # --- Lint ---
    # Pester-based lint checks: every *.Lint.Tests.ps1 in Tests\Pester and
    # .local\tests, run via containers. Static values come from
    # Tests\TestConfig.psd1's 'lint' table; the scan target and the computed
    # build-artifact exclusions are merged in here. Data is subset per file to
    # the parameters it declares, so lint files may differ in signature.
    # An individual check category (LineLength, JoinPath, ...) runs the same
    # way, narrowed to that check's own file.
    if ($RunAllLintChecks -or $RequestedLintChecks.Count -gt 0) {
        Write-Host "`n=== Invoke-Pester (Lint) ===" -ForegroundColor Cyan
        $LintFiles = @(Get-ChildItem -Path $PesterTestsFolder -Filter '*.Lint.Tests.ps1')
        if (Test-Path $LocalTestsFolder) {
            $LintFiles += @(Get-ChildItem -Path $LocalTestsFolder -Filter '*.Lint.Tests.ps1')
        }
        if (-not $RunAllLintChecks) {
            $WantedLintFiles = @(
                $RequestedLintChecks | ForEach-Object { "$($_).Lint.Tests.ps1" }
            )
            $LintFiles = @($LintFiles | Where-Object { $_.Name -in $WantedLintFiles })
        }
        if (-not $LintFiles) {
            Write-Host 'No *.Lint.Tests.ps1 files found.' -ForegroundColor Yellow
        }
        else {
            $LintData = if ($TestConfig.ContainsKey('lint')) {
                $TestConfig['lint'].Clone()
            }
            else {
                @{}
            }
            # Resolve config exclusions against the repo root and append the
            # build-artifact exclusions (built module files at the repo root,
            # CopyPaths folders from Build.psd1).
            $ConfigExcludePaths = @(
                if ($LintData.ContainsKey('ExcludePath')) { $LintData['ExcludePath'] }
            )
            $ComputedExcludePaths = @(
                "$ModuleName.psd1"
                "$ModuleName.psm1"
            ) + $CopiedFolderNames
            $LintData['ExcludePath'] = @(
                $ConfigExcludePaths + $ComputedExcludePaths | ForEach-Object {
                    if ([System.IO.Path]::IsPathRooted($_)) {
                        $_
                    }
                    else {
                        Join-Path -Path $PSScriptRoot -ChildPath $_
                    }
                }
            )
            $LintData['Path'] = $TargetPath
            # A check that reports without failing (FixmeComments) has no
            # failure message to carry its findings, so it writes them itself
            # and needs to know whether output was asked for.
            $LintData['Quiet'] = [bool] $Quiet
            $LintContainers = @(
                foreach ($LintFile in $LintFiles) {
                    # Subset Data to this file's declared parameters: the config
                    # table may hold keys (e.g. MaxLength) other lint files do
                    # not take, and unknown Data keys are a binding error.
                    $DeclaredParams = (Get-Command -Name $LintFile.FullName).Parameters.Keys
                    $FileData = @{}
                    foreach ($Key in $LintData.Keys) {
                        if ($Key -in $DeclaredParams) { $FileData[$Key] = $LintData[$Key] }
                    }
                    New-PesterContainer -Path $LintFile.FullName -Data $FileData
                }
            )
            # Pester's own per-test output is suppressed and the findings are
            # rendered here instead: each lint test throws its findings as the
            # exception message, one 'path Line:N detail' per line, so the report
            # is the same terse, greppable shape the standalone checks produce.
            $LintSplat = @{
                Container = $LintContainers
                TagFilter = 'lint'
                PassThru  = $true
                Output    = 'None'
            }
            $LintResult = Invoke-Pester @LintSplat

            $LintFindings = [System.Collections.Generic.List[string]]::new()
            foreach ($FailedTest in $LintResult.Failed) {
                $FailMessage = $FailedTest.ErrorRecord.Exception.Message
                $LintFindings.AddRange([string[]] ($FailMessage -split '\r?\n'))
            }
            if (-not $Quiet) {
                foreach ($Finding in $LintFindings) {
                    Write-Host $Finding -ForegroundColor Red
                }
            }
            # A container that fails to load (syntax error, bad -Data key) never
            # produces a test result, so report those separately or the run would
            # look clean while nothing actually ran.
            foreach ($LintContainer in $LintResult.Containers) {
                if (-not $LintContainer.ErrorRecord) { continue }
                foreach ($ContainerError in $LintContainer.ErrorRecord) {
                    Write-Host "lint container error: $ContainerError" -ForegroundColor Red
                    $FormattingFailedCount++
                }
            }

            $LintChecks = $LintResult.PassedCount + $LintResult.FailedCount
            $LintSecs = [math]::Round($LintResult.Duration.TotalSeconds, 2)
            $LintColor = if ($LintFindings.Count -gt 0) { 'Red' } else { 'Green' }
            $LintMsg = "$($LintFindings.Count) lint finding(s) -- " +
            "$LintChecks check(s). (${LintSecs}s)"
            Write-Host $LintMsg -ForegroundColor $LintColor
            $PesterFailedCount += $LintResult.FailedCount
        }
    }

    # --- Live ---
    # Generic run: any Pester tests tagged 'live', excluding 'destructive'. Projects
    # needing auth, a token cache, or connect-gating provide that in PreTests.ps1,
    # which sets $TestContext.LiveHandled to take over the Live run entirely.
    if ('Live' -in $Test -and -not $TestContext.LiveHandled) {
        Write-Host "`n=== Invoke-Pester (Live) ===" -ForegroundColor Cyan
        $LiveSplat = @{
            Path             = $PesterTarget
            TagFilter        = 'live'
            ExcludeTagFilter = 'destructive'
            PassThru         = $true
        }
        $LiveResult = Invoke-Pester @LiveSplat
        $PesterFailedCount += $LiveResult.FailedCount
    }

    # --- Destructive ---
    # Destructive tests mutate real state and must be opted into deliberately, at
    # two independent layers (see AGENTS.TESTING.md):
    #   local  -- mutates this host. Gated on DISPOSABLE_ENVIRONMENT=1.
    #   remote -- mutates an external target. Gated on
    #             Tests\Confirm-RemoteDisposable.ps1 confirming it (not throwing).
    # Each destructive test must carry exactly one of those two scope tags. A test
    # tagged 'destructive' with neither, or with both, is ambiguous and refuses the
    # whole category fail-closed -- ExcludeTagFilter alone cannot keep an ambiguous
    # test out of both subset runs (neither case) or confine it to one (both case).
    if ('Destructive' -in $Test) {
        Write-Host "`n=== Destructive: discovery ===" -ForegroundColor Cyan

        # A discovered Test's own .Tag only holds tags set directly on that
        # It block. Every test in this repo (per AGENTS.TESTING.md convention)
        # tags at the enclosing Describe/Context level instead, so the gate
        # below must walk the Block/Parent chain to see those -- checking
        # only $_.Tag would silently never find any of them, defeating the
        # ambiguous-tag refusal fail-closed below.
        function Get-EffectiveTag {
            param([Parameter(Mandatory)]$PesterTest)
            $Tags = [System.Collections.Generic.List[string]]::new()
            if ($PesterTest.Tag) { $Tags.AddRange([string[]] $PesterTest.Tag) }
            $Block = $PesterTest.Block
            while ($Block) {
                if ($Block.Tag) { $Tags.AddRange([string[]] $Block.Tag) }
                $Block = $Block.Parent
            }
            return $Tags
        }

        $DiscoveryConfig = New-PesterConfiguration
        $DiscoveryConfig.Run.Path = $PesterTarget
        $DiscoveryConfig.Run.SkipRun = $true
        $DiscoveryConfig.Run.PassThru = $true
        $DiscoveryConfig.Output.Verbosity = 'None'
        $DiscoveryResult = Invoke-Pester -Configuration $DiscoveryConfig
        $DestructiveTests = @(
            $DiscoveryResult.Tests | Where-Object {
                (Get-EffectiveTag -PesterTest $_) -contains 'destructive'
            }
        )
        $AmbiguousTests = @(
            $DestructiveTests | Where-Object {
                $EffectiveTags = Get-EffectiveTag -PesterTest $_
                $IsLocalTest = $EffectiveTags -contains 'local'
                $IsRemoteTest = $EffectiveTags -contains 'remote'
                -not ($IsLocalTest -xor $IsRemoteTest)
            }
        )

        if ($AmbiguousTests.Count -gt 0) {
            Write-Host 'Refusing Destructive: ambiguous scope tags.' -ForegroundColor Red
            Write-Host "Tag each 'local' or 'remote' (not neither, not both):" -ForegroundColor Red
            foreach ($AmbiguousTest in $AmbiguousTests) {
                Write-Host "  - $($AmbiguousTest.ExpandedPath)" -ForegroundColor Red
            }
            $DestructiveGateFailedCount++
        }
        elseif ($DestructiveTests.Count -eq 0) {
            Write-Host 'No destructive-tagged tests found.' -ForegroundColor Cyan
        }
        else {
            $HasLocalDestructive = [bool] (
                $DestructiveTests |
                    Where-Object { (Get-EffectiveTag -PesterTest $_) -contains 'local' }
            )
            $HasRemoteDestructive = [bool] (
                $DestructiveTests |
                    Where-Object { (Get-EffectiveTag -PesterTest $_) -contains 'remote' }
            )

            if ($HasLocalDestructive) {
                if ($env:DISPOSABLE_ENVIRONMENT -eq '1') {
                    Write-Host "`n=== Invoke-Pester (Destructive Local) ===" -ForegroundColor Cyan
                    $DestructiveLocalSplat = @{
                        Path             = $PesterTarget
                        TagFilter        = 'destructive'
                        ExcludeTagFilter = 'remote'
                        PassThru         = $true
                    }
                    $DestructiveLocalResult = Invoke-Pester @DestructiveLocalSplat
                    $PesterFailedCount += $DestructiveLocalResult.FailedCount
                }
                else {
                    Write-Host "`n=== Destructive Local ===" -ForegroundColor Cyan
                    Write-Host 'Refusing: DISPOSABLE_ENVIRONMENT is not 1.' -ForegroundColor Red
                    Write-Host 'See AGENTS.TESTING.md to set it.' -ForegroundColor Red
                    $DestructiveGateFailedCount++
                }
            }

            if ($HasRemoteDestructive) {
                $RemoteGateSplat = @{
                    Path      = $TestsFolder
                    ChildPath = 'Confirm-RemoteDisposable.ps1'
                }
                $RemoteGateScript = Join-Path @RemoteGateSplat
                # Confirm-RemoteDisposable.ps1 throws (not `exit`s) to refuse;
                # a clean return means the target is confirmed disposable.
                $RemoteConfirmed = $true
                try {
                    & $RemoteGateScript
                }
                catch {
                    $RemoteConfirmed = $false
                }
                if ($RemoteConfirmed) {
                    Write-Host "`n=== Invoke-Pester (Destructive Remote) ===" -ForegroundColor Cyan
                    $DestructiveRemoteSplat = @{
                        Path             = $PesterTarget
                        TagFilter        = 'destructive'
                        ExcludeTagFilter = 'local'
                        PassThru         = $true
                    }
                    $DestructiveRemoteResult = Invoke-Pester @DestructiveRemoteSplat
                    $PesterFailedCount += $DestructiveRemoteResult.FailedCount
                }
                else {
                    Write-Host "`n=== Destructive Remote ===" -ForegroundColor Cyan
                    Write-Host 'Refusing: remote target unconfirmed.' -ForegroundColor Red
                    $NotConfirmedMsg = 'Confirm-RemoteDisposable.ps1 did not confirm it.'
                    Write-Host $NotConfirmedMsg -ForegroundColor Red
                    $DestructiveGateFailedCount++
                }
            }
        }
    }
}
finally {
    if (Test-Path $PostTestsHook) {
        Write-Host "`n=== PostTests.ps1 ===" -ForegroundColor Cyan
        . $PostTestsHook
    }
}

# Nonzero exit so CI and callers can gate on Pester, formatting, and Destructive
# gate results. Uses `throw`, not `exit`: after Invoke-Pester has run at least
# once in this session, a plain `exit N` here is silently overridden and the
# process exits 0 regardless of N (verified with pwsh 7.6.3, this repo's dev
# environment). An uncaught `throw` still makes pwsh -File exit non-zero, and
# unlike `exit` -- which, run inside an interactive host (dot-sourced, or as
# the top-level script of that session) can close the whole terminal instead
# of just this script -- it never touches host-exit state, so it is safe run
# either way.
if ($PesterFailedCount -gt 0 -or
    $FormattingFailedCount -gt 0 -or
    $DestructiveGateFailedCount -gt 0) {
    throw 'Tests.ps1 failed: see Pester, formatting, or Destructive gate output above.'
}
