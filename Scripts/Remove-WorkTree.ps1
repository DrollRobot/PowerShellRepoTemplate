#Requires -Version 7.4

<#
.SYNOPSIS
    Interactively delete a finished git worktree created by New-Worktree.ps1.

.DESCRIPTION
    The inverse of New-Worktree.ps1, and the final step of the worktree
    lifecycle:

        New-Worktree  ->  (work, commit, Complete-WorkTree)  ->  Remove-WorkTree

    Run this once the work is done: the PR opened from the worktree's 'wt/<slug>'
    branch has been merged into the integration branch and the worktree is no
    longer needed.

    WARNING: this permanently deletes the worktree directory and its local
    branch. It walks through the teardown one step at a time, showing what is
    about to happen and prompting for confirmation (y/n) before each action;
    answering 'n' stops without taking the remaining steps. The output of every
    git command is shown.

    Steps:
      1. Refresh base     - git switch <base> (if needed) + git pull --ff-only origin <base>
      2. Remove worktree  - git worktree remove --force <path>
      3. Delete branch    - git branch -D wt/<slug>
      4. Prune stale refs - git fetch --prune

    Paths and names are derived exactly as New-Worktree.ps1 derives them, so the
    same slug that created a worktree will clean it up. Every step runs against
    the main worktree, so this is safe to run even from inside the worktree
    being removed (git refuses to remove the worktree you are standing in).

.PARAMETER Slug
    The same slug passed to New-Worktree.ps1 (e.g. "issue-42" or "fix/login").

.PARAMETER Base
    Integration branch to refresh and that the PR was merged into. Defaults to
    $env:WT_BASE, then auto-detected: origin/develop, then origin/dev, then
    origin's default branch.

.EXAMPLE
    .\Remove-WorkTree.ps1 issue-42

.EXAMPLE
    .\Remove-WorkTree.ps1 fix/login

.NOTES
    Requirements:
      - PowerShell 7.4 or later.
      - The PR for 'wt/<slug>' has already been merged into the integration branch.

    Env overrides mirror New-Worktree.ps1: WT_HOME (parent dir for worktrees),
    WT_BASE (default base branch), WT_PREFIX (branch prefix, default "wt/").
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '')]
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateScript({
            if ($_ -notmatch '^[A-Za-z0-9._/-]+$') {
                throw "Slug may only contain letters, digits, and . _ / - characters."
            }
            if ($_ -like '*..*') {
                throw "Slug may not contain '..'."
            }
            $true
        })]
    [string]$Slug,

    [Parameter(Position = 1)]
    [string]$Base
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

# --- helpers (kept in step with Push-NewTagToMain.ps1) ----------------------

function Write-Section {
    param([string]$Title)
    Write-Host ''
    Write-Host "== $Title ==" -ForegroundColor Cyan
}

function Write-Info {
    param([string]$Label, [string]$Value)
    Write-Host "  $("${Label}:".PadRight(20))" -NoNewline -ForegroundColor DarkGray
    Write-Host $Value -ForegroundColor White
}

function Write-Run {
    param([string]$CommandText)
    Write-Host "  > $CommandText" -ForegroundColor DarkGray
}

function Confirm-Step {
    param([string]$Prompt)
    while ($true) {
        $answer = (Read-Host "$Prompt [y/n]").Trim().ToLowerInvariant()
        switch ($answer) {
            { $_ -in 'y', 'yes' } { return $true }
            { $_ -in 'n', 'no' } { return $false }
            default { Write-Host "  Please answer 'y' or 'n'." -ForegroundColor Yellow }
        }
    }
}

# Resolve the integration branch when -Base is not given: $env:WT_BASE, then
# origin/develop, then origin/dev, then origin's default branch. Keeps the
# script portable across repos with different conventions.
function Get-DefaultBase {
    if ($env:WT_BASE) { return $env:WT_BASE }
    foreach ($name in @('develop', 'dev')) {
        if (git branch --list --remotes "origin/$name") { return $name }
    }
    try {
        $head = git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>$null
        if ($head) { return ($head -replace '^origin/', '') }
    }
    catch { }
    return 'main'
}

# Prompt before running an action. Answering 'n' aborts the whole script and
# reports where the repository was left, since earlier steps are not undone.
function Invoke-Step {
    param(
        [string]$Prompt,
        [scriptblock]$Action
    )
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

# Compare two filesystem paths for equality without requiring either to exist
# (the worktree may already be gone). Normalises slash direction and trailing
# separators; comparison is case-insensitive to match Windows.
function Test-SamePath {
    param([string]$A, [string]$B)
    $na = ($A -replace '/', '\').TrimEnd('\')
    $nb = ($B -replace '/', '\').TrimEnd('\')
    return $na -ieq $nb
}

# --- what this does (shown up front, before anything is touched) ------------

Write-Host ''
Write-Host 'Remove-WorkTree - tear down a finished worktree' -ForegroundColor Cyan
Write-Host ''
Write-Host '  The inverse of New-Worktree.ps1. Run it once the work is' -ForegroundColor Gray
Write-Host '  done: the PR opened from this worktree''s wt/<slug> branch' -ForegroundColor Gray
Write-Host '  has been merged into the integration branch, and the' -ForegroundColor Gray
Write-Host '  worktree is no longer needed.' -ForegroundColor Gray
Write-Host ''
Write-Host '  WARNING: this DELETES the worktree directory and its local' -ForegroundColor Yellow
Write-Host '  branch. It runs one step at a time and asks before each;' -ForegroundColor Yellow
Write-Host '  answer n to stop.' -ForegroundColor Yellow

# --- resolve paths (mirrors New-Worktree.ps1) -------------------------------

Write-Section "Cleanup setup"

# Resolve the MAIN worktree, not whichever worktree we happen to be standing in:
# `git worktree list` always reports the main worktree first. Deriving names
# from it means this works even when run from inside the worktree we remove.
$worktreePaths = git worktree list --porcelain |
    Where-Object { $_ -like 'worktree *' } |
    ForEach-Object { $_ -replace '^worktree ', '' }
$mainRepo = $worktreePaths | Select-Object -First 1
if ([string]::IsNullOrWhiteSpace($mainRepo)) {
    throw "Could not determine the main worktree (are you inside a git repository?)."
}

$repoName = Split-Path $mainRepo -Leaf
$prefix = if ($env:WT_PREFIX) { $env:WT_PREFIX } else { 'wt/' }
$branch = "$prefix$Slug"
$dirSlug = $Slug -replace '/', '-'
$wtHome = if ($env:WT_HOME) { $env:WT_HOME }
else { Join-Path -Path (Split-Path $mainRepo -Parent) -ChildPath "$repoName-wt" }
$wtPath = Join-Path -Path $wtHome -ChildPath $dirSlug

if (-not $Base) { $Base = Get-DefaultBase }

Write-Info "Slug" $Slug
Write-Info "Branch" $branch
Write-Info "Worktree" $wtPath
Write-Info "Integration branch" $Base
Write-Info "Main worktree" $mainRepo

# --- preflight: figure out what actually still exists -----------------------

$wtRegistered = $false
foreach ($p in $worktreePaths) {
    if (Test-SamePath $p $wtPath) { $wtRegistered = $true; break }
}
if (-not $wtRegistered) {
    $NoteMsg = "  Note: no registered worktree at '$wtPath' - remove step will be skipped."
    Write-Host $NoteMsg -ForegroundColor Yellow
}

$branchExists = [bool](git branch --list $branch)
if (-not $branchExists) {
    $NoteMsg = "  Note: branch '$branch' does not exist - delete-branch step will be skipped."
    Write-Host $NoteMsg -ForegroundColor Yellow
}

if (-not $wtRegistered -and -not $branchExists) {
    Write-Host ''
    Write-Host "Nothing to clean up for slug '$Slug'." -ForegroundColor Green
    exit 0
}

# Operate from the main worktree for every step. This guarantees the worktree
# being removed is never the "current" one (git refuses to remove that) and
# moves us out of it if we happened to be inside it.
Write-Run "Set-Location $mainRepo"
Set-Location -LiteralPath $mainRepo

# --- step 1: refresh the integration branch ---------------------------------

Write-Section "Step: refresh '$Base'"
$current = git branch --show-current
$currentLabel = if ($current) { $current } else { '(detached HEAD)' }
Write-Info "Current branch" $currentLabel
if ($current -ne $Base) {
    Invoke-Step "Switch from '$currentLabel' to '$Base'?" {
        Write-Run "git switch $Base"
        git switch $Base
    }
}
Invoke-Step "Pull '$Base' from origin (fast-forward only)?" {
    Write-Run "git pull --ff-only origin $Base"
    git pull --ff-only origin $Base
}

# --- step 2: remove the worktree --------------------------------------------

if ($wtRegistered) {
    Write-Section "Step: remove worktree"
    # --force: the worktree carries untracked/ignored files (generated
    # .code-workspace, .vscode and .env links) that a plain remove would
    # refuse to discard.
    Invoke-Step "DELETE the worktree directory at '$wtPath'?" {
        Write-Run "git worktree remove --force `"$wtPath`""
        git worktree remove --force "$wtPath"
    }
}

# --- step 3: delete the branch ----------------------------------------------

if ($branchExists) {
    Write-Section "Step: delete branch"
    # -D (force): a squash- or rebase-merged PR leaves the local branch looking
    # unmerged to git, so -d would refuse to delete it.
    Invoke-Step "Force-delete local branch '$branch'?" {
        Write-Run "git branch -D $branch"
        git branch -D $branch
    }
}

# --- step 4: prune stale remote-tracking refs -------------------------------

Write-Section "Step: prune"
Invoke-Step "Fetch and prune deleted remote branches?" {
    Write-Run "git fetch --prune"
    git fetch --prune
}

# --- done -------------------------------------------------------------------

Write-Section "Done"
Write-Host "  Removed worktree '$Slug'." -ForegroundColor Green
Write-Info "Current branch" (git branch --show-current)
Write-Info "Location" (Get-Location).Path
