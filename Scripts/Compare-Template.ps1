#Requires -Version 7.4
<#
.SYNOPSIS
    Compares a child repo against the template it was created from and offers to
    bring versioned tooling files up to date.

.DESCRIPTION
    A module created from this template (via Scripts\Setup-NewProject.ps1) keeps a
    set of tooling, CI, and config files that should track the template as it
    evolves. Run this script from inside the child repo, pointing -TemplatePath
    at a template checkout, to see where the two have drifted.

    Two kinds of files are handled:

      - Versioned files: the dev/build/test scripts that declare their own
        $ScriptVersion. Their versions are compared and, when the template's copy
        is newer (or the same version but different content), the script offers to
        copy the template's copy over the child's. This runs first, as a
        pre-flight, so an outdated copy of this script (and its manifest) is
        refreshed before the content comparison.

      - Non-versioned files: CI workflows, lint/format config, and the AGENTS docs.
        Their contents are compared after replaying the transformations
        Setup-NewProject.ps1 applied to the child (module-name and GitHub owner
        substitution, and stripping the TEMPLATE SETUP NOTES banner), so only
        genuine drift is reported. These are never written automatically; pass
        -Diff to review each difference side by side.

    Files the child owns (its Source\ code, the module manifest and its version,
    the changelog, the license, generated docs) are not compared.

.PARAMETER TemplatePath
    Path to the template checkout. Defaults to a sibling folder with the
    template's name, next to the child repo.

.PARAMETER Diff
    Open each differing non-versioned file as a side-by-side diff (see -DiffTool),
    falling back to a 'git diff --no-index' in the terminal when the editor is not
    available.

.PARAMETER DiffTool
    Command used to open -Diff pairs. Defaults to 'code' (VS Code).

.PARAMETER All
    List every compared file, including the ones that match.

.PARAMETER GitHubUser
    The child's GitHub owner, used to normalize the template's owner placeholders.
    Defaults to the owner parsed from the child's 'origin' remote.

.PARAMETER NoUpdate
    Report versioned-file drift but never offer to write anything. For CI.

.PARAMETER Yes
    Assume 'yes' to every confirmation prompt (non-interactive).

.PARAMETER Trace
    Emit verbose trace output.

.EXAMPLE
    .\Scripts\Compare-Template.ps1

    Compares against the sibling template checkout and reports drift.

.EXAMPLE
    .\Scripts\Compare-Template.ps1 -TemplatePath C:\dev\template-checkout -Diff

    Compares against an explicit template checkout and opens the differences.

.EXAMPLE
    .\Scripts\Compare-Template.ps1 -NoUpdate

    Read-only report suitable for CI (exit 1 on drift).

.OUTPUTS
    Progress and a drift report to the host. No pipeline output. Exit code 0 when
    there is no drift, 1 when a strict file differs or a required file is missing.

.NOTES
    Run from inside the child repo. This script is itself a versioned file, so a
    child keeps its own copy in sync via the pre-flight.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseShouldProcessForStateChangingFunctions', '')]
[CmdletBinding()]
param(
    [Parameter()]
    [string] $TemplatePath,

    [Parameter()]
    [switch] $Diff,

    [Parameter()]
    [string] $DiffTool = 'code',

    [Parameter()]
    [switch] $All,

    [Parameter()]
    [string] $GitHubUser,

    [Parameter()]
    [switch] $NoUpdate,

    [Parameter()]
    [Alias('y')]
    [switch] $Yes,

    [Parameter()]
    [switch] $Trace
)

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseDeclaredVarsMoreThanAssignments', 'ScriptVersion')]
$ScriptVersion = '1.1.1'

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# git is asked questions whose non-zero exit is an expected answer (no 'origin'
# remote; 'diff --no-index' returns 1 when files differ). Keep those from
# throwing under $ErrorActionPreference = 'Stop'; exit codes are checked by hand.
$PSNativeCommandUseErrorActionPreference = $false

# Answer every Confirm-Prompt with 'y' (set from -Yes). Script-scoped so the
# helper functions can read it.
$script:AssumeYes = [bool]$Yes
if ($Trace) { $InformationPreference = 'Continue' }

# --- output helpers (mirrors Scripts\New-Worktree.ps1) ----------------------

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

function Write-Echo {
    param([Parameter(Mandatory)][string]$CommandText)
    Write-Host "  > $CommandText" -ForegroundColor DarkGray
}

function Write-Warn {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host $Message -ForegroundColor Yellow
}

function Write-Success {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host $Message -ForegroundColor Green
}

function Stop-Script {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "ERROR: $Message" -ForegroundColor Red
    exit 1
}

# Non-domain trace output (Scripts\ is non-domain per AGENTS.md).
function Write-Trace {
    param([Parameter(Mandatory)][string]$Message)
    Write-Information $Message -Tags 'Trace'
}

# Ask the user a yes/no question. Always 'yes' in assume-yes mode, with the
# auto-answer printed so the transcript still shows the step.
function Confirm-Prompt {
    param([Parameter(Mandatory)][string]$Message)
    if ($script:AssumeYes) {
        Write-Host "$Message [y/n] y " -NoNewline
        Write-Host '(auto: -Yes)' -ForegroundColor DarkGray
        return $true
    }
    while ($true) {
        $answer = (Read-Host "$Message [y/n]").Trim().ToLower()
        if ($answer -in @('y', 'yes')) { return $true }
        if ($answer -in @('n', 'no')) { return $false }
        Write-Host "  Please answer 'y' or 'n'."
    }
}

# --- identity tokens --------------------------------------------------------

# Built from pieces on purpose: Setup-NewProject.ps1 string-replaces the template
# name and owner placeholders across every text file in a child. Assembling the
# tokens here keeps those contiguous strings out of this file so a child's setup
# run cannot rewrite (and break) the tool's own constants. This mirrors the
# Python compare_to_template.py, which builds its identity tokens the same way.
$script:TemplateName = 'Powershell' + 'RepoTemplate'
$script:OwnerToken = 'FIX' + 'ME'

# The two TEMPLATE SETUP NOTES banner forms, taken verbatim from the strip step
# in Scripts\Setup-NewProject.ps1 (markdown comment block and hash block).
$script:MarkdownBanner =
    '(?ms)^<!--\s*\r?\n=+\r?\nTEMPLATE SETUP NOTES.*?-->\s*\r?\n'
$script:HashBanner =
    '(?ms)^# =+\s*\r?\n# TEMPLATE SETUP NOTES.*?\r?\n# =+\s*\r?\n'

# Extracts a script's own $ScriptVersion. Anchored to line start so the
# SuppressMessageAttribute line above the declaration cannot match. Escaped
# quotes are doubled for the single-quoted PowerShell string.
$script:VersionPattern = '(?m)^\s*\$ScriptVersion\s*=\s*[''"]([^''"]+)[''"]'

# Directories scanned (non-recursively) for versioned scripts. Tests\Pester is
# deliberately excluded: those are the child's tests, not template tooling.
$script:VersionedDirs = @(
    '.'
    'Build'
    'Tests'
    'Scripts'
    'Scripts/Debug'
    'Source/ScriptsToProcess'
)

# Versioned template scripts to keep OUT of the copy workflow. The template (the
# parent) owns this list: a discovered versioned file whose '/'-relative path
# matches one of these -like glob patterns is dropped during discovery, so it is
# never version-checked, never offered for copy, and never shown -- exactly as if
# it declared no $ScriptVersion. Populate it with template-internal tooling that
# should not propagate to children (for example 'Scripts/Debug/*').
$script:VersionedExclude = @(
    'Tests.ps1'
    'Source/ScriptsToProcess/Install-Dependencies.ps1'
)

# One non-versioned tracked file. {NAME} in a path is the module name, replaced
# per side (the dev-loader .psm1 is renamed in a child). Required: a missing one
# is drift. Strict: content drift is an error (vs 'review' only). ExistenceOnly:
# a present file matches whatever its contents (the child rewrites it).
function New-Entry {
    param(
        [Parameter(Mandatory)][string]$Path,
        [bool]$Required = $true,
        [bool]$Strict = $true,
        [bool]$ExistenceOnly = $false
    )
    return [pscustomobject]@{
        Path          = $Path
        Required       = $Required
        Strict         = $Strict
        ExistenceOnly = $ExistenceOnly
    }
}

# Non-versioned tracked files. Versioned files (scripts carrying $ScriptVersion)
# are discovered separately by Get-VersionedRelPath.
$script:Manifest = @(
    # GitHub automation and templates.
    (New-Entry '.github/workflows/ci.yml')
    (New-Entry '.github/workflows/docs.yml' -Required $false)
    (New-Entry '.github/dependabot.yml')
    (New-Entry '.github/pull_request_template.md')
    (New-Entry '.github/ISSUE_TEMPLATE/bug_report.yml')
    (New-Entry '.github/ISSUE_TEMPLATE/feature_request.yml')
    (New-Entry '.github/ISSUE_TEMPLATE/config.yml')
    # Editor / lint / format / hygiene config.
    (New-Entry '.editorconfig')
    (New-Entry '.gitattributes')
    (New-Entry '.pre-commit-config.yaml')
    (New-Entry '.gitignore' -ExistenceOnly $true)
    (New-Entry '.secrets.baseline' -ExistenceOnly $true)
    # Agent and contributor docs.
    (New-Entry 'AGENTS.md' -Strict $false)
    (New-Entry 'AGENTS.RELEASING.md')
    (New-Entry 'AGENTS.TESTING.md')
    (New-Entry 'AGENTS.WORKTREE.md')
    (New-Entry 'CLAUDE.md')
    (New-Entry 'CONTRIBUTING.md')
    (New-Entry 'SECURITY.md')
    (New-Entry 'README.md' -ExistenceOnly $true)
    # Module scaffolding that tracks the template (normalized for the name).
    (New-Entry 'Source/Build.psd1')
    (New-Entry 'Source/ScriptsToProcess/Confirm-Dependencies.ps1')
    (New-Entry 'Source/ScriptsToProcess/Install-Dependencies.ps1')
    # Editor / docs-site config (per-project; reviewed, not enforced).
    (New-Entry 'mkdocs.yml' -Required $false -Strict $false)
)

# --- pure helpers -----------------------------------------------------------

# Read a file as raw text, treating an empty file as ''.
function Get-RawText {
    param([Parameter(Mandatory)][string]$Path)
    $text = Get-Content -LiteralPath $Path -Raw
    if ($null -eq $text) { return '' }
    return $text
}

# Join a '/'-separated relative path onto a root using native separators.
function Join-Rel {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Rel
    )
    $native = $Rel.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
    return Join-Path -Path $Root -ChildPath $native
}

# Normalize CRLF/CR line endings to LF so checkouts compare equal.
function Convert-Eol {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    return $Text.Replace("`r`n", "`n").Replace("`r", "`n")
}

# Remove the TEMPLATE SETUP NOTES banner blocks, if present.
function Remove-TemplateBanner {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    return ($Text -replace $script:MarkdownBanner, '' -replace $script:HashBanner, '')
}

# Extract a script's declared $ScriptVersion, or $null when it declares none.
function Get-ScriptVersion {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $match = [regex]::Match($Text, $script:VersionPattern)
    if ($match.Success) { return $match.Groups[1].Value }
    return $null
}

# Parse a GitHub owner from a remote URL (SSH or HTTPS forms). Non-GitHub
# remotes yield $null, mirroring the Python github_user_from_url.
function Get-OwnerFromUrl {
    param([Parameter(Mandatory)][string]$Url)
    if ($Url -match 'github\.com[:/]([A-Za-z0-9-]+)/') {
        return $Matches[1]
    }
    return $null
}

# Decide what the pre-flight should do about the child's copy of a versioned
# file. Ported from the Python self_check_action.
function Get-VersionAction {
    param(
        [Parameter()][AllowNull()][string]$TemplateVersion,
        [Parameter()][AllowNull()][string]$ChildVersion,
        [Parameter(Mandatory)][bool]$SameContent
    )
    if ($SameContent) { return 'ok' }
    $tv = $null
    $cv = $null
    $tParsed = $TemplateVersion -and [version]::TryParse($TemplateVersion, [ref]$tv)
    $cParsed = $ChildVersion -and [version]::TryParse($ChildVersion, [ref]$cv)
    if (-not $tParsed -or -not $cParsed) { return 'update' }
    if ($cv -gt $tv) { return 'ahead' }
    if ($cv -lt $tv) { return 'update' }
    return 'refresh'
}

# Substitute the template's identity tokens (module name, GitHub owner) with the
# child's, exactly as Setup-NewProject.ps1 did. Used both to normalize for
# comparison and to rewrite a file copied into the child, so a copy never carries
# the raw template placeholders back into the child.
function Convert-TemplateToken {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $out = $Text -replace [regex]::Escape($script:TemplateName), $script:ChildName
    if ($script:ChildOwner) {
        $token = $script:OwnerToken
        $pagesFrom = "$token.github.io/$token"
        $pagesTo = "$($script:ChildOwner).github.io/$($script:ChildName)"
        $ownerFrom = "$token/$token"
        $ownerTo = "$($script:ChildOwner)/$($script:ChildName)"
        $out = $out -replace [regex]::Escape($pagesFrom), $pagesTo
        $out = $out -replace [regex]::Escape($ownerFrom), $ownerTo
    }
    return $out
}

# Replay the template-setup transformations onto template-side content so an
# unmodified child compares equal. Order matters: EOL, banner, then tokens.
function ConvertTo-NormalizedTemplate {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    return (Convert-TemplateToken (Remove-TemplateBanner (Convert-Eol $Text)))
}

# Normalize child-side content: EOL, plus a defensive banner strip in case the
# setup step was skipped.
function ConvertTo-NormalizedChild {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    return (Remove-TemplateBanner (Convert-Eol $Text))
}

# --- versioned discovery ----------------------------------------------------

# True when the template excludes a versioned file from the copy workflow via
# $script:VersionedExclude. Matched with -like against the '/'-relative path.
function Test-VersionedExcluded {
    param([Parameter(Mandatory)][string]$Rel)
    foreach ($pattern in $script:VersionedExclude) {
        if ($Rel -like $pattern) { return $true }
    }
    return $false
}

# Return the '/'-relative paths of versioned template files (those declaring a
# single $ScriptVersion), discovered under VersionedDirs. The build/test hook
# stubs (Pre/PostBuild, Pre/PostTests) deliberately carry no $ScriptVersion --
# they are child customization points -- so they are not discovered here; they
# are compared as lenient non-versioned files (see the manifest). Files the
# template lists in $script:VersionedExclude are dropped here too, so an excluded
# script never reaches the pre-flight or the report.
function Get-VersionedRelPath {
    param([Parameter(Mandatory)][string]$TemplateRoot)
    $FunctionName = $MyInvocation.MyCommand.Name
    $found = [System.Collections.Generic.List[string]]::new()
    foreach ($dir in $script:VersionedDirs) {
        $full = if ($dir -eq '.') { $TemplateRoot } else { Join-Rel $TemplateRoot $dir }
        if (-not (Test-Path -LiteralPath $full)) { continue }
        $files = Get-ChildItem -LiteralPath $full -Filter '*.ps1' -File
        foreach ($file in $files) {
            if (-not (Get-ScriptVersion (Get-RawText $file.FullName))) { continue }
            $abs = [System.IO.Path]::GetRelativePath($TemplateRoot, $file.FullName)
            $rel = $abs.Replace('\', '/')
            if (Test-VersionedExcluded $rel) {
                Write-Trace "${FunctionName}: excluded '$rel'"
                continue
            }
            $found.Add($rel)
            Write-Trace "${FunctionName}: versioned file '$rel'"
        }
    }
    return $found
}

# A versioned file whose absence in the child is not drift: the one-time setup
# script (usually deleted after use) and the optional debug helpers.
function Test-OptionalVersioned {
    param([Parameter(Mandatory)][string]$Rel)
    if ($Rel -eq 'Scripts/Setup-NewProject.ps1') { return $true }
    if ($Rel -like 'Scripts/Debug/*') { return $true }
    return $false
}

# --- versioned pre-flight ---------------------------------------------------

# Write the template's copy into the child, substituting the identity tokens
# first. Token-free files are copied byte-for-byte (preserving encoding and line
# endings); only name/owner-bearing files are rewritten.
function Write-ChildFile {
    param(
        [Parameter(Mandatory)][string]$From,
        [Parameter(Mandatory)][string]$To
    )
    $dir = Split-Path -Path $To -Parent
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $text = Get-RawText $From
    $transformed = Convert-TemplateToken $text
    if ($transformed -ceq $text) {
        Copy-Item -LiteralPath $From -Destination $To -Force
    } else {
        Set-Content -LiteralPath $To -Value $transformed -NoNewline -Encoding utf8
    }
}

# Compare one versioned file and, when allowed, offer to update the child's copy.
# Returns 'wrote' when the child's copy was written, 'flagged' when the file needs
# attention but was not written, or 'ok' when nothing was reported.
function Update-VersionedFile {
    param(
        [Parameter(Mandatory)][string]$Rel,
        [Parameter(Mandatory)][string]$TemplateRoot,
        [Parameter(Mandatory)][string]$ChildRoot,
        [Parameter(Mandatory)][bool]$AllowUpdate
    )
    $FunctionName = $MyInvocation.MyCommand.Name
    $templatePath = Join-Rel $TemplateRoot $Rel
    $childPath = Join-Rel $ChildRoot $Rel
    $optional = Test-OptionalVersioned $Rel

    if (-not (Test-Path -LiteralPath $templatePath)) {
        Write-Warn "  The template has no $Rel; skipping."
        return 'flagged'
    }
    $templateText = Get-RawText $templatePath
    $templateVersion = Get-ScriptVersion $templateText

    if (-not (Test-Path -LiteralPath $childPath)) {
        if ($optional) { return 'ok' }
        $shown = if ($templateVersion) { $templateVersion } else { 'unversioned' }
        Write-Warn "  The child is missing $Rel (template $shown)."
        if ($AllowUpdate -and (Confirm-Prompt "  Copy $Rel from the template into the child?")) {
            Write-ChildFile -From $templatePath -To $childPath
            Write-Success "  Installed $Rel."
            return 'wrote'
        }
        return 'flagged'
    }

    $childText = Get-RawText $childPath
    $childVersion = Get-ScriptVersion $childText
    # Compare after replaying the setup transforms so a versioned file that differs
    # only by the name/owner substitution is not read as drift.
    $same = (ConvertTo-NormalizedTemplate $templateText) -ceq (ConvertTo-NormalizedChild $childText)
    $actionParams = @{
        TemplateVersion = $templateVersion
        ChildVersion    = $childVersion
        SameContent     = $same
    }
    $action = Get-VersionAction @actionParams
    Write-Trace "${FunctionName}: $Rel action=$action"
    if ($action -eq 'ok') { return 'ok' }

    $templateShown = if ($templateVersion) { $templateVersion } else { 'unversioned' }
    $childShown = if ($childVersion) { $childVersion } else { 'unversioned' }
    Write-Info $Rel "template $templateShown, child $childShown"
    if ($action -eq 'ahead') {
        Write-Warn "  The child's copy of $Rel is NEWER than the template's."
        Write-Warn '  Consider upstreaming the change to the template; not overwriting it.'
        return 'flagged'
    }
    if ($action -eq 'update') {
        Write-Warn '  The child''s copy is outdated.'
    } else {
        Write-Warn '  The copies share a version but their contents differ (missing bump?).'
    }
    if (-not $AllowUpdate) {
        Write-Warn '  Skipping the update offer (-NoUpdate).'
        return 'flagged'
    }
    if (-not (Confirm-Prompt "  Update the child's copy of $Rel from the template?")) {
        Write-Warn '  Keeping the current copy.'
        return 'flagged'
    }
    Write-ChildFile -From $templatePath -To $childPath
    Write-Success "  Updated $Rel."
    return 'wrote'
}

# Compare every versioned file and offer to update the child's copies. When the
# running script replaces itself, exit afterwards so the user re-runs the new
# version (with its current manifest).
function Invoke-VersionedPreflight {
    param(
        [Parameter(Mandatory)][string]$TemplateRoot,
        [Parameter(Mandatory)][string]$ChildRoot,
        [Parameter(Mandatory)][bool]$AllowUpdate
    )
    Write-Section 'Versioned files'
    $selfPath = (Resolve-Path -LiteralPath $PSCommandPath).Path
    $attention = 0
    $replacedSelf = $false
    foreach ($rel in (Get-VersionedRelPath -TemplateRoot $TemplateRoot)) {
        $updateParams = @{
            Rel          = $rel
            TemplateRoot = $TemplateRoot
            ChildRoot    = $ChildRoot
            AllowUpdate  = $AllowUpdate
        }
        $status = Update-VersionedFile @updateParams
        if ($status -ne 'ok') { $attention++ }
        if ($status -ne 'wrote') { continue }
        $childPath = Join-Rel $ChildRoot $rel
        if ((Resolve-Path -LiteralPath $childPath).Path -eq $selfPath) {
            $replacedSelf = $true
        }
    }
    if ($attention -eq 0) {
        Write-Success '  All versioned files are up to date with the template.'
    }
    if ($replacedSelf) {
        Write-Host '  This script was updated; re-run it to use the new version.'
        exit 0
    }
}

# --- non-versioned comparison -----------------------------------------------

# Compare one manifest entry. Returns a result object carrying the normalized
# texts (for -Diff) when the contents differ.
function Compare-Entry {
    param(
        [Parameter(Mandatory)][pscustomobject]$Entry,
        [Parameter(Mandatory)][string]$TemplateRoot,
        [Parameter(Mandatory)][string]$ChildRoot
    )
    $templateRel = $Entry.Path.Replace('{NAME}', $script:TemplateName)
    $childRel = $Entry.Path.Replace('{NAME}', $script:ChildName)
    $templatePath = Join-Rel $TemplateRoot $templateRel
    $childPath = Join-Rel $ChildRoot $childRel

    $result = [pscustomobject]@{
        ChildRel     = $childRel
        Status       = 'match'
        Note         = ''
        HasText      = $false
        TemplateNorm = ''
        ChildNorm    = ''
    }

    if (-not (Test-Path -LiteralPath $templatePath)) {
        $result.Status = 'no-template'
        $result.Note = ' (not in this template checkout)'
        return $result
    }
    if (-not (Test-Path -LiteralPath $childPath)) {
        $result.Status = if ($Entry.Required) { 'missing' } else { 'absent' }
        return $result
    }
    if ($Entry.ExistenceOnly) {
        $result.Note = ' (exists; contents not compared)'
        return $result
    }

    $templateNorm = ConvertTo-NormalizedTemplate (Get-RawText $templatePath)
    $childNorm = ConvertTo-NormalizedChild (Get-RawText $childPath)
    if ($templateNorm -ceq $childNorm) { return $result }

    $note = ''
    if (-not $Entry.Strict) { $note = ' (expected to differ)' }
    if ($childNorm -match [regex]::Escape($script:TemplateName)) {
        $note += ' (child still has the template name; setup incomplete?)'
    }
    $result.Status = if ($Entry.Strict) { 'modified' } else { 'review' }
    $result.Note = $note
    $result.HasText = $true
    $result.TemplateNorm = $templateNorm
    $result.ChildNorm = $childNorm
    return $result
}

$script:StatusColors = @{
    'modified'    = 'Red'
    'missing'     = 'Red'
    'review'      = 'Yellow'
    'no-template' = 'Yellow'
    'match'       = 'Green'
    'absent'      = 'DarkGray'
}

function Write-Report {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Results,
        [Parameter(Mandatory)][bool]$ShowAll
    )
    $shown = $Results | Where-Object { $ShowAll -or $_.Status -notin @('match', 'absent') }
    if (-not $shown) {
        Write-Success '  All compared files match the template.'
        return
    }
    foreach ($result in $shown) {
        $color = $script:StatusColors[$result.Status]
        Write-Host "  $($result.Status.PadRight(12))" -ForegroundColor $color -NoNewline
        Write-Host $result.ChildRel -NoNewline
        Write-Host $result.Note -ForegroundColor DarkGray
    }
}

# --- diff -------------------------------------------------------------------

# Open each differing file as a side-by-side diff. The template's normalized text
# exists nowhere on disk, so it is written to a temp file. With the editor, the
# child's LIVE file is opened so edits land in the real file; the git fallback
# diffs the two normalized temp files for a noise-free view.
function Show-Diff {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Results,
        [Parameter(Mandatory)][string]$ChildRoot,
        [Parameter(Mandatory)][string]$DiffTool
    )
    $diffs = $Results | Where-Object { $_.Status -in @('modified', 'review') -and $_.HasText }
    if (-not $diffs) {
        Write-Warn '  No differences to open.'
        return
    }
    $tool = Get-Command $DiffTool -ErrorAction SilentlyContinue
    $tempName = 'Compare-Template-' + [System.IO.Path]::GetRandomFileName()
    $tempDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath $tempName
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

    if ($tool) {
        Write-Section "Diffs ($DiffTool)"
    } else {
        Write-Warn "  '$DiffTool' not found on PATH; printing diffs with git."
    }

    $index = 0
    foreach ($result in $diffs) {
        $index++
        $leaf = Split-Path -Path $result.ChildRel -Leaf
        $templateTemp = Join-Path -Path $tempDir -ChildPath "$index-template-$leaf"
        Set-Content -LiteralPath $templateTemp -Value $result.TemplateNorm -NoNewline -Encoding utf8
        if ($tool) {
            $childLive = Join-Rel $ChildRoot $result.ChildRel
            & $DiffTool --diff $templateTemp $childLive
        } else {
            $childTemp = Join-Path -Path $tempDir -ChildPath "$index-child-$leaf"
            Set-Content -LiteralPath $childTemp -Value $result.ChildNorm -NoNewline -Encoding utf8
            Write-Section "Diff: $($result.ChildRel)"
            $gitArgs = @('--no-pager', '-c', 'color.ui=always', '-c', 'core.autocrlf=false',
                'diff', '--no-index', '--', $templateTemp, $childTemp)
            Write-Echo "git $($gitArgs -join ' ')"
            & git @gitArgs
        }
    }
    if ($tool) {
        Write-Success "  Opened $($diffs.Count) diff(s) with $DiffTool."
    }
}

# --- orientation ------------------------------------------------------------

# The child's module name: the basename of its source manifest (excluding
# ModuleBuilder's Build.psd1), mirroring Build.ps1's discovery.
function Get-ModuleName {
    param([Parameter(Mandatory)][string]$Root)
    $sourceDir = Join-Path -Path $Root -ChildPath 'Source'
    if (-not (Test-Path -LiteralPath $sourceDir)) { return $null }
    $manifest = Get-ChildItem -LiteralPath $sourceDir -Filter '*.psd1' -File |
        Where-Object Name -ne 'Build.psd1' |
        Select-Object -First 1
    if ($manifest) { return $manifest.BaseName }
    return $null
}

# The child's 'origin' remote URL, or $null when there is none. git is invoked
# directly (not via a wrapper) so its expected non-zero exit does not throw.
function Get-ChildOrigin {
    param([Parameter(Mandatory)][string]$Root)
    $global:LASTEXITCODE = 0
    $url = & git -C $Root remote get-url origin 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $url) { return $null }
    return ($url | Select-Object -First 1).Trim()
}

# --- main -------------------------------------------------------------------

# Pester tests dot-source this script to load the helper functions above without
# running the comparison. When dot-sourced, InvocationName is '.', so stop here;
# the functions and $script: constants are already defined.
if ($MyInvocation.InvocationName -eq '.') { return }

Write-Host 'Compare-Template - template drift report' -ForegroundColor Cyan
Write-Info 'Script version' $ScriptVersion

$childRoot = (Resolve-Path -LiteralPath (Split-Path -Path $PSScriptRoot -Parent)).Path

if (-not $TemplatePath) {
    $parentDir = Split-Path -Path $childRoot -Parent
    $sibling = Join-Path -Path $parentDir -ChildPath $script:TemplateName
    if (-not (Test-Path -LiteralPath $sibling)) {
        Stop-Script ("No template checkout found at '$sibling'. " +
            'Pass -TemplatePath with the template''s location.')
    }
    $TemplatePath = $sibling
}
$templateRoot = (Resolve-Path -LiteralPath $TemplatePath).Path

if ($templateRoot -eq $childRoot) {
    Stop-Script 'The template path and the child repo are the same folder.'
}
if (-not (Test-Path -LiteralPath (Join-Rel $templateRoot 'Scripts/Setup-NewProject.ps1'))) {
    Write-Warn "  '$templateRoot' has no Scripts\Setup-NewProject.ps1; is it the template?"
}

$script:ChildName = Get-ModuleName -Root $childRoot
if (-not $script:ChildName) {
    Stop-Script "Could not find a source manifest under '$childRoot\Source'."
}

$script:ChildOwner = $GitHubUser
if (-not $script:ChildOwner) {
    $url = Get-ChildOrigin -Root $childRoot
    if ($url) { $script:ChildOwner = Get-OwnerFromUrl $url }
}

Write-Section 'Repositories'
Write-Info 'Template' $templateRoot
Write-Info 'Child' $childRoot
Write-Info 'Module name' $script:ChildName
if ($script:ChildOwner) {
    Write-Info 'GitHub owner' $script:ChildOwner
} else {
    Write-Warn '  No GitHub owner found (origin is not a GitHub remote?).'
    Write-Warn '  Owner placeholders will show as drift; pass -GitHubUser to fix.'
}

$preflightParams = @{
    TemplateRoot = $templateRoot
    ChildRoot    = $childRoot
    AllowUpdate  = (-not $NoUpdate)
}
Invoke-VersionedPreflight @preflightParams

$results = @(
    foreach ($entry in $script:Manifest) {
        Compare-Entry -Entry $entry -TemplateRoot $templateRoot -ChildRoot $childRoot
    }
)

Write-Section 'Comparison'
Write-Report -Results $results -ShowAll ([bool]$All)
if ($Diff) {
    Show-Diff -Results $results -ChildRoot $childRoot -DiffTool $DiffTool
}

$counts = @{}
foreach ($status in $script:StatusColors.Keys) {
    $counts[$status] = @($results | Where-Object Status -eq $status).Count
}
$noTemplate = @($results | Where-Object Status -eq 'no-template').Count

Write-Section 'Summary'
Write-Info 'Files compared' "$($results.Count)"
Write-Info 'Match' "$($counts['match'])"
Write-Info 'Modified (drift)' "$($counts['modified'])"
Write-Info 'Missing (drift)' "$($counts['missing'])"
Write-Info 'Review only' "$($counts['review'])"
Write-Info 'Absent (optional)' "$($counts['absent'])"
if ($noTemplate) { Write-Info 'Not in template' "$noTemplate" }

$differing = $counts['modified'] + $counts['review']
if ($differing -and -not $Diff) {
    Write-Host ''
    Write-Host '  Run again with -Diff to see the differences.' -ForegroundColor DarkGray
}

$drift = $counts['modified'] + $counts['missing']
Write-Host ''
if ($drift) {
    Write-Warn "Drift detected in $drift file(s)."
    exit 1
}
Write-Success 'No drift in strict files.'
exit 0
