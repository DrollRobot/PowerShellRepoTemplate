<#
.SYNOPSIS
    Pester lint check: flags backtick line continuations.

.DESCRIPTION
    One It per scanned file, generated during Discovery. A failing file is
    identified by its test name; the failure message lists every offending
    line number and the line itself.

    A backtick used to continue a line is a line-continuation escape;
    splatting or string concatenation should be used instead. The finding is
    the parser's own LineContinuation token, so a backtick inside a string or
    a comment is never mistaken for one.

    To suppress a finding on a specific line, append the inline exemption
    marker:

        <code>  # noqa: BacktickContinuation

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

.EXAMPLE
    .\Tests.ps1 BacktickContinuation

    Scans the repository root for backtick line continuations.

.OUTPUTS
    None. Findings are thrown as the failing test's exception message, one
    'path Line:N text' finding per line.
#>
# Settings arrive as script parameters and are consumed inside Discovery/It
# scriptblocks, which PSScriptAnalyzer does not connect to the param block.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '')]
param(
    [string[]] $Path,
    [string[]] $ExcludePath = @()
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

Describe 'BacktickContinuation' -Tag 'lint' {

    BeforeAll {
        . (Join-Path -Path $PSScriptRoot -ChildPath 'Read-LintFile.ps1')
    }

    It '<RelativePath>' -ForEach $script:LintCases {
        $LintFile = Read-LintFile -Path $FullName
        $ExemptParams = @{
            LintFile = $LintFile
            Rule     = 'BacktickContinuation'
            Line     = 0
        }
        $Hits = foreach ($Token in $LintFile.Token) {
            if ($Token.Kind -ne 'LineContinuation') { continue }
            $Number = $Token.Extent.StartLineNumber
            $ExemptParams.Line = $Number
            if (Test-LintExempt @ExemptParams) { continue }
            "$($RelativePath) Line:$($Number) $($LintFile.Line[$Number - 1].Trim())"
        }
        # throw, not Should: Tests.ps1 prints Exception.Message verbatim,
        # and only a raw throw leaves it free of "Expected ... but got ..."
        # wrapping. One finding per line, each already prefixed with its path.
        if ($Hits) { throw ($Hits -join [System.Environment]::NewLine) }
    }
}
