#Requires -Version 7.5
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.0.0' }

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
    TestsFolder, PesterTestsFolder, the bound parameters, and LiveHandled). A
    hook owning the Live run sets $TestContext.LiveHandled to suppress the
    generic Live Pester run.

.PARAMETER Test
    One or more test categories to run. Accepted values:

      NonLive              -- Pester tests that are not tagged 'live' or
                             'destructive'. No connectivity or external
                             resources required.
      Live                 -- Pester tests tagged 'live', excluding any also
                             tagged 'destructive'. Connectivity/auth setup is
                             provided by the project's PreTests.ps1 hook;
                             without one, the live-tagged tests run as-is.
      Destructive          -- Pester tests tagged 'destructive'. Each such test
                             must also carry exactly one scope tag, 'local' or
                             'remote'; a test tagged 'destructive' with neither
                             (or a scope tag Pester cannot resolve) causes the
                             whole category to refuse, fail-closed. The 'local'
                             subset runs only when DISPOSABLE_ENVIRONMENT=1;
                             the 'remote' subset runs only when
                             Tests\Confirm-RemoteDisposable.ps1 exits 0. See
                             AGENTS.TESTING.md.
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
    a folder checks everything matching under it, recursively). For NonLive,
    Live, and Destructive, this path is what Invoke-Pester scans -- e.g. point
    it at a single *.Tests.ps1 file. Defaults to the repo root, so omitting it
    is unchanged.

.PARAMETER InteractiveAuth
    Passed through to the project's PreTests.ps1 hook via $TestContext for use
    with Live runs. Projects whose live-tagged tests need an interactive
    sign-in (or other interactive setup) read this from $TestContext; when
    omitted (default) setup stays non-interactive. Projects without a Live
    hook ignore it.

    Requires Live; rejected without it.

.PARAMETER Built
    Load the module from the built artifact instead of the source manifest.
    Looks for a root build first (Build.ps1 -BuildToRoot), then falls back to
    the newest versioned build under Output\. Only valid with NonLive, Live,
    and Destructive.

.PARAMETER Quiet
    Forward -Quiet to the individual formatting checks so each prints only its
    one-line summary (files scanned + findings), suppressing detail tables and
    finding notes. Intended for agents that just need a quick pass/fail. Applies
    to individual checks, not the Formatting aggregate or Pester runs.

.EXAMPLE
    .\Tests.ps1 NonLive
    Runs Pester tests that need no connectivity or external resources.

.EXAMPLE
    .\Tests.ps1 LineLength -Quiet
    Runs the line-length check and prints only its one-line summary.

.EXAMPLE
    .\Tests.ps1 NonLive Live
    Runs all non-destructive Pester tests (NonLive and Live).

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
    .\Tests.ps1 NonLive -Path .\tests\pester\Get-Script.Tests.ps1
    Runs one NonLive Pester test file.

.EXAMPLE
    .\Tests.ps1 AutoFormat
    Fixes trailing whitespace then runs PSSA auto-fix and formatting; suppresses lint findings.

.EXAMPLE
    .\Tests.ps1 Live -InteractiveAuth
    Runs live tests with interactive sign-in.

.EXAMPLE
    .\Tests.ps1 Destructive
    Runs destructive tests. The 'local' subset requires DISPOSABLE_ENVIRONMENT=1;
    the 'remote' subset requires Tests\Confirm-RemoteDisposable.ps1 to exit 0.

.EXAMPLE
    .\Tests.ps1 NonLive Live -Built
    Runs Pester tests against the compiled module artifact.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '')]
[CmdletBinding()]
param(
    [Parameter(Position = 0, Mandatory, ValueFromRemainingArguments)]
    [ValidateSet(
        'NonLive', 'Live', 'Destructive', 'Formatting',
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
$ScriptVersion = '1.1.0'

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($InteractiveAuth -and 'Live' -notin $Test) {
    Write-Host '-InteractiveAuth requires -Test Live.' -ForegroundColor Yellow
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

    # --- NonLive ---
    if ('NonLive' -in $Test) {
        Write-Host "`n=== Invoke-Pester (NonLive) ===" -ForegroundColor Cyan
        $NonLiveSplat = @{
            Path             = $PesterTarget
            ExcludeTagFilter = 'live', 'destructive'
            PassThru         = $true
        }
        $NonLiveResult = Invoke-Pester @NonLiveSplat
        $PesterFailedCount += $NonLiveResult.FailedCount
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
            # Reset the global exit code before each check so the tally below
            # reads a value that is always defined (safe under StrictMode) and
            # never stale from an earlier command. This MUST be $global: -- a
            # plain $LASTEXITCODE = 0 creates a script-scoped variable that
            # shadows the global a child's `exit` writes to, silently defeating
            # failure detection. A check that returns without calling `exit`
            # (e.g. an environment skip) then reads as 0, a clean pass.
            $global:LASTEXITCODE = 0
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
            # Capture immediately so nothing added between here and the tally
            # can perturb the reading.
            $CheckExitCode = $LASTEXITCODE
            # Tally detection-check failures for the final exit code. The fixers
            # (AutoFormat, TrailingWhitespace) mutate files rather than report, so
            # their exit code does not gate the run.
            if ($IndividualTest -notin @('AutoFormat', 'TrailingWhitespace') -and
                $CheckExitCode -ne 0) {
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
    #             Tests\Confirm-RemoteDisposable.ps1 exiting 0.
    # Each destructive test must carry exactly one of those two scope tags. A test
    # tagged 'destructive' with neither, or with both, is ambiguous and refuses the
    # whole category fail-closed -- ExcludeTagFilter alone cannot keep an ambiguous
    # test out of both subset runs (neither case) or confine it to one (both case).
    if ('Destructive' -in $Test) {
        Write-Host "`n=== Destructive: discovery ===" -ForegroundColor Cyan
        $DiscoveryConfig = New-PesterConfiguration
        $DiscoveryConfig.Run.Path = $PesterTarget
        $DiscoveryConfig.Run.SkipRun = $true
        $DiscoveryConfig.Run.PassThru = $true
        $DiscoveryConfig.Output.Verbosity = 'None'
        $DiscoveryResult = Invoke-Pester -Configuration $DiscoveryConfig
        $DestructiveTests = @(
            $DiscoveryResult.Tests | Where-Object { $_.Tag -contains 'destructive' }
        )
        $AmbiguousTests = @(
            $DestructiveTests | Where-Object {
                $IsLocalTest = $_.Tag -contains 'local'
                $IsRemoteTest = $_.Tag -contains 'remote'
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
                $DestructiveTests | Where-Object { $_.Tag -contains 'local' }
            )
            $HasRemoteDestructive = [bool] (
                $DestructiveTests | Where-Object { $_.Tag -contains 'remote' }
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
                $global:LASTEXITCODE = 0
                & $RemoteGateScript
                if ($LASTEXITCODE -eq 0) {
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
                    Write-Host 'Confirm-RemoteDisposable.ps1 did not exit 0.' -ForegroundColor Red
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
# gate results.
if ($PesterFailedCount -gt 0 -or
    $FormattingFailedCount -gt 0 -or
    $DestructiveGateFailedCount -gt 0) {
    exit 1
}
