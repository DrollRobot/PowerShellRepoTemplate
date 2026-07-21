<#
.SYNOPSIS
    Pester tests for Scripts\Compare-Template.ps1.

.DESCRIPTION
    Dot-sources the script to load its helper functions -- the dot-source guard
    in the script skips the comparison itself -- and exercises the pure helpers
    plus the manifest (including which entries are blind-copy eligible) against
    the real repo. NotLive; no tag.

.NOTES
    The template identity tokens are assembled from string pieces so that a
    child's Setup-NewProject.ps1 run cannot rewrite them here, matching the
    script under test.
#>

BeforeAll {
    $sutRel = Join-Path -Path $PSScriptRoot -ChildPath '..\..\Scripts\Compare-Template.ps1'
    . (Resolve-Path -Path $sutRel).Path
    $script:RepoRoot = (Resolve-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath '..\..')).Path
    $script:TemplateToken = 'Powershell' + 'RepoTemplate'
    $script:FixmeToken = 'FIX' + 'ME'
}

Describe 'Convert-Eol' -Tag 'unit', 'functional' {
    It 'converts CRLF to LF' {
        Convert-Eol "a`r`nb" | Should -Be "a`nb"
    }
    It 'converts a lone CR to LF' {
        Convert-Eol "a`rb" | Should -Be "a`nb"
    }
    It 'leaves LF unchanged' {
        Convert-Eol "a`nb" | Should -Be "a`nb"
    }
}

Describe 'Get-ScriptVersion' -Tag 'unit', 'functional' {
    It 'extracts a declared version' {
        Get-ScriptVersion "`$ScriptVersion = '1.2.3'" | Should -Be '1.2.3'
    }
    It 'reads the real declaration, not a commented mention above it' {
        $text = "# a note about `$ScriptVersion`n`$ScriptVersion = '2.0.0'"
        Get-ScriptVersion $text | Should -Be '2.0.0'
    }
    It 'reads a bare hashtable-key version (no $), as in a .psd1' {
        Get-ScriptVersion "@{`n    ScriptVersion = '1.0.0'`n}" | Should -Be '1.0.0'
    }
    It 'returns null when there is no version' {
        Get-ScriptVersion 'nothing here' | Should -BeNullOrEmpty
    }
}

Describe 'Get-VersionAction' -Tag 'unit', 'functional' {
    It 'reports ok when the content is identical' {
        Get-VersionAction -TemplateVersion '1.0.0' -ChildVersion '1.0.0' -SameContent $true |
            Should -Be 'ok'
    }
    It 'reports update when the child is older' {
        Get-VersionAction -TemplateVersion '1.2.0' -ChildVersion '1.1.0' -SameContent $false |
            Should -Be 'update'
    }
    It 'reports ahead when the child is newer' {
        Get-VersionAction -TemplateVersion '1.0.0' -ChildVersion '2.0.0' -SameContent $false |
            Should -Be 'ahead'
    }
    It 'reports refresh when versions match but content differs' {
        Get-VersionAction -TemplateVersion '1.0.0' -ChildVersion '1.0.0' -SameContent $false |
            Should -Be 'refresh'
    }
    It 'reports update when a version is unparseable or missing' {
        Get-VersionAction -TemplateVersion '1.0.0' -ChildVersion $null -SameContent $false |
            Should -Be 'update'
    }
}

Describe 'Get-OwnerFromUrl' -Tag 'unit', 'functional' {
    It 'parses an HTTPS GitHub URL' {
        Get-OwnerFromUrl 'https://github.com/octocat/my-repo.git' | Should -Be 'octocat'
    }
    It 'parses an SSH GitHub URL' {
        Get-OwnerFromUrl 'git@github.com:octocat/my-repo.git' | Should -Be 'octocat'
    }
    It 'returns null for a non-GitHub remote' {
        Get-OwnerFromUrl 'https://gitlab.com/octocat/my-repo.git' | Should -BeNullOrEmpty
    }
}

Describe 'Remove-TemplateBanner' -Tag 'unit', 'functional' {
    It 'strips a markdown banner block' {
        $text = "<!--`n======`nTEMPLATE SETUP NOTES`ndelete me`n-->`n# real content`n"
        Remove-TemplateBanner $text | Should -Be "# real content`n"
    }
    It 'strips a hash banner block' {
        $text = "# ======`n# TEMPLATE SETUP NOTES`n# delete me`n# ======`nreal: content`n"
        Remove-TemplateBanner $text | Should -Be "real: content`n"
    }
    It 'leaves text without a banner unchanged' {
        Remove-TemplateBanner "no banner here`n" | Should -Be "no banner here`n"
    }
}

Describe 'Convert-TemplateToken' -Tag 'unit', 'functional' {
    BeforeEach {
        $script:ChildName = 'MyModule'
        $script:ChildOwner = 'octocat'
    }
    It 'substitutes the template name (case-insensitive)' {
        Convert-TemplateToken $script:TemplateToken | Should -Be 'MyModule'
    }
    It 'substitutes the owner/repo placeholder' {
        Convert-TemplateToken "$script:FixmeToken/$script:FixmeToken" |
            Should -Be 'octocat/MyModule'
    }
    It 'substitutes the pages placeholder' {
        Convert-TemplateToken "$script:FixmeToken.github.io/$script:FixmeToken" |
            Should -Be 'octocat.github.io/MyModule'
    }
    It 'leaves owner placeholders when no owner is known' {
        $script:ChildOwner = $null
        Convert-TemplateToken "$script:FixmeToken/$script:FixmeToken" |
            Should -Be "$script:FixmeToken/$script:FixmeToken"
    }
}

Describe 'ConvertTo-NormalizedTemplate' -Tag 'unit', 'functional' {
    BeforeEach {
        $script:ChildName = 'MyModule'
        $script:ChildOwner = 'octocat'
    }
    It 'strips the banner, normalizes EOL, and substitutes the name' {
        $body = "<!--`r`n===`r`nTEMPLATE SETUP NOTES`r`nx`r`n-->`r`nname: $script:TemplateToken`r`n"
        ConvertTo-NormalizedTemplate $body | Should -Be "name: MyModule`n"
    }
}

Describe 'ConvertTo-NormalizedChild' -Tag 'unit', 'functional' {
    It 'strips the banner and normalizes EOL without touching the name' {
        $body = "# ===`r`n# TEMPLATE SETUP NOTES`r`n# x`r`n# ===`r`nkeep: MyModule`r`n"
        ConvertTo-NormalizedChild $body | Should -Be "keep: MyModule`n"
    }
}

Describe 'New-Entry' -Tag 'unit', 'functional' {
    It 'defaults to required, strict, content-compared, not blind-copy, ungated' {
        $entry = New-Entry 'x'
        $entry.Required | Should -BeTrue
        $entry.Strict | Should -BeTrue
        $entry.ExistenceOnly | Should -BeFalse
        $entry.VersionOnly | Should -BeFalse
        $entry.BlindCopy | Should -BeFalse
        $entry.Gate | Should -BeNullOrEmpty
        $entry.LocalOverrideFlag | Should -BeNullOrEmpty
        $entry.LocalOverridePath | Should -BeNullOrEmpty
    }
    It 'defaults ChildPath to the same value as Path' {
        $entry = New-Entry 'some/file.ps1'
        $entry.ChildPath | Should -Be 'some/file.ps1'
    }
    It 'honors overrides' {
        $params = @{
            Required          = $false
            Strict            = $false
            ExistenceOnly     = $true
            VersionOnly       = $true
            BlindCopy         = $true
            Gate              = 'SomeFeature'
            LocalOverrideFlag = 'SomeFlag'
            LocalOverridePath = 'elsewhere/x'
        }
        $entry = New-Entry 'x' @params
        $entry.Required | Should -BeFalse
        $entry.Strict | Should -BeFalse
        $entry.ExistenceOnly | Should -BeTrue
        $entry.VersionOnly | Should -BeTrue
        $entry.BlindCopy | Should -BeTrue
        $entry.Gate | Should -Be 'SomeFeature'
        $entry.LocalOverrideFlag | Should -Be 'SomeFlag'
        $entry.LocalOverridePath | Should -Be 'elsewhere/x'
    }
}

Describe 'Manifest' -Tag 'unit', 'functional', 'acceptance' {
    It 'does not track the child-owned build/test files' {
        $paths = $script:Manifest.Path
        $paths | Should -Not -Contain 'Build/PreBuild.ps1'
        $paths | Should -Not -Contain 'Build/PostBuild.ps1'
        $paths | Should -Not -Contain 'Tests/PreTests.ps1'
        $paths | Should -Not -Contain 'Tests/PostTests.ps1'
        $paths | Should -Not -Contain 'Tests.ps1'
        $paths | Should -Not -Contain 'Tests/Pester/Compare-Template.Tests.ps1'
    }
    It 'tracks the CI workflow as a strict required entry' {
        $entry = $script:Manifest | Where-Object Path -EQ '.github/workflows/ci.yml'
        $entry | Should -Not -BeNullOrEmpty
        $entry.Required | Should -BeTrue
        $entry.Strict | Should -BeTrue
    }
    It 'tracks the curated whitelist as blind-copy eligible' {
        $whitelist = @(
            'Docs.ps1'
            'Scripts/Compare-Template.ps1'
            'Scripts/Complete-WorkTree.ps1'
            'Scripts/New-Worktree.ps1'
            'Scripts/Push-NewTagToMain.ps1'
            'Scripts/Remove-WorkTree.ps1'
            'Source/ScriptsToProcess/Confirm-Dependencies.ps1'
        )
        foreach ($path in $whitelist) {
            $entry = $script:Manifest | Where-Object Path -EQ $path
            $entry | Should -Not -BeNullOrEmpty -Because "$path should be tracked"
            $entry.BlindCopy | Should -BeTrue -Because "$path should be blind-copy eligible"
        }
    }
    It 'keeps other versioned dev scripts diff-only, never blind-copied' {
        $diffOnly = @(
            'Build.ps1'
            'Scripts/Setup-NewProject.ps1'
            'Scripts/Find-ScriptCommand.ps1'
            'Scripts/Resolve-CommandModule.ps1'
            'Source/ScriptsToProcess/Install-Dependencies.ps1'
            'Tests/Test-LineLength.ps1'
            'Tests/Test-PSSA.ps1'
            'Tests/Test-FixmeComments.ps1'
            'Tests/Test-FindUnwantedStrings.ps1'
            'Tests/Test-WriteVerboseDebug.ps1'
            'Tests/Test-NonASCIICharacters.ps1'
            'Tests/Test-JoinPath.ps1'
            'Tests/Test-FormatOperator.ps1'
            'Tests/Test-BacktickContinuation.ps1'
            'Tests/Test-ModuleSyntax.ps1'
            'Tests/Test-ExplicitModuleImport.ps1'
        )
        foreach ($path in $diffOnly) {
            $entry = $script:Manifest | Where-Object Path -EQ $path
            $entry | Should -Not -BeNullOrEmpty -Because "$path should be tracked"
            $entry.BlindCopy | Should -BeFalse -Because "$path should not be blind-copy eligible"
        }
    }
    It 'treats the two known hand-edit points leniently' {
        $installDeps = $script:Manifest |
            Where-Object Path -EQ 'Source/ScriptsToProcess/Install-Dependencies.ps1'
        $installDeps.Strict | Should -BeFalse
        $unwantedStrings = $script:Manifest |
            Where-Object Path -EQ 'Tests/Test-FindUnwantedStrings.ps1'
        $unwantedStrings.Strict | Should -BeFalse
    }
    It 'tracks the setup config file as version-only, never blind-copied' {
        $entry = $script:Manifest | Where-Object Path -EQ 'Scripts/setup.psd1'
        $entry | Should -Not -BeNullOrEmpty
        $entry.VersionOnly | Should -BeTrue
        $entry.ExistenceOnly | Should -BeFalse
        $entry.BlindCopy | Should -BeFalse
    }
    It 'gates every docs-feature file on Docs' {
        $docsFiles = @(
            '.github/workflows/docs.yml'
            'mkdocs.yml'
            'Docs.ps1'
        )
        foreach ($path in $docsFiles) {
            $entry = $script:Manifest | Where-Object Path -EQ $path
            $entry.Gate | Should -Be 'Docs' -Because "$path should be gated on Docs"
        }
    }
    It 'gates the explicit-module-import trio on ExplicitModuleImport' {
        $trio = @(
            'Scripts/Find-ScriptCommand.ps1'
            'Scripts/Resolve-CommandModule.ps1'
            'Tests/Test-ExplicitModuleImport.ps1'
        )
        foreach ($path in $trio) {
            $entry = $script:Manifest | Where-Object Path -EQ $path
            $entry.Gate | Should -Be 'ExplicitModuleImport' -Because "$path should be gated"
        }
    }
    It 'gates the dependency-check pair on Dependencies' {
        $pair = @(
            'Source/ScriptsToProcess/Confirm-Dependencies.ps1'
            'Source/ScriptsToProcess/Install-Dependencies.ps1'
        )
        foreach ($path in $pair) {
            $entry = $script:Manifest | Where-Object Path -EQ $path
            $entry.Gate | Should -Be 'Dependencies' -Because "$path should be gated"
        }
    }
    It 'gates each opinionated formatting check on its own feature' {
        $gateMap = @{
            'Tests/Test-NonASCIICharacters.ps1'   = 'NonASCIICharacters'
            'Tests/Test-FormatOperator.ps1'       = 'FormatOperator'
            'Tests/Test-WriteVerboseDebug.ps1'    = 'WriteVerboseDebug'
            'Tests/Test-BacktickContinuation.ps1' = 'BacktickContinuation'
        }
        foreach ($path in $gateMap.Keys) {
            $entry = $script:Manifest | Where-Object Path -EQ $path
            $entry.Gate | Should -Be $gateMap[$path]
        }
    }
    It 'gates SECURITY.md and CONTRIBUTING.md independently' {
        $security = $script:Manifest | Where-Object Path -EQ 'SECURITY.md'
        $security.Gate | Should -Be 'SecurityMd'
        $contributing = $script:Manifest | Where-Object Path -EQ 'CONTRIBUTING.md'
        $contributing.Gate | Should -Be 'ContributingMd'
    }
    It 'points the unwanted-strings entry at a local override, not a gate' {
        $entry = $script:Manifest | Where-Object Path -EQ 'Tests/Test-FindUnwantedStrings.ps1'
        $entry.Gate | Should -BeNullOrEmpty
        $entry.LocalOverrideFlag | Should -Be 'UnwantedStringsLocal'
        $entry.LocalOverridePath | Should -Be '.local/tests/Test-FindUnwantedStrings.ps1'
    }
}

Describe 'Get-ChildFeatureFlag' -Tag 'integration', 'functional' {
    BeforeAll {
        $ScratchParams = @{
            Path      = [System.IO.Path]::GetTempPath()
            ChildPath = [System.IO.Path]::GetRandomFileName()
        }
        $script:FlagScratchDir = Join-Path @ScratchParams
        $ScratchScriptsDir = Join-Path -Path $script:FlagScratchDir -ChildPath 'Scripts'
        New-Item -ItemType Directory -Path $ScratchScriptsDir -Force | Out-Null
    }
    AfterAll {
        $RemoveParams = @{
            LiteralPath = $script:FlagScratchDir
            Recurse     = $true
            Force       = $true
            ErrorAction = 'SilentlyContinue'
        }
        Remove-Item @RemoveParams
    }

    It 'defaults every feature to true, and UnwantedStringsLocal to false, when no config exists' {
        $flags = Get-ChildFeatureFlag -ChildRoot $script:FlagScratchDir
        $flags['Docs'] | Should -BeTrue
        $flags['SecurityMd'] | Should -BeTrue
        $flags['Dependencies'] | Should -BeTrue
        $flags['UnwantedStringsLocal'] | Should -BeFalse
    }
    It 'reads a real [Features] table and leaves unmentioned keys at their default' {
        $configPath = Join-Path -Path $script:FlagScratchDir -ChildPath 'Scripts\setup.psd1'
        Set-Content -LiteralPath $configPath -Value @'
@{
    Features = @{
        Docs = $false
        UnwantedStringsLocal = $true
    }
}
'@
        $flags = Get-ChildFeatureFlag -ChildRoot $script:FlagScratchDir
        $flags['Docs'] | Should -BeFalse
        $flags['UnwantedStringsLocal'] | Should -BeTrue
        $flags['SecurityMd'] | Should -BeTrue
        Remove-Item -LiteralPath $configPath -Force
    }
    It 'falls back to defaults when the config file is not valid PowerShell data' {
        $configPath = Join-Path -Path $script:FlagScratchDir -ChildPath 'Scripts\setup.psd1'
        Set-Content -LiteralPath $configPath -Value 'not valid { data'
        $flags = Get-ChildFeatureFlag -ChildRoot $script:FlagScratchDir
        $flags['Docs'] | Should -BeTrue
        Remove-Item -LiteralPath $configPath -Force
    }
}

Describe 'Get-ApplicableManifest' -Tag 'unit', 'functional', 'acceptance' {
    BeforeAll {
        $script:OriginalManifest = $script:Manifest
        $LocalParams = @{
            LocalOverrideFlag = 'UnwantedStringsLocal'
            LocalOverridePath = '.local/moved.txt'
        }
        $script:Manifest = @(
            (New-Entry 'always/here.txt')
            (New-Entry 'gated/on/docs.txt' -Gate 'Docs')
            (New-Entry 'tracked/moves.txt' @LocalParams)
            (New-Entry '.pre-commit-config.yaml')
        )
        # All-kept baseline; individual tests override just the flag(s) under test.
        function script:New-TestFlag {
            param([hashtable]$Overrides = @{})
            $base = @{
                Docs                 = $true
                UnwantedStringsLocal = $false
                NonASCIICharacters   = $true
                FormatOperator       = $true
                WriteVerboseDebug    = $true
                BacktickContinuation = $true
            }
            foreach ($key in $Overrides.Keys) { $base[$key] = $Overrides[$key] }
            return $base
        }
    }
    AfterAll {
        $script:Manifest = $script:OriginalManifest
        Remove-Item -Path function:script:New-TestFlag -ErrorAction SilentlyContinue
    }

    It 'keeps ungated entries regardless of flags' {
        $flags = New-TestFlag -Overrides @{ Docs = $false }
        $result = Get-ApplicableManifest -Flags $flags
        $result.Applicable.Path | Should -Contain 'always/here.txt'
    }
    It 'drops a gated entry when its flag is false' {
        $flags = New-TestFlag -Overrides @{ Docs = $false }
        $result = Get-ApplicableManifest -Flags $flags
        $result.Applicable.Path | Should -Not -Contain 'gated/on/docs.txt'
        $result.Skipped.Path | Should -Contain 'gated/on/docs.txt'
    }
    It 'keeps a gated entry when its flag is true' {
        $flags = New-TestFlag
        $result = Get-ApplicableManifest -Flags $flags
        $result.Applicable.Path | Should -Contain 'gated/on/docs.txt'
        $result.Skipped.Count | Should -Be 0
    }
    It 'remaps ChildPath, but never Path, when the local-override flag is true' {
        $flags = New-TestFlag -Overrides @{ UnwantedStringsLocal = $true }
        $result = Get-ApplicableManifest -Flags $flags
        $moved = $result.Applicable | Where-Object LocalOverrideFlag -EQ 'UnwantedStringsLocal'
        $moved.ChildPath | Should -Be '.local/moved.txt'
        $moved.Path | Should -Be 'tracked/moves.txt' -Because 'the template copy never moves'
    }
    It 'leaves ChildPath unchanged when the local-override flag is false' {
        $flags = New-TestFlag
        $result = Get-ApplicableManifest -Flags $flags
        $unmoved = $result.Applicable | Where-Object LocalOverrideFlag -EQ 'UnwantedStringsLocal'
        $unmoved.ChildPath | Should -Be 'tracked/moves.txt'
        $unmoved.Path | Should -Be 'tracked/moves.txt'
    }
    It 'does not mutate $script:Manifest' {
        $flags = New-TestFlag -Overrides @{ UnwantedStringsLocal = $true }
        $null = Get-ApplicableManifest -Flags $flags
        $original = $script:Manifest | Where-Object LocalOverrideFlag -EQ 'UnwantedStringsLocal'
        $original.Path | Should -Be 'tracked/moves.txt'
        $original.ChildPath | Should -Be 'tracked/moves.txt'
    }
    It 'keeps .pre-commit-config.yaml strict when every formatting check is kept' {
        $flags = New-TestFlag
        $result = Get-ApplicableManifest -Flags $flags
        $preCommit = $result.Applicable | Where-Object Path -EQ '.pre-commit-config.yaml'
        $preCommit.Strict | Should -BeTrue
    }
    It 'downgrades .pre-commit-config.yaml to lenient when any one formatting check is declined' {
        foreach ($gate in $script:PreCommitFormattingGates) {
            $flags = New-TestFlag -Overrides @{ $gate = $false }
            $result = Get-ApplicableManifest -Flags $flags
            $preCommit = $result.Applicable | Where-Object Path -EQ '.pre-commit-config.yaml'
            $preCommit.Strict | Should -BeFalse -Because "$gate = false should downgrade it"
        }
    }
    It 'does not downgrade .pre-commit-config.yaml''s Strict in $script:Manifest itself' {
        $flags = New-TestFlag -Overrides @{ NonASCIICharacters = $false }
        $null = Get-ApplicableManifest -Flags $flags
        $original = $script:Manifest | Where-Object Path -EQ '.pre-commit-config.yaml'
        $original.Strict | Should -BeTrue
    }
}

Describe 'Get-VersionNote' -Tag 'unit', 'functional' {
    It 'returns empty when either side has no version' {
        Get-VersionNote -TemplateText "`$ScriptVersion = '1.0.0'" -ChildText 'nothing here' |
            Should -BeNullOrEmpty
    }
    It 'flags an outdated child' {
        $params = @{
            TemplateText = "`$ScriptVersion = '1.2.0'"
            ChildText    = "`$ScriptVersion = '1.1.0'"
        }
        Get-VersionNote @params | Should -Match 'outdated'
    }
    It 'flags a child ahead of the template' {
        $params = @{
            TemplateText = "`$ScriptVersion = '1.0.0'"
            ChildText    = "`$ScriptVersion = '2.0.0'"
        }
        Get-VersionNote @params | Should -Match 'ahead'
    }
    It 'flags matching versions with different content' {
        $params = @{
            TemplateText = "`$ScriptVersion = '1.0.0'"
            ChildText    = "`$ScriptVersion = '1.0.0'"
        }
        Get-VersionNote @params | Should -Match 'without a version bump'
    }
}
