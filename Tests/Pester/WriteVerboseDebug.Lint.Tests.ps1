<#
.SYNOPSIS
    Pester lint check: flags leftover verbose and debug output calls.

.DESCRIPTION
    One It per scanned file, generated during Discovery. A failing file is
    identified by its test name; the failure message lists every offending
    line number and the line itself.

    Calls to the built-in verbose and debug output cmdlets are usually
    leftover debugging statements; module functions should use the module's
    own user-output wrapper (see AGENTS.md). The finding is a parsed command
    call, so naming either cmdlet in a comment or a string is not a finding.

    To suppress a finding on a specific line, append the inline exemption
    marker:

        <code>  # noqa: WriteVerboseDebug

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
    .\Tests.ps1 WriteVerboseDebug

    Scans the repository root for verbose/debug output calls.

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

Describe 'WriteVerboseDebug' -Tag 'lint' {

    BeforeAll {
        . (Join-Path -Path $PSScriptRoot -ChildPath 'Read-LintFile.ps1')

        # The command names live here as data, not as calls, so this check
        # never reports its own source.
        $script:BannedCommand = @('Write-Verbose', 'Write-Debug')
    }

    It '<RelativePath>' -ForEach $script:LintCases {
        $LintFile = Read-LintFile -Path $FullName
        if ($null -eq $LintFile.Ast) { return }

        $IsCommand = {
            param($Node)
            $Node -is [System.Management.Automation.Language.CommandAst]
        }
        $ExemptParams = @{
            LintFile = $LintFile
            Rule     = 'WriteVerboseDebug'
            Line     = 0
        }
        $Hits = foreach ($Command in $LintFile.Ast.FindAll($IsCommand, $true)) {
            if ($Command.GetCommandName() -notin $script:BannedCommand) { continue }
            $Number = $Command.Extent.StartLineNumber
            $ExemptParams.Line = $Number
            $ExemptParams.EndLine = $Command.Extent.EndLineNumber
            if (Test-LintExempt @ExemptParams) { continue }
            "$($RelativePath) Line:$($Number) $($LintFile.Line[$Number - 1].Trim())"
        }
        # throw, not Should: Tests.ps1 prints Exception.Message verbatim,
        # and only a raw throw leaves it free of "Expected ... but got ..."
        # wrapping. One finding per line, each already prefixed with its path.
        if ($Hits) { throw ($Hits -join [System.Environment]::NewLine) }
    }
}
