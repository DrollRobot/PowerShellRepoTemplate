<#
.SYNOPSIS
    Pester lint check: flags non-ASCII characters.

.DESCRIPTION
    One It per scanned file, generated during Discovery. A failing file is
    identified by its test name; the failure message lists every offending
    line number and the code points found on it.

    Every line is scanned, comments included -- a smart quote or an em dash is
    a finding wherever it appears. Findings report code points (U+2014) rather
    than the character itself, so the report survives any console encoding.

    To suppress a finding on a specific line, append the inline exemption
    marker:

        <code>  # noqa: NonASCIICharacters

    Parameterized via a Pester container. Tests.ps1's 'Lint' category builds the
    container, feeding static values from Tests\TestConfig.psd1 plus the scan
    target and computed build-artifact exclusions. Run with no -Data at all, it
    scans the repository root with no exclusions.

.PARAMETER Path
    Files and/or folders to scan (folders recurse). Defaults to the repository
    root, two levels above this file.

.PARAMETER ExcludePath
    Files and/or folders to skip. A file entry excludes that file; a folder
    entry excludes its whole subtree. Relative entries resolve against the
    current directory; Tests.ps1 passes absolute paths.

.PARAMETER ExemptCharacter
    Non-ASCII characters to allow everywhere, for projects that legitimately
    need a few. Set it in Tests\TestConfig.psd1.

.EXAMPLE
    .\Tests.ps1 NonASCIICharacters

    Scans the repository root for non-ASCII characters.

.OUTPUTS
    None. Findings are thrown as the failing test's exception message, one
    'path Line:N Chars:U+XXXX' finding per line.
#>
# Settings arrive as script parameters and are consumed inside Discovery/It
# scriptblocks, which PSScriptAnalyzer does not connect to the param block.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '')]
param(
    [string[]] $Path,
    [string[]] $ExcludePath = @(),
    [char[]] $ExemptCharacter = @()
)

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseDeclaredVarsMoreThanAssignments', 'ScriptVersion')]
$ScriptVersion = '1.0.0'

BeforeDiscovery {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'Build-TestFileList.ps1')

    if (-not $Path) {
        $RootParams = @{
            Path      = $PSScriptRoot
            ChildPath = '..\..'
        }
        $Path = @((Resolve-Path (Join-Path @RootParams)).Path)
    }

    $CaseParams = @{
        Path        = $Path
        ExcludePath = $ExcludePath
    }
    $script:LintCases = @(Build-TestFileList @CaseParams)
}

Describe 'NonASCIICharacters' -Tag 'lint' {

    BeforeAll {
        . (Join-Path -Path $PSScriptRoot -ChildPath 'Read-LintFile.ps1')
    }

    It '<RelativePath>' -ForEach $script:LintCases {
        $LintFile = Read-LintFile -Path $FullName
        $ExemptParams = @{
            LintFile = $LintFile
            Rule     = 'NonASCIICharacters'
            Line     = 0
        }
        $Hits = for ($Index = 0; $Index -lt $LintFile.Line.Count; $Index++) {
            $Text = $LintFile.Line[$Index]
            if ($null -eq $Text -or $Text -notmatch '[^\x00-\x7F]') { continue }
            $Number = $Index + 1
            $ExemptParams.Line = $Number
            if (Test-LintExempt @ExemptParams) { continue }
            $Offending = @($Text.ToCharArray() | Where-Object {
                    [int] $_ -gt 0x7F -and $_ -notin $ExemptCharacter
                })
            if ($Offending.Count -eq 0) { continue }
            $CodePoint = @($Offending | Sort-Object -Unique | ForEach-Object {
                    'U+' + ([int] $_).ToString('X4')
                }) -join ','
            "$($RelativePath) Line:$($Number) Chars:$($CodePoint)"
        }
        # throw, not Should: Tests.ps1 prints Exception.Message verbatim,
        # and only a raw throw leaves it free of "Expected ... but got ..."
        # wrapping. One finding per line, each already prefixed with its path.
        if ($Hits) { throw ($Hits -join [System.Environment]::NewLine) }
    }
}
