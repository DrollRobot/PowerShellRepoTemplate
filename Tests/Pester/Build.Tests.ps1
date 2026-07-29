<#
.SYNOPSIS
    Pester tests for Build.ps1.

.DESCRIPTION
    Runs a real build against a scratch copy of this repo's own Source\ tree
    (both -SourcePath and -OutputDirectory are parameterized, so this never
    touches the real repo's Output\ or root).

    Build.psd1's BuildToRoot key writes to the repo root, which Build.ps1
    resolves from $PSScriptRoot rather than a parameter. Those cases therefore
    run a scratch COPY of Build.ps1, so "the repo root" is the scratch folder
    and the real repo root is never written.

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

    $RealManifest = Get-ChildItem -Path $script:RealSource -Filter '*.psd1' |
        Where-Object Name -ne 'Build.psd1' |
        Select-Object -First 1
    $script:ModuleName = $RealManifest.BaseName

    function script:Set-BuildToRoot {
        <#
        .SYNOPSIS
            Rewrites the BuildToRoot value in a scratch copy of Build.psd1.

        .PARAMETER SourceDir
            Scratch Source\ folder holding the Build.psd1 to edit.

        .PARAMETER Value
            Literal PowerShell text to assign, e.g. '$true' or "'yes'".
        #>
        param(
            [Parameter(Mandatory)]
            [string]$SourceDir,

            [Parameter(Mandatory)]
            [string]$Value
        )

        $Psd1 = Join-Path -Path $SourceDir -ChildPath 'Build.psd1'
        $Content = Get-Content -LiteralPath $Psd1 -Raw
        $Pattern = '(?m)^\s*BuildToRoot\s*=.*$'
        $Content = [regex]::Replace($Content, $Pattern, "    BuildToRoot = $Value")
        Set-Content -LiteralPath $Psd1 -Value $Content -Encoding utf8
    }
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

    It 'builds flat to the repo root when Build.psd1 sets BuildToRoot' {
        $ScratchRepo = Join-Path -Path $script:ScratchDir -ChildPath 'RootBuild'
        $ScratchSource = Join-Path -Path $ScratchRepo -ChildPath 'Source'
        New-Item -ItemType Directory -Path $ScratchRepo -Force | Out-Null
        Copy-Item -LiteralPath $script:RealSource -Destination $ScratchSource -Recurse
        $ScratchSut = Join-Path -Path $ScratchRepo -ChildPath 'Build.ps1'
        Copy-Item -LiteralPath $script:Sut -Destination $ScratchSut

        Set-BuildToRoot -SourceDir $ScratchSource -Value '$true'

        $ArgList = @('-NoProfile', '-NonInteractive', '-File', $ScratchSut)
        $Output = & pwsh @ArgList 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($Output | Out-String)

        $RootManifest = @(Get-ChildItem -Path $ScratchRepo -Filter '*.psd1')
        $RootManifest.Name | Should -Contain "$script:ModuleName.psd1"
        $RootPsm1 = @(Get-ChildItem -Path $ScratchRepo -Filter '*.psm1')
        $RootPsm1.Name | Should -Contain "$script:ModuleName.psm1"

        # Flat: no version folder, and nothing written to Output\.
        Join-Path -Path $ScratchRepo -ChildPath 'Output' | Should -Not -Exist
    }

    It 'fails the build when BuildToRoot is not a boolean' {
        $ScratchRepo = Join-Path -Path $script:ScratchDir -ChildPath 'BadValue'
        $ScratchSource = Join-Path -Path $ScratchRepo -ChildPath 'Source'
        New-Item -ItemType Directory -Path $ScratchRepo -Force | Out-Null
        Copy-Item -LiteralPath $script:RealSource -Destination $ScratchSource -Recurse
        $ScratchSut = Join-Path -Path $ScratchRepo -ChildPath 'Build.ps1'
        Copy-Item -LiteralPath $script:Sut -Destination $ScratchSut

        Set-BuildToRoot -SourceDir $ScratchSource -Value "'yes'"

        $ArgList = @('-NoProfile', '-NonInteractive', '-File', $ScratchSut)
        $Output = & pwsh @ArgList 2>&1
        $LASTEXITCODE | Should -Not -Be 0
        ($Output | Out-String) | Should -Match 'BuildToRoot'
    }
}
