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

.PARAMETER NoManifest
    Release a repo that has no .psd1 manifest (a bare script). The manifest is
    never read or written; the tag is cut from -Version alone. Requires
    -Version (there is no manifest to derive or bump a version from), so it is
    only valid together with it. Merge, tag 'v<Version>', and push proceed as
    normal.

.PARAMETER ManifestPath
    Path to the .psd1 manifest holding ModuleVersion. If omitted, the manifest
    is resolved from the source tree: the repo root is located with
    'git rev-parse --show-toplevel' and its Source\ folder is searched for a
    single .psd1 (excluding ModuleBuilder's Build.psd1).

.PARAMETER Build
    Whether to build the module after updating the version, using Build.ps1 in
    the repo root. One of:
      none   - do not build (default); leave building to CI or a separate step
      root   - flat build to the repo root (Build.ps1 -BuildToRoot), for repos
               distributed by git clone; regenerated artifacts are committed
      output - versioned build to Output\ (Build.ps1), for Gallery publishing;
               Output\ is gitignored so nothing extra is committed
    The build runs even when the version is unchanged, since merged code
    changes still need rebuilding.

.PARAMETER Yes
    Assume 'yes' to every confirmation prompt (non-interactive). The prompt is
    still printed with the auto-answer so the transcript records each step.

.EXAMPLE
    .\Push-NewTagToMain.ps1 -Bump patch

.EXAMPLE
    .\Push-NewTagToMain.ps1 -Version 2.0.0

.EXAMPLE
    .\Push-NewTagToMain.ps1 -NoVersion

.EXAMPLE
    .\Push-NewTagToMain.ps1 -NoManifest -Version 1.2.0 -Build none

.EXAMPLE
    .\Push-NewTagToMain.ps1 -Bump patch -Yes

.EXAMPLE
    .\Push-NewTagToMain.ps1 -Bump patch -Build root

.NOTES
    Requirements:
      - PowerShell 7.4 or later.
      - Run from inside the source branch with a clean working tree.
      - Push access to origin for both main and the source branch.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPositionalParameters', '')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseShouldProcessForStateChangingFunctions', '')]
[CmdletBinding(DefaultParameterSetName = 'Bump')]
param(
    [Parameter(ParameterSetName = 'Bump', Mandatory)]
    [ValidateSet('patch', 'minor', 'major')]
    [string]$Bump,

    [Parameter(ParameterSetName = 'Version', Mandatory)]
    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string]$Version,

    [Parameter(ParameterSetName = 'NoVersion', Mandatory)]
    [switch]$NoVersion,

    # In the 'Version' set only, so it always pairs with an explicit -Version:
    # a manifest-less repo (a bare script) has nothing to read a version from or
    # write one to, so the version cannot be derived or bumped.
    [Parameter(ParameterSetName = 'Version')]
    [switch]$NoManifest,

    [string]$ManifestPath,

    [Parameter(Mandatory)]
    [ValidateSet('none', 'root', 'output')]
    [string]$Build,

    [Alias('y')]
    [switch]$Yes
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseDeclaredVarsMoreThanAssignments', 'ScriptVersion')]
$ScriptVersion = '1.3.0'

$useBump = $PSCmdlet.ParameterSetName -eq 'Bump'
$useNoVersion = [bool]$NoVersion
$useNoManifest = [bool]$NoManifest

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
        throw 'Aborted by user.'
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

# Locate the repo root via git, or $null if not in a working tree.
function Get-RepoRoot {
    $top = Invoke-NativeOk git rev-parse --show-toplevel
    if (-not $top) { return $null }
    # git prints forward slashes; normalize to a real filesystem path.
    return (Resolve-Path -LiteralPath $top).Path
}

# Resolve the manifest holding ModuleVersion. Priority:
#   1. Explicit -ManifestPath.
#   2. The single source manifest under the repo's Source\ folder (excluding
#      ModuleBuilder's Build.psd1) -- the metadata source of truth for a
#      ModuleBuilder layout, where the built copy in the root (if any) is
#      generated and must not be edited.
function Find-Manifest {
    param([string]$Path)

    if ($Path) {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            throw "Manifest not found: '$Path'."
        }
        return (Resolve-Path -LiteralPath $Path).Path
    }

    # Prefer the source manifest under Source\ when this is a ModuleBuilder repo.
    $repoRoot = Get-RepoRoot
    if ($repoRoot) {
        $sourceDir = Join-Path -Path $repoRoot -ChildPath 'Source'
        if (Test-Path -LiteralPath $sourceDir -PathType Container) {
            $srcCandidates = @(
                Get-ChildItem -Path $sourceDir -Filter '*.psd1' -File |
                    Where-Object Name -ne 'Build.psd1'
            )
            if ($srcCandidates.Count -eq 1) {
                return $srcCandidates[0].FullName
            }
            elseif ($srcCandidates.Count -gt 1) {
                $names = ($srcCandidates | Select-Object -ExpandProperty Name) -join ', '
                throw "Multiple .psd1 files found in '$sourceDir': $names. Specify -ManifestPath."
            }
        }
    }

    throw "No single .psd1 found under the repo's Source\ folder. Specify -ManifestPath."
}

# Surgically rewrite only the ModuleVersion assignment in the manifest, leaving
# every comment, blank line, and other key untouched. Update-ModuleManifest is
# deliberately NOT used: it re-serializes the whole file with PowerShellGet's own
# writer, which clobbers a curated ModuleBuilder source manifest (adds a PSGet_
# header, drops all comments, and collapses FunctionsToExport = '*' -- the
# sentinel Build-Module replaces at build time -- to @(), which would export no
# functions).
function Set-ManifestVersion {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][version]$NewVersion
    )
    $content = Get-Content -LiteralPath $Path -Raw
    # Match an uncommented 'ModuleVersion = "x"' assignment; capture indent and
    # spacing in 'pre' so alignment is preserved. Anchored to line start (after
    # optional whitespace) so a commented '# ModuleVersion' line cannot match.
    $pattern = "(?m)^(?<pre>\s*ModuleVersion\s*=\s*)(?<q>['`"])[^'`"]*\k<q>"
    $count = ([regex]::Matches($content, $pattern)).Count
    if ($count -ne 1) {
        throw "Expected exactly one ModuleVersion assignment in '$Path'; found $count."
    }
    $replacement = "`${pre}'$($NewVersion.ToString())'"
    $updated = [regex]::Replace($content, $pattern, $replacement)
    Set-Content -LiteralPath $Path -Value $updated -NoNewline -Encoding utf8
}

# --- gather state ----------------------------------------------------------

if ($MyInvocation.InvocationName -eq '.') { return }

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
if ($useNoManifest) {
    Write-Info "Version change" "tag '$Version' only (-NoManifest)"
}
elseif ($useNoVersion) {
    Write-Info "Version change" "none (-NoVersion)"
}
elseif ($useBump) {
    Write-Info "Version change" "bump '$Bump'"
}
else {
    Write-Info "Version change" "set to '$Version'"
}
Write-Info "Build" $Build

# Resolve and validate the build script up front so a missing Build.ps1 fails
# during setup rather than after the merge has already happened.
$buildScript = $null
if ($Build -ne 'none') {
    $repoRoot = Get-RepoRoot
    if (-not $repoRoot) {
        throw "-Build '$Build' requires a git repository, but the repo root could not be found."
    }
    $buildScript = Join-Path -Path $repoRoot -ChildPath 'Build.ps1'
    if (-not (Test-Path -LiteralPath $buildScript -PathType Leaf)) {
        $NoBuildMsg = "-Build '$Build' requires Build.ps1 in the repo root, but none " +
        "was found at '$buildScript'."
        throw $NoBuildMsg
    }
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

if ($useNoManifest) {
    # No manifest to read or write: the tag comes straight from -Version and no
    # version-update step runs. $currentVersion is set to the same value so the
    # shared tag/commit logic below can treat it uniformly.
    $manifest = $null
    $currentVersion = [version]$Version
    $newVersion = $currentVersion
    $versionChanged = $false
    Write-Info "Manifest" "none (-NoManifest)"
    Write-Info "Tag version" $Version
}
else {
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
        $ResultMsg = 'version already set; manifest update skipped ' +
        '(a build may still commit)'
        Write-Info "Result" $ResultMsg
    }
}

# The tag that will be created below. Check it up front, before any merge or
# commit, so a duplicate aborts while the repo is still untouched rather than
# after it has been left on main with a release commit made. Runs in every mode.
$targetTag = "v$($newVersion.ToString())"
if (Invoke-NativeOk git rev-parse --verify --quiet "refs/tags/$targetTag") {
    $DupTagMsg = "Tag '$targetTag' already exists; nothing to release. " +
    'Delete it or choose another version.'
    throw $DupTagMsg
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
        Write-Run "Set-ManifestVersion -Path `"$manifest`" -NewVersion $newVersion"
        Set-ManifestVersion -Path $manifest -NewVersion $newVersion
    }

    # Read the manifest back rather than trusting the in-memory value, so the
    # commit/tag below always reflect what was actually written.
    $versionStr = ([version](Import-PowerShellDataFile -Path $manifest).ModuleVersion).ToString()
    if ($versionStr -ne $newVersion.ToString()) {
        throw "Manifest reports version '$versionStr' after update; expected '$newVersion'."
    }
    Write-Info "New version" $versionStr
}
else {
    $versionStr = $currentVersion.ToString()
}

# Build after the version bump so root builds stamp the new version into the
# regenerated artifacts. Runs even when the version is unchanged, since merged
# code still needs rebuilding.
if ($Build -ne 'none') {
    Write-Section "Step: build ($Build)"
    if ($Build -eq 'root') {
        Invoke-Step "Build the module to the repo root (Build.ps1 -BuildToRoot)?" {
            Write-Run "& `"$buildScript`" -BuildToRoot"
            & $buildScript -BuildToRoot
        }
    }
    else {
        Invoke-Step "Build the module to Output\ (Build.ps1)?" {
            Write-Run "& `"$buildScript`""
            & $buildScript
        }
    }
}

# Commit when the version changed or when the build left tracked files dirty
# (a root build regenerates committed artifacts; an output build touches only
# the gitignored Output\ folder, leaving nothing to commit). The working tree
# was verified clean at startup, so any dirtiness here is script-generated.
$treeDirty = $false
try {
    git diff-index --quiet HEAD --
}
catch {
    $treeDirty = $true
}

if ($versionChanged -or $treeDirty) {
    Write-Section "Step: commit release"
    Invoke-Step "Stage all changes and commit as 'Release v$versionStr'?" {
        Write-Run "git add -A"
        git add -A
        Write-Run "git commit -m `"Release v$versionStr`""
        git commit -m "Release v$versionStr"
    }
}
else {
    Write-Section "Step: commit release"
    Write-Host "  Nothing to commit; skipping." -ForegroundColor Green
}

Write-Section "Step: tag release"
Invoke-Step "Create annotated tag '$targetTag'?" {
    Write-Run "git tag -a `"$targetTag`" -m `"Release $versionStr`""
    git tag -a "$targetTag" -m "Release $versionStr"
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
