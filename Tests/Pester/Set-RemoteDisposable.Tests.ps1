<#
.SYNOPSIS
    Pester tests for Scripts\Set-RemoteDisposable.ps1.

.DESCRIPTION
    Regression test only: this fail-closed stub must keep refusing until a
    project implements its FIXME. The script throws (not `exit`s) to refuse,
    so it is safe to dot-source in-process directly. It banners via Write-Host,
    which Pester does not capture, so stream 6 is redirected to keep the run
    output clean. NotLive; no tag.
#>

BeforeAll {
    $SutParams = @{
        Path      = $PSScriptRoot
        ChildPath = '..\..\Scripts\Set-RemoteDisposable.ps1'
    }
    $script:Sut = (Resolve-Path (Join-Path @SutParams)).Path
}

Describe 'Set-RemoteDisposable' -Tag 'unit', 'functional', 'regression' {
    BeforeAll {
        $script:RefusalPattern = '*has not been implemented*'
    }

    It 'refuses unconditionally with no arguments' {
        { . $script:Sut 6>$null } | Should -Throw -ExpectedMessage $script:RefusalPattern
    }

    It 'still refuses when -Force is passed' {
        { . $script:Sut -Force 6>$null } | Should -Throw -ExpectedMessage $script:RefusalPattern
    }
}
