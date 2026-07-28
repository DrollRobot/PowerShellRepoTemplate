<#
.SYNOPSIS
    Shared helper for Pester test files that scan a set of repo files.

.DESCRIPTION
    Dot-sourced by test files (lint checks and any other file-driven tests)
    in their BeforeDiscovery block. Not a Pester test file itself -- the
    *.Tests.ps1 glob never picks it up.
#>

function Build-TestFileList {
    <#
    .SYNOPSIS
        Builds per-file Pester test cases from scan paths and exclusions.

    .DESCRIPTION
        Expands -Path entries (files listed directly, folders scanned
        recursively), keeps only the requested extensions, drops anything
        matching -ExcludePath (a file entry excludes that file; a folder entry
        excludes its whole subtree), and returns one hashtable per surviving
        file for use with Pester's -ForEach:

            @{ FullName = <absolute path>; RelativePath = <display path> }

        RelativePath is relative to the single folder passed as -Path, or to
        the current directory when -Path holds a file list.

    .PARAMETER Path
        Files and/or folders to scan. Folders recurse.

    .PARAMETER ExcludePath
        Files and/or folders to skip. Relative entries resolve against the
        current directory; pass absolute paths for predictable results.

    .PARAMETER Extension
        File extensions to keep. Defaults to .ps1, .psm1, and .psd1.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]] $Path,
        [string[]] $ExcludePath = @(),
        [string[]] $Extension = @('.ps1', '.psm1', '.psd1')
    )

    # Normalize exclusions to absolute paths. An entry that exists as a file
    # excludes exactly that file; anything else is treated as a folder prefix
    # (nonexistent folders are harmless -- they simply never match).
    $Base = (Get-Location).Path
    $ExcludeFiles = [System.Collections.Generic.List[string]]::new()
    $ExcludeDirs = [System.Collections.Generic.List[string]]::new()
    foreach ($Item in $ExcludePath) {
        $Full = [System.IO.Path]::GetFullPath($Item, $Base)
        if (Test-Path -LiteralPath $Full -PathType Leaf) {
            $ExcludeFiles.Add($Full)
        }
        else {
            $ExcludeDirs.Add($Full.TrimEnd('\') + '\')
        }
    }

    # Display base: a single folder argument anchors relative paths; a file
    # list has no single base, so fall back to the current directory.
    $ScanBase = if (@($Path).Count -eq 1 -and
        (Test-Path -LiteralPath $Path[0] -PathType Container)) {
        (Resolve-Path -LiteralPath $Path[0]).Path
    }
    else {
        $Base
    }

    $Files = foreach ($Item in $Path) {
        if (Test-Path -LiteralPath $Item -PathType Leaf) {
            Get-Item -LiteralPath $Item
        }
        else {
            Get-ChildItem -Path $Item -File -Recurse
        }
    }

    @(
        foreach ($File in ($Files | Where-Object Extension -in $Extension)) {
            $Full = $File.FullName
            if ($ExcludeFiles -contains $Full) { continue }
            $InExcludedDir = $ExcludeDirs | Where-Object {
                $Full.StartsWith($_, [System.StringComparison]::OrdinalIgnoreCase)
            }
            if ($InExcludedDir) { continue }
            @{
                FullName     = $Full
                RelativePath = [System.IO.Path]::GetRelativePath($ScanBase, $Full)
            }
        }
    )
}
