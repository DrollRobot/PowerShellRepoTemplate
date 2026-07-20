<#
.SYNOPSIS
    Pester tests for Build.ps1.

.DESCRIPTION
    Runs a real build against a scratch copy of this repo's own Source\ tree
    (both -SourcePath and -OutputDirectory are parameterized, so this never
    touches the real repo's Output\ or root). -BuildToRoot is deliberately
    never exercised here: it writes to $PSScriptRoot (Build.ps1's own real
    location), not a parameter, so it cannot be redirected into scratch.

    Build\PreBuild.ps1 and Build\PostBuild.ps1 are resolved from the real
    repo root regardless of -SourcePath/-OutputDirectory; both are currently
    empty FIXME stubs (see AGENTS coverage plan), so this is a no-op today.
    Integration; no tag.
#>

BeforeAll {
    $SutParams = @{
        Path      = $PSScriptRoot
        ChildPath = '..\..\Build.ps1'
    }
    $script:Sut = (Resolve-Path (Join-Path @SutParams)).Path
    $RealSourceParams = @{
        Path      = $PSScriptRoot
        ChildPath = '..\..\Source'
    }
    $script:RealSource = (Resolve-Path (Join-Path @RealSourceParams)).Path

    $ScratchParams = @{
        Path      = [System.IO.Path]::GetTempPath()
        ChildPath = [System.IO.Path]::GetRandomFileName()
    }
    $script:ScratchDir = Join-Path @ScratchParams
    New-Item -ItemType Directory -Path $script:ScratchDir -Force | Out-Null
}

AfterAll {
    Remove-Item -LiteralPath $script:ScratchDir -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Build.ps1' -Tag 'integration', 'functional', 'slow' {
    It 'builds a versioned artifact from a scratch copy of Source\' {
        $ScratchSource = Join-Path -Path $script:ScratchDir -ChildPath 'Source'
        Copy-Item -LiteralPath $script:RealSource -Destination $ScratchSource -Recurse
        $ScratchOutput = Join-Path -Path $script:ScratchDir -ChildPath 'Output'

        $ArgList = @(
            '-NoProfile', '-NonInteractive', '-File', $script:Sut,
            '-SourcePath', $ScratchSource, '-OutputDirectory', $ScratchOutput
        )
        $Output = & pwsh @ArgList 2>&1
        $ExitCode = $LASTEXITCODE

        $ExitCode | Should -Be 0

        $BuiltManifest = @(Get-ChildItem -Path $ScratchOutput -Filter '*.psd1' -Recurse)
        $BuiltManifest.Count | Should -Be 1
        $BuiltPsm1 = @(Get-ChildItem -Path $ScratchOutput -Filter '*.psm1' -Recurse)
        $BuiltPsm1.Count | Should -Be 1
        $BuiltPsm1[0].BaseName | Should -Be $BuiltManifest[0].BaseName

        $EscapedName = [regex]::Escape($BuiltManifest[0].BaseName)
        ($Output | Out-String) | Should -Match $EscapedName
    }
}
