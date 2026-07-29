<#
.SYNOPSIS
    Pester lint check: flags path-building anti-patterns.

.DESCRIPTION
    One It per scanned file, generated during Discovery. A failing file is
    identified by its test name; the failure message lists every offending
    line number, the rule it broke, and the line itself.

    Three rules, all matched against parsed calls rather than text, so a
    multi-line call is judged as a whole and a mention in a comment or a
    string is never a finding:

    1. PathCombine   -- the .NET Path.Combine() method must not be used;
                        Join-Path replaces it.
    2. NoNamedParams -- Join-Path must name its -Path parameter, not pass it
                        positionally.
    3. SplatRequired -- a Join-Path call with three or more named parameters
                        must splat them (Join-Path @Params), per AGENTS.md.

    To suppress a finding, append the inline exemption marker to any line the
    call spans:

        <code>  # noqa: JoinPath

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
    .\Tests.ps1 JoinPath

    Scans the repository root for path-building anti-patterns.

.OUTPUTS
    None. Findings are thrown as the failing test's exception message, one
    'path Line:N Rule text' finding per line.
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

Describe 'JoinPath' -Tag 'lint' {

    BeforeAll {
        . (Join-Path -Path $PSScriptRoot -ChildPath 'Read-LintFile.ps1')

        # Splatting is mandatory past two parameters (AGENTS.md), so a call
        # naming this many or more without a splat is a finding.
        $script:SplatThreshold = 3
    }

    It '<RelativePath>' -ForEach $script:LintCases {
        $LintFile = Read-LintFile -Path $FullName
        if ($null -eq $LintFile.Ast) { return }

        $IsStaticCall = {
            param($Node)
            $Node -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
            $Node.Static
        }
        $IsCommand = {
            param($Node)
            $Node -is [System.Management.Automation.Language.CommandAst]
        }
        $ExemptParams = @{
            LintFile = $LintFile
            Rule     = 'JoinPath'
            Line     = 0
            EndLine  = 0
        }
        $Finding = [System.Collections.Generic.List[pscustomobject]]::new()

        # Rule 1: [System.IO.Path]::Combine() -- use Join-Path instead.
        foreach ($Call in $LintFile.Ast.FindAll($IsStaticCall, $true)) {
            # A dynamic member name ([type]::$Name()) has no Member text.
            if ($null -eq $Call.Member -or $null -eq $Call.Expression) { continue }
            if ($Call.Member.Extent.Text -ne 'Combine') { continue }
            if ($Call.Expression.Extent.Text -notmatch '^\[(System\.)?IO\.Path\]$') { continue }
            $ExemptParams.Line = $Call.Extent.StartLineNumber
            $ExemptParams.EndLine = $Call.Extent.EndLineNumber
            if (Test-LintExempt @ExemptParams) { continue }
            $Finding.Add([pscustomobject]@{
                    Number = $Call.Extent.StartLineNumber
                    Rule   = 'PathCombine'
                })
        }

        foreach ($Command in $LintFile.Ast.FindAll($IsCommand, $true)) {
            if ($Command.GetCommandName() -ne 'Join-Path') { continue }
            $Elements = @($Command.CommandElements)
            $Splat = @($Elements | Where-Object {
                    $_ -is [System.Management.Automation.Language.VariableExpressionAst] -and
                    $_.Splatted
                })
            $Named = @($Elements | Where-Object {
                    $_ -is [System.Management.Automation.Language.CommandParameterAst]
                })
            if ($Splat.Count -gt 0) { continue }

            # Collected one by one, not by member enumeration: Tests.ps1 runs
            # under Set-StrictMode -Version Latest, where reading a property
            # off an empty array throws.
            $NamedName = @($Named | ForEach-Object { $_.ParameterName })

            # Rule 2: called positionally, with no -Path parameter named.
            # Rule 3: three or more named parameters and no splatting.
            $Rule = if ($NamedName -notcontains 'Path') {
                'NoNamedParams'
            }
            elseif ($Named.Count -ge $script:SplatThreshold) {
                'SplatRequired'
            }
            if (-not $Rule) { continue }

            $ExemptParams.Line = $Command.Extent.StartLineNumber
            $ExemptParams.EndLine = $Command.Extent.EndLineNumber
            if (Test-LintExempt @ExemptParams) { continue }
            $Finding.Add([pscustomobject]@{
                    Number = $Command.Extent.StartLineNumber
                    Rule   = $Rule
                })
        }

        # throw, not Should: Tests.ps1 prints Exception.Message verbatim,
        # and only a raw throw leaves it free of "Expected ... but got ..."
        # wrapping. One finding per line, each already prefixed with its path.
        if ($Finding.Count -gt 0) {
            $Hits = $Finding | Sort-Object Number | ForEach-Object {
                $Text = $LintFile.Line[$_.Number - 1].Trim()
                "$($RelativePath) Line:$($_.Number) $($_.Rule) $($Text)"
            }
            throw ($Hits -join [System.Environment]::NewLine)
        }
    }
}
