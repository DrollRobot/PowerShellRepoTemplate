<#
.SYNOPSIS
    Shared helper for Pester lint checks: reads one file into the shapes the
    rules match against, and answers inline-exemption questions about it.

.DESCRIPTION
    Dot-sourced by *.Lint.Tests.ps1 files in their BeforeAll block. Not a
    Pester test file itself -- the *.Tests.ps1 glob never picks it up.

    Defines two functions:

        Read-LintFile    -- parse/read a file once, return lines + tokens + AST
        Test-LintExempt  -- does a given line carry '# noqa: <Rule>'?

    PowerShell files are parsed, so rules match language constructs (a token
    kind, a command call) rather than text patterns. That keeps a '#' inside a
    string from reading as a comment, a backtick inside a string from reading
    as a line continuation, and a rule's own source from matching itself.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseDeclaredVarsMoreThanAssignments', 'ScriptVersion')]
$ScriptVersion = '1.0.0'

# Inline exemption marker: '# noqa: Rule', or several rules on one marker
# ('# noqa: JoinPath, LineLength').
$script:NoqaPattern = '#\s*noqa:\s*(?<Rules>[\w\s,-]+)'

function Read-LintFile {
    <#
    .SYNOPSIS
        Reads one file into the shapes lint rules match against.

    .DESCRIPTION
        Returns the file's raw lines plus, for PowerShell files, the token
        stream and AST from a single parse. Also returns a map of line number
        to the rule names exempted on that line, built from comment tokens
        when the file parsed cleanly and from the raw text otherwise (so a
        file with syntax errors still honors its markers).

        Line numbers throughout are the file's own 1-based numbers. Nothing
        is stripped or rewritten, so a finding's line number always points at
        the live file.

    .PARAMETER Path
        Full path to the file to read.

    .EXAMPLE
        $LintFile = Read-LintFile -Path $FullName
        $LintFile.Token | Where-Object Kind -EQ 'LineContinuation'

        Every line-continuation token in the file.

    .OUTPUTS
        System.Management.Automation.PSCustomObject with Path, Line (raw
        lines), Token, Ast, ParseError, and Exempt (line number -> rules).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    $Line = @(Get-Content -LiteralPath $Path)
    $Token = @()
    $Ast = $null
    $ParseError = @()

    # Only PowerShell files are parseable; everything else (UnwantedStrings
    # scans any text file) stays on the raw-text path.
    $Extension = [System.IO.Path]::GetExtension($Path)
    if ($Extension -in @('.ps1', '.psm1', '.psd1')) {
        $ParsedToken = $null
        $ParsedError = $null
        $Parser = [System.Management.Automation.Language.Parser]
        $Ast = $Parser::ParseFile($Path, [ref] $ParsedToken, [ref] $ParsedError)
        $Token = @($ParsedToken)
        $ParseError = @($ParsedError)
    }

    # Prefer comment tokens: a marker-shaped string literal is not a marker.
    # A file that failed to parse has no trustworthy tokens, so fall back to
    # scanning the raw lines rather than silently ignoring its markers.
    $Exempt = @{}
    if ($Token.Count -gt 0 -and $ParseError.Count -eq 0) {
        foreach ($Comment in ($Token | Where-Object Kind -EQ 'Comment')) {
            $CommentLine = @($Comment.Text -split '\r?\n')
            for ($Offset = 0; $Offset -lt $CommentLine.Count; $Offset++) {
                $Number = $Comment.Extent.StartLineNumber + $Offset
                Add-LintExempt -Map $Exempt -Number $Number -Text $CommentLine[$Offset]
            }
        }
    }
    else {
        for ($Index = 0; $Index -lt $Line.Count; $Index++) {
            Add-LintExempt -Map $Exempt -Number ($Index + 1) -Text $Line[$Index]
        }
    }

    return [pscustomobject]@{
        Path       = $Path
        Line       = $Line
        Token      = $Token
        Ast        = $Ast
        ParseError = $ParseError
        Exempt     = $Exempt
    }
}

# Records any '# noqa:' rules found in one line of text against that line
# number. Internal to this helper; callers use Test-LintExempt.
function Add-LintExempt {
    param(
        [Parameter(Mandatory)][hashtable] $Map,
        [Parameter(Mandatory)][int] $Number,
        [AllowNull()][string] $Text
    )
    if ($null -eq $Text -or $Text -notmatch $script:NoqaPattern) { return }
    $Rules = @($Matches['Rules'] -split '[,\s]+' | Where-Object { $_ })
    if (-not $Map.ContainsKey($Number)) { $Map[$Number] = @() }
    $Map[$Number] += $Rules
}

function Test-LintExempt {
    <#
    .SYNOPSIS
        Reports whether a finding is exempted by an inline '# noqa:' marker.

    .DESCRIPTION
        A marker on any line the finding spans exempts it, so a marker at
        either end of a multi-line command works.

    .PARAMETER LintFile
        The object returned by Read-LintFile.

    .PARAMETER Rule
        Name of the calling rule, as written in a '# noqa:' marker.

    .PARAMETER Line
        First line of the finding.

    .PARAMETER EndLine
        Last line of the finding. Defaults to Line.

    .EXAMPLE
        Test-LintExempt -LintFile $LintFile -Rule 'JoinPath' -Line 42

        True when line 42 carries '# noqa: JoinPath'.

    .OUTPUTS
        System.Boolean.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $LintFile,
        [Parameter(Mandatory)]
        [string] $Rule,
        [Parameter(Mandatory)]
        [int] $Line,
        [int] $EndLine = 0
    )

    if ($EndLine -lt $Line) { $EndLine = $Line }
    for ($Number = $Line; $Number -le $EndLine; $Number++) {
        if (-not $LintFile.Exempt.ContainsKey($Number)) { continue }
        if ($LintFile.Exempt[$Number] -contains $Rule) { return $true }
    }
    return $false
}
