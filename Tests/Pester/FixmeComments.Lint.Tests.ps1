<#
.SYNOPSIS
    Pester lint check: reports FIXME comments.

.DESCRIPTION
    One It per scanned file, generated during Discovery. Findings name the
    file, the line number, and the comment text.

    Only parsed comment tokens are searched, so the word inside a string or a
    file name is not a finding -- and this check never reports its own source.

    Whether a finding fails the run is a project setting: FailOnFixme in
    Tests\TestConfig.psd1. Left at its default ($false) the check reports what
    it found and passes, which suits a template where open FIXMEs are the
    to-do list. Set it to $true to gate commits on a clean report.

    To suppress a finding on a specific line, append the inline exemption
    marker:

        <code>  # noqa: FixmeComments

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

.PARAMETER FailOnFixme
    Fail the test when a FIXME is found. Defaults to false, which reports the
    findings and passes.

.PARAMETER Quiet
    Suppress the informational report printed when FailOnFixme is false.
    Tests.ps1 passes its own -Quiet through.

.EXAMPLE
    .\Tests.ps1 FixmeComments

    Lists the FIXME comments in the repository root.

.OUTPUTS
    None. With FailOnFixme, findings are thrown as the failing test's
    exception message, one 'path Line:N text' finding per line; otherwise the
    same lines are written to the host.
#>
# Settings arrive as script parameters and are consumed inside Discovery/It
# scriptblocks, which PSScriptAnalyzer does not connect to the param block.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '')]
param(
    [string[]] $Path,
    [string[]] $ExcludePath = @(),
    [bool] $FailOnFixme = $false,
    [bool] $Quiet = $false
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

Describe 'FixmeComments' -Tag 'lint' {

    BeforeAll {
        . (Join-Path -Path $PSScriptRoot -ChildPath 'Read-LintFile.ps1')

        # Built from pieces, matched case-sensitively, and bounded: the marker
        # is the shouted word on its own, so 'FailOnFixme' and this file's own
        # help text are not findings.
        $script:FixmePattern = '\bFIX' + 'ME\b'
    }

    It '<RelativePath>' -ForEach $script:LintCases {
        # This file's own help has to spell the marker out; skip it rather than
        # litter the help with exemption markers.
        if ((Split-Path -Path $FullName -Leaf) -eq 'FixmeComments.Lint.Tests.ps1') { return }
        $LintFile = Read-LintFile -Path $FullName
        $ExemptParams = @{
            LintFile = $LintFile
            Rule     = 'FixmeComments'
            Line     = 0
        }
        $Hits = foreach ($Comment in ($LintFile.Token | Where-Object Kind -EQ 'Comment')) {
            # A block comment is one token spanning many lines; report the
            # line the word is actually on.
            $CommentLine = @($Comment.Text -split '\r?\n')
            for ($Offset = 0; $Offset -lt $CommentLine.Count; $Offset++) {
                if ($CommentLine[$Offset] -cnotmatch $script:FixmePattern) { continue }
                $Number = $Comment.Extent.StartLineNumber + $Offset
                $ExemptParams.Line = $Number
                if (Test-LintExempt @ExemptParams) { continue }
                "$($RelativePath) Line:$($Number) $($CommentLine[$Offset].Trim())"
            }
        }
        if (-not $Hits) { return }

        # throw, not Should: Tests.ps1 prints Exception.Message verbatim,
        # and only a raw throw leaves it free of "Expected ... but got ..."
        # wrapping. One finding per line, each already prefixed with its path.
        if ($FailOnFixme) { throw ($Hits -join [System.Environment]::NewLine) }
        # Informational mode: the run still passes, so the findings have no
        # failure message to travel in -- write them out here instead.
        if (-not $Quiet) {
            Write-Host ($Hits -join [System.Environment]::NewLine) -ForegroundColor DarkGray
        }
    }
}
