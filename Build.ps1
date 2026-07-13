<#
.SYNOPSIS
    Builds a module's distributable artifacts (manifest + flat .psm1) from the source tree.

.DESCRIPTION
    Intended to be non-project-specific and reusable across modules without modification.

    Compiles the per-function source layout under .\source into a single self-contained
    module using ModuleBuilder. The output is always cleaned before building so a stale
    artifact can never survive a build.

    By default it produces a versioned build under .\output (output\<ModuleName>\<version>\),
    which is the layout Publish-Module expects for the PowerShell Gallery.

    With -BuildToRoot, it instead emits a flat, unversioned manifest and .psm1 to the repo
    root and commits them, so a fresh clone placed on $env:PSModulePath is immediately
    importable by name with no build step. In that mode the root artifacts are generated
    files that must never be hand-edited - only .\source is edited, and only this script
    writes the root.

    The source manifest under .\source is always the metadata source of truth. The module
    name is derived from it, so the script is portable across modules without modification.
    ModuleBuilder is installed to CurrentUser scope on demand if missing.

    Linting and testing are intentionally NOT handled here - this script is dedicated to
    building. Run those from their own scripts.

    If a PreBuild.ps1 script exists in the repo root it is invoked automatically
    before the ModuleBuilder step. Use it for project-specific tasks such as generating
    files that must be present in the source tree before the build runs.

    If a PostBuild.ps1 script exists in the repo root it is invoked automatically
    after the ModuleBuilder step. Use it for project-specific tasks that depend on
    the finished build output (e.g. copying extra files, updating docs).

.PARAMETER SourcePath
    Path to the source directory containing the source manifest, Public/, Private/, etc.
    Defaults to the 'source' folder next to this script.

.PARAMETER OutputDirectory
    Optional override for the build output location. When omitted, the
    OutputDirectory value in Source\Build.psd1 is used (resolved relative to
    Source\), falling back to the 'Output' folder next to this script.
    Ignored when -BuildToRoot is specified.

.PARAMETER Version
    Optional version to stamp into the built manifest, overriding the source manifest's
    ModuleVersion. Intended for CI to pass a computed version.

.PARAMETER BuildToRoot
    Emit a flat, unversioned build to the repo root instead of a versioned build to
    .\output. Use this for repos distributed by git clone rather than the Gallery.

.EXAMPLE
    .\build.ps1
    Cleans and produces a versioned build in .\output using the source manifest version.

.EXAMPLE
    .\build.ps1 -Version 1.2.0
    Cleans and builds into .\output stamped with version 1.2.0, ready for Publish-Module.
    The form typically called from CI.

.EXAMPLE
    .\build.ps1 -BuildToRoot
    Cleans and compiles the module to the repo root so a clone on $env:PSModulePath works
    immediately.

.NOTES
    Build artifacts are staged in .\.staging (gitignored) and removed after a successful
    build. If the module takes PSFramework (or any module) as a RequiredModules dependency,
    consumers still need to Install-Module it before importing.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '')]
[CmdletBinding()]
param(
    [string] $SourcePath = (Join-Path -Path $PSScriptRoot -ChildPath 'Source'),
    [string] $OutputDirectory,
    [string] $Version,

    [switch] $BuildToRoot
)

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseDeclaredVarsMoreThanAssignments', 'ScriptVersion')]
$ScriptVersion = '1.0.0'

$ErrorActionPreference = 'Stop'
$RepoRoot = $PSScriptRoot
$Staging = Join-Path -Path $RepoRoot -ChildPath '.staging'

# Source manifest is the metadata source of truth (exclude ModuleBuilder's Build.psd1)
$srcManifest = Get-ChildItem -Path $SourcePath -Filter '*.psd1' |
    Where-Object Name -ne 'Build.psd1' |
    Select-Object -First 1
if (-not $srcManifest) { throw "No source manifest found under $SourcePath" }
$ModuleName = $srcManifest.BaseName

# Build.psd1 supplies Build-Module's defaults. Build.ps1 reads it too so the
# clean step and CopyPaths handling agree with what Build-Module will do.
$buildPsd1Path = Join-Path -Path $SourcePath -ChildPath 'Build.psd1'
$buildConfig = @{}
if (Test-Path $buildPsd1Path) {
    $buildConfig = Import-PowerShellDataFile -Path $buildPsd1Path
}

# Resolve the output directory: explicit -OutputDirectory wins, then
# Build.psd1's OutputDirectory (relative to Source\), then .\Output.
if (-not $OutputDirectory) {
    $OutputDirectory = if ($buildConfig.OutputDirectory) {
        $OutDirJoin = Join-Path -Path $SourcePath -ChildPath $buildConfig.OutputDirectory
        [System.IO.Path]::GetFullPath($OutDirJoin)
    } else {
        Join-Path -Path $PSScriptRoot -ChildPath 'Output'
    }
}

function Resolve-Dependency {
    param([string] $Name, [version] $MinimumVersion)
    $have = Get-Module -ListAvailable -Name $Name |
        Sort-Object Version -Descending | Select-Object -First 1
    if (-not $have -or ($MinimumVersion -and $have.Version -lt $MinimumVersion)) {
        $params = @{ Name = $Name; Scope = 'CurrentUser'; Force = $true; AllowClobber = $true }
        if ($MinimumVersion) { $params.MinimumVersion = $MinimumVersion }
        Write-Host "Installing $Name..." -ForegroundColor Cyan
        Install-Module @params
    }
    Import-Module $Name -Force
}

# --- Clean (always runs first) -------------------------------------------------
Write-Host '==> Clean' -ForegroundColor Green
if (Test-Path $Staging) { Remove-Item $Staging -Recurse -Force }

if ($BuildToRoot) {
    # Remove the committed root artifacts (regenerated by the build below)
    $rootArtifacts = @(
        (Join-Path -Path $RepoRoot -ChildPath "$ModuleName.psd1")
        (Join-Path -Path $RepoRoot -ChildPath "$ModuleName.psm1")
    )

    # Add CopyPaths folders declared in Build.psd1
    foreach ($cp in $buildConfig.CopyPaths) {
        $rootArtifacts += Join-Path -Path $RepoRoot -ChildPath (Split-Path -Path $cp -Leaf)
    }

    # Add any culture-named help folders present in the source tree (e.g. en-US)
    Get-ChildItem -Path $SourcePath -Directory |
        Where-Object { $_.Name -match '^\w{2}(-\w{2,4})?$' } |
        ForEach-Object { $rootArtifacts += Join-Path -Path $RepoRoot -ChildPath $_.Name }

    foreach ($path in $rootArtifacts) {
        if (Test-Path $path) { Remove-Item $path -Recurse -Force }
    }
}
else {
    if (Test-Path $OutputDirectory) { Remove-Item $OutputDirectory -Recurse -Force }
}

# --- Pre-build hook ------------------------------------------------------------
$preBuildScript = Join-Path -Path $RepoRoot -ChildPath 'Build\PreBuild.ps1'
if (Test-Path $preBuildScript) {
    Write-Host '==> PreBuild' -ForegroundColor Green
    & $preBuildScript
}

# --- Build ---------------------------------------------------------------------
Write-Host '==> Build' -ForegroundColor Green
Resolve-Dependency -Name ModuleBuilder

if ($BuildToRoot) {
    # Flat build into staging, then mirror up to the repo root.
    $buildParams = @{
        SourcePath                 = $srcManifest.FullName
        OutputDirectory            = $Staging
        UnversionedOutputDirectory = $true   # flat: .staging\<ModuleName>\
        Passthru                   = $true
    }
    if ($Version) { $buildParams.Version = $Version }
    $built = Build-Module @buildParams

    $BuiltSrc = Join-Path -Path $built.ModuleBase -ChildPath '*'
    Copy-Item -Path $BuiltSrc -Destination $RepoRoot -Recurse -Force
    Remove-Item $Staging -Recurse -Force

    $Msg = "   $ModuleName $($built.Version) -> repo root"
    Write-Host $Msg -ForegroundColor Cyan
}
else {
    # Default build. Versioning behavior comes from Build.psd1
    # (VersionedOutputDirectory); only the resolved output path is passed.
    $buildParams = @{
        SourcePath      = $srcManifest.FullName
        OutputDirectory = $OutputDirectory
        Passthru        = $true
    }
    if ($Version) { $buildParams.Version = $Version }
    $built = Build-Module @buildParams

    $Msg = "   $ModuleName $($built.Version) -> $($built.ModuleBase)"
    Write-Host $Msg -ForegroundColor Cyan
}

# --- Post-build hook -----------------------------------------------------------
$postBuildScript = Join-Path -Path $RepoRoot -ChildPath 'Build\PostBuild.ps1'
if (Test-Path $postBuildScript) {
    Write-Host '==> PostBuild' -ForegroundColor Green
    & $postBuildScript
}
