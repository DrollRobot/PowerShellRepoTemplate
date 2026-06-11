<#
.SYNOPSIS
    Runs PSScriptAnalyzer against all PowerShell files in a directory.
    Optionally applies auto-fixes and formatting via -AutoFormat.
.DESCRIPTION
    Does not work in the VS Code PowerShell Extension terminal due to assembly
    conflicts with the extension's bundled PSScriptAnalyzer. Run in a standard
    pwsh terminal instead (the VS Code integrated terminal works fine).

    When -AutoFormat is specified:
    1. Runs Invoke-ScriptAnalyzer -Fix on each file to apply auto-corrections.
    2. Runs Invoke-Formatter on each file to enforce consistent whitespace
       and indentation.
    3. Reports any issues that remain after the fix+format pass.

    When -AutoFormat is omitted, only detects and reports issues.
.PARAMETER Path
    Root directory to search. Defaults to the current directory.
.PARAMETER Recurse
    Search subdirectories recursively.
.PARAMETER AutoFormat
    Apply Invoke-ScriptAnalyzer -Fix and Invoke-Formatter to each file, then
    report remaining issues.
.PARAMETER Quiet
    Suppress the per-finding table, grouped output, and the AI-agent remediation
    note, printing only the summary. Operational notes (e.g. the load-time /
    do-not-poll warning) are still shown. Most useful with -AutoFormat when you
    only want to format, not review findings.
.OUTPUTS
    Formatted table to the host. No pipeline output.
.EXAMPLE
    .\Test-PSSA.ps1 -Path . -Recurse
    Reports PSScriptAnalyzer issues without modifying any files.
.EXAMPLE
    .\Test-PSSA.ps1 -Path . -Recurse -AutoFormat
    Auto-fixes and formats all files, then reports remaining issues.
.EXAMPLE
    .\Test-PSSA.ps1 -Path . -Recurse -AutoFormat -Quiet
    Auto-fixes and formats all files, then shows only the summary line.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '')]
[CmdletBinding()]
param(
    [string] $Path = (Get-Location).Path,
    [switch] $Recurse,
    [switch] $AutoFormat,
    [switch] $Quiet
)

# All analyzer configuration lives here.
# PSScriptAnalyzer reads: ExcludeRules, Rules (and any other native keys).
$AnalyzerSettings = @{
    ExcludeRules = @(
        'PSAvoidGlobalVars'
        'PSAvoidUsingEmptyCatchBlock'
    )
    Rules        = @{
        PSAvoidUsingPositionalParameters = @{
            Enable           = $true
            # FIXME: add your module's user-output wrapper (e.g. Write-XYZ).
            CommandAllowList = @('Write-Trace')
        }
    }
}

# Per-file rule suppressions. Add entries here for findings that cannot be suppressed
# in source (e.g. psd1 files) and where a global ExcludeRules entry would be too broad.
# Key: path relative to the scan root. Value: array of rule names to suppress.
$PerFileSuppressions = @{
    # FunctionsToExport = '*' is intentional in the Source manifest;
    # ModuleBuilder replaces it with the real export list on build.
    'Source\PowershellRepoTemplate.psd1' = @('PSUseToExportFieldsInManifest')
    # Build scripts use Write-Host for user-facing output.
    'Build\PreBuild.ps1'                 = @('PSAvoidUsingWriteHost')
}

# Per-path rule suppressions. Each key is a relative path prefix.
# Any finding under that prefix is suppressed when its RuleName is listed.
$PerPathSuppressions = @{
    'Tests\'               = @('PSAvoidUsingWriteHost')
    'Scripts\'               = @('PSAvoidUsingWriteHost')
    'Source\Private\Lib\' = @('PSAvoidUsingWriteHost')
}

# Formatting rules applied by Invoke-Formatter when -AutoFormat is used.
$FormatterSettings = @{
    Rules = @{
        PSUseConsistentIndentation = @{
            Enable              = $true
            Kind                = 'space'
            IndentationSize     = 4
            PipelineIndentation = 'IncreaseIndentationForFirstPipeline'
        }
        PSUseConsistentWhitespace  = @{
            Enable                                  = $true
            CheckInnerBrace                         = $true
            CheckOpenBrace                          = $true
            CheckOpenParen                          = $true
            CheckOperator                           = $true
            CheckPipe                               = $true
            CheckPipeForRedundantWhitespace         = $true
            CheckSeparator                          = $true
            CheckParameter                          = $true
            IgnoreAssignmentOperatorInsideHashTable = $true
        }
    }
}

# The PS Extension terminal hosts its own PSScriptAnalyzer assembly, which conflicts
# with the installed module. Detect and skip rather than error out.
if ($host.Name -eq 'Visual Studio Code Host') {
    Write-Warning 'PSScriptAnalyzer cannot run in the VS Code PowerShell Extension terminal.'
    $WarnMsg = 'Run .\tests.ps1 -PSScriptAnalyzer in the integrated terminal (pwsh) instead.'
    Write-Warning $WarnMsg
    return
}

if (-not (Get-Module -ListAvailable -Name PSScriptAnalyzer)) {
    $WarnMsg = 'PSScriptAnalyzer is not installed. Run: Install-Module PSScriptAnalyzer ' +
    '-Repository PSGallery -Scope CurrentUser'
    Write-Warning $WarnMsg
    return
}

$Stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

# Root-level files to exclude (relative paths from $Path).
$ExcludedFiles = @()

# Folder names to exclude from scanning. Any file under a matching folder is skipped.
$ExcludedFolders = @('.local')

# Merge exclusions from the test orchestrator when called via Tests.ps1.
if ($Global:Dev_FormattingExclusions) {
    $ExcludedFiles += $Global:Dev_FormattingExclusions.ExcludeFiles
    $ExcludedFolders += $Global:Dev_FormattingExclusions.ExcludeFolders
}

# --- AutoFormat pass ---
$FixedCount = 0
$FormattedCount = 0

if ($AutoFormat) {
    $GetChildParams = @{
        Path    = $Path
        File    = $true
        Recurse = $Recurse.IsPresent
    }
    $FormatFiles = Get-ChildItem @GetChildParams |
        Where-Object Extension -in '.ps1', '.psm1', '.psd1' |
        Where-Object {
            $Rel = [System.IO.Path]::GetRelativePath($Path, $_.FullName)
            (-not ($ExcludedFiles -contains $Rel)) -and
            (-not ($ExcludedFolders | Where-Object { $Rel -like "$_\*" -or $Rel -like "*\$_\*" }))
        }

    Write-Host 'Applying auto-fixes and formatting...' -ForegroundColor Cyan

    foreach ($FormatFile in $FormatFiles) {
        # Step 1: PSSA -Fix (modifies file in-place; returns unfixable findings).
        $BeforeFix = Get-Content -Path $FormatFile.FullName -Raw
        $FixParams = @{
            Path     = $FormatFile.FullName
            Fix      = $true
            Settings = $AnalyzerSettings
            ErrorAction = 'SilentlyContinue'
            ErrorVariable = 'FixErrors'
        }
        $FixErrors = $null
        $null = Invoke-ScriptAnalyzer @FixParams
        if ($FixErrors) {
            foreach ($fe in $FixErrors) {
                Write-Warning "PSSA internal error on $($FormatFile.Name): $($fe.Exception.Message)"
            }
        }
        $AfterFix = Get-Content -Path $FormatFile.FullName -Raw
        if ($AfterFix -ne $BeforeFix) { $FixedCount++ }

        # Skip empty files -- Invoke-Formatter requires a non-null ScriptDefinition.
        if ([string]::IsNullOrEmpty($AfterFix)) { continue }

        # Step 2: Invoke-Formatter (writes back only if content changed).
        $FormatParams = @{
            ScriptDefinition = $AfterFix
            Settings         = $FormatterSettings
        }
        $Formatted = Invoke-Formatter @FormatParams
        if ($Formatted -ne $AfterFix) {
            $SetParams = @{
                Path     = $FormatFile.FullName
                Value    = $Formatted
                Encoding = 'utf8'
                NoNewline = $true
            }
            Set-Content @SetParams
            $FormattedCount++
        }
    }

    $FixMsg = "$FixedCount file(s) fixed by PSSA, $FormattedCount file(s) reformatted."
    Write-Host $FixMsg -ForegroundColor Cyan
}

# --- Detection pass ---
Get-Module PSScriptAnalyzer | Select-Object Path, Version | Format-List
Write-Host "Running PSScriptAnalyzer against $Path..." -ForegroundColor Cyan
Write-Host 'This could take multiple minutes. Please wait...' -ForegroundColor Cyan
$Msg = 'NOTE FOR AI AGENTS: Loading PSScriptAnalyzer can take up to 3 minutes. ' +
'Do not poll or call get_terminal_output. ' +
'Wait for terminal completion notification.'
Write-Host $Msg -ForegroundColor DarkGray

$InvokeParams = @{
    Path     = $Path
    Recurse  = $Recurse.IsPresent
    Settings = $AnalyzerSettings
    Verbose  = $true
}
try {
    # 4>&1 merges the verbose stream into output so we can capture it.
    $AllOutput = Invoke-ScriptAnalyzer @InvokeParams 4>&1
    $Results = $AllOutput | Where-Object {
        $_ -isnot [System.Management.Automation.VerboseRecord]
    }
    # Exclude built artifacts and copy-path folders -- source files are already scanned.
    $Results = $Results | Where-Object {
        $Rel = [System.IO.Path]::GetRelativePath($Path, $_.ScriptPath)
        (-not ($ExcludedFiles -contains $Rel)) -and
        (-not ($ExcludedFolders | Where-Object { $Rel -like "$_\*" -or $Rel -like "*\$_\*" }))
    }
    # Apply per-file and per-path rule suppressions.
    if ($PerFileSuppressions.Count -gt 0 -or $PerPathSuppressions.Count -gt 0) {
        $BeforeCount = ($Results | Measure-Object).Count
        $Results = $Results | Where-Object {
            $Rel = [System.IO.Path]::GetRelativePath($Path, $_.ScriptPath)
            $IsFileSuppressed = $PerFileSuppressions.ContainsKey($Rel) -and
            ($PerFileSuppressions[$Rel] -contains $_.RuleName)

            $IsPathSuppressed = $false
            foreach ($Prefix in $PerPathSuppressions.Keys) {
                if ($Rel.StartsWith($Prefix, [System.StringComparison]::OrdinalIgnoreCase) -and
                    ($PerPathSuppressions[$Prefix] -contains $_.RuleName)) {
                    $IsPathSuppressed = $true
                    break
                }
            }

            $IsSuppressed = $IsFileSuppressed -or $IsPathSuppressed
            -not $IsSuppressed
        }
        $AfterCount = ($Results | Measure-Object).Count
        $SuppressedCount = $BeforeCount - $AfterCount
        Write-Host "Suppressed $SuppressedCount issue(s) via per-file rules" -ForegroundColor Cyan
    }
    $FileCount = ($AllOutput | Where-Object {
            ($_ -is [System.Management.Automation.VerboseRecord]) -and
            ($_.Message -like 'Analyzing file: *')
        }).Count
}
catch {
    Write-Warning "PSScriptAnalyzer failed: $_"
    $WarnMsg = 'If running in the VS Code PowerShell Extension terminal, ' +
    'switch to the integrated pwsh terminal.'
    Write-Warning $WarnMsg
    return
}

$Stopwatch.Stop()
$ElapsedSec = $Stopwatch.Elapsed.TotalSeconds.ToString('F1')
Write-Host "Completed in ${ElapsedSec}s." -ForegroundColor Cyan

$IssueCount = ($Results | Measure-Object).Count

if ($IssueCount -gt 0 -and -not $Quiet) {
    $Msg = 'NOTE FOR AI AGENTS: Always fix all PSScriptAnalyzer findings, ' +
    "even if they aren't related to changes you made. " +
    'Do this only after all Pester tests are passing.'
    Write-Host $Msg -ForegroundColor DarkGray

    Write-Host 'Results' -ForegroundColor Cyan
    $Results | Format-Table -AutoSize

    if ($IssueCount -gt 5) {
        Write-Host 'Results grouped by rule:' -ForegroundColor Cyan
        $Results | Group-Object RuleName | Format-Table Count, Name, Group -AutoSize
    }
}

$SummaryColor = if ($IssueCount -gt 0) { 'Red' } else { 'Green' }
$Msg = "$IssueCount issue(s) -- $FileCount file(s) checked. (${ElapsedSec}s)"
Write-Host $Msg -ForegroundColor $SummaryColor
