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

        <code>  # noqa: LineLength

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

Describe 'LineLength' -Tag 'lint' {

    It '<RelativePath>' -ForEach $script:LintCases {
        $Lines = @(Get-Content -LiteralPath $FullName)
        $Hits = for ($i = 0; $i -lt $Lines.Count; $i++) {
            if ($null -eq $Lines[$i]) { continue }
            if ($Lines[$i] -match '#\s*noqa:\s*LineLength') { continue }
            if ($Lines[$i].Length -gt $MaxLength) {
                "$($RelativePath) Line:$($i + 1) Length:$($Lines[$i].Length)"
            }
        }
        # throw, not Should: Tests.ps1 prints Exception.Message verbatim, and
        # only a raw throw leaves it free of "Expected ... but got ..." wrapping.
        # One finding per line, each already prefixed with its file path.
        if ($Hits) { throw ($Hits -join [System.Environment]::NewLine) }
    }
}
