#Requires -Version 5.1
<#
.SYNOPSIS
    Interactively create an isolated git worktree on a fresh branch, generate a
    VS Code workspace, and open it.

.DESCRIPTION
    Intended for running multiple agents in parallel: each gets its own checkout
    on its own branch, forked from current upstream. The generated
    .code-workspace is forced to point only at its own worktree and is kept out
    of git via the shared .git/info/exclude.

    Before creating the worktree it syncs the base branch: if your local base is
    ahead of origin it offers to push (so the new worktree, forked from
    origin/<base>, includes those commits), warns if the base has diverged, and
    warns about uncommitted changes that can never transfer to a worktree.

    Walks through the steps one at a time. Before each action it shows what is
    about to happen and prompts for confirmation (y/n); answering 'n' aborts
    without taking the remaining steps (anything already created is left in
    place). Pass -Yes to answer every prompt with 'y' for non-interactive use.

    Worktrees are created in a sibling '<repo>-wt' folder, on 'wt/<slug>'
    branches, forked from 'develop' (or the base branch given as -Base).

.PARAMETER Slug
    Short name for the work, e.g. "issue-42" or "fix/login".

.PARAMETER Base
    Branch to fork from. Defaults to "develop".

.PARAMETER NoBootstrap
    Skip the per-worktree setup (.vscode/.env links and dependency install).

.PARAMETER Yes
    Assume 'yes' to every confirmation prompt (non-interactive). The prompt is
    still printed with the auto-answer so the transcript records each step.

.EXAMPLE
    .\New-Worktree.ps1 issue-42

.EXAMPLE
    .\New-Worktree.ps1 fix/login develop

.EXAMPLE
    .\New-Worktree.ps1 issue-42 -NoBootstrap

.EXAMPLE
    .\New-Worktree.ps1 issue-42 -Yes

.NOTES
    Script version 1.2.0. Kept functionally in step with the maintained
    new_worktree.py source of truth; bump on every change.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPositionalParameters', '')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseShouldProcessForStateChangingFunctions', '')]
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
    [string]$Base = 'develop',

    [switch]$NoBootstrap,

    [Alias('y')]
    [switch]$Yes
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Version of this helper script itself. Bump on every change so copies in other
# repos can be compared: patch = bugfix, minor = new flag/behavior, major =
# breaking CLI change.
$ScriptVersion = '1.2.0'

# --- output helpers ---------------------------------------------------------

# Answer every Confirm-Prompt with 'y' (set from -Yes). Script-scoped so the
# helper functions below can read it.
$script:AssumeYes = [bool]$Yes

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

# Show a command line just before it runs.
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

# Print an error and exit with status 1.
function Stop-Script {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "ERROR: $Message" -ForegroundColor Red
    exit 1
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

# Confirm a step before it runs; answering 'n' aborts the whole script. Earlier
# steps are not undone, so report where the repository was left.
function Confirm-Step {
    param([Parameter(Mandatory)][string]$Message)
    if (Confirm-Prompt $Message) { return }
    Write-Host ''
    Write-Warn 'Aborted by user.'
    $current = git branch --show-current 2>$null
    if (-not $current) { $current = '(unknown)' }
    Write-Warn "Repository is currently on branch '$current'."
    Write-Warn 'Any steps already completed above have NOT been undone.'
    exit 1
}

# $ErrorActionPreference = 'Stop' does NOT halt on a failing native command; it
# only governs cmdlets/terminating errors. So wrap git and check the exit code
# ourselves. Reset the GLOBAL $LASTEXITCODE first: it is only ever updated by a
# native command, so a stale value can otherwise linger. Using $global: (not a
# bare assignment) avoids creating a local that would shadow the engine-updated
# global and pin the check to 0.

# Echo a command, run it with output streaming to the terminal, and stop on
# failure.
function Invoke-Run {
    Write-Echo "$($args -join ' ')"
    $global:LASTEXITCODE = 0
    & $args[0] @($args[1..($args.Count - 1)])
    if ($LASTEXITCODE -ne 0) {
        Stop-Script "$($args -join ' ') failed (exit $LASTEXITCODE)"
    }
}

# Like Invoke-Run, but return the exit code without exiting so the caller can
# decide what to do on a non-zero exit (e.g. a 'git push' origin may reject).
function Invoke-RunOk {
    Write-Echo "$($args -join ' ')"
    $global:LASTEXITCODE = 0
    & $args[0] @($args[1..($args.Count - 1)])
    return $LASTEXITCODE
}

# Run a command and return its stdout, stopping the script on failure.
function Invoke-Capture {
    $global:LASTEXITCODE = 0
    $output = & $args[0] @($args[1..($args.Count - 1)])
    if ($LASTEXITCODE -ne 0) {
        Stop-Script "$($args -join ' ') failed (exit $LASTEXITCODE)"
    }
    if ($null -eq $output) { return '' }
    return ($output -join "`n").Trim()
}

# Run a command and return its stdout, or $null if it exits non-zero. For
# probing commands where a non-zero exit is an expected answer (e.g. rev-parse
# on a branch that does not exist).
function Invoke-CaptureOk {
    $global:LASTEXITCODE = 0
    $output = & $args[0] @($args[1..($args.Count - 1)]) 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    if ($null -eq $output) { return '' }
    return ($output -join "`n").Trim()
}

# --- worktree helpers -------------------------------------------------------

# Find a workspace to use as a template. Prefer one already in the new worktree
# (a committed workspace, checked out from the branch) over one in the main repo
# root. Never returns our own target file.
function Get-SourceWorkspace {
    param(
        [string[]]$SearchDirs,
        [string]$ExcludeName
    )
    foreach ($dir in $SearchDirs) {
        $GciParams = @{
            LiteralPath = $dir
            Filter      = '*.code-workspace'
            File        = $true
            ErrorAction = 'SilentlyContinue'
        }
        $hit = Get-ChildItem @GciParams |
            Where-Object { $_.Name -ne $ExcludeName } |
            Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    return $null
}

# Push the local base branch to origin, handling a rejected push. A worktree
# forks from origin/<base>, so the local base must be on origin for the new
# checkout to include its latest commits. If origin rejects the push (branch
# protection, diverged history, no network), ask whether to create the worktree
# from origin as-is rather than aborting outright.
function Invoke-PushBase {
    param([Parameter(Mandatory)][string]$BaseBranch)
    # "${BaseBranch}:..." not "$BaseBranch:...": a bare colon after a variable
    # name parses as a scope/drive qualifier in PowerShell.
    $code = Invoke-RunOk git push origin "${BaseBranch}:$BaseBranch"
    if ($code -ne 0) {
        Write-Warn ('  Push to origin was rejected (branch protection, ' +
            'diverged history, or network).')
        if (-not (Confirm-Prompt "Create the worktree from origin/$BaseBranch as-is anyway?")) {
            Stop-Script 'Aborted: push to origin failed.'
        }
    }
}

# --- main -------------------------------------------------------------------

Write-Info 'Script version' $ScriptVersion
Write-Host ''

# --- resolve paths ----------------------------------------------------------

# rev-parse fails fast if not in a repo; --git-common-dir is the shared .git,
# not the worktree stub, and may come back relative to the cwd.
$repoRoot = Invoke-Capture git rev-parse --show-toplevel
$common = Invoke-Capture git rev-parse --git-common-dir
$commonDir = if ([System.IO.Path]::IsPathRooted($common)) { $common }
else { (Resolve-Path -LiteralPath (Join-Path -Path (Get-Location) -ChildPath $common)).Path }
$repoName = Split-Path -Path $repoRoot -Leaf

$prefix = 'wt/'
$branch = "$prefix$Slug"
$dirSlug = $Slug -replace '/', '-'
$wtHome = Join-Path -Path (Split-Path -Path $repoRoot -Parent) -ChildPath "$repoName-wt"
$wtPath = Join-Path -Path $wtHome -ChildPath $dirSlug
$wsName = "$dirSlug.code-workspace"
$wsFile = Join-Path -Path $wtPath -ChildPath $wsName

# --- setup summary ----------------------------------------------------------

Write-Section 'Worktree setup'
Write-Info 'Slug' $Slug
Write-Info 'Branch' $branch
Write-Info 'Base' "origin/$Base"
Write-Info 'Worktree' $wtPath
Write-Info 'Workspace' $wsFile
Write-Info 'Bootstrap' $(if ($NoBootstrap) { 'no (-NoBootstrap)' } else { 'yes' })

# --- guards -----------------------------------------------------------------

if (Test-Path -LiteralPath $wtPath) {
    Stop-Script "$wtPath already exists"
}
if (Invoke-Capture git branch --list $branch) {
    Stop-Script "branch $branch already exists"
}

# --- step: fetch origin -----------------------------------------------------

Write-Section 'Step: fetch origin'
Confirm-Step "Fetch 'origin'?"
Invoke-Run git fetch origin

# --- step: sync base with origin --------------------------------------------

# The worktree forks from origin/<base>, so anything only in your local checkout
# is missing from it. Uncommitted changes never transfer (a worktree forks from
# a commit), and local commits don't transfer unless pushed first. Surface both
# before creating the worktree.
Write-Section 'Step: sync base with origin'

if (Invoke-Capture git status --porcelain) {
    Write-Warn '  You have uncommitted changes in this working tree.'
    Write-Warn '  They will NOT appear in the new worktree (it forks from a commit).'
    if (-not (Confirm-Prompt 'Continue anyway?')) {
        Stop-Script 'Aborted: commit or stash your changes, then re-run.'
    }
}

$remoteRef = "origin/$Base"
$localBase = Invoke-CaptureOk git rev-parse --verify "refs/heads/$Base"
$remoteBase = Invoke-CaptureOk git rev-parse --verify "refs/remotes/$remoteRef"

if ($null -eq $localBase) {
    Write-Info 'Base sync' "no local '$Base' branch; will fork from $remoteRef"
}
elseif ($null -eq $remoteBase) {
    Write-Warn "  origin has no '$Base' branch yet."
    Confirm-Step "Push local '$Base' to origin to create $remoteRef?"
    Invoke-PushBase $Base
}
else {
    $ahead = [int](Invoke-Capture git rev-list --count "$remoteRef..$Base")
    $behind = [int](Invoke-Capture git rev-list --count "$Base..$remoteRef")
    if ($ahead -eq 0) {
        Write-Info 'Base sync' "local '$Base' not ahead of $remoteRef; nothing to push"
    }
    elseif ($behind -eq 0) {
        Confirm-Step "Local '$Base' is $ahead commit(s) ahead of $remoteRef. Push to origin?"
        Invoke-PushBase $Base
    }
    else {
        Write-Warn ("  Local '$Base' has diverged from $remoteRef " +
            "($ahead ahead, $behind behind); not pushing (would need a force-push).")
        Write-Warn "  Worktree forks from $remoteRef, missing your $ahead local commit(s)."
        if (-not (Confirm-Prompt 'Continue anyway?')) {
            Stop-Script 'Aborted: reconcile your base branch with origin, then re-run.'
        }
    }
}

# --- step: create the worktree ----------------------------------------------

Write-Section 'Step: create worktree'
Confirm-Step "Create worktree at '$wtPath' on new branch '$branch' from 'origin/$Base'?"
New-Item -ItemType Directory -Path $wtHome -Force | Out-Null
Invoke-Run git worktree add -b $branch $wtPath "origin/$Base"

# --- step: generate the workspace -------------------------------------------

Write-Section 'Step: generate workspace'
$srcWs = Get-SourceWorkspace -SearchDirs @($wtPath, $repoRoot) -ExcludeName $wsName

$ws = $null
if ($srcWs) {
    try {
        # NB: VS Code workspace files are often JSONC (// comments, trailing
        # commas), which ConvertFrom-Json rejects on both 5.1 and 7. Fall back
        # to a minimal workspace rather than crashing.
        $ws = Get-Content -Raw -LiteralPath $srcWs | ConvertFrom-Json
        Write-Info 'Template' $srcWs
    }
    catch {
        $WarnMsg = "  Could not parse $srcWs ($($_.Exception.Message)); " +
        'generating a minimal workspace.'
        Write-Warn $WarnMsg
        $ws = $null
    }
}
else {
    Write-Info 'Template' '(none found; generating a minimal workspace)'
}
if (-not $ws) {
    $ws = [pscustomobject]@{ settings = @{} }
}

# Keep generated workspace files out of git. info/exclude lives in the shared
# .git and is never committed, so this covers every worktree without touching
# the tracked .gitignore.
$exclude = Join-Path -Path $commonDir -ChildPath 'info/exclude'
$pattern = '*.code-workspace'
$needExclude = -not (Test-Path -LiteralPath $exclude) -or
    -not (Select-String -LiteralPath $exclude -Pattern $pattern -SimpleMatch -Quiet)

if ($needExclude) {
    Confirm-Step "Write '$wsName' and add '$pattern' to .git/info/exclude?"
}
else {
    Confirm-Step "Write '$wsName'?"
}

# Guard: the workspace must point only at this worktree. -Force overwrites any
# existing 'folders' (and adds it if absent), version-safely.
$FoldersParams = @{
    NotePropertyName  = 'folders'
    NotePropertyValue = @([pscustomobject]@{ path = '.' })
    Force             = $true
}
$ws | Add-Member @FoldersParams

# -Depth 32: ConvertTo-Json defaults to depth 2 and silently stringifies
# anything deeper (e.g. nested settings). -Encoding utf8: keep 5.1 from writing
# UTF-16LE, which 'code' won't like.
Write-Echo "write $wsFile"
$ws | ConvertTo-Json -Depth 32 | Set-Content -LiteralPath $wsFile -Encoding utf8

if ($needExclude) {
    Write-Echo "append '$pattern' to $exclude"
    Add-Content -LiteralPath $exclude -Value $pattern
}

if (-not $NoBootstrap) {

    # --- step: link config files --------------------------------------------

    # Link local .vscode/launch.json and settings.json into the worktree. Skip
    # any that already exist: a committed .vscode file is checked out by the
    # worktree, and we don't clobber tracked files.
    $links = @()
    $vscodeSrc = Join-Path -Path $repoRoot -ChildPath '.vscode'
    foreach ($name in @('launch.json', 'settings.json')) {
        $src = Join-Path -Path $vscodeSrc -ChildPath $name
        $dst = Join-Path -Path (Join-Path -Path $wtPath -ChildPath '.vscode') -ChildPath $name
        if ((Test-Path -LiteralPath $src) -and -not (Test-Path -LiteralPath $dst)) {
            $links += [pscustomobject]@{ Src = $src; Dst = $dst; Label = ".vscode/$name" }
        }
    }

    # Link every .env / .env.* file (testing, production, ...) so each worktree
    # shares the repo's single copy. Skip .env.example templates.
    $envFiles = Get-ChildItem -LiteralPath $repoRoot -File -Force -ErrorAction SilentlyContinue |
        Where-Object {
            ($_.Name -eq '.env' -or $_.Name -like '.env.*') -and
            $_.Name -notlike '*.example'
        }
    foreach ($envFile in $envFiles) {
        $links += [pscustomobject]@{
            Src   = $envFile.FullName
            Dst   = Join-Path -Path $wtPath -ChildPath $envFile.Name
            Label = $envFile.Name
        }
    }

    Write-Section 'Step: link config files'
    if ($links) {
        Write-Host '  Files to link or copy into the worktree:' -ForegroundColor DarkGray
        foreach ($link in $links) {
            Write-Host "  - $($link.Label)" -ForegroundColor DarkGray
        }
        Confirm-Step 'Link/copy these files into the worktree?'
        foreach ($link in $links) {
            $dstDir = Split-Path -Path $link.Dst -Parent
            New-Item -ItemType Directory -Path $dstDir -Force | Out-Null   # idempotent
            Write-Echo "link $($link.Dst) -> $($link.Src)"
            try {
                $LinkParams = @{
                    ItemType    = 'SymbolicLink'
                    Path        = $link.Dst
                    Target      = $link.Src
                    ErrorAction = 'Stop'
                }
                New-Item @LinkParams | Out-Null
            }
            catch {
                # Creating symlinks on Windows requires Developer Mode or
                # elevation, so a plain copy is the fallback.
                Copy-Item -LiteralPath $link.Src -Destination $link.Dst
                Write-Warn "  Symlink unavailable; copied $($link.Label) instead."
            }
        }
    }
    else {
        Write-Host '  Nothing to link.' -ForegroundColor DarkGray
    }

    # --- step: install dependencies -----------------------------------------

    Write-Section 'Step: install dependencies'
    if ((Test-Path -LiteralPath (Join-Path -Path $wtPath -ChildPath 'uv.lock')) -or
        (Test-Path -LiteralPath (Join-Path -Path $wtPath -ChildPath 'pyproject.toml'))) {
        if (Get-Command uv -ErrorAction SilentlyContinue) {
            Confirm-Step "Run 'uv sync' in the new worktree?"
            Push-Location -LiteralPath $wtPath
            try { Invoke-Run uv sync }
            finally { Pop-Location }
        }
        else {
            Write-Warn "  'uv' not found on PATH; skipping dependency install."
        }
    }
    elseif (Test-Path -LiteralPath (Join-Path -Path $wtPath -ChildPath 'package-lock.json')) {
        if (Get-Command npm -ErrorAction SilentlyContinue) {
            Confirm-Step "Run 'npm ci' in the new worktree?"
            Push-Location -LiteralPath $wtPath
            try { Invoke-Run npm ci }
            finally { Pop-Location }
        }
        else {
            Write-Warn "  'npm' not found on PATH; skipping dependency install."
        }
    }
    else {
        $note = '  No uv project or npm lockfile found; nothing to install.'
        Write-Host $note -ForegroundColor DarkGray
    }
}

# --- step: open VS Code -----------------------------------------------------

Write-Section 'Step: open VS Code'
if (Get-Command code -ErrorAction SilentlyContinue) {
    Confirm-Step "Open VS Code with '$wsName'?"
    Invoke-Run code $wsFile
}
else {
    Write-Warn "  VS Code 'code' command not found; open manually: $wsFile"
}

# --- done -------------------------------------------------------------------

Write-Section 'Done'
Write-Success "  Created worktree '$Slug'."
Write-Info 'Worktree' $wtPath
Write-Info 'Branch' $branch
Write-Info 'Workspace' $wsFile
