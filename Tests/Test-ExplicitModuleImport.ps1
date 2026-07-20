<#
.SYNOPSIS
    A developer helper script. Checks that each source file explicitly names
    every external module it uses.
.DESCRIPTION
    For each .ps1 file under Source\, parses the file with Find-ScriptCommand,
    resolves each command to its owning module with Resolve-CommandModule, and
    checks that every module classified as Installed appears as a literal string
    in the file. The intent is to ensure each file explicitly imports (or at
    least names) every external module it depends on.

    To suppress all findings for a file, add this comment anywhere in the file:

        # noqa: Test-ExplicitModuleImport

.PARAMETER Path
    Root directory to search. Defaults to the current directory.
.PARAMETER Recurse
    Search subdirectories recursively.
.PARAMETER Quiet
    Suppress the per-finding table, printing only the one-line summary. Useful
    for a quick pass/fail check.
.OUTPUTS
    Formatted table to the host. No pipeline output.
.EXAMPLE
    .\Test-ExplicitModuleImport.ps1 -Path . -Recurse
    Lists all external-module usage that lacks an explicit module name reference.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '')]
[CmdletBinding()]
param(
    [string] $Path = (Get-Location).Path,
    [switch] $Recurse,
    [switch] $Quiet
)

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseDeclaredVarsMoreThanAssignments', 'ScriptVersion')]
$ScriptVersion = '1.0.1'

# import helper functions from the Scripts folder.
. (Join-Path -Path $PSScriptRoot -ChildPath '..\Scripts\Find-ScriptCommand.ps1')
. (Join-Path -Path $PSScriptRoot -ChildPath '..\Scripts\Resolve-CommandModule.ps1')

# Resolve the module name from the repo's Source\ manifest (excluding ModuleBuilder's
# Build.psd1), for standalone runs where $Global:Dev_ModuleName has not been set by the
# Tests.ps1 orchestrator. The repo root is located via git, so this stays correct in a
# worktree (where the folder name is the branch, not the module name).
function Get-SourceModuleName {
    param([Parameter(Mandatory)][string]$Path)
    $global:LASTEXITCODE = 0
    $RepoRoot = git -C $Path rev-parse --show-toplevel 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $RepoRoot) { return $null }
    $SourceDir = Join-Path -Path $RepoRoot -ChildPath 'Source'
    if (-not (Test-Path -LiteralPath $SourceDir)) { return $null }
    $Manifest = Get-ChildItem -LiteralPath $SourceDir -Filter '*.psd1' -File |
        Where-Object Name -ne 'Build.psd1' |
        Select-Object -First 1
    if ($Manifest) { return $Manifest.BaseName }
    return $null
}

# This check enforces the explicit-import convention from AGENTS.md, which
# applies only to in-domain code under Source\. Dev tooling, build scripts,
# tests, and module-init/data folders (ScriptsToProcess, Data) are non-domain
# and exempt.
$ExcludedFolders = @(
    'Scripts', 'Tests', 'Build', 'Docs', 'Source\ScriptsToProcess', 'Source\Data', '.local'
)
$ExcludedFiles = @('Build.ps1', 'Tests.ps1', 'Docs.ps1')

if (Get-Variable -Name Dev_FormattingExclusions -Scope Global -ErrorAction SilentlyContinue) {
    $ExcludedFiles += $Global:Dev_FormattingExclusions.ExcludeFiles
    $ExcludedFolders += $Global:Dev_FormattingExclusions.ExcludeFolders
}

$Stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

# Find current module name. Error out if not currently imported.
#   Prefer erroring over importing because script doesn't know if dev wants
#   to test source or build module.
# The orchestrator resolves the module name from the manifest (worktree-safe)
# and shares it via $Global:Dev_ModuleName; prefer that. Fall back to resolving
# the repo root via git and reading its Source\ manifest for standalone runs.
$ModuleNameSet = Get-Variable -Name Dev_ModuleName -Scope Global -ErrorAction SilentlyContinue
$CurrentModuleName = if ($ModuleNameSet) {
    $Global:Dev_ModuleName
}
else {
    Get-SourceModuleName -Path $PSScriptRoot
}
if (-not $CurrentModuleName) {
    $ErrMsg = 'Could not determine the module name. Run via Tests.ps1, ' +
    'or ensure the repo folder matches the module manifest.'
    throw $ErrMsg
}
if (-not (Get-Module -Name $CurrentModuleName)) {
    $ErrMsg = "Module '$CurrentModuleName' is not imported. " +
    "Import it before running this test."
    throw $ErrMsg
}

# Static map for commands that Get-Command cannot discover on this machine
# Add entries as new undiscoverable dependencies are introduced.
$CommandModuleMap = @{
}

$GetChildParams = @{
    Path = $Path
    File = $true
}
if ($Recurse) {
    $GetChildParams.Recurse = $true
}

$files = Get-ChildItem @GetChildParams |
    Where-Object Extension -eq '.ps1' |
    Where-Object {
        $Rel = [System.IO.Path]::GetRelativePath($Path, $_.FullName)
        (-not ($ExcludedFiles -contains $Rel)) -and
        (-not ($ExcludedFolders | Where-Object { $Rel -like "$_\*" }))
    }

$hitCount = 0
$totalFiles = 0
$hits = [System.Collections.Generic.List[PSCustomObject]]::new()

$FileTotal = @($files).Count
$FileIndex = 0

foreach ($file in $files) {
    $FileIndex++
    $WpParams = @{
        Activity        = $MyInvocation.MyCommand.Name
        Status          = [System.IO.Path]::GetRelativePath($Path, $file.FullName)
        PercentComplete = ($FileIndex / $FileTotal) * 100
    }
    Write-Progress @WpParams
    $totalFiles++

    $content = Get-Content -Path $file.FullName -Raw

    if ($content -match '#\s*noqa:\s*Test-ExplicitModuleImport') { continue }

    # Functions defined in the file itself (including nested helpers) are not
    # external dependencies; without this they all surface as NotFound noise.
    $commands = @(Find-ScriptCommand -Path $file.FullName -ExcludeLocalFunctions)
    if ($commands.Count -eq 0) { continue }

    $ResolvedCommands = $commands | Resolve-CommandModule -HostModuleName $CurrentModuleName
    # @() guard: with no HostPrivate commands the pipeline yields $null, and
    # casting $null to HashSet produces $null rather than an empty set.
    $PrivateShadowed = [System.Collections.Generic.HashSet[string]]@(
        $ResolvedCommands |
            Where-Object { $_.Source -eq 'HostPrivate' } |
            Select-Object -ExpandProperty Name
    )
    $InstalledCommands = $ResolvedCommands |
        Where-Object { $_.Source -eq 'Installed' -and -not $PrivateShadowed.Contains($_.Name) } |
        Select-Object Name, Module

    $MappedCommands = $ResolvedCommands |
        Where-Object { $_.Source -eq 'NotFound' -and $CommandModuleMap.ContainsKey($_.Name) } |
        ForEach-Object { [PSCustomObject]@{ Name = $_.Name; Module = $CommandModuleMap[$_.Name] } }

    # Names without a hyphen are not module commands: native tools (repadmin)
    # or bare words the parser reads as commands inside AD -Filter
    # scriptblocks (AdminCount).
    $UnknownCommands = @(
        $ResolvedCommands |
            Where-Object {
                $_.Source -eq 'NotFound' -and
                $_.Name -match '-' -and
                -not $PrivateShadowed.Contains($_.Name) -and
                -not $CommandModuleMap.ContainsKey($_.Name)
            }
    )

    $ModuleGroups = @($InstalledCommands) + @($MappedCommands) | Group-Object -Property Module

    foreach ($group in $ModuleGroups) {
        if ($content -notlike "*$($group.Name)*") {
            $hitCount++
            $hits.Add([PSCustomObject]@{
                    File     = [System.IO.Path]::GetRelativePath($Path, $file.FullName)
                    Module   = $group.Name
                    Commands = ($group.Group.Name | Sort-Object -Unique) -join ', '
                })
        }
    }

    if ($UnknownCommands.Count -gt 0) {
        $hitCount++
        $hits.Add([PSCustomObject]@{
                File     = [System.IO.Path]::GetRelativePath($Path, $file.FullName)
                Module   = '(unknown - add to $CommandModuleMap)'
                Commands = ($UnknownCommands.Name | Sort-Object -Unique) -join ', '
            })
    }
}

if ($hitCount -gt 0 -and -not $Quiet) {
    $hits | Format-Table -AutoSize
}

Write-Progress -Activity $MyInvocation.MyCommand.Name -Completed
$Stopwatch.Stop()
$Elapsed = "$([math]::Round($Stopwatch.Elapsed.TotalSeconds, 2))s"
$SummaryColor = if ($hitCount -gt 0) { 'Red' } else { 'Green' }
$Msg = "$hitCount missing module reference(s) -- $totalFiles file(s) checked. ($Elapsed)"
Write-Host $Msg -ForegroundColor $SummaryColor

# Throw (not exit) so pre-commit/CI still see a nonzero process exit via an
# uncaught error, without risking closing an interactive host if this script
# is ever dot-sourced or run directly at a prompt instead of through Tests.ps1.
if ($hitCount -gt 0) { throw $Msg }
