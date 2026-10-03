<#
.SYNOPSIS
    Pester tests for Tests\Pester\Build-TestFileList.ps1.

.DESCRIPTION
    The helper is a plain dot-sourced function, so these run in-process: build a
    scratch tree, list it, assert on which files survived. NotLive.
#>

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'Build-TestFileList.ps1')

    $ScratchParams = @{
        Path      = [System.IO.Path]::GetTempPath()
        ChildPath = [System.IO.Path]::GetRandomFileName()
    }
    $script:ScratchDir = Join-Path @ScratchParams
    foreach ($Rel in @('Keep.ps1', 'Notes.md', 'Skip.ps1', 'Output\Built.ps1')) {
        $FilePath = Join-Path -Path $script:ScratchDir -ChildPath $Rel
        New-Item -ItemType File -Path $FilePath -Force | Out-Null
    }

    # The surviving files' paths relative to the scratch root, '/'-separated so
    # the assertions read the same on every platform.
    function script:Get-Kept {
        param([hashtable] $Params = @{})
        $ListParams = @{ Path = $script:ScratchDir }
        foreach ($Key in $Params.Keys) { $ListParams[$Key] = $Params[$Key] }
        @(Build-TestFileList @ListParams | ForEach-Object {
                $_.RelativePath -replace '\\', '/'
            } | Sort-Object)
    }
}

AfterAll {
    $RemoveParams = @{
        LiteralPath = $script:ScratchDir
        Recurse     = $true
        Force       = $true
        ErrorAction = 'SilentlyContinue'
    }
    Remove-Item @RemoveParams
}

Describe 'Build-TestFileList' -Tag 'unit', 'functional' {
    It 'keeps only PowerShell files by default' {
        Get-Kept | Should -Be @('Keep.ps1', 'Output/Built.ps1', 'Skip.ps1')
    }
    It 'skips every file under an excluded folder' -Tag 'regression' {
        $Excluded = Join-Path -Path $script:ScratchDir -ChildPath 'Output'
        Get-Kept @{ ExcludePath = $Excluded } | Should -Be @('Keep.ps1', 'Skip.ps1')
    }
    It 'skips an excluded file' {
        $Excluded = Join-Path -Path $script:ScratchDir -ChildPath 'Skip.ps1'
        Get-Kept @{ ExcludePath = $Excluded } | Should -Be @('Keep.ps1', 'Output/Built.ps1')
    }
    It 'keeps every extension when asked to' {
        $Expected = @('Keep.ps1', 'Notes.md', 'Output/Built.ps1', 'Skip.ps1')
        Get-Kept @{ Extension = '*' } | Should -Be $Expected
    }
}
