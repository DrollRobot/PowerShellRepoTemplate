<#
.SYNOPSIS
    Pester tests for Scripts\Compare-Template.ps1.

.DESCRIPTION
    Dot-sources the script to load its helper functions -- the dot-source guard
    in the script skips the comparison itself -- and exercises the pure helpers
    plus the versioned-file discovery against the real repo. Offline; no tag.

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

Describe 'Convert-Eol' {
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

Describe 'Get-ScriptVersion' {
    It 'extracts a declared version' {
        Get-ScriptVersion "`$ScriptVersion = '1.2.3'" | Should -Be '1.2.3'
    }
    It 'reads the real declaration, not a commented mention above it' {
        $text = "# a note about `$ScriptVersion`n`$ScriptVersion = '2.0.0'"
        Get-ScriptVersion $text | Should -Be '2.0.0'
    }
    It 'returns null when there is no version' {
        Get-ScriptVersion 'nothing here' | Should -BeNullOrEmpty
    }
}

Describe 'Get-VersionAction' {
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

Describe 'Get-OwnerFromUrl' {
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

Describe 'Remove-TemplateBanner' {
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

Describe 'Convert-TemplateToken' {
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

Describe 'ConvertTo-NormalizedTemplate' {
    BeforeEach {
        $script:ChildName = 'MyModule'
        $script:ChildOwner = 'octocat'
    }
    It 'strips the banner, normalizes EOL, and substitutes the name' {
        $body = "<!--`r`n===`r`nTEMPLATE SETUP NOTES`r`nx`r`n-->`r`nname: $script:TemplateToken`r`n"
        ConvertTo-NormalizedTemplate $body | Should -Be "name: MyModule`n"
    }
}

Describe 'ConvertTo-NormalizedChild' {
    It 'strips the banner and normalizes EOL without touching the name' {
        $body = "# ===`r`n# TEMPLATE SETUP NOTES`r`n# x`r`n# ===`r`nkeep: MyModule`r`n"
        ConvertTo-NormalizedChild $body | Should -Be "keep: MyModule`n"
    }
}

Describe 'Test-OptionalVersioned' {
    It 'treats Setup-NewProject as optional' {
        Test-OptionalVersioned 'Scripts/Setup-NewProject.ps1' | Should -BeTrue
    }
    It 'treats debug helpers as optional' {
        Test-OptionalVersioned 'Scripts/Debug/Find-ModuleRoot.ps1' | Should -BeTrue
    }
    It 'treats a normal helper as required' {
        Test-OptionalVersioned 'Scripts/New-Worktree.ps1' | Should -BeFalse
    }
}

Describe 'Test-VersionedExcluded' {
    BeforeAll { $script:SavedExclude = $script:VersionedExclude }
    AfterEach { $script:VersionedExclude = $script:SavedExclude }
    It 'excludes nothing when the list is empty' {
        $script:VersionedExclude = @()
        Test-VersionedExcluded 'Scripts/Compare-Template.ps1' | Should -BeFalse
    }
    It 'matches an exact path' {
        $script:VersionedExclude = @('Tests/Test-LineLength.ps1')
        Test-VersionedExcluded 'Tests/Test-LineLength.ps1' | Should -BeTrue
    }
    It 'matches a glob pattern' {
        $script:VersionedExclude = @('Scripts/Debug/*')
        Test-VersionedExcluded 'Scripts/Debug/Find-ModuleRoot.ps1' | Should -BeTrue
    }
    It 'leaves non-matching paths included' {
        $script:VersionedExclude = @('Tests/Test-LineLength.ps1')
        Test-VersionedExcluded 'Scripts/New-Worktree.ps1' | Should -BeFalse
    }
}

Describe 'VersionedExclude default' {
    It 'keeps the Tests.ps1 orchestrator out of the copy workflow' {
        $script:VersionedExclude | Should -Contain 'Tests.ps1'
    }
}

Describe 'New-Entry' {
    It 'defaults to required, strict, content-compared' {
        $entry = New-Entry 'x'
        $entry.Required | Should -BeTrue
        $entry.Strict | Should -BeTrue
        $entry.ExistenceOnly | Should -BeFalse
    }
    It 'honors overrides' {
        $entry = New-Entry 'x' -Required $false -Strict $false -ExistenceOnly $true
        $entry.Required | Should -BeFalse
        $entry.Strict | Should -BeFalse
        $entry.ExistenceOnly | Should -BeTrue
    }
}

Describe 'Manifest' {
    It 'does not track the build/test hook stubs (the child owns them)' {
        $paths = $script:Manifest.Path
        $paths | Should -Not -Contain 'Build/PreBuild.ps1'
        $paths | Should -Not -Contain 'Build/PostBuild.ps1'
        $paths | Should -Not -Contain 'Tests/PreTests.ps1'
        $paths | Should -Not -Contain 'Tests/PostTests.ps1'
    }
    It 'tracks the CI workflow as a strict required entry' {
        $entry = $script:Manifest | Where-Object Path -EQ '.github/workflows/ci.yml'
        $entry | Should -Not -BeNullOrEmpty
        $entry.Required | Should -BeTrue
        $entry.Strict | Should -BeTrue
    }
}

Describe 'Get-VersionedRelPath' {
    BeforeAll {
        # Discover against an empty exclude list so these cases stay independent of
        # whatever the shipped $script:VersionedExclude default happens to be.
        $script:SavedDiscoverExclude = $script:VersionedExclude
        $script:VersionedExclude = @()
        $script:Discovered = @(Get-VersionedRelPath -TemplateRoot $script:RepoRoot)
    }
    AfterAll {
        $script:VersionedExclude = $script:SavedDiscoverExclude
    }
    It 'includes the top-level dev scripts' {
        $script:Discovered | Should -Contain 'Build.ps1'
        $script:Discovered | Should -Contain 'Tests.ps1'
    }
    It 'includes the Scripts helpers' {
        $script:Discovered | Should -Contain 'Scripts/New-Worktree.ps1'
        $script:Discovered | Should -Contain 'Scripts/Compare-Template.ps1'
    }
    It 'excludes the build/test hook stubs' {
        $script:Discovered | Should -Not -Contain 'Build/PreBuild.ps1'
        $script:Discovered | Should -Not -Contain 'Build/PostBuild.ps1'
        $script:Discovered | Should -Not -Contain 'Tests/PreTests.ps1'
        $script:Discovered | Should -Not -Contain 'Tests/PostTests.ps1'
    }
    It 'drops files matching the versioned-exclude list' {
        $saved = $script:VersionedExclude
        try {
            $script:VersionedExclude = @('Tests/Test-*.ps1')
            $filtered = @(Get-VersionedRelPath -TemplateRoot $script:RepoRoot)
            $filtered | Should -Not -Contain 'Tests/Test-PSSA.ps1'
            $filtered | Should -Contain 'Scripts/Compare-Template.ps1'
        }
        finally {
            $script:VersionedExclude = $saved
        }
    }
}
