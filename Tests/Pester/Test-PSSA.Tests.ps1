<#
.SYNOPSIS
    Pester tests for Tests\Test-PSSA.ps1.

.DESCRIPTION
    Wraps PSScriptAnalyzer directly (a slow, external tool), so coverage here
    stays shallow by design: confirm detection works against a small fixture
    with a known-bad pattern, and that a clean file passes. Not a rehearsal of
    PSScriptAnalyzer's own rule set. Skipped entirely when PSScriptAnalyzer is
    not installed, matching the checker's own graceful-skip behavior. The
    checker calls `exit` at top level, so it runs as a child pwsh process via
    a generated wrapper script rather than being dot-sourced. Integration; no
    tag beyond scope, since it exercises the real PSScriptAnalyzer module.
#>

# Computed at discovery time (outside BeforeAll) because Pester evaluates
# -Skip: expressions during discovery, before any BeforeAll block has run.
$script:PssaAvailable = [bool] (Get-Module -ListAvailable -Name PSScriptAnalyzer)

BeforeAll {
    $SutParams = @{
        Path      = $PSScriptRoot
        ChildPath = '..\..\Tests\Test-PSSA.ps1'
    }
    $script:Sut = (Resolve-Path (Join-Path @SutParams)).Path

    $ScratchParams = @{
        Path      = [System.IO.Path]::GetTempPath()
        ChildPath = [System.IO.Path]::GetRandomFileName()
    }
    $script:ScratchDir = Join-Path @ScratchParams
    New-Item -ItemType Directory -Path $script:ScratchDir -Force | Out-Null

    function script:Invoke-Checker {
        param([Parameter(Mandatory)][string[]] $ScriptArgs)
        $FormattedArgs = $ScriptArgs | ForEach-Object {
            if ($_ -match '^-[A-Za-z]') {
                $_
            }
            else {
                "'" + ($_ -replace "'", "''") + "'"
            }
        }
        $CatchBody = 'Write-Host $_.Exception.Message; exit 1'
        $CallLine = "try { & '$script:Sut' $($FormattedArgs -join ' ') } catch { $CatchBody }"
        $Lines = @($CallLine, 'exit 0')

        $WrapperParams = @{
            Path      = $script:ScratchDir
            ChildPath = "wrapper-$([guid]::NewGuid().ToString('N')).ps1"
        }
        $WrapperPath = Join-Path @WrapperParams
        Set-Content -LiteralPath $WrapperPath -Value $Lines

        $ArgList = @('-NoProfile', '-NonInteractive', '-File', $WrapperPath)
        $Output = & pwsh @ArgList 2>&1
        $Result = [PSCustomObject]@{
            Output   = ($Output | Out-String)
            ExitCode = $LASTEXITCODE
        }
        Remove-Item -LiteralPath $WrapperPath -Force -ErrorAction SilentlyContinue
        return $Result
    }

    function script:New-ScratchFile {
        param([Parameter(Mandatory)][string[]] $Content)
        $NameParams = @{
            Path      = $script:ScratchDir
            ChildPath = "case-$([guid]::NewGuid().ToString('N')).ps1"
        }
        $Path = Join-Path @NameParams
        Set-Content -LiteralPath $Path -Value $Content
        return $Path
    }
}

AfterAll {
    Remove-Item -LiteralPath $script:ScratchDir -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Test-PSSA' -Tag 'integration', 'functional' {

    It 'reports 0 issues for a clean file' -Skip:(-not $script:PssaAvailable) {
        $File = New-ScratchFile -Content @('function Get-Thing {', '    param()', '    1', '}')
        $Result = Invoke-Checker -ScriptArgs @('-Path', $File)
        $Result.ExitCode | Should -Be 0
        $Result.Output | Should -Match '0 issue'
    }

    It 'detects a known-bad pattern (a cmdlet alias)' -Skip:(-not $script:PssaAvailable) {
        $File = New-ScratchFile -Content @('gci -Path .')
        $Result = Invoke-Checker -ScriptArgs @('-Path', $File)
        $Result.ExitCode | Should -Be 1
        $Result.Output | Should -Match 'PSAvoidUsingCmdletAliases'
    }

    It 'suppresses the detail table with -Quiet' -Skip:(-not $script:PssaAvailable) {
        # The load-time "could take minutes" note is unconditional; only the
        # findings table and its remediation note are gated on -Quiet.
        $File = New-ScratchFile -Content @('gci -Path .')
        $Result = Invoke-Checker -ScriptArgs @('-Path', $File, '-Quiet')
        $Result.ExitCode | Should -Be 1
        $Result.Output | Should -Not -Match 'PSAvoidUsingCmdletAliases'
        $Result.Output | Should -Not -Match 'Always fix all PSScriptAnalyzer findings'
        $Result.Output | Should -Match '1 issue'
    }
}
