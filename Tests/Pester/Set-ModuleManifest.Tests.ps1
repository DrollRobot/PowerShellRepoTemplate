<#
.SYNOPSIS
    Pester tests for Scripts\TemplateSetup\Set-ModuleManifest.ps1.

.DESCRIPTION
    Set-ModuleManifest takes an explicit -RepoRoot, so -- unlike the
    orchestrator -- its apply path is safe to exercise for real against a
    throwaway scratch tree. The script guards its parameter-driven body with
    `if ($MyInvocation.InvocationName -eq '.') { return }`, so dot-sourcing it
    reaches the Set-ModuleManifest function (and the shared helpers it
    dot-sources) without running the standalone entrypoint. The function reports
    progress via Write-Host; Pester does not capture stream 6, so every call
    redirects it to keep the run output clean.

    The scratch manifest mirrors the template's own: the identity keys with
    their placeholder values, the note comments parked above the GUID, and
    neighbouring keys that must survive untouched.
#>

BeforeAll {
    $SutParams = @{
        Path      = $PSScriptRoot
        ChildPath = '..\..\Scripts\TemplateSetup\Set-ModuleManifest.ps1'
    }
    $script:Sut = (Resolve-Path (Join-Path @SutParams)).Path
    . $script:Sut

    $script:PlaceholderGuid = '32e4ddb2-5950-422b-b94b-4cee5c99862c'
    $script:KnownGuid = '3f2504e0-4f89-11d3-9a0c-0305e82c3301'
}

Describe 'Set-ModuleManifest' -Tag 'unit', 'functional' {
    BeforeEach {
        $ScratchParams = @{
            Path      = [System.IO.Path]::GetTempPath()
            ChildPath = "setmanifest-$([guid]::NewGuid().ToString('N'))"
        }
        $script:Scratch = Join-Path @ScratchParams
        $script:SourceDir = Join-Path -Path $script:Scratch -ChildPath 'Source'
        New-Item -ItemType Directory -Path $script:SourceDir -Force | Out-Null

        $script:ManifestPath = Join-Path -Path $script:SourceDir -ChildPath 'MyModule.psd1'
        $Manifest = @(
            '@{'
            "    RootModule        = 'MyModule.psm1'"
            "    ModuleVersion     = '1.2.0'"
            ''
            '    # ID used to uniquely identify this module'
            '    # FIXME: generate a fresh GUID with New-Guid for your module.'
            '    # Note: an all-zeros placeholder breaks ModuleBuilder, which treats'
            '    # [Guid]::Empty as "manifest could not be parsed".'
            "    GUID              = '$script:PlaceholderGuid'"
            ''
            '    # Author of this module'
            "    Author            = 'FIXME'"
            ''
            '    # Company or vendor of this module'
            "    CompanyName       = 'Unknown'"
            ''
            '    # Copyright statement for this module'
            "    Copyright         = '(c) FIXME. All rights reserved.'"
            '}'
        ) -join "`r`n"
        Set-Content -LiteralPath $script:ManifestPath -Value $Manifest -NoNewline

        # ModuleBuilder's build config lives next to the manifest and is never a
        # target, so discovery must not treat it as a second candidate.
        $script:BuildConfigPath = Join-Path -Path $script:SourceDir -ChildPath 'Build.psd1'
        Set-Content -LiteralPath $script:BuildConfigPath -Value '@{ }' -NoNewline

        $script:FullParams = @{
            RepoRoot    = $script:Scratch
            Author      = 'Jane Doe'
            CompanyName = 'Acme Inc'
            Year        = '2026'
            DryRun      = $false
        }
    }

    AfterEach {
        Remove-Item -LiteralPath $script:Scratch -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'stamps a fresh GUID into the manifest it discovers under Source\' {
        $Params = @{ RepoRoot = $script:Scratch; DryRun = $false }
        $Applied = Set-ModuleManifest @Params 6>$null
        $Applied | Should -BeTrue

        $Result = Get-Content -LiteralPath $script:ManifestPath -Raw
        $Result | Should -Not -Match $script:PlaceholderGuid
        $Match = [regex]::Match($Result, "GUID\s*=\s*'([0-9a-fA-F-]+)'")
        $Match.Success | Should -BeTrue
        $Parsed = [guid]::Empty
        [guid]::TryParse($Match.Groups[1].Value, [ref]$Parsed) | Should -BeTrue
        $Parsed | Should -Not -Be ([guid]::Empty)
    }

    It 'writes the GUID passed to -Guid instead of minting one' {
        $Params = @{ RepoRoot = $script:Scratch; Guid = $script:KnownGuid; DryRun = $false }
        $Applied = Set-ModuleManifest @Params 6>$null
        $Applied | Should -BeTrue

        $Result = Get-Content -LiteralPath $script:ManifestPath -Raw
        $Result | Should -Match "GUID\s*=\s*'$script:KnownGuid'"
    }

    It 'fills in Author, CompanyName, and a composed Copyright' {
        $Applied = Set-ModuleManifest @script:FullParams 6>$null
        $Applied | Should -BeTrue

        $Result = Get-Content -LiteralPath $script:ManifestPath -Raw
        $Result | Should -Match "Author            = 'Jane Doe'"
        $Result | Should -Match "CompanyName       = 'Acme Inc'"
        $Expected = "Copyright         = '\(c\) 2026 Jane Doe\. All rights reserved\.'"
        $Result | Should -Match $Expected
        $Result | Should -Not -Match 'FIXME'
    }

    It 'composes the Copyright from the author alone when no year is given' {
        $Params = @{ RepoRoot = $script:Scratch; Author = 'Jane Doe'; DryRun = $false }
        $Applied = Set-ModuleManifest @Params 6>$null
        $Applied | Should -BeTrue

        $Result = Get-Content -LiteralPath $script:ManifestPath -Raw
        $Result | Should -Match "Copyright         = '\(c\) Jane Doe\. All rights reserved\.'"
    }

    It 'leaves the placeholders alone for the values it was not given' {
        # What a 'gnu' or 'none' license choice looks like: no holder name, so
        # Author and Copyright stay in the FIXME report for a human to finish.
        $Params = @{ RepoRoot = $script:Scratch; DryRun = $false }
        $Applied = Set-ModuleManifest @Params 6>$null
        $Applied | Should -BeTrue

        $Result = Get-Content -LiteralPath $script:ManifestPath -Raw
        $Result | Should -Match "Author            = 'FIXME'"
        $Result | Should -Match "CompanyName       = 'Unknown'"
        $Result | Should -Match "Copyright         = '\(c\) FIXME\. All rights reserved\.'"
    }

    It 'doubles a single quote inside a value so the manifest still parses' {
        $Params = @{
            RepoRoot = $script:Scratch
            Author   = "Sean O'Brien"
            Year     = '2026'
            DryRun   = $false
        }
        $Applied = Set-ModuleManifest @Params 6>$null
        $Applied | Should -BeTrue

        $Data = Import-PowerShellDataFile -LiteralPath $script:ManifestPath
        $Data.Author | Should -BeExactly "Sean O'Brien"
        $Data.Copyright | Should -BeExactly "(c) 2026 Sean O'Brien. All rights reserved."
    }

    It 'leaves a manifest that still parses, with the GUID it wrote' {
        $Applied = Set-ModuleManifest @script:FullParams 6>$null
        $Applied | Should -BeTrue

        $Data = Import-PowerShellDataFile -LiteralPath $script:ManifestPath
        $Data.GUID | Should -Not -BeExactly $script:PlaceholderGuid
        $Data.CompanyName | Should -BeExactly 'Acme Inc'
        $Data.RootModule | Should -BeExactly 'MyModule.psm1'
    }

    It 'keeps the key alignment, the other keys, and the CRLF line endings' {
        $Params = @{ RepoRoot = $script:Scratch; Guid = $script:KnownGuid; DryRun = $false }
        $Applied = Set-ModuleManifest @Params 6>$null
        $Applied | Should -BeTrue

        $Result = Get-Content -LiteralPath $script:ManifestPath -Raw
        $Result | Should -Match "GUID              = '$script:KnownGuid'"
        $Result | Should -Match "RootModule        = 'MyModule.psm1'"
        $Result | Should -Match "ModuleVersion     = '1.2.0'"
        $Result | Should -Match "`r`n"
        $Result | Should -Not -Match "[^`r]`n"
    }

    It 'drops the placeholder note comments but keeps the key description' {
        $Applied = Set-ModuleManifest @script:FullParams 6>$null
        $Applied | Should -BeTrue

        $Result = Get-Content -LiteralPath $script:ManifestPath -Raw
        $Result | Should -Not -Match 'generate a fresh GUID'
        $Result | Should -Not -Match 'all-zeros placeholder'
        $Result | Should -Not -Match ([regex]::Escape('[Guid]::Empty'))
        $Result | Should -Match '# ID used to uniquely identify this module'
        $Result | Should -Match '# Author of this module'
    }

    It 'writes nothing under -DryRun' {
        $Before = Get-Content -LiteralPath $script:ManifestPath -Raw
        $Params = $script:FullParams.Clone()
        $Params.DryRun = $true
        $Applied = Set-ModuleManifest @Params 6>$null
        $Applied | Should -BeTrue

        $After = Get-Content -LiteralPath $script:ManifestPath -Raw
        $After | Should -BeExactly $Before
    }

    It 'fills in the manifest named by -ManifestPath instead of discovering one' {
        $OtherPath = Join-Path -Path $script:Scratch -ChildPath 'Other.psd1'
        $Other = @(
            '@{'
            "    GUID   = '$script:PlaceholderGuid'"
            "    Author = 'FIXME'"
            '}'
        ) -join "`r`n"
        Set-Content -LiteralPath $OtherPath -Value $Other -NoNewline

        $Params = $script:FullParams.Clone()
        $Params.ManifestPath = $OtherPath
        $Params.Guid = $script:KnownGuid
        $Params.CompanyName = ''
        $Applied = Set-ModuleManifest @Params 6>$null
        $Applied | Should -BeFalse

        # The named manifest carries no CompanyName or Copyright key, so those
        # are reported missing -- but Author and the GUID are still written, and
        # the discovered manifest is never touched.
        (Get-Content -LiteralPath $OtherPath -Raw) | Should -Match $script:KnownGuid
        (Get-Content -LiteralPath $OtherPath -Raw) | Should -Match "Author = 'Jane Doe'"
        (Get-Content -LiteralPath $script:ManifestPath -Raw) |
            Should -Match $script:PlaceholderGuid
    }

    It 'fails without writing when Source\ holds more than one manifest' {
        $SecondParams = @{ Path = $script:SourceDir; ChildPath = 'Extra.psd1' }
        Set-Content -LiteralPath (Join-Path @SecondParams) -Value '@{ }' -NoNewline

        $Applied = Set-ModuleManifest @script:FullParams 6>$null
        $Applied | Should -BeFalse

        (Get-Content -LiteralPath $script:ManifestPath -Raw) |
            Should -Match $script:PlaceholderGuid
    }

    It 'fails when Source\ is missing' {
        Remove-Item -LiteralPath $script:SourceDir -Recurse -Force

        $Applied = Set-ModuleManifest @script:FullParams 6>$null
        $Applied | Should -BeFalse
    }

    It 'reports a key the manifest does not carry' {
        $NoAuthor = @(
            '@{'
            "    GUID = '$script:PlaceholderGuid'"
            '}'
        ) -join "`r`n"
        Set-Content -LiteralPath $script:ManifestPath -Value $NoAuthor -NoNewline

        $Applied = Set-ModuleManifest @script:FullParams 6>$null
        $Applied | Should -BeFalse

        # The keys it could find are still written.
        (Get-Content -LiteralPath $script:ManifestPath -Raw) |
            Should -Not -Match $script:PlaceholderGuid
    }

    It 'fails without writing when -Guid is not a GUID' {
        $Params = $script:FullParams.Clone()
        $Params.Guid = 'not-a-guid'
        $Applied = Set-ModuleManifest @Params 6>$null
        $Applied | Should -BeFalse

        (Get-Content -LiteralPath $script:ManifestPath -Raw) |
            Should -Match $script:PlaceholderGuid
    }

    It 'mints a different GUID on every run' {
        $Params = @{ RepoRoot = $script:Scratch; DryRun = $false }
        $null = Set-ModuleManifest @Params 6>$null
        $First = Get-Content -LiteralPath $script:ManifestPath -Raw
        $null = Set-ModuleManifest @Params 6>$null
        $Second = Get-Content -LiteralPath $script:ManifestPath -Raw

        $Second | Should -Not -BeExactly $First
    }
}
