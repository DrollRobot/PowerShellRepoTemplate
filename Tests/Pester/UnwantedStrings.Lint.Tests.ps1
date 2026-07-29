<#
.SYNOPSIS
    Pester lint check: scans every text file for project-defined unwanted
    patterns.

.DESCRIPTION
    One It per scanned file, generated during Discovery. Findings name the
    file, the line number, the tag of the pattern that matched, and the line.

    The patterns are the project's own -- an internal hostname that must never
    be committed, a debugging helper that must not ship, a placeholder that
    means the file is unfinished. Ships empty: with no patterns defined the
    check has nothing to scan and generates no tests.

    Unlike the other checks this one reads every text file, not just
    PowerShell, so patterns can cover workflows, configs, and docs too.

    NOTE FOR AI AGENTS: findings here are for human review. Do not remove or
    rewrite a matched string unless the user explicitly asks; report it and
    stop.

    To suppress a finding on a specific line, append the inline exemption
    marker:

        <code>  # noqa: UnwantedStrings

    Parameterized via a Pester container. Tests.ps1's 'Lint' category builds the
    container, feeding static values from Tests\TestConfig.psd1 plus the scan
    target and computed build-artifact exclusions. Run with no -Data at all, it
    scans the repository root with no exclusions.

    Setting Features.UnwantedStringsLocal in Scripts\setup.psd1 relocates this
    file to .local\tests\, so a project's patterns stay personal and
    untracked; Tests.ps1 runs whichever copies exist.

.PARAMETER Path
    Files and/or folders to scan (folders recurse). Defaults to the repository
    root, two levels above this file.

.PARAMETER ExcludePath
    Files and/or folders to skip. A file entry excludes that file; a folder
    entry excludes its whole subtree. Relative entries resolve against the
    current directory; Tests.ps1 passes absolute paths.

.PARAMETER UnwantedPattern
    The patterns to search for: one hashtable each, with a Tag (the label
    shown in findings) and a Pattern (a case-insensitive regex). Edit the
    defaults below, or set the key in Tests\TestConfig.psd1.

.PARAMETER UnwantedException
    Regexes that exempt a matching line from every pattern. Use for the known,
    reviewed occurrences a pattern is bound to hit.

.PARAMETER BinaryExtension
    Extensions never scanned, to avoid garbled output and false positives.

.EXAMPLE
    .\Tests.ps1 UnwantedStrings

    Scans the repository root for the configured patterns.

.OUTPUTS
    None. Findings are thrown as the failing test's exception message, one
    'path Line:N Tag text' finding per line.
#>
# Settings arrive as script parameters and are consumed inside Discovery/It
# scriptblocks, which PSScriptAnalyzer does not connect to the param block.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '')]
param(
    [string[]] $Path,
    [string[]] $ExcludePath = @(),

    # Project-defined patterns. Examples:
    #     @{ Tag = 'TODO';       Pattern = '#.*\bTODO\b' }
    #     @{ Tag = 'Write-Host'; Pattern = '\bWrite-Host\b' }
    [hashtable[]] $UnwantedPattern = @(),

    # Lines matching any of these are exempt from every pattern. Examples:
    #     '\bSuppressMessageAttribute\b'
    #     "Write-Host.*-ForegroundColor '?DarkGray'?"
    [string[]] $UnwantedException = @(),

    [string[]] $BinaryExtension = @(
        '.png', '.jpg', '.jpeg', '.gif', '.bmp', '.ico', '.webp', '.svg',
        '.zip', '.gz', '.tar', '.7z', '.rar',
        '.dll', '.exe', '.pdb', '.bin', '.lib', '.obj',
        '.pdf', '.docx', '.xlsx', '.pptx'
    )
)

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseDeclaredVarsMoreThanAssignments', 'ScriptVersion')]
$ScriptVersion = '1.0.0'

BeforeDiscovery {
    # Helpers live in Tests\Pester\ even when this file has been relocated to
    # .local\tests\ (see Features.UnwantedStringsLocal). Both sit two levels
    # below the repo root, so the fallback is the same relative hop. Resolved
    # separately in BeforeAll -- Discovery variables do not survive into the
    # run phase.
    $HelperRoot = $PSScriptRoot
    $LocalHelper = Join-Path -Path $HelperRoot -ChildPath 'Build-TestFileList.ps1'
    if (-not (Test-Path -LiteralPath $LocalHelper)) {
        $FallbackParams = @{
            Path      = $PSScriptRoot
            ChildPath = '..\..\Tests\Pester'
        }
        $HelperRoot = (Resolve-Path (Join-Path @FallbackParams)).Path
    }
    . (Join-Path -Path $HelperRoot -ChildPath 'Build-TestFileList.ps1')

    if (-not $Path) {
        $RootParams = @{
            Path      = $PSScriptRoot
            ChildPath = '..\..'
        }
        $Path = @((Resolve-Path (Join-Path @RootParams)).Path)
    }

    # With no patterns there is nothing to look for, so generate no tests
    # rather than read every file in the repo to no purpose.
    $script:LintCases = @()
    if ($UnwantedPattern.Count -gt 0) {
        $CaseParams = @{
            Path             = $Path
            ExcludePath      = $ExcludePath
            Extension        = '*'
            ExcludeExtension = $BinaryExtension
        }
        $script:LintCases = @(Build-TestFileList @CaseParams)
    }
}

Describe 'UnwantedStrings' -Tag 'lint' {

    BeforeAll {
        # Same fallback as BeforeDiscovery: this file may live in .local\tests\
        # while the helpers stay in Tests\Pester\.
        $HelperRoot = $PSScriptRoot
        $LocalHelper = Join-Path -Path $HelperRoot -ChildPath 'Read-LintFile.ps1'
        if (-not (Test-Path -LiteralPath $LocalHelper)) {
            $FallbackParams = @{
                Path      = $PSScriptRoot
                ChildPath = '..\..\Tests\Pester'
            }
            $HelperRoot = (Resolve-Path (Join-Path @FallbackParams)).Path
        }
        . (Join-Path -Path $HelperRoot -ChildPath 'Read-LintFile.ps1')
    }

    # -AllowNullOrEmptyForEach: shipping with no patterns is the normal state,
    # and an empty case list is a run-stopping error to Pester otherwise.
    It '<RelativePath>' -AllowNullOrEmptyForEach -ForEach $script:LintCases {
        $LintFile = Read-LintFile -Path $FullName
        $ExemptParams = @{
            LintFile = $LintFile
            Rule     = 'UnwantedStrings'
            Line     = 0
        }
        $Hits = for ($Index = 0; $Index -lt $LintFile.Line.Count; $Index++) {
            $Text = $LintFile.Line[$Index]
            if ($null -eq $Text) { continue }
            $Number = $Index + 1
            $Excused = $false
            foreach ($Exception in $UnwantedException) {
                if ($Text -match $Exception) { $Excused = $true; break }
            }
            if ($Excused) { continue }
            $ExemptParams.Line = $Number
            if (Test-LintExempt @ExemptParams) { continue }
            foreach ($Entry in $UnwantedPattern) {
                # Keys read by index, not property: Tests.ps1 runs under
                # Set-StrictMode -Version Latest, where a missing key read as a
                # property throws instead of returning nothing.
                if (-not $Entry.ContainsKey('Pattern')) { continue }
                if ($Text -notmatch $Entry['Pattern']) { continue }
                $Tag = if ($Entry.ContainsKey('Tag')) { $Entry['Tag'] } else { 'Match' }
                "$($RelativePath) Line:$($Number) $($Tag) $($Text.Trim())"
            }
        }
        # throw, not Should: Tests.ps1 prints Exception.Message verbatim,
        # and only a raw throw leaves it free of "Expected ... but got ..."
        # wrapping. One finding per line, each already prefixed with its path.
        if ($Hits) { throw ($Hits -join [System.Environment]::NewLine) }
    }
}
