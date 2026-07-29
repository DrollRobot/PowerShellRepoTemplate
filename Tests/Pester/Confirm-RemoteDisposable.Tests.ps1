<#
.SYNOPSIS
    Pester tests for Tests\Confirm-RemoteDisposable.ps1.

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
        ChildPath = '..\..\Tests\Confirm-RemoteDisposable.ps1'
    }
    $script:Sut = (Resolve-Path (Join-Path @SutParams)).Path
}

Describe 'Confirm-RemoteDisposable' -Tag 'unit', 'functional', 'regression' {

    It 'throws (not disposable) until the FIXME is implemented' {
        { . $script:Sut 6>$null } | Should -Throw -ExpectedMessage '*not confirmed disposable*'
    }
}
