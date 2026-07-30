<#
.SYNOPSIS
    Pester tests for Source\ScriptsToProcess\Install-Dependency.ps1.

.DESCRIPTION
    The script reads RequiredModules.psd1 from $PSScriptRoot (its own file location,
    not a parameter), so a scratch copy is placed next to a fixture data file to
    exercise it in isolation. Anything that would install runs under -WhatIf, so the
    live PSGallery is never contacted; the real -Scope/-Force install path is never
    run here. The script uses `throw`, not `exit`, so it is safe to invoke in-process
    via the call operator. It banners via Write-Host, so output assertions merge
    stream 6 into the success stream. NotLive; no tag.

    'Pester' is used as the stand-in for an installed module -- it is by definition
    present whenever these tests run.
#>

BeforeAll {
    $RealScriptParams = @{
        Path      = $PSScriptRoot
        ChildPath = '..\..\Source\ScriptsToProcess\Install-Dependency.ps1'
    }
    $script:RealScript = (Resolve-Path (Join-Path @RealScriptParams)).Path

    $ScratchParams = @{
        Path      = [System.IO.Path]::GetTempPath()
        ChildPath = [System.IO.Path]::GetRandomFileName()
    }
    $script:ScratchDir = Join-Path @ScratchParams
    New-Item -ItemType Directory -Path $script:ScratchDir -Force | Out-Null

    # Returns a fresh scratch copy of the script plus, unless -NoDataFile is passed,
    # a RequiredModules.psd1 beside it -- the sibling layout $PSScriptRoot resolves to.
    function script:New-DependencyFixture {
        param(
            [string] $DataBody = '@{ RequiredModules = @() }',
            [switch] $NoDataFile
        )
        $DirParams = @{
            Path      = $script:ScratchDir
            ChildPath = "dep-$([guid]::NewGuid().ToString('N'))"
        }
        $Dir = Join-Path @DirParams
        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
        $ScriptCopy = Join-Path -Path $Dir -ChildPath 'Install-Dependency.ps1'
        Copy-Item -LiteralPath $script:RealScript -Destination $ScriptCopy
        if (-not $NoDataFile) {
            $DataParams = @{
                LiteralPath = Join-Path -Path $Dir -ChildPath 'RequiredModules.psd1'
                Value       = $DataBody
            }
            Set-Content @DataParams
        }
        return $ScriptCopy
    }

    $script:MissingModuleData = @'
@{
    RequiredModules = @(
        @{ ModuleName = 'DefinitelyNotARealModule12345'; ModuleVersion = '1.0.0' }
    )
}
'@

    $script:SatisfiedData = @'
@{
    RequiredModules = @(
        @{ ModuleName = 'Pester'; ModuleVersion = '0.0.1' }
    )
}
'@
}

AfterAll {
    Remove-Item -LiteralPath $script:ScratchDir -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Install-Dependency' -Tag 'unit', 'functional' {

    It 'throws when RequiredModules.psd1 is missing' {
        $ScriptCopy = New-DependencyFixture -NoDataFile
        { & $ScriptCopy 6>$null } | Should -Throw '*RequiredModules.psd1 not found*'
    }

    It 'does nothing and does not throw when no modules are declared' {
        $ScriptCopy = New-DependencyFixture
        { & $ScriptCopy 6>$null } | Should -Not -Throw
    }

    It 'reports there is nothing to do when no modules are declared' {
        $ScriptCopy = New-DependencyFixture
        $Output = & $ScriptCopy 6>&1
        ($Output | Out-String) | Should -Match 'Nothing to do'
    }

    It 'does not throw when the required module is already satisfied' {
        $ScriptCopy = New-DependencyFixture -DataBody $script:SatisfiedData
        { & $ScriptCopy 6>$null } | Should -Not -Throw
    }

    It 'reports OK for a satisfied module, and names the data file as its source' {
        $ScriptCopy = New-DependencyFixture -DataBody $script:SatisfiedData
        $Output = (& $ScriptCopy 6>&1) | Out-String
        $Output | Should -Match 'Pester'
        $Output | Should -Match 'OK'
        $Output | Should -Match 'RequiredModules\.psd1'
    }

    It 'reports MISSING for an unsatisfied module without installing anything' {
        # -WhatIf keeps ShouldProcess from running Install-Module, so this never
        # reaches the live PSGallery. -OutVariable accumulates as a side effect
        # even if the call later throws, unlike `$x = try { ... } catch { ... }`,
        # which would lose any output already emitted before the exception.
        $ScriptCopy = New-DependencyFixture -DataBody $script:MissingModuleData
        try {
            & $ScriptCopy -WhatIf -OutVariable RunOutput 6>&1 | Out-Null
        }
        catch {
        }
        ($RunOutput | Out-String) | Should -Match 'MISSING'
    }
}
