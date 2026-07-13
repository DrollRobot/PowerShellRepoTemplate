#Requires -Version 7.4

<#
.SYNOPSIS
    Interactively merge the current branch into main, bump the module version, tag, and push.

.DESCRIPTION
    Walks through the release process one step at a time. Before each action it
    shows what is about to happen and prompts for confirmation (y/n); answering
    'n' aborts without making any further changes. The output of every git
    command is shown so the process can be watched as it happens. Pass -Yes to
    answer every prompt with 'y' for non-interactive use.

    Along the way it reports the original branch, the working-tree status, and
    the current and target module versions read from the .psd1 manifest.

    Before merging it fetches from origin and fast-forwards both the source
    branch and main if either is behind its remote, so a release can never be
    cut from a stale branch (e.g. a PR merged on the remote but not yet pulled).
    A diverged branch aborts.

    The new version can either be bumped semantically (patch/minor/major), set
    to an explicit version number with -Version, or left unchanged with
    -NoVersion. When -Version names the version already in use, the version
    change is skipped automatically (same as -NoVersion). When the version is
    not changed, the manifest update and the release commit are skipped, but the
    current version is still tagged and pushed.

.PARAMETER Bump
    Semantic version bump level. One of:
      patch - bug fixes only           (1.4.2 -> 1.4.3)
      minor - new features, no breaks  (1.4.2 -> 1.5.0)
      major - breaking changes         (1.4.2 -> 2.0.0)

.PARAMETER Version
    An explicit version number to set (e.g. 1.5.0). Use instead of -Bump.

.PARAMETER NoVersion
    Merge, tag, and push without changing the version (no manifest update or
    release commit). For when the version was already updated by hand.

.PARAMETER ManifestPath
    Path to the .psd1 manifest holding ModuleVersion. If omitted, walks up the
    directory tree from the current location until a directory containing
    exactly one .psd1 file is found.

.PARAMETER Yes
    Assume 'yes' to every confirmation prompt (non-interactive). The prompt is
    still printed with the auto-answer so the transcript records each step.

.EXAMPLE
    .\Push-NewTagToMain.ps1 patch

.EXAMPLE
    .\Push-NewTagToMain.ps1 -Version 2.0.0

.EXAMPLE
    .\Push-NewTagToMain.ps1 -NoVersion

.EXAMPLE
    .\Push-NewTagToMain.ps1 patch -Yes

.NOTES
    Requirements:
      - PowerShell 7.4 or later.
      - Run from inside the source branch with a clean working tree.
      - Push access to origin for both main and the source branch.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPositionalParameters', '')]
[CmdletBinding(DefaultParameterSetName = 'Bump')]
param(
    [Parameter(ParameterSetName = 'Bump', Mandatory, Position = 0)]
    [ValidateSet('patch', 'minor', 'major')]
    [string]$Bump,

    [Parameter(ParameterSetName = 'Version', Mandatory)]
    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string]$Version,

    [Parameter(ParameterSetName = 'NoVersion', Mandatory)]
    [switch]$NoVersion,

    [string]$ManifestPath,

    [Alias('y')]
    [switch]$Yes
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseDeclaredVarsMoreThanAssignments', 'ScriptVersion')]
$ScriptVersion = '1.1.0'

$useBump = $PSCmdlet.ParameterSetName -eq 'Bump'
$useNoVersion = [bool]$NoVersion

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

# Report how far a local ref is ahead of and behind a remote ref. Aborts the
# script if the two refs have diverged (each has commits the other lacks), since
# reconciling that is a manual decision the release flow should not make. Returns
# an object with Ahead/Behind counts, or $null if either ref does not exist.
function Get-SyncStatus {
    param([string]$Local, [string]$Remote)
    if (-not (Invoke-NativeOk git rev-parse --verify --quiet $Local)) { return $null }
    if (-not (Invoke-NativeOk git rev-parse --verify --quiet $Remote)) { return $null }
    $ahead = [int](git rev-list --count "$Remote..$Local")
    $behind = [int](git rev-list --count "$Local..$Remote")
    Write-Info "'$Local' vs $Remote" "$ahead ahead, $behind behind"
    if ($ahead -gt 0 -and $behind -gt 0) {
        $DivergeMsg = "Local '$Local' has diverged from $Remote ($ahead ahead, $behind behind); " +
        'reconcile manually before releasing.'
        throw $DivergeMsg
    }
    return [pscustomobject]@{ Ahead = $ahead; Behind = $behind }
}

# Resolve the manifest: use the explicit path if given, otherwise walk up the
# directory tree until a directory containing exactly one .psd1 is found.
function Find-Manifest {
    param([string]$Path)

    if ($Path) {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            throw "Manifest not found: '$Path'."
        }
        return (Resolve-Path -LiteralPath $Path).Path
    }

    $searchDir = (Get-Location).Path
    while ($searchDir) {
        $candidates = @(Get-ChildItem -Path $searchDir -Filter '*.psd1' -File)
        if ($candidates.Count -eq 1) {
            return $candidates[0].FullName
        }
        elseif ($candidates.Count -gt 1) {
            $names = ($candidates | Select-Object -ExpandProperty Name) -join ', '
            throw "Multiple .psd1 files found in '$searchDir': $names. Specify -ManifestPath."
        }
        $parent = Split-Path -Path $searchDir -Parent
        if ($parent -eq $searchDir) { break }
        $searchDir = $parent
    }
    throw "No .psd1 file found walking up from '$(Get-Location)'."
}

# --- gather state ----------------------------------------------------------

Write-Host ''

Write-Section "Release setup"

# Detect current branch; fail on detached HEAD. symbolic-ref exits non-zero on
# detached HEAD, which throws under the native error preference -- wrap it to
# convert the throw into a clearer message.
try {
    $source = git symbolic-ref --short HEAD 2>$null
}
catch {
    throw "Not on a branch (detached HEAD?)"
}

if ($source -eq 'main') {
    throw "Already on main; switch to the source branch first."
}

Write-Info "Original branch" $source
Write-Info "Target branch" "main"
if ($useNoVersion) {
    Write-Info "Version change" "none (-NoVersion)"
}
elseif ($useBump) {
    Write-Info "Version change" "bump '$Bump'"
}
else {
    Write-Info "Version change" "set to '$Version'"
}

# --- working tree status ---------------------------------------------------

Write-Section "Working tree status"
Write-Run "git status --short --branch"
git status --short --branch

$treeClean = $true
try {
    git diff-index --quiet HEAD --
}
catch {
    $treeClean = $false
}
if ($treeClean) {
    Write-Host "  Working tree is clean." -ForegroundColor Green
}
else {
    throw "Working tree is not clean; commit or stash changes first."
}

# --- sync with origin -------------------------------------------------------

# Guard against releasing a stale branch. If a PR was merged into the source
# branch on the remote but never pulled, the local branch is behind origin and
# merging it into main would silently omit those commits. Fetch and fast-forward
# before anything is merged.
Write-Section "Sync with origin"
Write-Run "git fetch origin"
git fetch origin

# Source branch: it is checked out, so fast-forward it with a pull.
$upstream = "origin/$source"
$status = Get-SyncStatus -Local $source -Remote $upstream
if ($null -eq $status) {
    Write-Info "Note" "no '$upstream' on origin; nothing to sync"
}
elseif ($status.Behind -gt 0) {
    $BehindMsg = "  Local '$source' is $($status.Behind) commit(s) behind $upstream."
    Write-Host $BehindMsg -ForegroundColor Yellow
    Invoke-Step "Fast-forward '$source' to $upstream?" {
        Write-Run "git pull --ff-only origin $source"
        git pull --ff-only origin $source
    }
}
else {
    Write-Host "  '$source' is up to date with $upstream." -ForegroundColor Green
}

# Target branch: main is not checked out yet, so fast-forward its ref with a
# refspec fetch (which refuses a non-fast-forward update). Catches a stale local
# main early instead of at the 'git push origin main' rejection.
$mainStatus = Get-SyncStatus -Local 'main' -Remote 'origin/main'
if ($null -eq $mainStatus) {
    Write-Info "Note" "no local 'main' or 'origin/main'; nothing to sync"
}
elseif ($mainStatus.Behind -gt 0) {
    $BehindMsg = "  Local 'main' is $($mainStatus.Behind) commit(s) behind origin/main."
    Write-Host $BehindMsg -ForegroundColor Yellow
    Invoke-Step "Fast-forward local 'main' to origin/main?" {
        Write-Run "git fetch origin main:main"
        git fetch origin main:main
    }
}
else {
    Write-Host "  'main' is up to date with origin/main." -ForegroundColor Green
}

# --- versions --------------------------------------------------------------

Write-Section "Versions"

$manifest = Find-Manifest -Path $ManifestPath
$currentVersion = [version](Import-PowerShellDataFile -Path $manifest).ModuleVersion

# Decide whether the version actually changes. A bump always changes it; an
# explicit -Version only changes it when it differs from the current one.
if ($useNoVersion) {
    $versionChanged = $false
}
elseif (-not $useBump) {
    $versionChanged = ([version]$Version -ne $currentVersion)
    if (-not $versionChanged) {
        Write-Info "Note" "requested version matches current; version unchanged"
    }
}
else {
    $versionChanged = $true
}

$newVersion = if ($versionChanged) {
    if ($useBump) {
        switch ($Bump) {
            'major' { [version]::new($currentVersion.Major + 1, 0, 0) }
            'minor' { [version]::new($currentVersion.Major, $currentVersion.Minor + 1, 0) }
            'patch' {
                $patchNum = [Math]::Max($currentVersion.Build, 0) + 1
                [version]::new($currentVersion.Major, $currentVersion.Minor, $patchNum)
            }
        }
    }
    else {
        [version]$Version
    }
}
else {
    $currentVersion
}

Write-Info "Manifest" $manifest
Write-Info "Current version" $currentVersion
if ($versionChanged) {
    Write-Info "Target version" "$currentVersion -> $newVersion"
}
else {
    Write-Info "Result" "version already set; manifest update and release commit are skipped"
}

# --- release steps ---------------------------------------------------------

Write-Section "Step: switch to main"
Invoke-Step "Switch from '$source' to 'main'?" {
    Write-Run "git switch main"
    git switch main
}

Write-Section "Step: merge '$source' into main"
Invoke-Step "Merge '$source' into 'main'?" {
    Write-Run "git merge $source"
    git merge $source
}

if ($versionChanged) {
    Write-Section "Step: update version"
    Invoke-Step "Set ModuleVersion to $newVersion in the manifest?" {
        Write-Run "Update-ModuleManifest -Path `"$manifest`" -ModuleVersion $newVersion"
        Update-ModuleManifest -Path $manifest -ModuleVersion $newVersion
    }

    # Read the manifest back rather than trusting the in-memory value, so the
    # commit/tag below always reflect what was actually written.
    $versionStr = ([version](Import-PowerShellDataFile -Path $manifest).ModuleVersion).ToString()
    if ($versionStr -ne $newVersion.ToString()) {
        throw "Manifest reports version '$versionStr' after update; expected '$newVersion'."
    }
    Write-Info "New version" $versionStr

    Write-Section "Step: commit release"
    Invoke-Step "Stage the manifest and commit as 'Release v$versionStr'?" {
        Write-Run "git add `"$manifest`""
        git add "$manifest"
        Write-Run "git commit -m `"Release v$versionStr`""
        git commit -m "Release v$versionStr"
    }
}
else {
    $versionStr = $currentVersion.ToString()
}

Write-Section "Step: tag release"
Invoke-Step "Create annotated tag 'v$versionStr'?" {
    Write-Run "git tag -a `"v$versionStr`" -m `"Release $versionStr`""
    git tag -a "v$versionStr" -m "Release $versionStr"
}

Write-Section "Step: push main"
Invoke-Step "Push 'main' to origin?" {
    Write-Run "git push origin main"
    git push origin main
}

Write-Section "Step: push tags"
Invoke-Step "Push tags to origin?" {
    Write-Run "git push origin --tags"
    git push origin --tags
}

Write-Section "Step: return to '$source'"
Invoke-Step "Switch back to '$source'?" {
    Write-Run "git switch $source"
    git switch $source
}

Write-Section "Step: merge main into '$source'"
Invoke-Step "Merge 'main' into '$source'?" {
    Write-Run "git merge main"
    git merge main
}

Write-Section "Step: push '$source'"
Invoke-Step "Push '$source' to origin?" {
    Write-Run "git push origin $source"
    git push origin $source
}

# --- done ------------------------------------------------------------------

Write-Section "Done"
Write-Host "  Released v$versionStr." -ForegroundColor Green
Write-Info "Current branch" (git branch --show-current)
