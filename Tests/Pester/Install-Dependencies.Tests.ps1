<#
.SYNOPSIS
    Pester tests for Source\ScriptsToProcess\Install-Dependencies.ps1.

.DESCRIPTION
    The script discovers its manifest via $PSScriptRoot (its own file
    location, not a parameter), so a scratch copy is placed next to a fixture
    manifest to exercise it in isolation. Only -Check is exercised (no real
    installs); the real -Scope/-Force install path is never run here, since
    that would hit the live PSGallery. The script uses `throw`, not `exit`, so
    it is safe to invoke in-process via the call operator. NotLive; no tag.
#>

BeforeAll {
    $RealScriptParams = @{
        Path      = $PSScriptRoot
        ChildPath = '..\..\Source\ScriptsToProcess\Install-Dependencies.ps1'
    }
    $script:RealScript = (Resolve-Path (Join-Path @RealScriptParams)).Path

    $ScratchParams = @{
        Path      = [System.IO.Path]::GetTempPath()
        ChildPath = [System.IO.Path]::GetRandomFileName()
    }
    $script:ScratchDir = Join-Path @ScratchParams
    New-Item -ItemType Directory -Path $script:ScratchDir -Force | Out-Null

    # Returns a fresh scratch copy of the script plus a fixture manifest
    # declaring the given RequiredModules, so $PSScriptRoot resolves there.
    function script:New-DependencyFixture {
        param([Parameter(Mandatory)][string] $ManifestBody)
        $DirParams = @{
            Path      = $script:ScratchDir
            ChildPath = "dep-$([guid]::NewGuid().ToString('N'))"
        }
        $Dir = Join-Path @DirParams
        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
        $ScriptCopy = Join-Path -Path $Dir -ChildPath 'Install-Dependencies.ps1'
        Copy-Item -LiteralPath $script:RealScript -Destination $ScriptCopy
        $ManifestPath = Join-Path -Path $Dir -ChildPath 'Fixture.psd1'
        Set-Content -LiteralPath $ManifestPath -Value $ManifestBody
        return $ScriptCopy
    }
}

AfterAll {
    Remove-Item -LiteralPath $script:ScratchDir -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Install-Dependencies -Check' -Tag 'unit', 'functional' {

    It 'does not throw when the required module is already satisfied' {
        $ManifestBody = @'
@{
    RequiredModules = @(
        @{ ModuleName = 'Pester'; ModuleVersion = '6.0.0' }
    )
}
'@
        $ScriptCopy = New-DependencyFixture -ManifestBody $ManifestBody
        { & $ScriptCopy -Check -Quiet } | Should -Not -Throw
    }

    It 'throws when a required module is missing' {
        $ManifestBody = @'
@{
    RequiredModules = @(
        @{ ModuleName = 'DefinitelyNotARealModule12345'; ModuleVersion = '1.0.0' }
    )
}
'@
        $ScriptCopy = New-DependencyFixture -ManifestBody $ManifestBody
        { & $ScriptCopy -Check -Quiet } | Should -Throw
    }

    It 'reports MISSING for the unsatisfied module without -Quiet' {
        $ManifestBody = @'
@{
    RequiredModules = @(
        @{ ModuleName = 'DefinitelyNotARealModule12345'; ModuleVersion = '1.0.0' }
    )
}
'@
        $ScriptCopy = New-DependencyFixture -ManifestBody $ManifestBody
        # -OutVariable accumulates as a side effect even if the call later
        # throws, unlike `$x = try { ... } catch { ... }`, which would lose
        # any output already emitted before the exception.
        try {
            & $ScriptCopy -Check -OutVariable CheckOutput 6>&1 | Out-Null
        }
        catch {
        }
        ($CheckOutput | Out-String) | Should -Match 'MISSING'
    }

    It 'does nothing and does not throw when no modules are declared' {
        $ManifestBody = '@{}'
        $ScriptCopy = New-DependencyFixture -ManifestBody $ManifestBody
        { & $ScriptCopy -Check -Quiet } | Should -Not -Throw
    }
}
