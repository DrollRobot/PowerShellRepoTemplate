<#
.SYNOPSIS
    Fill in the module manifest's identity fields under Source\.

.DESCRIPTION
    A project created from this template must not keep the template's identity,
    so this step writes the manifest's own GUID, Author, CompanyName and
    Copyright:

        GUID         a fresh one from New-Guid, or the value passed to -Guid
        Author       -Author
        CompanyName  -CompanyName
        Copyright    '(c) <Year> <Author>. All rights reserved.'

    Setup feeds those from the [License] section of Scripts\setup.psd1 (Name,
    Company, Year), which describes the same person or organization the LICENSE
    file names. A blank value leaves that key at its template placeholder, so it
    still shows up in the closing FIXME report -- the 'gnu' and 'none' license
    choices require no holder name, so those repos fill in Author and Copyright
    by hand.

    Stamping the GUID also drops the placeholder note comments the template
    parks above that key (the FIXME telling you to mint a GUID by hand, and the
    warning that an all-zeros placeholder breaks ModuleBuilder, which reads
    [Guid]::Empty as "manifest could not be parsed").

    Values are written into each key's single-quoted string, so the manifest's
    own column alignment and line endings survive; a single quote inside a value
    is doubled, the escape a .psd1 string expects.

    The manifest is found by scanning Source\ for the single *.psd1 that is not
    Build.psd1, so this works either before or after the rename step has renamed
    it. Pass -ManifestPath to target one explicitly.

    Runnable on its own, or dot-sourced and called as one step of
    Scripts\TemplateSetup\Setup-NewProject.ps1. When dot-sourced it only defines
    the Set-ModuleManifest function; the parameter-driven body below runs solely
    on a direct invocation.

.PARAMETER RepoRoot
    Repository root to scan. Defaults to the repo two levels above this script
    (Scripts\TemplateSetup\ -> repo root).

.PARAMETER ManifestPath
    Manifest to fill in. Defaults to the single Source\*.psd1 that is not
    Build.psd1.

.PARAMETER Guid
    GUID to write. Defaults to a fresh one from New-Guid; pass a value only when
    the module already owns a GUID you need to keep.

.PARAMETER Author
    Module author. Setup passes [License].Name. Blank leaves the key alone.

.PARAMETER CompanyName
    Owning company or vendor. Setup passes [License].Company. Blank leaves the
    key alone.

.PARAMETER Year
    Copyright year, used with -Author to compose the Copyright statement. Setup
    passes [License].Year. Blank composes the statement from -Author alone.

.PARAMETER DryRun
    Preview the changes without writing anything.

.EXAMPLE
    .\Scripts\TemplateSetup\Set-ModuleManifest.ps1 -DryRun

    Shows which manifest keys would be filled in, without writing.

.EXAMPLE
    .\Scripts\TemplateSetup\Set-ModuleManifest.ps1 -Author 'Jane Doe' -Year '2026'

    Stamps a fresh GUID, sets Author, and writes
    '(c) 2026 Jane Doe. All rights reserved.' as the copyright.

.EXAMPLE
    .\Scripts\TemplateSetup\Set-ModuleManifest.ps1 -Guid '3f2504e0-4f89-11d3-9a0c-0305e82c3301'

    Writes a GUID the module already owns instead of minting one.

.OUTPUTS
    Progress text to the host. Returns $true from Set-ModuleManifest on success,
    $false when no single manifest could be found, or when a key it was given a
    value for is missing from that manifest.

.NOTES
    Deliberately not idempotent: every run without -Guid mints a new GUID, and a
    module's GUID is supposed to outlive its versions. Run it once, as part of
    setup.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '')]
[CmdletBinding()]
param(
    [Parameter()]
    [string] $RepoRoot,

    [Parameter()]
    [AllowEmptyString()]
    [string] $ManifestPath,

    [Parameter()]
    [AllowEmptyString()]
    [string] $Guid,

    [Parameter()]
    [AllowEmptyString()]
    [string] $Author,

    [Parameter()]
    [AllowEmptyString()]
    [string] $CompanyName,

    [Parameter()]
    [AllowEmptyString()]
    [string] $Year,

    [Parameter()]
    [switch] $DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path -Path $PSScriptRoot -ChildPath '_Common.ps1')

# Fragments that identify the template's placeholder note above the GUID key.
# Matched by content, so a comment a project wrote there survives.
$script:GuidNoteMarker = @(
    'generate a fresh GUID',
    'all-zeros placeholder',
    '[Guid]::Empty'
)

# The .psd1 under Source\ that is ModuleBuilder's build config rather than the
# module manifest; never a target.
$script:BuildConfigName = 'Build.psd1'

# Fill in the module manifest's identity keys and drop the template's
# placeholder note above the GUID. Returns $true so the orchestrator's step
# runner treats it as a success, $false when the manifest -- or a key it was
# given a value for -- could not be found.
function Set-ModuleManifest {
    # This whole setup framework previews with its own -DryRun flag instead of the
    # PSScriptAnalyzer-expected -WhatIf/-Confirm (ShouldProcess), matching every sibling step.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '')]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][bool]$DryRun,
        # All optional: the orchestrator can call this either side of the rename
        # step without knowing what the manifest is currently called, and a
        # license choice that needs no holder name supplies no author.
        [Parameter()][AllowEmptyString()][string]$ManifestPath = '',
        [Parameter()][AllowEmptyString()][string]$Guid = '',
        [Parameter()][AllowEmptyString()][string]$Author = '',
        [Parameter()][AllowEmptyString()][string]$CompanyName = '',
        [Parameter()][AllowEmptyString()][string]$Year = ''
    )
    if ($Guid) {
        $Parsed = [guid]::Empty
        if (-not [guid]::TryParse($Guid, [ref]$Parsed)) {
            Write-Warn "  Not a valid GUID: $Guid. Manifest not updated."
            return $false
        }
    }

    if (-not $ManifestPath) {
        $SourceDir = Join-Path -Path $RepoRoot -ChildPath 'Source'
        if (-not (Test-Path -LiteralPath $SourceDir)) {
            Write-Warn "  Source folder not found at $SourceDir; manifest not updated."
            return $false
        }
        $Candidates = @(Get-ChildItem -Path $SourceDir -Filter '*.psd1' -File |
                Where-Object { $_.Name -ne $script:BuildConfigName })
        if ($Candidates.Count -ne 1) {
            $Names = ($Candidates | ForEach-Object { $_.Name }) -join ', '
            $Message = "  Expected one module manifest in $SourceDir; found " +
            "$($Candidates.Count) ($Names). Manifest not updated."
            Write-Warn $Message
            return $false
        }
        $ManifestPath = $Candidates[0].FullName
    }
    if (-not (Test-Path -LiteralPath $ManifestPath)) {
        Write-Warn "  Manifest not found at $ManifestPath; manifest not updated."
        return $false
    }

    $Rel = [System.IO.Path]::GetRelativePath($RepoRoot, $ManifestPath)
    $Content = Get-Content -Path $ManifestPath -Raw
    if (-not $Content) {
        Write-Warn "  Manifest is empty: $Rel. Manifest not updated."
        return $false
    }

    # Line endings are preserved by splitting on either form and rejoining with
    # whichever one the file already uses.
    $Eol = if ($Content -match "`r`n") { "`r`n" } else { "`n" }
    $Lines = [System.Collections.Generic.List[string]] @($Content -split '\r?\n')

    # A preview must not advertise a GUID the apply run will not use: the apply
    # run mints its own.
    $NewGuid = if ($Guid) { $Guid } else { (New-Guid).Guid }
    $GuidDisplay = if ($DryRun -and -not $Guid) { 'a fresh GUID' } else { $NewGuid }

    # Composed rather than configured: the copyright names the same holder as
    # the Author key and the LICENSE file. Without an author there is no
    # statement to compose, so the placeholder stays.
    $Copyright = ''
    if ($Author) {
        $Holder = if ($Year) { "$Year $Author" } else { $Author }
        $Copyright = "(c) $Holder. All rights reserved."
    }

    $Fields = [ordered]@{
        GUID        = $NewGuid
        Author      = $Author
        CompanyName = $CompanyName
        Copyright   = $Copyright
    }
    $Display = [ordered]@{
        GUID        = $GuidDisplay
        Author      = $Author
        CompanyName = $CompanyName
        Copyright   = $Copyright
    }

    Write-Info 'Module manifest' $Rel
    $GuidIndex = -1
    $Missing = [System.Collections.Generic.List[string]]::new()
    foreach ($Key in $Fields.Keys) {
        $Value = $Fields[$Key]
        if (-not $Value) {
            Write-Host "    $(($Key + ':').PadRight(18))skipped (blank in config)"
            continue
        }

        # The key holding a single-quoted string, e.g. "    Author  = 'FIXME'".
        # The capture group holds everything up to the value, so rebuilding the
        # line from it keeps the key's column alignment.
        $Pattern = "^(\s*$Key\s*=\s*)'[^']*'"
        $Index = -1
        for ($Line = 0; $Line -lt $Lines.Count; $Line++) {
            if ($Lines[$Line] -match $Pattern) {
                $Index = $Line
                break
            }
        }
        if ($Index -lt 0) {
            $Missing.Add($Key)
            Write-Warn "    $(($Key + ':').PadRight(18))no such key in $Rel"
            continue
        }

        # Rebuilt from the matched prefix rather than replaced through -replace,
        # so a '$' in a value is never read as a replacement-group reference. A
        # single quote is doubled, the escape a .psd1 string expects.
        $Prefix = [regex]::Match($Lines[$Index], $Pattern).Groups[1].Value
        $Lines[$Index] = "$Prefix'$($Value.Replace("'", "''"))'"
        if ($Key -eq 'GUID') { $GuidIndex = $Index }
        Write-Host "    $(($Key + ':').PadRight(18))$($Display[$Key])"
    }

    # Walk up from the GUID key across the comment block sitting directly above
    # it, dropping only the template's placeholder note lines. Removing at an
    # index never shifts the lower indexes this loop has yet to visit.
    $Dropped = 0
    for ($Index = $GuidIndex - 1; $Index -ge 0; $Index--) {
        $Line = $Lines[$Index].Trim()
        if (-not $Line.StartsWith('#')) { break }
        $IsNote = $false
        foreach ($Marker in $script:GuidNoteMarker) {
            if ($Line.Contains($Marker)) {
                $IsNote = $true
                break
            }
        }
        if ($IsNote) {
            $Lines.RemoveAt($Index)
            $Dropped++
        }
    }
    if ($Dropped -gt 0) {
        Write-Host "    Drop $Dropped placeholder note comment line(s) above the GUID key"
    }

    if (-not $DryRun) {
        Set-Content -Path $ManifestPath -Value ($Lines -join $Eol) -NoNewline
    }
    return ($Missing.Count -eq 0)
}

# --- direct-invocation body (skipped when dot-sourced) ----------------------

if ($MyInvocation.InvocationName -eq '.') { return }

if (-not $RepoRoot) {
    $RepoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
}

$InvokeParams = @{
    RepoRoot     = $RepoRoot
    ManifestPath = $ManifestPath
    Guid         = $Guid
    Author       = $Author
    CompanyName  = $CompanyName
    Year         = $Year
    DryRun       = [bool]$DryRun
}
$null = Set-ModuleManifest @InvokeParams
if ($DryRun) {
    Write-Host ''
    Write-Host '  (dry run -- nothing changed)' -ForegroundColor Yellow
}
