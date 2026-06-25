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
      3. Resolve the PR base from the branch's UPSTREAM *before* pushing, since
         `git push -u` repoints tracking. Refuses to target main.
      4. Show the PR.md body and confirm the title.
      5. Push the branch with -u.
      6. Open the PR with `gh pr create --base <base> --body-file PR.md`.
      7. Report the PR URL and stop. The worktree is NOT cleaned up -- that is
         left to the user (see Remove-WorkTree.ps1).

    Pass -Yes to answer every prompt with 'y' for non-interactive use.

.PARAMETER Title
    PR title. Defaults to the subject line of the most recent commit. You are
    always given a chance to confirm or edit it interactively.

.PARAMETER Base
    Override the PR base branch. By default it is read from the branch's
    upstream (e.g. origin/develop -> develop). Targeting main is refused unless
    you pass it here explicitly.

.PARAMETER BodyFile
    Path to the PR body file. Defaults to PR.md at the worktree root. This file
    does not need to be committed; it is exempt from the clean-tree check.

.PARAMETER Draft
    Open the PR as a draft.

.PARAMETER Yes
    Assume 'yes' to every confirmation prompt (non-interactive). The prompt is
    still printed with the auto-answer so the transcript records each step.

.EXAMPLE
    .\Complete-WorkTree.ps1

.EXAMPLE
    .\Complete-WorkTree.ps1 -Title "feat(auth): add SSO login" -Draft

.EXAMPLE
    .\Complete-WorkTree.ps1 -Yes

.NOTES
    Script version 1.0.0. Kept functionally in step with the maintained
    complete_worktree.py source of truth; bump on every change.

    Requirements:
      - PowerShell 7.4 or later.
      - Run from inside the worktree, on a wt/ branch with all work committed
        (PR.md itself does not need to be committed).
      - `git` and `gh` installed and authenticated.
      - A PR.md body file written by the agent at the worktree root.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPositionalParameters', '')]
[CmdletBinding()]
param(
    [string]$Title,
    [string]$Base,
    [string]$BodyFile = 'PR.md',
    [switch]$Draft,
    [Alias('y')]
    [switch]$Yes
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

# Version of this helper script itself. Bump on every change so copies in other
# repos can be compared: patch = bugfix, minor = new flag/behavior, major =
# breaking CLI change.
$ScriptVersion = '1.0.0'

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

# Prompt before running an action. Answering 'n' aborts the whole script and
# reports where the repository was left, since earlier steps are not undone.
function Invoke-Step {
    param([string]$Prompt, [scriptblock]$Action)
    if (-not (Confirm-Step $Prompt)) {
        Write-Host ''
        Write-Host "Aborted by user." -ForegroundColor Yellow
        $branch = git branch --show-current
        Write-Host "Repository is currently on branch '$branch'." -ForegroundColor Yellow
        Write-Host "Any steps already completed above have NOT been undone." -ForegroundColor Yellow
        exit 1
    }
    & $Action
}

# --- gather state ----------------------------------------------------------

Write-Info "Script version" $ScriptVersion
Write-Host ''

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

# Resolve the PR base. Read it from the branch's configured upstream, because a
# later `git push -u` will repoint tracking to origin/<branch> and lose it.
# Refuse main/master only for a base we resolved here; an explicit -Base is
# taken as a deliberate override.
if (-not $Base) {
    $merge = git config "branch.$branch.merge"
    if ([string]::IsNullOrWhiteSpace($merge)) {
        Write-Host "  No upstream configured for '$branch'." -ForegroundColor Yellow
        $Base = Read-WithDefault "  Enter the PR base branch" 'develop'
    }
    else {
        $Base = $merge -replace '^refs/heads/', ''
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
Write-Section "PR title"
$Title = Read-WithDefault "Confirm or edit the PR title" $Title
if ([string]::IsNullOrWhiteSpace($Title)) {
    throw "PR title cannot be empty."
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

# --- existing PR guard -----------------------------------------------------

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

# --- push ------------------------------------------------------------------

Write-Section "Step: push branch"
Invoke-Step "Push '$branch' to origin (with -u)?" {
    Write-Run "git push -u origin HEAD"
    Invoke-Native git push -u origin HEAD
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
