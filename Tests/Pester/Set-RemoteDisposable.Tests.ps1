<#
.SYNOPSIS
    Pester tests for Scripts\Set-RemoteDisposable.ps1.

.DESCRIPTION
    Regression test only: this fail-closed stub must keep refusing until a
    project implements its FIXME. The script throws (not `exit`s) to refuse,
    so it is safe to dot-source in-process directly. NotLive; no tag.
#>

BeforeAll {
    $SutParams = @{
        Path      = $PSScriptRoot
        ChildPath = '..\..\Scripts\Set-RemoteDisposable.ps1'
    }
    $script:Sut = (Resolve-Path (Join-Path @SutParams)).Path
}

Describe 'Set-RemoteDisposable' -Tag 'unit', 'functional', 'regression' {

    It 'refuses unconditionally with no arguments' {
        { . $script:Sut } | Should -Throw -ExpectedMessage '*has not been implemented*'
    }

    It 'still refuses when -Force is passed' {
        { . $script:Sut -Force } | Should -Throw -ExpectedMessage '*has not been implemented*'
    }
}
