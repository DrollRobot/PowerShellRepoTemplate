<#
.SYNOPSIS
    Pester lint check: flags lines exceeding a maximum length.

.DESCRIPTION
    Pester implementation of the check in Tests\Test-LineLength.ps1 -- one It
    per scanned file, generated during Discovery. A failing file is identified
    by its test name; the failure message lists every offending line number
    and its length.

    To suppress a finding on a specific line, append the inline exemption
    marker:

        <code>  # noqa: Test-LineLength

    Parameterized via a Pester container. Tests.ps1's 'Lint' category builds
    the container, feeding static values from Tests\TestConfig.psd1 plus the
    scan target and computed build-artifact exclusions:

        $Container = New-PesterContainer -Path $PSCommandPath -Data @{
            Path        = 'C:\some\repo'
            ExcludePath = @('C:\some\repo\Output')
            MaxLength   = 100
        }
        Invoke-Pester -Container $Container -Output Detailed

    Run bare (Invoke-Pester -Path <this file>), it scans the repository root
    with no exclusions.

.PARAMETER Path
    Files and/or folders to scan (folders recurse). Defaults to the repository
    root, two levels above this file.

.PARAMETER ExcludePath
    Files and/or folders to skip. A file entry excludes that file; a folder
    entry excludes its whole subtree. Relative entries resolve against the
    current directory; Tests.ps1 passes absolute paths.

.PARAMETER MaxLength
    Maximum allowed line length in characters. Defaults to 100.
#>
param(
    [string[]] $Path,
    [string[]] $ExcludePath = @(),
    [int] $MaxLength = 100
)

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

Describe 'LineLength lint' -Tag 'lint' {

    It '<RelativePath> has no lines over <MaxLength> chars' -ForEach $script:LintCases {
        $Lines = @(Get-Content -LiteralPath $FullName)
        $Hits = for ($i = 0; $i -lt $Lines.Count; $i++) {
            if ($null -eq $Lines[$i]) { continue }
            if ($Lines[$i] -match '#\s*noqa:\s*Test-LineLength') { continue }
            if ($Lines[$i].Length -gt $MaxLength) {
                "line $($i + 1): $($Lines[$i].Length) chars"
            }
        }
        $Because = "every line must be at most $MaxLength characters. " +
        "Fix all findings, even ones unrelated to your changes; do not use " +
        "backtick continuations. Findings:`n" + ($Hits -join "`n")
        @($Hits).Count | Should -Be 0 -Because $Because
    }
}
