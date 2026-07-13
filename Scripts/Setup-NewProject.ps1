<#
.SYNOPSIS
    Converts this template into a new PowerShell module project.

.DESCRIPTION
    Automates the tedious parts of adopting PowershellRepoTemplate:

      1. Replaces the template name with your module name in every text file.
      2. Renames the files that carry the template name (source manifest, dev
         loader psm1, .code-workspace, and any root build artifacts).
      3. Stamps a fresh GUID into the source manifest.
      4. Optionally fills in your GitHub owner/repo in URLs (-GitHubUser).
      5. Optionally selects a license (-License), filling in year and holder.
      6. Optionally strips the TEMPLATE SETUP NOTES banner blocks
         (-StripTemplateHeaders).
      7. Lists every remaining FIXME so you can finish by hand.
      8. Optionally deletes .git and reinitializes a fresh history
         (-ReinitGit; destructive, prompts separately).

    Run it from anywhere; paths are resolved relative to the repo root. The
    planned changes are summarized first and nothing is written until you
    confirm (or pass -Yes). Use -DryRun to preview without writing at all.

.PARAMETER Name
    The new module name, e.g. MyModule. Used for file renames and as the
    replacement for 'PowershellRepoTemplate' throughout the repo.

.PARAMETER GitHubUser
    Optional GitHub account or org name. Replaces the FIXME owner/repo
    placeholders in URLs (mkdocs.yml, README badges, CHANGELOG links).

.PARAMETER License
    Optional license choice: mit, apache, or gnu. Renames the matching
    LICENSE.<choice>.FIXME file to LICENSE and deletes the other variants.

.PARAMETER CopyrightHolder
    Optional name for the license copyright line. Used with -License; the
    current year is filled in automatically.

.PARAMETER StripTemplateHeaders
    Remove the TEMPLATE SETUP NOTES banner blocks from all files.

.PARAMETER ReinitGit
    Delete the .git folder and run git init for a fresh history. Destructive;
    prompts for confirmation separately (suppressed by -Yes).

.PARAMETER DryRun
    Preview every change without writing anything.

.PARAMETER Yes
    Skip all confirmation prompts.

.EXAMPLE
    .\Scripts\Setup-NewProject.ps1 -Name MyModule -DryRun

    Shows everything that would change, without writing.

.EXAMPLE
    .\Scripts\Setup-NewProject.ps1 -Name MyModule -GitHubUser octocat -License mit

    Full conversion: rename, GUID, URLs, MIT license.

.OUTPUTS
    Progress text to the host. No pipeline output.

.NOTES
    Run once, right after creating a repo from this template.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '')]
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z][A-Za-z0-9._]*$')]
    [string] $Name,

    [Parameter()]
    [string] $GitHubUser,

    [Parameter()]
    [ValidateSet('mit', 'apache', 'gnu')]
    [string] $License,

    [Parameter()]
    [string] $CopyrightHolder,

    [Parameter()]
    [switch] $StripTemplateHeaders,

    [Parameter()]
    [switch] $ReinitGit,

    [Parameter()]
    [switch] $DryRun,

    [Parameter()]
    [switch] $Yes
)

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseDeclaredVarsMoreThanAssignments', 'ScriptVersion')]
$ScriptVersion = '1.0.0'

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$TemplateName = 'PowershellRepoTemplate'
$RepoRoot = Split-Path -Path $PSScriptRoot -Parent
$Cyan = @{ ForegroundColor = 'Cyan' }
$Green = @{ ForegroundColor = 'Green' }
$Yellow = @{ ForegroundColor = 'Yellow' }

# Text files eligible for in-place string replacement.
$TextExtensions = @(
    '.ps1', '.psd1', '.psm1', '.md', '.yml', '.yaml', '.json', '.code-workspace', '.txt'
)
$ExcludedFolders = @('.git', '.local', 'Output', '.staging', 'site')

function Get-TextFile {
    $ExcludePattern = ($ExcludedFolders | ForEach-Object { [regex]::Escape("\$_\") }) -join '|'
    Get-ChildItem -Path $RepoRoot -Recurse -File |
        Where-Object { $_.Extension -in $TextExtensions } |
        Where-Object { "$($_.FullName)\" -notmatch $ExcludePattern }
}

# ---------------------------------------------------------------------------
# Plan: collect every change before touching anything.
# ---------------------------------------------------------------------------
Write-Host @Cyan "Repo root : $RepoRoot"
Write-Host @Cyan "New name  : $Name"
if ($DryRun) { Write-Host @Yellow 'DRY RUN: nothing will be written.' }

$AllTextFiles = Get-TextFile
$RenameTargets = $AllTextFiles | Where-Object {
    (Get-Content -Path $_.FullName -Raw) -match [regex]::Escape($TemplateName)
}
$ExcludePattern = ($ExcludedFolders | ForEach-Object { [regex]::Escape("\$_\") }) -join '|'
$FileRenames = Get-ChildItem -Path $RepoRoot -Recurse -File |
    Where-Object { $_.Name -match [regex]::Escape($TemplateName) } |
    Where-Object { "$($_.FullName)\" -notmatch $ExcludePattern }

Write-Host ''
Write-Host @Green "Step 1: replace '$TemplateName' -> '$Name' in $($RenameTargets.Count) file(s)"
$RenameTargets | ForEach-Object {
    Write-Host "    $([System.IO.Path]::GetRelativePath($RepoRoot, $_.FullName))"
}
Write-Host @Green "Step 2: rename $($FileRenames.Count) file(s)"
$FileRenames | ForEach-Object {
    $Rel = [System.IO.Path]::GetRelativePath($RepoRoot, $_.FullName)
    Write-Host "    $Rel -> $($Rel -replace [regex]::Escape($TemplateName), $Name)"
}
Write-Host @Green 'Step 3: stamp a fresh GUID into the source manifest'
if ($GitHubUser) { Write-Host @Green "Step 4: set GitHub owner/repo to $GitHubUser/$Name" }
if ($License) { Write-Host @Green "Step 5: select $($License.ToUpper()) license" }
if ($StripTemplateHeaders) { Write-Host @Green 'Step 6: strip TEMPLATE SETUP NOTES blocks' }
Write-Host @Green 'Step 7: report remaining FIXMEs'
if ($ReinitGit) { Write-Host @Yellow 'Step 8: DELETE .git and reinitialize (destructive)' }

if ($DryRun) { return }
if (-not $Yes) {
    $Answer = Read-Host 'Apply these changes? [y/N]'
    if ($Answer -notmatch '^[Yy]') { Write-Host @Yellow 'Aborted.'; return }
}

# ---------------------------------------------------------------------------
# Step 1: in-place string replacement.
# ---------------------------------------------------------------------------
foreach ($File in $RenameTargets) {
    $Content = Get-Content -Path $File.FullName -Raw
    $Updated = $Content -replace [regex]::Escape($TemplateName), $Name
    Set-Content -Path $File.FullName -Value $Updated -NoNewline
}

# ---------------------------------------------------------------------------
# Step 2: file renames.
# ---------------------------------------------------------------------------
foreach ($File in $FileRenames) {
    $NewLeaf = $File.Name -replace [regex]::Escape($TemplateName), $Name
    Rename-Item -Path $File.FullName -NewName $NewLeaf
}

# ---------------------------------------------------------------------------
# Step 3: fresh manifest GUID.
# ---------------------------------------------------------------------------
$ManifestPath = Join-Path -Path $RepoRoot -ChildPath "Source\$Name.psd1"
if (Test-Path $ManifestPath) {
    $Guid = (New-Guid).Guid
    $Manifest = Get-Content -Path $ManifestPath -Raw
    $Manifest = $Manifest -replace "GUID(\s*)=(\s*)'[0-9a-fA-F-]+'", "GUID`$1=`$2'$Guid'"
    Set-Content -Path $ManifestPath -Value $Manifest -NoNewline
    Write-Host @Cyan "New GUID: $Guid"
} else {
    Write-Warning "Manifest not found at $ManifestPath; GUID not updated."
}

# ---------------------------------------------------------------------------
# Step 4: GitHub owner/repo placeholders.
# ---------------------------------------------------------------------------
if ($GitHubUser) {
    foreach ($File in Get-TextFile) {
        $Content = Get-Content -Path $File.FullName -Raw
        $Updated = $Content -replace 'FIXME\.github\.io/FIXME', "$GitHubUser.github.io/$Name"
        $Updated = $Updated -replace 'FIXME/FIXME', "$GitHubUser/$Name"
        if ($Updated -ne $Content) {
            Set-Content -Path $File.FullName -Value $Updated -NoNewline
        }
    }
}

# ---------------------------------------------------------------------------
# Step 5: license selection.
# ---------------------------------------------------------------------------
if ($License) {
    $Chosen = Join-Path -Path $RepoRoot -ChildPath "LICENSE.$License.FIXME"
    if (Test-Path $Chosen) {
        $LicenseText = Get-Content -Path $Chosen -Raw
        $LicenseText = $LicenseText -replace 'FIXME year', (Get-Date -Format 'yyyy')
        if ($CopyrightHolder) {
            $LicenseText = $LicenseText -replace 'FIXME name', $CopyrightHolder
        }
        $LicenseOut = Join-Path -Path $RepoRoot -ChildPath 'LICENSE'
        Set-Content -Path $LicenseOut -Value $LicenseText -NoNewline
        Get-ChildItem -Path $RepoRoot -Filter 'LICENSE.*.FIXME' | Remove-Item
        Write-Host @Cyan "License: $($License.ToUpper()) written to LICENSE"
    } else {
        Write-Warning "License variant not found: $Chosen"
    }
}

# ---------------------------------------------------------------------------
# Step 6: strip TEMPLATE SETUP NOTES banner blocks.
# ---------------------------------------------------------------------------
if ($StripTemplateHeaders) {
    $MarkdownBlock = '(?ms)^<!--\s*\r?\n=+\r?\nTEMPLATE SETUP NOTES.*?-->\s*\r?\n'
    $HashBlock = '(?ms)^# =+\s*\r?\n# TEMPLATE SETUP NOTES.*?\r?\n# =+\s*\r?\n'
    foreach ($File in Get-TextFile) {
        $Content = Get-Content -Path $File.FullName -Raw
        $Updated = $Content -replace $MarkdownBlock, '' -replace $HashBlock, ''
        if ($Updated -ne $Content) {
            Set-Content -Path $File.FullName -Value $Updated -NoNewline
            $Rel = [System.IO.Path]::GetRelativePath($RepoRoot, $File.FullName)
            Write-Host @Cyan "Stripped template header: $Rel"
        }
    }
}

# ---------------------------------------------------------------------------
# Step 7: FIXME report.
# ---------------------------------------------------------------------------
$FixmeScript = Join-Path -Path $RepoRoot -ChildPath 'Tests\Test-FixmeComments.ps1'
if (Test-Path $FixmeScript) {
    Write-Host ''
    Write-Host @Green 'Remaining FIXMEs (finish these by hand):'
    & $FixmeScript -Path $RepoRoot -Recurse
}

# ---------------------------------------------------------------------------
# Step 8: reinitialize git history.
# ---------------------------------------------------------------------------
if ($ReinitGit) {
    if (-not $Yes) {
        $Answer = Read-Host 'Really DELETE .git and start a fresh history? [y/N]'
        if ($Answer -notmatch '^[Yy]') { Write-Host @Yellow 'Skipped git reinit.'; return }
    }
    Remove-Item -Path (Join-Path -Path $RepoRoot -ChildPath '.git') -Recurse -Force
    git -C $RepoRoot init | Out-Host
    Write-Host @Cyan 'Fresh git history initialized. Review and make your first commit.'
}

Write-Host ''
Write-Host @Green 'Done. Suggested next steps:'
Write-Host '    1. Review changes (git diff if history was kept).'
Write-Host '    2. Resolve remaining FIXMEs.'
Write-Host '    3. .\Build.ps1 and .\Tests.ps1 Offline to confirm a clean baseline.'
