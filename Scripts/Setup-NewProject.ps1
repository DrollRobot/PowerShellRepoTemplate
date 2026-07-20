<#
.SYNOPSIS
    Converts this template into a new PowerShell module project, driven by a config file.

.DESCRIPTION
    Config-driven version of the template-to-project conversion. Edit Scripts\setup.psd1 with
    your values (project name, GitHub username, license choice, which optional features to keep,
    whether to reinitialize git), then run this script with no arguments.

    Validates every field in the config up front -- if anything is wrong, nothing runs and every
    problem is listed at once. Previews every change every step would make (nothing applied
    yet), asks for a single confirmation, and applies everything. -DryRun stops after the
    preview; -Yes skips the confirmation (the preview still runs first).

    Steps always run in this order, regardless of the config file's own table order: strip
    TEMPLATE SETUP NOTES banners -> replace the template name, rename files that carry it, and
    stamp a fresh manifest GUID -> fill in the GitHub owner/repo placeholders (only if
    [Project].GitHubUser is set) -> select a license -> remove any declined [Features] (docs
    site, SECURITY.md, CONTRIBUTING.md, the explicit-module-import check, the opinionated
    formatting checks, each independently) and relocate the unwanted-strings check to
    .local\tests\ if [Features].UnwantedStringsLocal is true -> reinitialize git (only if
    [Git].Reinit is true; destructive, has its own extra confirmation) -> report any remaining
    FIXMEs (read-only, always last, not gated by -DryRun's early exit).

    Removing a formatting-check feature also drops its .pre-commit-config.yaml hook entry, if
    present, so a declined check never leaves a dangling commit-hook reference to a deleted
    script. Scripts\Compare-Template.ps1 reads the same [Features] table afterward, so a declined
    feature is never reported as missing drift.

.PARAMETER ConfigPath
    Path to the setup config file. Defaults to Scripts\setup.psd1 next to this script.

.PARAMETER DryRun
    Preview every change without writing anything.

.PARAMETER Yes
    Skip the confirmation prompt. The preview still runs first, and the destructive git-reinit
    step's own confirmation is skipped too.

.EXAMPLE
    .\Scripts\Setup-NewProject.ps1 -DryRun

    Shows everything Scripts\setup.psd1 would change, without writing.

.EXAMPLE
    .\Scripts\Setup-NewProject.ps1

    Runs the full conversion, previewing first and asking for one confirmation.

.EXAMPLE
    .\Scripts\Setup-NewProject.ps1 -Yes

    Runs the full conversion non-interactively (still previews first).

.OUTPUTS
    Progress text to the host. No pipeline output.

.NOTES
    Run once, right after creating a repo from this template. Edit Scripts\setup.psd1 first.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '')]
[CmdletBinding()]
param(
    [Parameter()]
    [string] $ConfigPath,

    [Parameter()]
    [switch] $DryRun,

    [Parameter()]
    [switch] $Yes
)

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseDeclaredVarsMoreThanAssignments', 'ScriptVersion')]
$ScriptVersion = '2.0.1'

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# git is asked a question whose non-zero exit is an expected answer (no root commit yet on a
# shallow clone). Keep that from throwing under $ErrorActionPreference = 'Stop'; the exit code is
# checked by hand.
$PSNativeCommandUseErrorActionPreference = $false

$script:RepoRoot = Split-Path -Path $PSScriptRoot -Parent
$script:AssumeYes = [bool] $Yes

# Built from pieces so that a later run of this same script (after it has already renamed the
# project once) cannot match its own constant. Mirrors Scripts\Compare-Template.ps1.
$script:TemplateName = 'Powershell' + 'RepoTemplate'

# This repo's own root commit ("Initial commit"), verified via
# `git rev-list --max-parents=0 HEAD`. Used by Test-PristineTemplateClone to refuse a
# config-driven git reinit once history has already been replaced once.
$script:TemplateRootCommit = 'd79b53badf0c9baef3d03b6299aa03a91add932e' # pragma: allowlist secret

$script:LicenseCandidates = @('mit', 'apache', 'gnu', 'proprietary', 'none')
# The GNU GPL text carries its own copyright notice and takes no per-project name, so name/year
# substitution is skipped for it (and for 'none', which writes no LICENSE at all).
$script:LicenseNeedsHolder = @('mit', 'apache', 'proprietary')
# Proprietary additionally distinguishes the copyright holder (author) from the owning company.
$script:LicenseNeedsCompany = @('proprietary')

# Text files eligible for in-place string replacement.
$script:TextExtensions = @(
    '.ps1', '.psd1', '.psm1', '.md', '.yml', '.yaml', '.json', '.code-workspace', '.txt'
)
$script:ExcludedFolders = @('.git', '.local', 'Output', '.staging', 'site')

# --- output helpers (mirrors Scripts\Compare-Template.ps1) ------------------

function Write-Section {
    param([Parameter(Mandatory)][string]$Title)
    Write-Host ''
    Write-Host "== $Title ==" -ForegroundColor Cyan
}

function Write-Info {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$Value
    )
    Write-Host "  $(($Label + ':').PadRight(20))$Value"
}

function Write-Warn {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host $Message -ForegroundColor Yellow
}

function Write-Success {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host $Message -ForegroundColor Green
}

# Ask the user a yes/no question. Always 'yes' in assume-yes mode, with the auto-answer printed
# so the transcript still shows the step.
function Confirm-Step {
    param([Parameter(Mandatory)][string]$Prompt)
    if ($script:AssumeYes) {
        Write-Host "$Prompt [y/n] y " -NoNewline
        Write-Host '(auto: -Yes)' -ForegroundColor DarkGray
        return $true
    }
    while ($true) {
        $Answer = (Read-Host "$Prompt [y/n]").Trim().ToLowerInvariant()
        if ($Answer -in @('y', 'yes')) { return $true }
        if ($Answer -in @('n', 'no')) { return $false }
        Write-Host "  Please answer 'y' or 'n'."
    }
}

# --- config loading and validation ------------------------------------------

function Import-SetupConfig {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Config file not found: $Path"
    }
    try {
        return Import-PowerShellDataFile -Path $Path
    }
    catch {
        throw "'$Path' is not a valid PowerShell data file: $($_.Exception.Message)"
    }
}

# Read $Raw.<Section>.<Key> (dotted Path, e.g. 'Project.Name') as a string, recording a problem
# if the section or key is missing or not a string.
function Get-ConfigString {
    param(
        [Parameter(Mandatory)][hashtable]$Raw,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[string]]$Problems
    )
    $Section, $Key = $Path -split '\.', 2
    $Table = $Raw[$Section]
    $Value = if ($Table -is [hashtable]) { $Table[$Key] } else { $null }
    if ($Value -isnot [string]) {
        $Problems.Add("[$Path] is missing or is not a string.")
        return ''
    }
    return $Value
}

# Same as Get-ConfigString, for a true/false value.
function Get-ConfigBool {
    param(
        [Parameter(Mandatory)][hashtable]$Raw,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[string]]$Problems
    )
    $Section, $Key = $Path -split '\.', 2
    $Table = $Raw[$Section]
    $Value = if ($Table -is [hashtable]) { $Table[$Key] } else { $null }
    if ($Value -isnot [bool]) {
        $Problems.Add("[$Path] is missing or is not a true/false value.")
        return $false
    }
    return $Value
}

# Whether this repo still has the template's original git history. Used as a pre-flight guard
# before a config-driven, zero-prompt [Git].Reinit = $true: a human running the git-reinit step
# by hand already sees the current branch/origin printed and must type an explicit confirmation,
# which is itself the safety check for that path. This guard exists specifically for the
# config-driven path, where a stale Reinit = $true left in a committed config could otherwise
# delete history with no human ever specifically choosing that action for this run.
function Test-PristineTemplateClone {
    if (-not (Get-Command -Name 'git' -ErrorAction SilentlyContinue)) { return $false }
    $global:LASTEXITCODE = 0
    $RootCommits = @(& git -C $script:RepoRoot rev-list --max-parents=0 HEAD 2>$null)
    if ($LASTEXITCODE -ne 0 -or $RootCommits.Count -eq 0) { return $false }
    return ($RootCommits.Count -eq 1 -and $RootCommits[0] -eq $script:TemplateRootCommit)
}

# Validate every field in $Raw and return the resolved values plus a (possibly empty) list of
# problems. Scope: field presence/type, per-field validity, cross-field constraints, and (only
# when Git.Reinit is true) the pristine-clone guard. Does not check repo/filesystem state beyond
# that (e.g. whether a license candidate file still exists) -- that stays in each step.
function Test-SetupConfig {
    param([Parameter(Mandatory)][hashtable]$Raw)

    $Problems = [System.Collections.Generic.List[string]]::new()

    $Name = Get-ConfigString -Raw $Raw -Path 'Project.Name' -Problems $Problems
    $GitHubUser = Get-ConfigString -Raw $Raw -Path 'Project.GitHubUser' -Problems $Problems
    $LicenseKey = Get-ConfigString -Raw $Raw -Path 'License.Key' -Problems $Problems
    $LicenseYear = Get-ConfigString -Raw $Raw -Path 'License.Year' -Problems $Problems
    $LicenseName = Get-ConfigString -Raw $Raw -Path 'License.Name' -Problems $Problems
    $LicenseCompany = Get-ConfigString -Raw $Raw -Path 'License.Company' -Problems $Problems
    $GitBranch = Get-ConfigString -Raw $Raw -Path 'Git.Branch' -Problems $Problems
    $GitReinit = Get-ConfigBool -Raw $Raw -Path 'Git.Reinit' -Problems $Problems

    $Params = @{ Raw = $Raw; Path = 'Features.Docs'; Problems = $Problems }
    $FeatureDocs = Get-ConfigBool @Params
    $Params = @{ Raw = $Raw; Path = 'Features.SecurityMd'; Problems = $Problems }
    $FeatureSecurityMd = Get-ConfigBool @Params
    $Params = @{ Raw = $Raw; Path = 'Features.ContributingMd'; Problems = $Problems }
    $FeatureContributingMd = Get-ConfigBool @Params
    $Params = @{ Raw = $Raw; Path = 'Features.ExplicitModuleImport'; Problems = $Problems }
    $FeatureExplicitImport = Get-ConfigBool @Params
    $Params = @{ Raw = $Raw; Path = 'Features.NonASCIICharacters'; Problems = $Problems }
    $FeatureNonASCII = Get-ConfigBool @Params
    $Params = @{ Raw = $Raw; Path = 'Features.FormatOperator'; Problems = $Problems }
    $FeatureFormatOperator = Get-ConfigBool @Params
    $Params = @{ Raw = $Raw; Path = 'Features.WriteVerboseDebug'; Problems = $Problems }
    $FeatureWriteVerboseDebug = Get-ConfigBool @Params
    $Params = @{ Raw = $Raw; Path = 'Features.BacktickContinuation'; Problems = $Problems }
    $FeatureBacktick = Get-ConfigBool @Params
    $Params = @{ Raw = $Raw; Path = 'Features.UnwantedStringsLocal'; Problems = $Problems }
    $FeatureUnwantedLocal = Get-ConfigBool @Params

    if ($Name -and $Name -notmatch '^[A-Za-z][A-Za-z0-9._]*$') {
        $Problems.Add('[Project.Name] must start with a letter and contain only letters, ' +
            'numbers, dots, and underscores.')
    }
    elseif (-not $Name) {
        $Problems.Add('[Project.Name] is required.')
    }

    if ($GitHubUser -and -not $GitHubUser.Trim()) {
        $Problems.Add('[Project.GitHubUser] is whitespace only; leave it blank to skip, or ' +
            'set a real value.')
    }

    if ($LicenseKey -and $LicenseKey -notin $script:LicenseCandidates) {
        $CandidateList = $script:LicenseCandidates -join ', '
        $Problems.Add("[License.Key] '$LicenseKey' is not one of: $CandidateList.")
    }
    elseif (-not $LicenseKey) {
        $CandidateList = $script:LicenseCandidates -join ', '
        $Problems.Add("[License.Key] is required (one of: $CandidateList).")
    }
    else {
        if ($LicenseKey -in $script:LicenseNeedsHolder) {
            if (-not $LicenseYear.Trim()) {
                $Problems.Add('[License.Year] is required for this license.')
            }
            if (-not $LicenseName.Trim()) {
                $Problems.Add('[License.Name] is required for this license.')
            }
        }
        if ($LicenseKey -in $script:LicenseNeedsCompany -and -not $LicenseCompany.Trim()) {
            $Problems.Add('[License.Company] is required for the proprietary license.')
        }
    }

    if (-not $GitBranch.Trim()) {
        $Problems.Add('[Git.Branch] is empty.')
    }

    if ($GitReinit -and -not (Test-PristineTemplateClone)) {
        $ReinitMsg = '[Git.Reinit]=true, but this repo no longer looks like a pristine ' +
            'template clone (git history does not start at the template''s own root commit). ' +
            'Set [Git.Reinit]=false, or investigate before re-running.'
        $Problems.Add($ReinitMsg)
    }

    return [pscustomobject]@{
        Problems                 = $Problems
        Name                     = $Name
        GitHubUser               = $GitHubUser
        LicenseKey               = $LicenseKey
        LicenseYear              = $LicenseYear
        LicenseName              = $LicenseName
        LicenseCompany           = $LicenseCompany
        GitBranch                = $GitBranch
        GitReinit                = $GitReinit
        FeatureDocs              = $FeatureDocs
        FeatureSecurityMd        = $FeatureSecurityMd
        FeatureContributingMd    = $FeatureContributingMd
        FeatureExplicitImport    = $FeatureExplicitImport
        FeatureNonASCII          = $FeatureNonASCII
        FeatureFormatOperator    = $FeatureFormatOperator
        FeatureWriteVerboseDebug = $FeatureWriteVerboseDebug
        FeatureBacktick          = $FeatureBacktick
        FeatureUnwantedLocal     = $FeatureUnwantedLocal
    }
}

# --- steps --------------------------------------------------------------------

function Get-TemplateTextFile {
    $ExcludePattern = ($script:ExcludedFolders |
        ForEach-Object { [regex]::Escape("\$_\") }) -join '|'
    Get-ChildItem -Path $script:RepoRoot -Recurse -File |
        # A zero-length file (e.g. a placeholder .claude\settings.json) can never contain the
        # template name, a banner, or a FIXME placeholder; excluding it here also keeps
        # Get-Content -Raw's $null-for-empty-file quirk from reaching every caller below.
        Where-Object { $_.Extension -in $script:TextExtensions -and $_.Length -gt 0 } |
        Where-Object { "$($_.FullName)\" -notmatch $ExcludePattern }
}

function Invoke-StripHeader {
    param([Parameter(Mandatory)][bool]$DryRun)
    $MarkdownBlock = '(?ms)^<!--\s*\r?\n=+\r?\nTEMPLATE SETUP NOTES.*?-->\s*\r?\n'
    $HashBlock = '(?ms)^# =+\s*\r?\n# TEMPLATE SETUP NOTES.*?\r?\n# =+\s*\r?\n'
    $Changed = @()
    foreach ($File in (Get-TemplateTextFile)) {
        $Content = Get-Content -Path $File.FullName -Raw
        $Updated = $Content -replace $MarkdownBlock, '' -replace $HashBlock, ''
        if ($Updated -ne $Content) {
            $Changed += $File
            if (-not $DryRun) {
                Set-Content -Path $File.FullName -Value $Updated -NoNewline
            }
        }
    }
    Write-Info 'Strip template headers' "$($Changed.Count) file(s)"
    foreach ($File in $Changed) {
        $Rel = [System.IO.Path]::GetRelativePath($script:RepoRoot, $File.FullName)
        Write-Host "    $Rel"
    }
    return $true
}

function Invoke-RenameProject {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][bool]$DryRun
    )
    $RenameTargets = Get-TemplateTextFile | Where-Object {
        (Get-Content -Path $_.FullName -Raw) -match [regex]::Escape($script:TemplateName)
    }
    $ExcludePattern = ($script:ExcludedFolders |
        ForEach-Object { [regex]::Escape("\$_\") }) -join '|'
    $FileRenames = Get-ChildItem -Path $script:RepoRoot -Recurse -File |
        Where-Object { $_.Name -match [regex]::Escape($script:TemplateName) } |
        Where-Object { "$($_.FullName)\" -notmatch $ExcludePattern }

    Write-Info 'Rename project' "'$($script:TemplateName)' -> '$Name'"
    Write-Host "    Replace the template name in $($RenameTargets.Count) file(s)"
    Write-Host "    Rename $($FileRenames.Count) file(s) whose name carries the template name"
    Write-Host '    Stamp a fresh GUID into the source manifest'

    if ($DryRun) { return $true }

    foreach ($File in $RenameTargets) {
        $Content = Get-Content -Path $File.FullName -Raw
        $Updated = $Content -replace [regex]::Escape($script:TemplateName), $Name
        Set-Content -Path $File.FullName -Value $Updated -NoNewline
    }
    foreach ($File in $FileRenames) {
        $NewLeaf = $File.Name -replace [regex]::Escape($script:TemplateName), $Name
        Rename-Item -Path $File.FullName -NewName $NewLeaf
    }

    $ManifestPath = Join-Path -Path $script:RepoRoot -ChildPath "Source\$Name.psd1"
    if (Test-Path -LiteralPath $ManifestPath) {
        $Guid = (New-Guid).Guid
        $Manifest = Get-Content -Path $ManifestPath -Raw
        $Pattern = "GUID(\s*)=(\s*)'[0-9a-fA-F-]+'"
        $Manifest = $Manifest -replace $Pattern, "GUID`$1=`$2'$Guid'"
        Set-Content -Path $ManifestPath -Value $Manifest -NoNewline
        Write-Info 'New GUID' $Guid
    }
    else {
        Write-Warn "  Manifest not found at $ManifestPath; GUID not updated."
    }
    return $true
}

function Invoke-SetGitHubUser {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][AllowEmptyString()][string]$GitHubUser,
        [Parameter(Mandatory)][bool]$DryRun
    )
    if (-not $GitHubUser) {
        Write-Info 'GitHub user' 'skipped (blank in config)'
        return $true
    }
    Write-Info 'GitHub user' "$GitHubUser/$Name"
    if ($DryRun) { return $true }

    foreach ($File in (Get-TemplateTextFile)) {
        $Content = Get-Content -Path $File.FullName -Raw
        $Updated = $Content.Replace('FIXME.github.io/FIXME', "$GitHubUser.github.io/$Name")
        $Updated = $Updated.Replace('FIXME/FIXME', "$GitHubUser/$Name")
        if ($Updated -ne $Content) {
            Set-Content -Path $File.FullName -Value $Updated -NoNewline
        }
    }
    return $true
}

function Invoke-ChooseLicense {
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Year,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Name,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Company,
        [Parameter(Mandatory)][bool]$DryRun
    )
    if ($Key -eq 'none') {
        Write-Info 'License' 'none selected; removing LICENSE.*.FIXME variants'
        if (-not $DryRun) {
            Get-ChildItem -Path $script:RepoRoot -Filter 'LICENSE.*.FIXME' | Remove-Item
        }
        return $true
    }

    Write-Info 'License' $Key.ToUpper()
    if ($DryRun) { return $true }

    $Chosen = Join-Path -Path $script:RepoRoot -ChildPath "LICENSE.$Key.FIXME"
    if (-not (Test-Path -LiteralPath $Chosen)) {
        Write-Warn "  License variant not found: $Chosen"
        return $false
    }
    $LicenseText = Get-Content -Path $Chosen -Raw
    if ($Key -in $script:LicenseNeedsHolder) {
        $LicenseText = $LicenseText.Replace('FIXME year', $Year).Replace('FIXME name', $Name)
    }
    if ($Key -in $script:LicenseNeedsCompany) {
        $LicenseText = $LicenseText.Replace('FIXME company', $Company)
    }
    $LicenseOut = Join-Path -Path $script:RepoRoot -ChildPath 'LICENSE'
    Set-Content -Path $LicenseOut -Value $LicenseText -NoNewline
    Get-ChildItem -Path $script:RepoRoot -Filter 'LICENSE.*.FIXME' | Remove-Item
    Write-Success "  License: $($Key.ToUpper()) written to LICENSE"
    if ($LicenseText -match 'FIXME') {
        Write-Warn '  LICENSE still contains FIXME placeholder(s); complete them by hand.'
    }
    return $true
}

function Invoke-ReinitGit {
    param(
        [Parameter(Mandatory)][string]$Branch,
        [Parameter(Mandatory)][bool]$DryRun
    )
    Write-Warn "  DELETE .git and reinitialize on branch '$Branch' (destructive)"
    if ($DryRun) { return $true }

    if (-not $script:AssumeYes) {
        $Answer = Read-Host 'Really DELETE .git and start a fresh history? [y/N]'
        if ($Answer -notmatch '^[Yy]') {
            Write-Warn '  Skipped git reinit.'
            return $true
        }
    }
    $GitDir = Join-Path -Path $script:RepoRoot -ChildPath '.git'
    Remove-Item -Path $GitDir -Recurse -Force

    $global:LASTEXITCODE = 0
    git -C $script:RepoRoot init -b $Branch | Out-Host
    if ($LASTEXITCODE -ne 0) {
        Write-Warn "  'git init' exited with code $LASTEXITCODE."
        return $false
    }
    Write-Success '  Fresh git history initialized. Review and make your first commit.'
    return $true
}

# Delete a set of repo-relative paths (files or folders). Shared by every feature-removal step
# below; each step is responsible for its own preview text.
function Invoke-RemoveRepoPath {
    param([Parameter(Mandatory)][string[]]$RelativePath)
    foreach ($Rel in $RelativePath) {
        $Full = Join-Path -Path $script:RepoRoot -ChildPath $Rel
        if (Test-Path -LiteralPath $Full) {
            Remove-Item -LiteralPath $Full -Recurse -Force
        }
    }
}

function Invoke-RemoveDocsFeature {
    param([Parameter(Mandatory)][bool]$DryRun)
    $Targets = @('mkdocs.yml', 'Docs.ps1', 'Docs', '.github\workflows\docs.yml')
    Write-Info 'Remove docs feature' 'mkdocs.yml, Docs.ps1, Docs\, docs.yml workflow'
    if (-not $DryRun) { Invoke-RemoveRepoPath -RelativePath $Targets }
    return $true
}

function Invoke-RemoveSecurityMd {
    param([Parameter(Mandatory)][bool]$DryRun)
    Write-Info 'Remove SECURITY.md' 'community-health file not needed for this project'
    if (-not $DryRun) { Invoke-RemoveRepoPath -RelativePath 'SECURITY.md' }
    return $true
}

function Invoke-RemoveContributingMd {
    param([Parameter(Mandatory)][bool]$DryRun)
    Write-Info 'Remove CONTRIBUTING.md' 'community-health file not needed for this project'
    if (-not $DryRun) { Invoke-RemoveRepoPath -RelativePath 'CONTRIBUTING.md' }
    return $true
}

function Invoke-RemoveExplicitModuleImport {
    param([Parameter(Mandatory)][bool]$DryRun)
    $Targets = @(
        'Scripts\Find-ScriptCommand.ps1'
        'Scripts\Resolve-CommandModule.ps1'
        'Tests\Test-ExplicitModuleImport.ps1'
    )
    Write-Info 'Remove explicit-module-import check' ($Targets -join ', ')
    if (-not $DryRun) { Invoke-RemoveRepoPath -RelativePath $Targets }
    return $true
}

# Remove the block for one hook (matched by its 'id:') from .pre-commit-config.yaml, if the file
# and that hook are present. Each hook is 5 lines: the '- id:' line plus 4 indented property
# lines, usually followed by one blank separator line before the next hook.
function Invoke-RemovePreCommitHook {
    param([Parameter(Mandatory)][string]$HookId)
    $PreCommitPath = Join-Path -Path $script:RepoRoot -ChildPath '.pre-commit-config.yaml'
    if (-not (Test-Path -LiteralPath $PreCommitPath)) { return }
    $Text = Get-Content -Path $PreCommitPath -Raw
    $Escaped = [regex]::Escape($HookId)
    $Pattern = "(?ms)^      - id: $Escaped\r?\n(?:        .*\r?\n)*\r?\n?"
    $Updated = $Text -replace $Pattern, ''
    if ($Updated -ne $Text) {
        Set-Content -Path $PreCommitPath -Value $Updated -NoNewline
    }
}

# One opinionated formatting check: deletes Tests\<FileName> and, if present, that check's
# pre-commit hook entry (so a declined check never leaves a dangling commit-hook reference to a
# script that no longer exists).
function Invoke-RemoveFormattingTest {
    param(
        [Parameter(Mandatory)][string]$FileName,
        [Parameter(Mandatory)][string]$HookId,
        [Parameter(Mandatory)][bool]$DryRun
    )
    Write-Info "Remove Tests\$FileName" "and its pre-commit hook ($HookId), if present"
    if ($DryRun) { return $true }
    Invoke-RemoveRepoPath -RelativePath "Tests\$FileName"
    Invoke-RemovePreCommitHook -HookId $HookId
    return $true
}

# Relocates Tests\Test-FindUnwantedStrings.ps1 to .local\tests\, so its patterns stay personal
# and untracked instead of shared and committed. Tests.ps1 already discovers and runs whichever
# copy (or copies) exist under tests\ and .local\tests\, so no orchestrator change is needed.
function Invoke-MoveUnwantedStringsTest {
    param([Parameter(Mandatory)][bool]$DryRun)
    Write-Info 'Move unwanted-strings test' 'Tests\Test-FindUnwantedStrings.ps1 -> .local\tests\'
    if ($DryRun) { return $true }

    $Source = Join-Path -Path $script:RepoRoot -ChildPath 'Tests\Test-FindUnwantedStrings.ps1'
    if (-not (Test-Path -LiteralPath $Source)) { return $true }
    $DestDir = Join-Path -Path $script:RepoRoot -ChildPath '.local\tests'
    if (-not (Test-Path -LiteralPath $DestDir)) {
        New-Item -ItemType Directory -Path $DestDir -Force | Out-Null
    }
    $Dest = Join-Path -Path $DestDir -ChildPath 'Test-FindUnwantedStrings.ps1'
    Move-Item -LiteralPath $Source -Destination $Dest -Force
    return $true
}

# Dispatches one entry from the $FeatureSteps list (built in main, below) to its underlying
# Invoke-Remove*/Invoke-Move* function. A single dispatcher, rather than per-feature scriptblocks
# stored in the list, sidesteps PowerShell closure-capture pitfalls when the list is built in a
# loop (see the FormattingTest entries below).
function Invoke-FeatureStep {
    param(
        [Parameter(Mandatory)][pscustomobject]$Step,
        [Parameter(Mandatory)][bool]$DryRun
    )
    switch ($Step.Type) {
        'Docs' { return Invoke-RemoveDocsFeature -DryRun $DryRun }
        'SecurityMd' { return Invoke-RemoveSecurityMd -DryRun $DryRun }
        'ContributingMd' { return Invoke-RemoveContributingMd -DryRun $DryRun }
        'ExplicitModuleImport' { return Invoke-RemoveExplicitModuleImport -DryRun $DryRun }
        'FormattingTest' {
            $Params = @{ FileName = $Step.FileName; HookId = $Step.HookId; DryRun = $DryRun }
            return Invoke-RemoveFormattingTest @Params
        }
        'UnwantedStringsLocal' { return Invoke-MoveUnwantedStringsTest -DryRun $DryRun }
    }
}

# Build the list of feature steps this run needs, in a fixed order, from the validated config.
# Declined keep-by-default features (Docs, SecurityMd, ContributingMd, ExplicitModuleImport, the
# four formatting checks) are included as removals; UnwantedStringsLocal is the opposite -- it is
# included when true (opted in), since false is the always-shipped default.
function Get-FeatureStep {
    param([Parameter(Mandatory)][pscustomobject]$Config)

    $Steps = [System.Collections.Generic.List[pscustomobject]]::new()
    if (-not $Config.FeatureDocs) {
        $Steps.Add([pscustomobject]@{ Key = 'remove_docs'; Type = 'Docs' })
    }
    if (-not $Config.FeatureSecurityMd) {
        $Steps.Add([pscustomobject]@{ Key = 'remove_security_md'; Type = 'SecurityMd' })
    }
    if (-not $Config.FeatureContributingMd) {
        $Steps.Add([pscustomobject]@{ Key = 'remove_contributing_md'; Type = 'ContributingMd' })
    }
    if (-not $Config.FeatureExplicitImport) {
        $Steps.Add([pscustomobject]@{
                Key  = 'remove_explicit_module_import'
                Type = 'ExplicitModuleImport'
            })
    }

    $FormattingFeatures = @(
        [pscustomobject]@{
            Enabled  = $Config.FeatureNonASCII
            Key      = 'remove_nonascii_test'
            FileName = 'Test-NonASCIICharacters.ps1'
            HookId   = 'ps-non-ascii'
        }
        [pscustomobject]@{
            Enabled  = $Config.FeatureFormatOperator
            Key      = 'remove_format_operator_test'
            FileName = 'Test-FormatOperator.ps1'
            HookId   = 'ps-format-operator'
        }
        [pscustomobject]@{
            Enabled  = $Config.FeatureWriteVerboseDebug
            Key      = 'remove_write_verbose_debug_test'
            FileName = 'Test-WriteVerboseDebug.ps1'
            HookId   = 'ps-write-verbose-debug' # noqa: Test-WriteVerboseDebug
        }
        [pscustomobject]@{
            Enabled  = $Config.FeatureBacktick
            Key      = 'remove_backtick_continuation_test'
            FileName = 'Test-BacktickContinuation.ps1'
            HookId   = 'ps-backtick-continuation'
        }
    )
    foreach ($Formatting in $FormattingFeatures) {
        if ($Formatting.Enabled) { continue }
        $Steps.Add([pscustomobject]@{
                Key      = $Formatting.Key
                Type     = 'FormattingTest'
                FileName = $Formatting.FileName
                HookId   = $Formatting.HookId
            })
    }

    if ($Config.FeatureUnwantedLocal) {
        $Steps.Add([pscustomobject]@{
                Key  = 'move_unwanted_strings'
                Type = 'UnwantedStringsLocal'
            })
    }
    return $Steps
}

function Invoke-FixmeReport {
    $FixmeScript = Join-Path -Path $script:RepoRoot -ChildPath 'Tests\Test-FixmeComments.ps1'
    if (-not (Test-Path -LiteralPath $FixmeScript)) { return }
    Write-Section 'Remaining FIXMEs (finish these by hand)'
    & $FixmeScript -Path $script:RepoRoot -Recurse
}

# Run one apply-phase step, recording its key in $Failed on a returned failure or a thrown
# error, so one step's problem does not block the independent steps after it.
function Invoke-SetupStep {
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][scriptblock]$Action,
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[string]]$Failed
    )
    try {
        if (-not (& $Action)) { $Failed.Add($Key) }
    }
    catch {
        Write-Warn "  $Key failed: $($_.Exception.Message)"
        $Failed.Add($Key)
    }
}

# --- main ---------------------------------------------------------------------

if ($MyInvocation.InvocationName -eq '.') { return }

Write-Host ''
Write-Host 'Setup-NewProject - config-driven template setup' -ForegroundColor Cyan
Write-Info 'Script version' $ScriptVersion
Write-Info 'Repo root' $script:RepoRoot

if (-not $ConfigPath) {
    $ConfigPath = Join-Path -Path $PSScriptRoot -ChildPath 'setup.psd1'
}
Write-Info 'Config file' $ConfigPath
if ($DryRun) { Write-Warn 'DRY RUN: nothing will be written.' }

$RawConfig = Import-SetupConfig -Path $ConfigPath
$Config = Test-SetupConfig -Raw $RawConfig

if ($Config.Problems.Count -gt 0) {
    Write-Section 'Config problems'
    foreach ($Problem in $Config.Problems) {
        Write-Host "  - $Problem"
    }
    Write-Host ''
    $ProblemMsg = "$($Config.Problems.Count) problem(s) found in $ConfigPath; nothing changed."
    throw $ProblemMsg
}

Write-Section 'Preview'
$null = Invoke-StripHeader -DryRun $true
$null = Invoke-RenameProject -Name $Config.Name -DryRun $true
$GitHubUserPreviewParams = @{ Name = $Config.Name; GitHubUser = $Config.GitHubUser; DryRun = $true }
$null = Invoke-SetGitHubUser @GitHubUserPreviewParams
$LicensePreviewParams = @{
    Key     = $Config.LicenseKey
    Year    = $Config.LicenseYear
    Name    = $Config.LicenseName
    Company = $Config.LicenseCompany
    DryRun  = $true
}
$null = Invoke-ChooseLicense @LicensePreviewParams
$FeatureSteps = Get-FeatureStep -Config $Config
foreach ($Step in $FeatureSteps) {
    $null = Invoke-FeatureStep -Step $Step -DryRun $true
}
if ($Config.GitReinit) {
    Write-Section 'Reinitialize git'
    $null = Invoke-ReinitGit -Branch $Config.GitBranch -DryRun $true
}

if ($DryRun) {
    Write-Host ''
    Write-Host '  (dry run -- nothing changed)' -ForegroundColor Yellow
    return
}

Write-Host ''
if (-not (Confirm-Step 'Apply the setup above?')) {
    Write-Warn '  Aborted; nothing changed.'
    throw 'Aborted by user.'
}

Write-Section 'Applying'
$Failed = [System.Collections.Generic.List[string]]::new()

Invoke-SetupStep -Key 'strip_headers' -Failed $Failed -Action {
    Invoke-StripHeader -DryRun $false
}
Invoke-SetupStep -Key 'rename_project' -Failed $Failed -Action {
    Invoke-RenameProject -Name $Config.Name -DryRun $false
}
Invoke-SetupStep -Key 'set_github_user' -Failed $Failed -Action {
    $Params = @{ Name = $Config.Name; GitHubUser = $Config.GitHubUser; DryRun = $false }
    Invoke-SetGitHubUser @Params
}
Invoke-SetupStep -Key 'choose_license' -Failed $Failed -Action {
    $Params = @{
        Key     = $Config.LicenseKey
        Year    = $Config.LicenseYear
        Name    = $Config.LicenseName
        Company = $Config.LicenseCompany
        DryRun  = $false
    }
    Invoke-ChooseLicense @Params
}
foreach ($Step in $FeatureSteps) {
    Invoke-SetupStep -Key $Step.Key -Failed $Failed -Action {
        Invoke-FeatureStep -Step $Step -DryRun $false
    }
}
if ($Config.GitReinit) {
    Write-Section 'Reinitialize git'
    Invoke-SetupStep -Key 'reinit_git' -Failed $Failed -Action {
        Invoke-ReinitGit -Branch $Config.GitBranch -DryRun $false
    }
}

Invoke-FixmeReport

Write-Section 'Setup complete'
if ($Failed.Count -gt 0) {
    Write-Host "  Steps that reported a problem: $($Failed -join ', ')" -ForegroundColor Red
    Write-Host '  Review their output above; fix setup.psd1 or the repo state, then re-run.'
    throw "Setup finished with problems in: $($Failed -join ', ')"
}
Write-Success '  Review the changes, then write some code!'
Write-Host '    1. Review changes (git diff if history was kept).'
Write-Host '    2. Resolve remaining FIXMEs.'
Write-Host '    3. .\Build.ps1 and .\Tests.ps1 NonLive to confirm a clean baseline.'
