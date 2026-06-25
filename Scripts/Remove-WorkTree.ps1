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

    Before each destructive step it warns about work the force flags would
    otherwise discard silently: uncommitted changes in the worktree (step 2) and
    commits on the branch that were never pushed to origin (step 3). Each warning
    is its own y/n confirmation, so nothing is lost without an explicit yes.

    Paths and names are derived exactly as New-Worktree.ps1 derives them, so the
    same slug that created a worktree will clean it up. Every step runs against
    the main worktree, so this is safe to run even from inside the worktree
    being removed (git refuses to remove the worktree you are standing in).

    Run without a slug to pick one interactively: the script lists every open
    worktree whose branch carries the wt/ prefix and asks which to remove.

    Pass -Yes to answer every prompt with 'y' for non-interactive use (a slug is
    required in that case, since there is nobody to answer the picker).

.PARAMETER Slug
    The same slug passed to New-Worktree.ps1 (e.g. "issue-42" or "fix/login").
    Omit it to pick from a list of open worktrees.

.PARAMETER Base
    Integration branch to refresh and that the PR was merged into. Defaults to
    "develop".

.PARAMETER Yes
    Assume 'yes' to every confirmation prompt (non-interactive). A slug is
    required when this is set. The prompt is still printed with the auto-answer
    so the transcript records each step.

.EXAMPLE
    .\Remove-WorkTree.ps1 issue-42

.EXAMPLE
    .\Remove-WorkTree.ps1 fix/login

.EXAMPLE
    .\Remove-WorkTree.ps1

.EXAMPLE
    .\Remove-WorkTree.ps1 issue-42 -Yes

.NOTES
    Script version 1.2.1. Kept functionally in step with the maintained
    remove_worktree.py source of truth; bump on every change.

    Requirements:
      - PowerShell 7.4 or later.
      - The PR for 'wt/<slug>' has already been merged into the integration branch.

    Paths and names mirror New-Worktree.ps1: the sibling '<repo>-wt' folder and
    'wt/<slug>' branches.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPositionalParameters', '')]
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateScript({
            if ($_ -notmatch '^[A-Za-z0-9._/-]+$') {
                throw "Slug may only contain letters, digits, and . _ / - characters."
            }
            if ($_ -like '*..*') {
                throw "Slug may not contain '..'."
            }
            if ($_ -match '^/' -or $_ -match '/$') {
                throw "Slug may not start or end with '/'."
            }
            if ($_ -like '*//*') {
                throw "Slug may not contain '//'."
            }
            $true
        })]
    [string]$Slug,

    [Parameter(Position = 1)]
    [string]$Base = 'develop',

    [Alias('y')]
    [switch]$Yes
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

# Version of this helper script itself. Bump on every change so copies in other
# repos can be compared: patch = bugfix, minor = new flag/behavior, major =
# breaking CLI change.
$ScriptVersion = '1.2.1'

# Answer every confirmation prompt with 'y' (set from -Yes). Script-scoped so
# the helper functions below can read it.
$script:AssumeYes = [bool]$Yes

# A slug is required when auto-answering: the interactive picker has nobody to
# answer it. Fail fast, mirroring the Python parser's argument error.
if ($script:AssumeYes -and -not $Slug) {
    throw "A slug is required with -Yes (there is nobody to answer the picker)."
}

# --- helpers ----------------------------------------------------------------

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

# Run a native command and return its output, or $null if it exits non-zero.
# For probes where a non-zero exit is an expected answer (e.g. rev-parse on a
# ref that does not exist), which would otherwise throw under the native error
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

# Parse `git worktree list --porcelain` output into path/branch pairs, in
# listing order (the main worktree first). Branch is the full ref (e.g.
# refs/heads/wt/issue-42), or $null for a detached HEAD.
function Get-WorktreeEntry {
    param([string[]]$Porcelain)
    $entries = @()
    $path = $null
    $branch = $null
    foreach ($line in $Porcelain) {
        if ($line -like 'worktree *') {
            if ($null -ne $path) {
                $entries += [pscustomobject]@{ Path = $path; Branch = $branch }
            }
            $path = $line -replace '^worktree ', ''
            $branch = $null
        }
        elseif ($line -like 'branch *') {
            $branch = $line -replace '^branch ', ''
        }
    }
    if ($null -ne $path) {
        $entries += [pscustomobject]@{ Path = $path; Branch = $branch }
    }
    return $entries
}

# Find the open worktrees that look like they were made by New-Worktree.ps1:
# linked worktrees (the main worktree is skipped) whose branch starts with the
# wt/ prefix. Returns Slug/Path pairs.
function Get-OpenWorktreeSlug {
    param([object[]]$Worktrees, [string]$Prefix)
    $refPrefix = "refs/heads/$Prefix"
    $result = @()
    foreach ($wt in ($Worktrees | Select-Object -Skip 1)) {
        if ($wt.Branch -and $wt.Branch.StartsWith($refPrefix)) {
            $result += [pscustomobject]@{
                Slug = $wt.Branch.Substring($refPrefix.Length)
                Path = $wt.Path
            }
        }
    }
    return $result
}

# Show the open worktrees and ask which one to remove. Returns the chosen slug.
function Read-WorktreeChoice {
    param([object[]]$Candidates)
    Write-Section "Open worktrees"
    for ($i = 0; $i -lt $Candidates.Count; $i++) {
        Write-Host "  $($i + 1). $($Candidates[$i].Slug)  " -NoNewline
        Write-Host $Candidates[$i].Path -ForegroundColor DarkGray
    }
    Write-Host ''
    while ($true) {
        $answer = (Read-Host "Which worktree should be removed? [1-$($Candidates.Count)]").Trim()
        $value = 0
        if ([int]::TryParse($answer, [ref]$value) -and
            $value -ge 1 -and $value -le $Candidates.Count) {
            return $Candidates[$value - 1].Slug
        }
        $RangeMsg = "  Please enter a number between 1 and $($Candidates.Count)."
        Write-Host $RangeMsg -ForegroundColor Yellow
    }
}

# --- intro (shown up front, before anything is touched) ---------------------

Write-Info "Script version" $ScriptVersion
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

# Resolve the MAIN worktree, not whichever worktree we happen to be standing in:
# `git worktree list` always reports the main worktree first. Deriving names
# from it means this works even when run from inside the worktree we remove.
$porcelain = @(git worktree list --porcelain)
$worktrees = @(Get-WorktreeEntry -Porcelain $porcelain)
$worktreePaths = @($worktrees | ForEach-Object { $_.Path })
$mainRepo = $worktreePaths | Select-Object -First 1
if ([string]::IsNullOrWhiteSpace($mainRepo)) {
    throw "Could not determine the main worktree (are you inside a git repository?)."
}

$repoName = Split-Path $mainRepo -Leaf
$prefix = 'wt/'

# No slug given: list the open wt/ worktrees and let the user pick one.
if (-not $Slug) {
    $candidates = @(Get-OpenWorktreeSlug -Worktrees $worktrees -Prefix $prefix)
    if ($candidates.Count -eq 0) {
        $ErrMsg = "No open worktrees with branch prefix '$prefix' found. Pass a slug to " +
        'clean up leftovers (e.g. a branch without a worktree).'
        throw $ErrMsg
    }
    $Slug = Read-WorktreeChoice -Candidates $candidates
}

Write-Section "Cleanup setup"

$branch = "$prefix$Slug"
$dirSlug = $Slug -replace '/', '-'
$wtHome = Join-Path -Path (Split-Path $mainRepo -Parent) -ChildPath "$repoName-wt"
$wtPath = Join-Path -Path $wtHome -ChildPath $dirSlug

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
    # --force discards untracked/ignored files (generated .code-workspace,
    # .vscode and .env links) AND any uncommitted tracked changes. The latter is
    # real work, so surface it before deleting. Tracked-file changes only; the
    # generated/ignored noise above is expected.
    $dirty = Invoke-NativeOk git -C $wtPath status --porcelain --untracked-files=no
    if ($dirty) {
        $DirtyMsg = '  This worktree has uncommitted changes that --force will discard:'
        Write-Host $DirtyMsg -ForegroundColor Yellow
        foreach ($line in $dirty) {
            Write-Host "  $line" -ForegroundColor DarkGray
        }
        $DiscardPrompt = '  Discard these uncommitted changes and remove the worktree?'
        if (-not (Confirm-Step $DiscardPrompt)) {
            throw "Aborted: commit, push, or stash the changes first."
        }
    }
    Invoke-Step "DELETE the worktree directory at '$wtPath'?" {
        Write-Run "git worktree remove --force `"$wtPath`""
        git worktree remove --force "$wtPath"
    }
}

# --- step 3: delete the branch ----------------------------------------------

if ($branchExists) {
    Write-Section "Step: delete branch"
    # -D (force): a squash- or rebase-merged PR leaves the local branch looking
    # unmerged to git, so -d would refuse to delete it. That same force, though,
    # will discard a branch whose commits never reached origin, so warn about
    # unpushed work before deleting.
    $remoteRef = "refs/remotes/origin/$branch"
    if (Invoke-NativeOk git rev-parse --verify --quiet $remoteRef) {
        $unpushed = [int](git rev-list --count "origin/$branch..$branch")
        if ($unpushed -gt 0) {
            $WarnMsg = "  '$branch' has $unpushed commit(s) not pushed to origin/$branch; " +
            'force-deleting will lose them.'
            Write-Host $WarnMsg -ForegroundColor Yellow
            if (-not (Confirm-Step "  Force-delete anyway?")) {
                throw "Aborted: push the branch first (e.g. via Complete-WorkTree.ps1)."
            }
        }
    }
    else {
        $ahead = Invoke-NativeOk git rev-list --count "origin/$Base..$branch"
        $detail = if ($ahead) { " ($ahead commit(s) ahead of origin/$Base)" } else { '' }
        Write-Host "  '$branch' was never pushed to origin$detail." -ForegroundColor Yellow
        $WarnMsg = '  If this work was not merged via a PR, force-deleting will lose it.'
        Write-Host $WarnMsg -ForegroundColor Yellow
        if (-not (Confirm-Step "  Force-delete anyway?")) {
            throw "Aborted: push or merge the branch first."
        }
    }
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
