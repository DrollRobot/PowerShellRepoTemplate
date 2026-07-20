#Requires -Version 7.4
<#
.SYNOPSIS
    Compares a child repo against the template it was created from and offers to
    bring versioned tooling files up to date.

.DESCRIPTION
    A module created from this template (via Scripts\Setup-NewProject.ps1, which
    is config-driven -- see Scripts\setup.psd1) keeps a set of tooling, CI, and
    config files that should track the template as it evolves. Run this script
    from inside the child repo, pointing -TemplatePath at a template checkout, to
    see where the two have drifted.

    Every tracked file is a single manifest entry ($script:Manifest) and always
    goes through the diff-based comparison below. A curated few of those entries
    are ALSO marked -BlindCopy: generic dev tooling (this script itself, the
    worktree helpers, the release script, the docs generator, the dependency
    hook) that a child almost never hand-edits. Those get an extra, earlier
    pre-flight offer to sync straight from the template by version number alone,
    with no diff shown -- so an outdated copy of this script (and its manifest)
    is refreshed before the content comparison runs. Every other tracked file --
    including other scripts that declare their own $ScriptVersion, such as
    Build.ps1 or the Tests\Test-*.ps1 checkers -- is diff-only: never blindly
    copied, always reviewed as a normal drift entry (with a version note shown
    alongside it when both sides parse a version).

    Non-versioned files -- CI workflows, lint/format config, and the AGENTS docs
    -- are compared after replaying the transformations Setup-NewProject.ps1
    applied to the child (module-name and GitHub owner substitution, and
    stripping the TEMPLATE SETUP NOTES banner), so only genuine drift is
    reported. Diff-only entries are never written automatically; pass -Diff to
    review each difference side by side.

    Files the child owns (its Source\ code, the module manifest and its version,
    the changelog, the license, generated docs, Tests.ps1 and its PreTests.ps1 /
    PostTests.ps1 hooks) are not compared at all.

    Manifest entries belonging to a config-driven optional feature (the docs site,
    SECURITY.md, CONTRIBUTING.md, the explicit-module-import check, or one of the
    opinionated formatting checks) are gated on that child's own choice, read from
    Scripts\setup.psd1 -- a feature the child declined is skipped entirely rather
    than reported as missing. One entry (Tests\Test-FindUnwantedStrings.ps1) is
    compared at a different child-side path instead, when the child moved it to
    .local\tests\ ([Features].UnwantedStringsLocal).

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

    Read-only report suitable for CI (throws, a nonzero process exit, on drift).

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
$ScriptVersion = '2.0.1'

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

# Throws (not `exit`s): `exit` can close the whole calling host session, not
# just this script, if it is ever run directly at an interactive prompt.
function Stop-Script {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "ERROR: $Message" -ForegroundColor Red
    throw $Message
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

# One tracked file. {NAME} in a path is the module name, replaced per side (the
# dev-loader .psm1 is renamed in a child). Required: a missing one is drift.
# Strict: content drift is an error (vs 'review' only). ExistenceOnly: a present
# file matches whatever its contents (the child rewrites it). BlindCopy: this
# entry is also offered in the versioned pre-flight (Invoke-VersionedPreflight)
# -- a low-friction, no-diff version-number-based sync -- on top of always going
# through the normal diff comparison below. Reserved for a short, curated list
# of generic dev tooling nobody hand-edits; everything else that happens to
# declare $ScriptVersion is still diff-only.
#
# Gate: name of a Scripts\setup.psd1 [Features] flag (see Get-ChildFeatureFlag).
# When the child's config has that flag set to false, this entry is dropped
# from comparison entirely -- never reported as missing, never offered for
# copy -- exactly like a feature the child deliberately declined at setup.
# $null (the default) means always applicable.
#
# LocalOverrideFlag / LocalOverridePath: for the one entry (currently just
# Test-FindUnwantedStrings.ps1) whose child-side location depends on a config
# choice rather than being present-or-absent. When the named flag is true,
# Get-ApplicableManifest sets ChildPath to LocalOverridePath; Compare-Entry
# then reads the CHILD from ChildPath while still reading the TEMPLATE from
# Path -- the two must stay independent, since the template's own copy never
# moves. ChildPath starts equal to Path (the common case: same relative path
# on both sides) and is the only field Get-ApplicableManifest ever rewrites.
function New-Entry {
    param(
        [Parameter(Mandatory)][string]$Path,
        [bool]$Required = $true,
        [bool]$Strict = $true,
        [bool]$ExistenceOnly = $false,
        [bool]$BlindCopy = $false,
        [string]$Gate = $null,
        [string]$LocalOverrideFlag = $null,
        [string]$LocalOverridePath = $null
    )
    return [pscustomobject]@{
        Path              = $Path
        ChildPath         = $Path
        Required          = $Required
        Strict            = $Strict
        ExistenceOnly     = $ExistenceOnly
        BlindCopy         = $BlindCopy
        Gate              = $Gate
        LocalOverrideFlag = $LocalOverrideFlag
        LocalOverridePath = $LocalOverridePath
    }
}

# Every tracked file. Versioned dev scripts are listed explicitly below, either
# as -BlindCopy (curated whitelist, offered for a no-diff sync) or diff-only
# (everything else that carries $ScriptVersion) -- see New-Entry above.
$script:Manifest = @(
    # GitHub automation and templates.
    (New-Entry '.github/workflows/ci.yml')
    (New-Entry '.github/workflows/docs.yml' -Required $false -Gate 'Docs')
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
    (New-Entry 'CONTRIBUTING.md' -Gate 'ContributingMd')
    (New-Entry 'SECURITY.md' -Gate 'SecurityMd')
    (New-Entry 'README.md' -ExistenceOnly $true)
    # Config-driven setup's own input file: content is this project's choices,
    # never the template's, but the file itself must stay present.
    (New-Entry 'Scripts/setup.psd1' -ExistenceOnly $true)
    # Module scaffolding that tracks the template (normalized for the name).
    (New-Entry 'Source/Build.psd1')
    (New-Entry 'Source/ScriptsToProcess/Confirm-Dependencies.ps1' -BlindCopy $true)
    # Has a '# FIXME: optionally mirror...' hand-edit block -- diff-only, lenient.
    (New-Entry 'Source/ScriptsToProcess/Install-Dependencies.ps1' -Strict $false)
    # Documentation site: mkdocs.yml plus the PlatyPS-driven Docs.ps1 above and
    # the docs.yml workflow above. All three share the 'Docs' gate.
    (New-Entry 'mkdocs.yml' -Required $false -Strict $false -Gate 'Docs')
    # Generic dev tooling, curated whitelist: nobody hand-edits these, so they
    # get the low-friction version-based sync on top of the normal diff.
    (New-Entry 'Docs.ps1' -BlindCopy $true -Gate 'Docs')
    (New-Entry 'Scripts/Compare-Template.ps1' -BlindCopy $true)
    (New-Entry 'Scripts/Complete-WorkTree.ps1' -BlindCopy $true)
    (New-Entry 'Scripts/New-Worktree.ps1' -BlindCopy $true)
    (New-Entry 'Scripts/Push-NewTagToMain.ps1' -BlindCopy $true)
    (New-Entry 'Scripts/Remove-WorkTree.ps1' -BlindCopy $true)
    # Other versioned dev scripts: tracked, but diff-only -- reviewed, never
    # blindly overwritten.
    (New-Entry 'Build.ps1')
    # Used by nothing except the explicit-module-import check below; all three
    # share the 'ExplicitModuleImport' gate.
    (New-Entry 'Scripts/Find-ScriptCommand.ps1' -Gate 'ExplicitModuleImport')
    (New-Entry 'Scripts/Resolve-CommandModule.ps1' -Gate 'ExplicitModuleImport')
    # One-time setup script; usually deleted after use.
    (New-Entry 'Scripts/Setup-NewProject.ps1' -Required $false)
    (New-Entry 'Tests/Test-BacktickContinuation.ps1' -Gate 'BacktickContinuation')
    (New-Entry 'Tests/Test-ExplicitModuleImport.ps1' -Gate 'ExplicitModuleImport')
    # Its $UnwantedPatterns has no external override hook -- a genuine
    # per-project hand-edit point, unlike this file's exclusions. Its child-side
    # location depends on [Features].UnwantedStringsLocal rather than being
    # simply present or absent, hence LocalOverride* instead of Gate.
    $UnwantedStringsParams = @{
        Strict            = $false
        LocalOverrideFlag = 'UnwantedStringsLocal'
        LocalOverridePath = '.local/tests/Test-FindUnwantedStrings.ps1'
    }
    (New-Entry 'Tests/Test-FindUnwantedStrings.ps1' @UnwantedStringsParams)
    (New-Entry 'Tests/Test-FixmeComments.ps1')
    (New-Entry 'Tests/Test-FormatOperator.ps1' -Gate 'FormatOperator')
    (New-Entry 'Tests/Test-JoinPath.ps1')
    (New-Entry 'Tests/Test-LineLength.ps1')
    (New-Entry 'Tests/Test-ModuleSyntax.ps1')
    (New-Entry 'Tests/Test-NonASCIICharacters.ps1' -Gate 'NonASCIICharacters')
    (New-Entry 'Tests/Test-PSSA.ps1')
    (New-Entry 'Tests/Test-WriteVerboseDebug.ps1' -Gate 'WriteVerboseDebug')
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

# Describe how two versions of a file relate, for a diff-only manifest entry
# that happens to declare $ScriptVersion on both sides (a -BlindCopy entry
# never reaches this -- its version is already handled by the pre-flight).
# Purely informational; never triggers a copy.
function Get-VersionNote {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$TemplateText,
        [Parameter(Mandatory)][AllowEmptyString()][string]$ChildText
    )
    $templateVersion = Get-ScriptVersion $TemplateText
    $childVersion = Get-ScriptVersion $ChildText
    if (-not $templateVersion -or -not $childVersion) { return '' }
    $tv = $null
    $cv = $null
    $tParsed = [version]::TryParse($templateVersion, [ref]$tv)
    $cParsed = [version]::TryParse($childVersion, [ref]$cv)
    if (-not $tParsed -or -not $cParsed) { return '' }
    if ($cv -lt $tv) {
        return " (child $childVersion < template ${templateVersion}: outdated)"
    }
    if ($cv -gt $tv) {
        return " (child $childVersion > template ${templateVersion}: ahead - upstream?)"
    }
    return " (both ${templateVersion}: changed without a version bump?)"
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

# --- versioned pre-flight ---------------------------------------------------
#
# The versioned pre-flight below runs only over $script:Manifest entries marked
# -BlindCopy (see New-Entry) -- a short, curated whitelist of generic dev
# tooling. Every other manifest entry, whitelisted or not, still goes through
# the diff-based comparison further down (Compare-Entry).

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

# Compare one whitelisted (-BlindCopy) manifest entry and, when allowed, offer to
# update the child's copy. Returns 'wrote' when the child's copy was written,
# 'flagged' when the file needs attention but was not written, or 'ok' when
# nothing was reported.
function Update-VersionedFile {
    param(
        [Parameter(Mandatory)][pscustomobject]$Entry,
        [Parameter(Mandatory)][string]$TemplateRoot,
        [Parameter(Mandatory)][string]$ChildRoot,
        [Parameter(Mandatory)][bool]$AllowUpdate
    )
    $FunctionName = $MyInvocation.MyCommand.Name
    $Rel = $Entry.Path
    $templatePath = Join-Rel $TemplateRoot $Rel
    $childPath = Join-Rel $ChildRoot $Entry.ChildPath

    if (-not (Test-Path -LiteralPath $templatePath)) {
        Write-Warn "  The template has no $Rel; skipping."
        return 'flagged'
    }
    $templateText = Get-RawText $templatePath
    $templateVersion = Get-ScriptVersion $templateText

    if (-not (Test-Path -LiteralPath $childPath)) {
        if (-not $Entry.Required) { return 'ok' }
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

# Compare every -BlindCopy entry in $Entries (the caller's already feature-filtered manifest)
# and offer to update the child's copies. When the running script replaces itself, exit
# afterwards so the user re-runs the new version (with its current manifest).
function Invoke-VersionedPreflight {
    <#
    .OUTPUTS
        System.Boolean. $true if this script itself was replaced by a newer
        template version -- the caller must stop immediately in that case
        (comparing further would run against a script file that no longer
        matches what is loaded in memory).
    #>
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Entries,
        [Parameter(Mandatory)][string]$TemplateRoot,
        [Parameter(Mandatory)][string]$ChildRoot,
        [Parameter(Mandatory)][bool]$AllowUpdate
    )
    Write-Section 'Versioned files'
    $selfPath = (Resolve-Path -LiteralPath $PSCommandPath).Path
    $attention = 0
    $replacedSelf = $false
    foreach ($entry in ($Entries | Where-Object BlindCopy)) {
        $updateParams = @{
            Entry        = $entry
            TemplateRoot = $TemplateRoot
            ChildRoot    = $ChildRoot
            AllowUpdate  = $AllowUpdate
        }
        $status = Update-VersionedFile @updateParams
        if ($status -ne 'ok') { $attention++ }
        if ($status -ne 'wrote') { continue }
        $childPath = Join-Rel $ChildRoot $entry.ChildPath
        if ((Resolve-Path -LiteralPath $childPath).Path -eq $selfPath) {
            $replacedSelf = $true
        }
    }
    if ($attention -eq 0) {
        Write-Success '  All versioned files are up to date with the template.'
    }
    if ($replacedSelf) {
        Write-Host '  This script was updated; re-run it to use the new version.'
    }
    return $replacedSelf
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
    $childRel = $Entry.ChildPath.Replace('{NAME}', $script:ChildName)
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

    $templateRawText = Get-RawText $templatePath
    $childRawText = Get-RawText $childPath
    $templateNorm = ConvertTo-NormalizedTemplate $templateRawText
    $childNorm = ConvertTo-NormalizedChild $childRawText
    if ($templateNorm -ceq $childNorm) { return $result }

    $note = ''
    if (-not $Entry.Strict) { $note = ' (expected to differ)' }
    $note += Get-VersionNote -TemplateText $templateRawText -ChildText $childRawText
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

# Last-resort fallback for the child's GitHub owner: Setup-NewProject.ps1's own
# config file, read directly rather than trusting a possibly-stale git remote
# lookup to have already found one. Only consulted when -GitHubUser was not
# passed and no origin remote resolved to a GitHub owner.
function Get-ConfiguredGitHubUser {
    param([Parameter(Mandatory)][string]$ChildRoot)
    $configPath = Join-Rel $ChildRoot 'Scripts/setup.psd1'
    if (-not (Test-Path -LiteralPath $configPath)) { return $null }
    try {
        $config = Import-PowerShellDataFile -Path $configPath
    }
    catch {
        return $null
    }
    $project = $config['Project']
    if ($project -isnot [hashtable]) { return $null }
    $value = $project['GitHubUser']
    if ($value -is [string] -and $value.Trim()) { return $value }
    return $null
}

# --- feature gating ----------------------------------------------------------

# Every [Features] flag this script understands, and the "keep everything" default
# each takes when the child's Scripts\setup.psd1 is missing, unreadable, or simply
# does not mention that key -- matching what an unedited config means for it.
$script:FeatureDefaults = @{
    Docs                 = $true
    SecurityMd           = $true
    ContributingMd       = $true
    ExplicitModuleImport = $true
    NonASCIICharacters   = $true
    FormatOperator       = $true
    WriteVerboseDebug    = $true
    BacktickContinuation = $true
    UnwantedStringsLocal = $false
}

# Resolve which config-driven features this child kept, from its own Scripts\setup.psd1. Falls
# back to $script:FeatureDefaults wholesale when the file is missing or unreadable, and per-key
# when the [Features] table exists but a given key is absent or the wrong type -- mirroring how
# Setup-NewProject.ps1 treats those same conditions.
function Get-ChildFeatureFlag {
    param([Parameter(Mandatory)][string]$ChildRoot)
    $flags = $script:FeatureDefaults.Clone()
    $configPath = Join-Rel $ChildRoot 'Scripts/setup.psd1'
    if (-not (Test-Path -LiteralPath $configPath)) { return $flags }
    try {
        $config = Import-PowerShellDataFile -Path $configPath
    }
    catch {
        return $flags
    }
    $features = $config['Features']
    if ($features -isnot [hashtable]) { return $flags }
    foreach ($key in @($flags.Keys)) {
        if ($features[$key] -is [bool]) {
            $flags[$key] = $features[$key]
        }
    }
    return $flags
}

# .pre-commit-config.yaml is edited in place -- one hook block removed -- by
# Invoke-RemoveFormattingTest whenever any of these four checks is declined
# (see Scripts\Setup-NewProject.ps1). Get-ApplicableManifest reports the
# resulting difference for review instead of as strict drift, the same way
# Python's remove_mkdocs.py-edited files (CONTRIBUTING.md, AGENTS.RELEASING.md
# in that template) are compared leniently once the feature they describe is
# actually gone.
$script:PreCommitFormattingGates = @(
    'NonASCIICharacters', 'FormatOperator', 'WriteVerboseDebug', 'BacktickContinuation'
)

# Split $script:Manifest into the entries applicable to this child's feature choices (Applicable)
# and the ones tied to a declined feature (Skipped). Returns new entry objects; $script:Manifest
# itself is never mutated, so repeated calls (and the Pester tests, which assert against the raw
# manifest) stay unaffected. Two per-entry adjustments happen here, each only via a cloned copy:
#   - LocalOverrideFlag true: ChildPath swaps to LocalOverridePath. Path (the template-side
#     location) is deliberately left untouched, since the template's own copy never moves.
#   - .pre-commit-config.yaml, when any $script:PreCommitFormattingGates flag is false: Strict
#     downgrades to false (see comment above).
function Get-ApplicableManifest {
    param([Parameter(Mandatory)][hashtable]$Flags)
    $applicable = [System.Collections.Generic.List[pscustomobject]]::new()
    $skipped = [System.Collections.Generic.List[pscustomobject]]::new()
    $preCommitEdited = $false
    foreach ($gate in $script:PreCommitFormattingGates) {
        if (-not $Flags[$gate]) { $preCommitEdited = $true }
    }
    foreach ($entry in $script:Manifest) {
        if ($entry.Gate -and -not $Flags[$entry.Gate]) {
            $skipped.Add($entry)
            continue
        }
        if ($entry.LocalOverrideFlag -and $Flags[$entry.LocalOverrideFlag]) {
            $entry = $entry.PSObject.Copy()
            $entry.ChildPath = $entry.LocalOverridePath
        }
        if ($preCommitEdited -and $entry.Path -eq '.pre-commit-config.yaml') {
            $entry = $entry.PSObject.Copy()
            $entry.Strict = $false
        }
        $applicable.Add($entry)
    }
    return [pscustomobject]@{ Applicable = $applicable; Skipped = $skipped }
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
if (-not $script:ChildOwner) {
    $script:ChildOwner = Get-ConfiguredGitHubUser -ChildRoot $childRoot
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

$childFlags = Get-ChildFeatureFlag -ChildRoot $childRoot
Write-Section 'Feature configuration'
foreach ($featureName in $script:FeatureDefaults.Keys | Sort-Object) {
    $state = if ($childFlags[$featureName]) { 'on' } else { 'off' }
    Write-Info $featureName $state
}
$manifestSplit = Get-ApplicableManifest -Flags $childFlags
$applicableEntries = $manifestSplit.Applicable

$preflightParams = @{
    Entries      = $applicableEntries
    TemplateRoot = $templateRoot
    ChildRoot    = $childRoot
    AllowUpdate  = (-not $NoUpdate)
}
# Stop entirely if the preflight replaced this script itself: comparing
# further would run against a script file that no longer matches what is
# loaded in memory.
if (Invoke-VersionedPreflight @preflightParams) { return }

$results = @(
    foreach ($entry in $applicableEntries) {
        Compare-Entry -Entry $entry -TemplateRoot $templateRoot -ChildRoot $childRoot
    }
)

Write-Section 'Comparison'
if ($manifestSplit.Skipped.Count -gt 0) {
    $SkipMsg = "  Skipping $($manifestSplit.Skipped.Count) file(s) tied to features " +
    'this child declined:'
    Write-Warn $SkipMsg
    foreach ($skippedEntry in $manifestSplit.Skipped) {
        Write-Host "    $($skippedEntry.Path)"
    }
}
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
    throw "Drift detected in $drift file(s)."
}
Write-Success 'No drift in strict files.'
