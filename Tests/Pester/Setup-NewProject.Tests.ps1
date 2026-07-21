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
                Docs                 = $true
                SecurityMd           = $true
                ContributingMd       = $true
                ExplicitModuleImport = $true
                Dependencies         = $true
                NonASCIICharacters   = $true
                FormatOperator       = $true
                WriteVerboseDebug    = $true
                BacktickContinuation = $true
                UnwantedStringsLocal = $false
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
        Dependencies = $true
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
