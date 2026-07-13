#Requires -Version 7.4

<#
.SYNOPSIS
    Interactively complete a worktree: verify it is committed, push the branch,
    and open a pull request against the integration branch from PR.md.

.DESCRIPTION
    Picks up where the agent leaves off. Once the feature/fix is committed and a
    PR description has been written to PR.md, this walks through the remaining
    steps one at a time. Before each action it shows what is about to happen and
    prompts for confirmation (y/n); answering 'n' aborts without taking the
    remaining steps. The output of every git and gh command is shown.

    The procedure:
      1. Confirm we are on a wt/ branch in a worktree (never the integration
         or release branch).
      2. Verify the working tree is clean -- everything is committed. PR.md
         itself is exempt; it may stay uncommitted since it only feeds
         `gh pr create`.
      3. Resolve the PR base: the base recorded at worktree creation
         (branch.<branch>.prBase) if present, else the branch's upstream -- but
         only while it still names an integration branch, since `git push -u` repoints
         tracking to the branch itself. Refuses to target main.
      4. Show the PR.md body and confirm the title.
      5. Push the branch with -u.
      6. Open the PR with `gh pr create --base <base> --body-file PR.md`.
      7. Report the PR URL and stop. The worktree is NOT cleaned up -- that is
         left to the user (see Remove-WorkTree.ps1).

    Pass -Yes to answer every prompt with 'y' for non-interactive use.

    Cross-device handoff (push on one device, open the PR on another):
      - On the device with the worktree, run with -PushPRToNotes. It verifies
        and pushes the branch, then attaches PR.md (with the base and title) as
        a per-slug git note (refs/notes/pr-body-<slug>) and pushes that note to
        origin. The note rides on the commit, so it never appears in the PR
        diff; one ref per slug means concurrent PRs never collide. No PR is
        created and gh is not required here.
      - On the other device, run with -GHFromNotes -Slug <slug> (creates the PR
        with gh) or -WebFromNotes -Slug <slug> (opens a prefilled PR form in the
        browser; no gh auth needed). Either fetches the branch and the note,
        recovers the base/title/body, creates the PR, and then deletes the note
        from origin.

.PARAMETER Title
    PR title. Defaults to the subject line of the most recent commit (or the
    title carried in the note, for the -*FromNotes modes). The default is shown
    and confirmed with a y/n prompt; answer 'n' to abort and re-run with -Title
    to set a different one.

.PARAMETER Base
    Override the PR base branch. By default it is taken from the base recorded
    when the worktree was created (branch.<branch>.prBase), falling back to the
    branch's upstream when that still names an integration branch, or from the
    note for the -*FromNotes modes. Targeting main is refused unless you pass it
    here.

.PARAMETER BodyFile
    Path to the PR body file. Defaults to PR.md at the worktree root. This file
    does not need to be committed; it is exempt from the clean-tree check.

.PARAMETER Draft
    Open the PR as a draft.

.PARAMETER Yes
    Assume 'yes' to every confirmation prompt (non-interactive). The prompt is
    still printed with the auto-answer so the transcript records each step.

.PARAMETER PushPRToNotes
    Device A: verify and push the branch, then attach PR.md (with base/title) as
    a per-slug 'pr-body-<slug>' git note and push it to origin. No PR created.

.PARAMETER GHFromNotes
    Device B: fetch the branch and the per-slug 'pr-body-<slug>' note for -Slug,
    create the PR with gh, then delete the note from origin. Requires gh
    installed and authenticated.

.PARAMETER WebFromNotes
    Device B: fetch the branch and the per-slug 'pr-body-<slug>' note for -Slug,
    open a prefilled PR form in the browser, then offer to delete the note from
    origin. No gh authentication required.

.PARAMETER Slug
    The worktree slug (the part after 'wt/'), used by -GHFromNotes/-WebFromNotes
    to identify the branch. Defaults to the current branch if it is a wt/ branch.

.EXAMPLE
    .\Complete-WorkTree.ps1

.EXAMPLE
    .\Complete-WorkTree.ps1 -Title "feat(auth): add SSO login" -Draft

.EXAMPLE
    .\Complete-WorkTree.ps1 -PushPRToNotes

.EXAMPLE
    .\Complete-WorkTree.ps1 -WebFromNotes -Slug issue-42

.NOTES
    Requirements:
      - PowerShell 7.4 or later.
      - Run from inside the worktree, on a wt/ branch with all work committed
        (PR.md itself does not need to be committed).
      - `git` and `gh` installed and authenticated (gh not needed for
        -PushPRToNotes or -WebFromNotes).
      - A PR.md body file written by the agent at the worktree root.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPositionalParameters', '')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseShouldProcessForStateChangingFunctions', '')]
[CmdletBinding()]
param(
    [string]$Title,
    [string]$Base,
    [string]$BodyFile = 'PR.md',
    [switch]$Draft,
    [Alias('y')]
    [switch]$Yes,
    [switch]$PushPRToNotes,
    [switch]$GHFromNotes,
    [switch]$WebFromNotes,
    [string]$Slug
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseDeclaredVarsMoreThanAssignments', 'ScriptVersion')]
$ScriptVersion = '1.2.2'

# The cross-device PR-body handoff stores one note per slug
# (refs/notes/pr-body-<slug>) so concurrent PRs never share - or force-push
# over - a single ref. See Get-NotesRef.
$NotesRefPrefix = 'pr-body'

# Answer every confirmation prompt with 'y' (set from -Yes). Script-scoped so
# the helper functions below can read it.
$script:AssumeYes = [bool]$Yes

# --- helpers ---------------------------------------------------------------

function Write-Section {
    param([string]$Title)
    Write-Host ''
    Write-Host "== $Title ==" -ForegroundColor Cyan
}

function Write-Info {
    param([string]$Label, [string]$Value)
    Write-Host "  $("${Label}:".PadRight(18))" -NoNewline -ForegroundColor DarkGray
    Write-Host $Value -ForegroundColor White
}

function Write-Run {
    param([string]$CommandText)
    Write-Host "  > $CommandText" -ForegroundColor DarkGray
}

# $ErrorActionPreference = 'Stop' does NOT halt on a failing native command; it
# only governs cmdlets/terminating errors. Wrap git/gh and check the exit code
# ourselves. Reset the GLOBAL $LASTEXITCODE first so a stale value can't linger.
function Invoke-Native {
    param([string]$Exe, [Parameter(ValueFromRemainingArguments)][string[]]$Arguments)
    $global:LASTEXITCODE = 0
    $output = & $Exe @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Exe $($Arguments -join ' ') failed (exit $LASTEXITCODE)"
    }
    $output
}

# Run a native command and return its output, or $null if it exits non-zero.
# For probes where a non-zero exit is an expected answer (e.g. notes show on a
# commit that has no note), which would otherwise throw under the native error
# preference set above.
function Invoke-NativeOk {
    param([string]$Exe, [Parameter(ValueFromRemainingArguments)][string[]]$Arguments)
    $global:LASTEXITCODE = 0
    try {
        $output = & $Exe @Arguments 2>$null
    }
    catch {
        return $null
    }
    if ($LASTEXITCODE -ne 0) { return $null }
    return $output
}

function Confirm-Step {
    param([string]$Prompt)
    if ($script:AssumeYes) {
        Write-Host "$Prompt [y/n] y " -NoNewline
        Write-Host '(auto: -Yes)' -ForegroundColor DarkGray
        return $true
    }
    while ($true) {
        $answer = (Read-Host "$Prompt [y/n]").Trim().ToLowerInvariant()
        switch ($answer) {
            { $_ -in 'y', 'yes' } { return $true }
            { $_ -in 'n', 'no' } { return $false }
            default { Write-Host "  Please answer 'y' or 'n'." -ForegroundColor Yellow }
        }
    }
}

function Read-WithDefault {
    param([string]$Prompt, [string]$Default)
    if ($script:AssumeYes) {
        Write-Host "$Prompt`n  [$Default]: $Default " -NoNewline
        Write-Host '(auto: -Yes)' -ForegroundColor DarkGray
        return $Default
    }
    $entered = Read-Host "$Prompt`n  [$Default]"
    if ([string]::IsNullOrWhiteSpace($entered)) { return $Default }
    return $entered.Trim()
}

# Report an abort and exit, naming the branch the repository was left on. Shared
# by Invoke-Step and the inline confirmations in the -*FromNotes flows.
function Stop-Aborted {
    Write-Host ''
    Write-Host "Aborted by user." -ForegroundColor Yellow
    $current = git branch --show-current
    Write-Host "Repository is currently on branch '$current'." -ForegroundColor Yellow
    Write-Host "Any steps already completed above have NOT been undone." -ForegroundColor Yellow
    exit 1
}

# Prompt before running an action. Answering 'n' aborts the whole script, since
# earlier steps are not undone.
function Invoke-Step {
    param([string]$Prompt, [scriptblock]$Action)
    if (-not (Confirm-Step $Prompt)) { Stop-Aborted }
    & $Action
}

# Filter `git status --porcelain` lines, ignoring the exempt PR body file. The
# PR body only feeds `gh pr create`, so it may stay uncommitted; every other
# changed file still counts as a dirty tree.
function Get-DirtyStatusLine {
    param([string[]]$StatusLines, [string]$ExemptPath)
    $dirty = @()
    foreach ($line in $StatusLines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        # Porcelain v1: two status letters, a space, then the path. Paths with
        # special characters are quoted; the plain trim covers the simple case.
        $path = $line.Substring(3).Trim().Trim('"')
        if ($ExemptPath -and $path -eq $ExemptPath) { continue }
        $dirty += $line
    }
    return $dirty
}

# Parse a pr-body note: front-matter ('base:'/'title:' lines, then a '---'
# separator) followed by the body. A note with no '---' is treated as all body.
function ConvertFrom-PrNote {
    param([string]$Content)
    $lines = $Content -split "`r?`n"
    $sep = [Array]::IndexOf($lines, '---')
    if ($sep -lt 0) {
        return [pscustomobject]@{ Base = $null; Title = $null; Body = $Content }
    }
    $base = $null
    $title = $null
    if ($sep -gt 0) {
        foreach ($line in $lines[0..($sep - 1)]) {
            if ($line -match '^base:\s*(.*)$') { $base = $Matches[1].Trim() }
            elseif ($line -match '^title:\s*(.*)$') { $title = $Matches[1].Trim() }
        }
    }
    $body = ''
    if ($sep -lt ($lines.Count - 1)) {
        $body = ($lines[($sep + 1)..($lines.Count - 1)] -join "`n")
    }
    return [pscustomobject]@{ Base = $base; Title = $title; Body = $body }
}

# Parse 'owner/repo' from origin's URL (SSH or HTTPS), for building a github.com
# compare URL. Matches the trailing 'owner/repo' regardless of host, so custom
# SSH host aliases (e.g. 'git@github_drollrobot:owner/repo.git') still parse.
function Get-OriginSlug {
    $url = (git remote get-url origin).Trim()
    if ($url -match '[:/]([^/:]+)/([^/]+?)(?:\.git)?/?$') {
        return "$($Matches[1])/$($Matches[2])"
    }
    throw "Could not parse owner/repo from origin URL: $url"
}

# Open a github.com PR-compare page with the title and body prefilled via query
# params. If the encoded URL is too long for a browser/GitHub to accept, fall
# back to copying the body to the clipboard and opening the form without it.
function Open-WebPr {
    param(
        [string]$OwnerRepo, [string]$Branch, [string]$Base,
        [string]$Title, [string]$Body
    )
    $compareUrl = "https://github.com/$OwnerRepo/compare/$Base...${Branch}?expand=1"
    $encTitle = [uri]::EscapeDataString($Title)
    $encBody = [uri]::EscapeDataString($Body)
    $full = "$compareUrl&title=$encTitle&body=$encBody"
    if ($full.Length -le 8000) {
        Write-Run "Start-Process <compare URL with prefilled title and body>"
        Start-Process $full
        Write-Host "  Opened the prefilled PR form in your browser." -ForegroundColor Green
    }
    else {
        Set-Clipboard -Value $Body
        Write-Run "Start-Process <compare URL with prefilled title>"
        Start-Process "$compareUrl&title=$encTitle"
        $msg = '  Body too long to prefill via URL; copied it to your clipboard - ' +
        'paste it into the form.'
        Write-Host $msg -ForegroundColor Yellow
    }
}

# Compute the per-slug notes ref (refs/notes/pr-body-<slug>). One ref per slug
# keeps concurrent PRs from sharing - and force-pushing over - each other.
function Get-NotesRef {
    param([string]$Slug)
    return "$NotesRefPrefix-$($Slug -replace '/', '-')"
}

# Delete a PR-body notes ref from origin and locally. Tolerates an already-gone
# ref so cleanup is safe to run more than once.
function Remove-PrNote {
    param([string]$NotesRef)
    Write-Run "git push origin :refs/notes/$NotesRef"
    $null = Invoke-NativeOk git push origin ":refs/notes/$NotesRef"
    Write-Run "git update-ref -d refs/notes/$NotesRef"
    $null = Invoke-NativeOk git update-ref -d "refs/notes/$NotesRef"
}

# --- mode validation -------------------------------------------------------

Write-Host ''

$noteModes = @($PushPRToNotes, $GHFromNotes, $WebFromNotes).Where({ $_ })
if ($noteModes.Count -gt 1) {
    throw "Specify at most one of -PushPRToNotes, -GHFromNotes, -WebFromNotes."
}

# --- device B: create the PR from a pushed branch + pr-body note ------------

if ($GHFromNotes -or $WebFromNotes) {
    if (-not $Slug) {
        $cur = $null
        try { $cur = git symbolic-ref --short HEAD 2>$null }
        catch { $cur = $null }
        if ($cur -like 'wt/*') { $Slug = $cur -replace '^wt/', '' }
    }
    if (-not $Slug) {
        throw "Specify -Slug to identify the worktree branch (e.g. -Slug issue-42)."
    }
    $branch = "wt/$Slug"
    $notesRef = Get-NotesRef $Slug

    if ($GHFromNotes -and -not (Get-Command gh -ErrorAction SilentlyContinue)) {
        throw "gh not found on PATH. Use -WebFromNotes to create the PR in the browser instead."
    }

    Write-Section "Fetch branch and PR note"
    Write-Run "git fetch origin +refs/heads/${branch}:refs/remotes/origin/$branch"
    Invoke-Native git fetch origin "+refs/heads/${branch}:refs/remotes/origin/$branch"
    Write-Run "git fetch origin +refs/notes/${notesRef}:refs/notes/$notesRef"
    Invoke-Native git fetch origin "+refs/notes/${notesRef}:refs/notes/$notesRef"

    $noteRaw = Invoke-NativeOk git notes "--ref=$notesRef" show "origin/$branch"
    if (-not $noteRaw) {
        $ErrMsg = "No '$notesRef' note found on origin/$branch. " +
        'Run -PushPRToNotes on the device that has the worktree first.'
        throw $ErrMsg
    }
    $parsed = ConvertFrom-PrNote -Content ($noteRaw -join "`n")

    $prBase = $Base
    if (-not $prBase) { $prBase = $parsed.Base }
    if (-not $prBase) { $prBase = 'develop' }
    if ($prBase -in 'main', 'master') {
        $ErrMsg = "Refusing to target '$prBase'. This project uses git flow; PRs go to " +
        'develop. Pass -Base to override deliberately.'
        throw $ErrMsg
    }

    $prTitle = $Title
    if (-not $prTitle) { $prTitle = $parsed.Title }
    if (-not $prTitle) { $prTitle = (git log -1 --pretty=%s "origin/$branch").Trim() }

    Write-Info "Slug" $Slug
    Write-Info "Branch" $branch
    Write-Info "PR base" $prBase
    Write-Info "PR title" $prTitle
    Write-Host ''
    Write-Host ($parsed.Body.TrimEnd()) -ForegroundColor Gray

    if ($WebFromNotes) {
        Write-Section "Step: open pull request (web)"
        $WebPrompt = "Open the prefilled PR form for '$branch' into '$prBase' in your browser?"
        if (-not (Confirm-Step $WebPrompt)) { Stop-Aborted }
        $WebParams = @{
            OwnerRepo = (Get-OriginSlug)
            Branch    = $branch
            Base      = $prBase
            Title     = $prTitle
            Body      = $parsed.Body
        }
        Open-WebPr @WebParams

        Write-Section "Step: clean up PR body note"
        $CleanPrompt = "Once you've created the PR in the browser, delete the " +
        "'$notesRef' note from origin?"
        if (Confirm-Step $CleanPrompt) {
            Remove-PrNote -NotesRef $notesRef
            Write-Host "  Removed the PR body note from origin." -ForegroundColor Green
        }
        else {
            Write-Host "  Left the note in place. Remove it later with:" -ForegroundColor DarkGray
            Write-Host "    git push origin :refs/notes/$notesRef" -ForegroundColor DarkGray
        }
        return
    }

    # GHFromNotes
    Write-Section "Step: open pull request"
    $draftNote = if ($Draft) { ' (draft)' } else { '' }
    if (-not (Confirm-Step "Open a PR from '$branch' into '$prBase'?$draftNote")) { Stop-Aborted }
    $tempBody = [System.IO.Path]::GetTempFileName()
    try {
        Set-Content -LiteralPath $tempBody -Value $parsed.Body -Encoding utf8
        $createArgs = @('pr', 'create', '--base', $prBase, '--head', $branch,
            '--title', $prTitle, '--body-file', $tempBody)
        if ($Draft) { $createArgs += '--draft' }
        Write-Run "gh pr create --base $prBase --head $branch (title and body from the note)"
        $prUrl = (Invoke-Native gh @createArgs | Select-Object -Last 1).Trim()
    }
    finally {
        Remove-Item -LiteralPath $tempBody -Force -ErrorAction SilentlyContinue
    }

    Write-Section "Step: clean up PR body note"
    if (Confirm-Step "Delete the '$notesRef' note from origin now the PR is created?") {
        Remove-PrNote -NotesRef $notesRef
        Write-Host "  Removed the PR body note from origin." -ForegroundColor Green
    }
    else {
        Write-Host "  Left the note in place. Remove it later with:" -ForegroundColor DarkGray
        Write-Host "    git push origin :refs/notes/$notesRef" -ForegroundColor DarkGray
    }

    Write-Section "Done"
    Write-Host "  Pull request opened." -ForegroundColor Green
    Write-Info "PR" $prUrl
    Write-Info "Base" $prBase
    return
}

# --- gather state ----------------------------------------------------------

Write-Section "Worktree setup"

# Detect current branch; fail on detached HEAD. symbolic-ref exits non-zero on
# detached HEAD, which throws under the native error preference.
try {
    $branch = git symbolic-ref --short HEAD 2>$null
}
catch {
    throw "Not on a branch (detached HEAD?). Check out the wt/ branch first."
}

if ($branch -in 'main', 'master', 'develop', 'dev') {
    $ErrMsg = "On '$branch'; this script is for wt/ feature branches, " +
    'not the integration/release branch.'
    throw $ErrMsg
}
if ($branch -notlike 'wt/*') {
    $WarnMsg = "  Warning: branch '$branch' does not look like a wt/ branch."
    Write-Host $WarnMsg -ForegroundColor Yellow
    if (-not (Confirm-Step "  Continue anyway?")) { exit 1 }
}

$repoRoot = (Invoke-Native git rev-parse --show-toplevel).Trim()

# Resolve the PR base. Prefer the base recorded when the worktree was created
# (the custom 'branch.<branch>.prBase' key, which `git push -u` never rewrites).
# Otherwise fall back to the branch's tracking ref -- but only while it still
# names an integration branch. Once the branch has been pushed with -u,
# 'branch.<branch>.merge' is repointed to the branch itself, so reading it then
# would target the worktree branch instead of develop. Refuse main/master only
# for a base we resolved here; an explicit -Base is a deliberate override.
if (-not $Base) {
    $prBase = "$(Invoke-NativeOk git config "branch.$branch.prBase")".Trim()
    $merge = "$(Invoke-NativeOk git config "branch.$branch.merge")".Trim()
    $merge = $merge -replace '^refs/heads/', ''
    if ($prBase) {
        $Base = $prBase
    }
    elseif ($merge -and $merge -ne $branch -and $merge -notlike 'wt/*') {
        $Base = $merge
    }
    else {
        if ($merge) {
            $WarnMsg = "  Upstream of '$branch' is '$merge', not an integration " +
            'branch (likely pushed with -u); ignoring it for the PR base.'
            Write-Host $WarnMsg -ForegroundColor Yellow
        }
        else {
            Write-Host "  No usable upstream for '$branch'." -ForegroundColor Yellow
        }
        $Base = Read-WithDefault "  Enter the PR base branch" 'develop'
    }
    if ($Base -in 'main', 'master') {
        $ErrMsg = "Refusing to target '$Base'. This project uses git flow; PRs go to " +
        'develop. Pass -Base to override deliberately.'
        throw $ErrMsg
    }
}

Write-Info "Worktree" $repoRoot
Write-Info "Source branch" $branch
Write-Info "PR base" $Base

# --- PR body ---------------------------------------------------------------

Write-Section "PR body"
$bodyPath = if ([System.IO.Path]::IsPathRooted($BodyFile)) { $BodyFile }
else { Join-Path -Path $repoRoot -ChildPath $BodyFile }

if (-not (Test-Path -LiteralPath $bodyPath)) {
    $ErrMsg = "PR body file not found: $bodyPath. " +
    'Have the agent write the PR description to PR.md first.'
    throw $ErrMsg
}
$bodyText = Get-Content -Raw -LiteralPath $bodyPath
if ([string]::IsNullOrWhiteSpace($bodyText)) {
    throw "PR body file is empty: $bodyPath."
}
Write-Info "Body file" $bodyPath
Write-Host ''
Write-Host ($bodyText.TrimEnd()) -ForegroundColor Gray

# --- title -----------------------------------------------------------------

if (-not $Title) {
    $Title = (git log -1 --pretty=%s).Trim()
}
if ([string]::IsNullOrWhiteSpace($Title)) {
    throw "PR title cannot be empty. Pass -Title to set one explicitly."
}
Write-Section "PR title"
Write-Info "PR title" $Title
# A y/n confirmation (not an editable prompt) keeps this step consistent with
# every other prompt, so an absent-minded 'y' can't become the PR title itself.
# To use a different title, answer 'n' and re-run with -Title.
if (-not (Confirm-Step "Use this title?")) {
    Write-Host ''
    $HintMsg = 'Re-run with -Title "your title here" to set a different PR title.'
    Write-Host $HintMsg -ForegroundColor Yellow
    exit 1
}

# --- working tree status ---------------------------------------------------

Write-Section "Working tree status"
Write-Run "git status --short --branch"
git status --short --branch

# The PR body file only feeds `gh pr create`, so it may stay uncommitted; exempt
# it from the clean-tree check (when it lives inside the worktree). Compute its
# repo-root-relative POSIX path to match what `git status --porcelain` reports.
$exempt = $null
$resolvedBody = (Resolve-Path -LiteralPath $bodyPath).Path
$relBody = [System.IO.Path]::GetRelativePath($repoRoot, $resolvedBody)
if (-not $relBody.StartsWith('..')) {
    $exempt = $relBody -replace '\\', '/'
}
$bodyName = Split-Path -Path $bodyPath -Leaf

$statusLines = @(git status --porcelain)
$dirty = Get-DirtyStatusLine -StatusLines $statusLines -ExemptPath $exempt
if ($dirty) {
    Write-Host ''
    $WarnMsg = "  Working tree is not clean. Commit everything except $bodyName"
    Write-Host $WarnMsg -ForegroundColor Yellow
    Write-Host '  before completing the worktree.' -ForegroundColor Yellow
    throw "Uncommitted changes present; refusing to push."
}
$CleanMsg = "  Working tree is clean; all changes committed ($bodyName is exempt)."
Write-Host $CleanMsg -ForegroundColor Green

# --- existing PR guard (gh; skipped when only pushing the note) -------------

if (-not $PushPRToNotes) {
    Write-Section "Existing PR check"
    $existingUrl = $null
    try {
        $existingUrl = (gh pr view $branch --json url --jq .url 2>$null)
    }
    catch { $existingUrl = $null }
    if (-not [string]::IsNullOrWhiteSpace($existingUrl)) {
        Write-Host "  A pull request already exists for '$branch':" -ForegroundColor Yellow
        Write-Host "  $existingUrl" -ForegroundColor White
        Write-Host "  Pushing will update it; a new PR will not be created." -ForegroundColor Yellow
    }
    else {
        Write-Host "  No existing PR for this branch." -ForegroundColor Green
    }
}

# --- push ------------------------------------------------------------------

Write-Section "Step: push branch"
Invoke-Step "Push '$branch' to origin (with -u)?" {
    Write-Run "git push -u origin HEAD"
    Invoke-Native git push -u origin HEAD
}

# --- device A: attach the PR body as a note and stop ------------------------

if ($PushPRToNotes) {
    $slug = $branch -replace '^wt/', ''
    $notesRef = Get-NotesRef $slug
    Write-Section "Step: attach PR body note"
    $noteBody = "base: $Base`ntitle: $Title`n---`n$bodyText"
    $tempNote = [System.IO.Path]::GetTempFileName()
    $NotePrompt = "Attach $bodyName (with base/title) as a '$notesRef' note and push it to origin?"
    Invoke-Step $NotePrompt {
        Set-Content -LiteralPath $tempNote -Value $noteBody -Encoding utf8
        Write-Run "git notes --ref=$notesRef add --force --file <note> HEAD"
        Invoke-Native git notes "--ref=$notesRef" add --force --file $tempNote HEAD
        Write-Run "git push origin +refs/notes/${notesRef}:refs/notes/$notesRef"
        Invoke-Native git push origin "+refs/notes/${notesRef}:refs/notes/$notesRef"
        Remove-Item -LiteralPath $tempNote -Force -ErrorAction SilentlyContinue
    }

    Write-Section "Done"
    Write-Host "  Pushed branch and PR body note for '$slug'." -ForegroundColor Green
    Write-Info "Branch" $branch
    Write-Host ''
    Write-Host "  On the other device, create the PR with one of:" -ForegroundColor DarkGray
    Write-Host "    .\Complete-WorkTree.ps1 -GHFromNotes -Slug $slug" -ForegroundColor DarkGray
    Write-Host "    .\Complete-WorkTree.ps1 -WebFromNotes -Slug $slug" -ForegroundColor DarkGray
    return
}

# --- open PR ---------------------------------------------------------------

if (-not [string]::IsNullOrWhiteSpace($existingUrl)) {
    Write-Section "Done"
    Write-Host "  Branch pushed; existing PR updated." -ForegroundColor Green
    Write-Info "PR" $existingUrl
    Write-Info "Current branch" (git branch --show-current)
    Write-Host ''
    Write-Host "  Worktree left in place for you to clean up." -ForegroundColor DarkGray
    return
}

Write-Section "Step: open pull request"
$draftFlag = if ($Draft) { " --draft" } else { "" }
Invoke-Step "Open a PR from '$branch' into '$Base'?$(if($Draft){' (draft)'})" {
    Write-Run "gh pr create --base $Base --title `"$Title`" --body-file `"$bodyPath`"$draftFlag"
    $createArgs = @('pr', 'create', '--base', $Base, '--title', $Title, '--body-file', $bodyPath)
    if ($Draft) { $createArgs += '--draft' }
    $script:prUrl = (Invoke-Native gh @createArgs | Select-Object -Last 1).Trim()
}

# --- done ------------------------------------------------------------------

Write-Section "Done"
Write-Host "  Pull request opened." -ForegroundColor Green
Write-Info "PR" $script:prUrl
Write-Info "Base" $Base
Write-Info "Current branch" (git branch --show-current)
Write-Host ''
Write-Host "  Worktree left in place for you to clean up." -ForegroundColor DarkGray
