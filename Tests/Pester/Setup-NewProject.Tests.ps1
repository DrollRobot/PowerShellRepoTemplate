<#
.SYNOPSIS
    Pester tests for Scripts\Setup-NewProject.ps1.

.DESCRIPTION
    The script already guards its main body with `if ($MyInvocation.
    InvocationName -eq '.') { return }`, so it can be dot-sourced to reach its
    validation functions directly.

    $script:RepoRoot is derived from $PSScriptRoot, i.e. it always resolves to
    THIS repo (wherever the real script file lives), regardless of the
    process's current directory -- there is no -RepoPath override. That makes
    the apply path unsafe to run for real against anything but a scratch copy
    of the whole template tree, which this suite does not build (high setup
    cost for a one-time converter script, per the coverage plan). Instead:

      - Get-ConfigString / Get-ConfigBool / Test-SetupConfig are pure and
        covered directly via dot-source.
      - Test-PristineTemplateClone and the -DryRun preview functions
        (Invoke-StripHeader, Invoke-RenameProject) are read-only against the
        real repo -- safe, and exercised here as a light integration check
        that DryRun truly writes nothing (verified via `git status`).
      - The real config-driven -Yes apply path (file rewrites, renames,
        license selection, feature removal, and especially [Git].Reinit's
        `Remove-Item .git`) is NOT exercised at all: there is no safe way to
        run it without a full scratch copy of the repo, and accidentally
        running it here would mutate or destroy this actual repository.
#>

BeforeAll {
    $SutParams = @{
        Path      = $PSScriptRoot
        ChildPath = '..\..\Scripts\TemplateSetup\Setup-NewProject.ps1'
    }
    $script:Sut = (Resolve-Path (Join-Path @SutParams)).Path
    $RepoRootParams = @{
        Path      = $PSScriptRoot
        ChildPath = '..\..'
    }
    $script:RealRepoRoot = (Resolve-Path (Join-Path @RepoRootParams)).Path

    $ScratchParams = @{
        Path      = [System.IO.Path]::GetTempPath()
        ChildPath = [System.IO.Path]::GetRandomFileName()
    }
    $script:ScratchDir = Join-Path @ScratchParams
    New-Item -ItemType Directory -Path $script:ScratchDir -Force | Out-Null

    . $script:Sut
}

AfterAll {
    Remove-Item -LiteralPath $script:ScratchDir -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Get-ConfigString and Get-ConfigBool' -Tag 'unit', 'functional' {
    It 'reads a nested string value' {
        $Raw = @{ Project = @{ Name = 'MyModule' } }
        $Problems = [System.Collections.Generic.List[string]]::new()
        Get-ConfigString -Raw $Raw -Path 'Project.Name' -Problems $Problems | Should -Be 'MyModule'
        $Problems.Count | Should -Be 0
    }

    It 'records a problem and returns empty for a missing string' {
        $Raw = @{}
        $Problems = [System.Collections.Generic.List[string]]::new()
        Get-ConfigString -Raw $Raw -Path 'Project.Name' -Problems $Problems | Should -Be ''
        $Problems.Count | Should -Be 1
    }

    It 'reads a nested bool value' {
        $Raw = @{ Features = @{ Docs = $false } }
        $Problems = [System.Collections.Generic.List[string]]::new()
        Get-ConfigBool -Raw $Raw -Path 'Features.Docs' -Problems $Problems | Should -BeFalse
        $Problems.Count | Should -Be 0
    }

    It 'records a problem when a bool field is actually a string' {
        $Raw = @{ Features = @{ Docs = 'yes' } }
        $Problems = [System.Collections.Generic.List[string]]::new()
        Get-ConfigBool -Raw $Raw -Path 'Features.Docs' -Problems $Problems | Should -BeFalse
        $Problems.Count | Should -Be 1
    }
}

Describe 'Test-SetupConfig' -Tag 'unit', 'functional' {
    # A minimal, fully valid config -- individual tests override just the
    # field(s) under test.
    function script:New-ValidRawConfig {
        param([hashtable] $Overrides = @{})
        $Base = @{
            Project  = @{ Name = 'MyModule'; GitHubUser = '' }
            License  = @{ Key = 'none'; Year = ''; Name = ''; Company = '' }
            Git      = @{ Branch = 'main'; Reinit = $false }
            Features = @{
                Docs                      = $true
                SecurityMd                = $true
                ContributingMd            = $true
                ExplicitModuleImport      = $true
                InstallDependenciesScript = $true
                StandaloneScriptGenerator = $true
                IntunePackageGenerator    = $true
                WriteLog                  = $true
                NonASCIICharacters        = $true
                FormatOperator            = $true
                WriteVerboseDebug         = $true
                BacktickContinuation      = $true
                UnwantedStringsLocal      = $false
            }
        }
        foreach ($Key in $Overrides.Keys) { $Base[$Key] = $Overrides[$Key] }
        return $Base
    }

    It 'reports no problems for a fully valid config' {
        $Result = Test-SetupConfig -Raw (New-ValidRawConfig)
        $Result.Problems.Count | Should -Be 0
        $Result.Name | Should -Be 'MyModule'
    }

    It 'requires Project.Name' {
        $Raw = New-ValidRawConfig -Overrides @{ Project = @{ Name = ''; GitHubUser = '' } }
        $Result = Test-SetupConfig -Raw $Raw
        $Result.Problems | Should -Contain '[Project.Name] is required.'
    }

    It 'rejects a Project.Name with invalid characters' {
        $NameTable = @{ Name = 'bad name!'; GitHubUser = '' }
        $Raw = New-ValidRawConfig -Overrides @{ Project = $NameTable }
        $Result = Test-SetupConfig -Raw $Raw
        $Result.Problems.Count | Should -BeGreaterThan 0
    }

    It 'accepts a blank Project.GitHubUser as a deliberate skip' {
        $Raw = New-ValidRawConfig -Overrides @{ Project = @{ Name = 'MyModule'; GitHubUser = '' } }
        $Result = Test-SetupConfig -Raw $Raw
        $Result.Problems.Count | Should -Be 0
        $Result.GitHubUser | Should -Be ''
    }

    It 'rejects a whitespace-only Project.GitHubUser' {
        $ProjectTable = @{ Name = 'MyModule'; GitHubUser = '   ' }
        $Raw = New-ValidRawConfig -Overrides @{ Project = $ProjectTable }
        $Result = Test-SetupConfig -Raw $Raw
        ($Result.Problems -join "`n") | Should -Match 'Project.GitHubUser'
    }

    It 'rejects an unknown License.Key' {
        $LicenseTable = @{ Key = 'bogus'; Year = ''; Name = ''; Company = '' }
        $Raw = New-ValidRawConfig -Overrides @{ License = $LicenseTable }
        $Result = Test-SetupConfig -Raw $Raw
        $ExpectedProblem = "[License.Key] 'bogus' is not one of: " +
        'mit, apache, gnu, proprietary, none.'
        $Result.Problems | Should -Contain $ExpectedProblem
    }

    It 'requires License.Year and License.Name for licenses that need a holder' {
        $LicenseTable = @{ Key = 'mit'; Year = ''; Name = ''; Company = '' }
        $Raw = New-ValidRawConfig -Overrides @{ License = $LicenseTable }
        $Result = Test-SetupConfig -Raw $Raw
        $Result.Problems | Should -Contain '[License.Year] is required for this license.'
        $Result.Problems | Should -Contain '[License.Name] is required for this license.'
    }

    It 'requires License.Company only for the proprietary license' {
        $LicenseTable = @{ Key = 'proprietary'; Year = '2026'; Name = 'Me'; Company = '' }
        $Raw = New-ValidRawConfig -Overrides @{ License = $LicenseTable }
        $Result = Test-SetupConfig -Raw $Raw
        $ExpectedProblem = '[License.Company] is required for the proprietary license.'
        $Result.Problems | Should -Contain $ExpectedProblem
    }

    It 'requires Git.Branch to be non-empty' {
        $Raw = New-ValidRawConfig -Overrides @{ Git = @{ Branch = '  '; Reinit = $false } }
        $Result = Test-SetupConfig -Raw $Raw
        $Result.Problems | Should -Contain '[Git.Branch] is empty.'
    }

    It 'flags Git.Reinit=true against a repo that is not a pristine template clone' {
        Mock Test-PristineTemplateClone { return $false }
        $Raw = New-ValidRawConfig -Overrides @{ Git = @{ Branch = 'main'; Reinit = $true } }
        $Result = Test-SetupConfig -Raw $Raw
        $Result.Problems.Count | Should -BeGreaterThan 0
    }

    It 'requires Features.WriteLog like every other feature flag' {
        $Raw = New-ValidRawConfig
        $Raw.Features.Remove('WriteLog')
        $Result = Test-SetupConfig -Raw $Raw
        $ExpectedProblem = '[Features.WriteLog] is missing or is not a true/false value.'
        $Result.Problems | Should -Contain $ExpectedProblem
    }
}

Describe 'Get-FeatureStep' -Tag 'unit', 'functional' {
    It 'plans no feature steps for an unedited (keep-everything) config' {
        $Config = Test-SetupConfig -Raw (New-ValidRawConfig)
        @(Get-FeatureStep -Config $Config) | Should -HaveCount 0
    }

    It 'plans the Write-Log removal when Features.WriteLog is false' {
        $Raw = New-ValidRawConfig
        $Raw.Features.WriteLog = $false
        $Config = Test-SetupConfig -Raw $Raw
        $Steps = @(Get-FeatureStep -Config $Config)
        $Steps | Should -HaveCount 1
        $Steps[0].Key | Should -Be 'remove_write_log'
        $Steps[0].Type | Should -Be 'WriteLog'
    }

    It 'dispatches the WriteLog step to Remove-WriteLog against the repo root' {
        Mock Remove-WriteLog { return $true }
        $Step = [pscustomobject]@{ Key = 'remove_write_log'; Type = 'WriteLog' }
        Invoke-FeatureStep -Step $Step -DryRun $true | Should -BeTrue
        Should -Invoke Remove-WriteLog -Times 1 -Exactly -ParameterFilter {
            $RepoRoot -eq $script:RepoRoot -and $DryRun -eq $true
        }
    }
}

Describe 'Invoke-RemoveSampleFunction' -Tag 'unit', 'functional' {
    BeforeEach {
        # Both the step and its nav helper read $script:RepoRoot, which the SUT points at THIS
        # repo. Redirect it at a scratch tree for the duration of each test so the real repo is
        # never touched, and restore it afterward.
        $script:SavedRepoRoot = $script:RepoRoot
        $TreeParams = @{
            Path      = $script:ScratchDir
            ChildPath = [System.IO.Path]::GetRandomFileName()
        }
        $script:FakeRepo = Join-Path @TreeParams
        foreach ($Rel in @('Source\Public', 'Tests\Pester', 'Docs\PowershellRepoTemplate')) {
            $Dir = Join-Path -Path $script:FakeRepo -ChildPath $Rel
            New-Item -ItemType Directory -Path $Dir -Force | Out-Null
        }
        $SampleFiles = @(
            'Source\Public\Get-Greeting.ps1'
            'Tests\Pester\Get-Greeting.Tests.ps1'
            'Docs\PowershellRepoTemplate\Get-Greeting.md'
        )
        foreach ($Rel in $SampleFiles) {
            $Full = Join-Path -Path $script:FakeRepo -ChildPath $Rel
            Set-Content -LiteralPath $Full -Value 'sample'
        }
        $MkDocs = @'
nav:
  - Home: index.md
  - Getting Started: getting-started.md
  - Command Reference:
    - Get-Greeting: PowershellRepoTemplate/Get-Greeting.md
'@
        $script:FakeMkDocs = Join-Path -Path $script:FakeRepo -ChildPath 'mkdocs.yml'
        Set-Content -LiteralPath $script:FakeMkDocs -Value $MkDocs
        $script:RepoRoot = $script:FakeRepo
    }

    AfterEach {
        $script:RepoRoot = $script:SavedRepoRoot
        Remove-Item -LiteralPath $script:FakeRepo -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'deletes the sample function, its test, and its docs page' {
        Invoke-RemoveSampleFunction -DryRun $false | Should -BeTrue
        $Deleted = @(
            'Source\Public\Get-Greeting.ps1'
            'Tests\Pester\Get-Greeting.Tests.ps1'
            'Docs\PowershellRepoTemplate\Get-Greeting.md'
        )
        foreach ($Rel in $Deleted) {
            $Full = Join-Path -Path $script:FakeRepo -ChildPath $Rel
            Test-Path -LiteralPath $Full | Should -BeFalse -Because "$Rel should be gone"
        }
    }

    It 'drops the whole Command Reference nav block, leaving the other nav entries' {
        Invoke-RemoveSampleFunction -DryRun $false | Should -BeTrue
        $Nav = Get-Content -LiteralPath $script:FakeMkDocs -Raw
        $Nav | Should -Not -Match 'Get-Greeting'
        # A childless nav parent breaks the mkdocs build, so it must go too.
        $Nav | Should -Not -Match 'Command Reference'
        $Nav | Should -Match 'Home: index\.md'
        $Nav | Should -Match 'Getting Started: getting-started\.md'
    }

    It 'writes nothing under -DryRun' {
        Invoke-RemoveSampleFunction -DryRun $true | Should -BeTrue
        $Kept = @(
            'Source\Public\Get-Greeting.ps1'
            'Tests\Pester\Get-Greeting.Tests.ps1'
            'Docs\PowershellRepoTemplate\Get-Greeting.md'
        )
        foreach ($Rel in $Kept) {
            $Full = Join-Path -Path $script:FakeRepo -ChildPath $Rel
            Test-Path -LiteralPath $Full | Should -BeTrue -Because "$Rel should still exist"
        }
        (Get-Content -LiteralPath $script:FakeMkDocs -Raw) | Should -Match 'Get-Greeting'
    }

    It 'is idempotent, and skips the nav edit when mkdocs.yml is absent' {
        Remove-Item -LiteralPath $script:FakeMkDocs -Force
        Invoke-RemoveSampleFunction -DryRun $false | Should -BeTrue
        { Invoke-RemoveSampleFunction -DryRun $false } | Should -Not -Throw
    }
}

Describe 'Script Generator feature removal' -Tag 'unit', 'functional' {
    BeforeEach {
        # Same scratch-tree redirection as Invoke-RemoveSampleFunction above: the
        # removal steps read $script:RepoRoot, which the SUT points at THIS repo.
        $script:SavedRepoRoot = $script:RepoRoot
        $TreeParams = @{
            Path      = $script:ScratchDir
            ChildPath = [System.IO.Path]::GetRandomFileName()
        }
        $script:FakeRepo = Join-Path @TreeParams
        $Dirs = @(
            'Build\Generators\Intune'
            'Source\Private\Lib'
            'Tests\Pester'
        )
        foreach ($Rel in $Dirs) {
            $Dir = Join-Path -Path $script:FakeRepo -ChildPath $Rel
            New-Item -ItemType Directory -Path $Dir -Force | Out-Null
        }
        $script:GeneratorFiles = @(
            'Build\Generators\ConvertTo-StandaloneScript.ps1'
            'Build\Generators\ConvertTo-ScriptVariant.ps1'
            'Build\Generators\ConvertTo-IntuneWinPackage.ps1'
            'Build\Generators\Intune\Install.ps1'
            'Build\Generators\Intune\Uninstall.ps1'
            'Build\Generators\Intune\Detect.ps1'
            'Build\Generators\Intune\Write-PackageLog.ps1'
            'Source\Private\Lib\Resolve-EnvParameter.ps1'
            'Tests\Pester\ConvertTo-StandaloneScript.Tests.ps1'
            'Tests\Pester\ConvertTo-ScriptVariant.Tests.ps1'
            'Tests\Pester\ConvertTo-IntuneWinPackage.Tests.ps1'
            'Tests\Pester\Resolve-EnvParameter.Tests.ps1'
        )
        foreach ($Rel in $script:GeneratorFiles) {
            $Full = Join-Path -Path $script:FakeRepo -ChildPath $Rel
            Set-Content -LiteralPath $Full -Value 'generator'
        }
        $script:RepoRoot = $script:FakeRepo
    }

    AfterEach {
        $script:RepoRoot = $script:SavedRepoRoot
        Remove-Item -LiteralPath $script:FakeRepo -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'removes the standalone-script generators, the resolver, and their tests' {
        Invoke-RemoveStandaloneScriptGenerator -DryRun $false | Should -BeTrue
        $Gone = @(
            'Build\Generators\ConvertTo-StandaloneScript.ps1'
            'Build\Generators\ConvertTo-ScriptVariant.ps1'
            'Source\Private\Lib\Resolve-EnvParameter.ps1'
            'Tests\Pester\ConvertTo-StandaloneScript.Tests.ps1'
            'Tests\Pester\ConvertTo-ScriptVariant.Tests.ps1'
            'Tests\Pester\Resolve-EnvParameter.Tests.ps1'
        )
        foreach ($Rel in $Gone) {
            $Full = Join-Path -Path $script:FakeRepo -ChildPath $Rel
            Test-Path -LiteralPath $Full | Should -BeFalse -Because "$Rel should be gone"
        }
    }

    It 'leaves the Intune generator alone when only the standalone one is declined' {
        Invoke-RemoveStandaloneScriptGenerator -DryRun $false | Should -BeTrue
        $Kept = @(
            'Build\Generators\ConvertTo-IntuneWinPackage.ps1'
            'Build\Generators\Intune\Install.ps1'
            'Tests\Pester\ConvertTo-IntuneWinPackage.Tests.ps1'
        )
        foreach ($Rel in $Kept) {
            $Full = Join-Path -Path $script:FakeRepo -ChildPath $Rel
            Test-Path -LiteralPath $Full | Should -BeTrue -Because "$Rel should remain"
        }
    }

    It 'removes the Intune generator, its whole template folder, and its test' {
        Invoke-RemoveIntunePackageGenerator -DryRun $false | Should -BeTrue
        $Gone = @(
            'Build\Generators\ConvertTo-IntuneWinPackage.ps1'
            'Build\Generators\Intune'
            'Tests\Pester\ConvertTo-IntuneWinPackage.Tests.ps1'
        )
        foreach ($Rel in $Gone) {
            $Full = Join-Path -Path $script:FakeRepo -ChildPath $Rel
            Test-Path -LiteralPath $Full | Should -BeFalse -Because "$Rel should be gone"
        }
        $Kept = Join-Path -Path $script:FakeRepo -ChildPath (
            'Build\Generators\ConvertTo-StandaloneScript.ps1')
        Test-Path -LiteralPath $Kept | Should -BeTrue
    }

    It 'writes nothing under -DryRun' {
        Invoke-RemoveStandaloneScriptGenerator -DryRun $true | Should -BeTrue
        Invoke-RemoveIntunePackageGenerator -DryRun $true | Should -BeTrue
        foreach ($Rel in $script:GeneratorFiles) {
            $Full = Join-Path -Path $script:FakeRepo -ChildPath $Rel
            Test-Path -LiteralPath $Full | Should -BeTrue -Because "$Rel should survive a dry run"
        }
    }

    It 'is idempotent when the files are already gone' {
        Invoke-RemoveStandaloneScriptGenerator -DryRun $false | Should -BeTrue
        Invoke-RemoveIntunePackageGenerator -DryRun $false | Should -BeTrue
        { Invoke-RemoveStandaloneScriptGenerator -DryRun $false } | Should -Not -Throw
        { Invoke-RemoveIntunePackageGenerator -DryRun $false } | Should -Not -Throw
    }
}

Describe 'Test-PristineTemplateClone' -Tag 'integration', 'functional' {
    It 'returns a boolean when run against this real repository' {
        # Read-only (`git rev-list`); $script:RepoRoot always resolves to this
        # real repo, so this only ever probes -- never mutates -- it.
        Test-PristineTemplateClone | Should -BeOfType [bool]
    }
}

Describe 'Setup-NewProject -DryRun' -Tag 'integration', 'functional' {
    It 'previews changes against the real repo without writing anything' {
        $ConfigParams = @{
            Path      = $script:ScratchDir
            ChildPath = "setup-$([guid]::NewGuid().ToString('N')).psd1"
        }
        $ConfigPath = Join-Path @ConfigParams
        $ConfigContent = @'
@{
    Project = @{ Name = 'DryRunPreviewOnly'; GitHubUser = '' }
    License = @{ Key = 'none'; Year = ''; Name = ''; Company = '' }
    Git = @{ Branch = 'main'; Reinit = $false }
    Features = @{
        Docs = $true
        SecurityMd = $true
        ContributingMd = $true
        ExplicitModuleImport = $true
        InstallDependenciesScript = $true
        StandaloneScriptGenerator = $true
        IntunePackageGenerator = $true
        WriteLog = $true
        NonASCIICharacters = $true
        FormatOperator = $true
        WriteVerboseDebug = $true
        BacktickContinuation = $true
        UnwantedStringsLocal = $false
    }
}
'@
        Set-Content -LiteralPath $ConfigPath -Value $ConfigContent

        $BeforeStatus = & git -C $script:RealRepoRoot status --porcelain

        $ArgList = @(
            '-NoProfile', '-NonInteractive', '-File', $script:Sut,
            '-ConfigPath', $ConfigPath, '-DryRun'
        )
        $Output = & pwsh @ArgList 2>&1
        $ExitCode = $LASTEXITCODE

        $AfterStatus = & git -C $script:RealRepoRoot status --porcelain

        $ExitCode | Should -Be 0
        ($Output | Out-String) | Should -Match 'dry run -- nothing changed'
        # The real safety check: -DryRun must never leave the repo dirty.
        ($AfterStatus | Out-String) | Should -Be ($BeforeStatus | Out-String)
    }

    It 'reports config problems and exits 1 without previewing anything' {
        $ConfigParams = @{
            Path      = $script:ScratchDir
            ChildPath = "setup-bad-$([guid]::NewGuid().ToString('N')).psd1"
        }
        $ConfigPath = Join-Path @ConfigParams
        Set-Content -LiteralPath $ConfigPath -Value '@{ Project = @{ Name = "" } }'

        $ArgList = @(
            '-NoProfile', '-NonInteractive', '-File', $script:Sut,
            '-ConfigPath', $ConfigPath, '-DryRun'
        )
        $Output = & pwsh @ArgList 2>&1
        $ExitCode = $LASTEXITCODE

        $ExitCode | Should -Be 1
        ($Output | Out-String) | Should -Match 'problem'
    }
}
