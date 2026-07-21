<#
.SYNOPSIS
    Shared helpers for the one-time template-setup scripts in this folder.

.DESCRIPTION
    Scripts\TemplateSetup\ holds the one-time scripts that turn a fresh clone of
    this template into a real project (rename, strip template headers, set the
    GitHub user, choose a license, remove declined features, ...). This file
    carries the console-output helpers and the text-file walker they all share,
    so each step script -- and the Setup-NewProject.ps1 orchestrator that calls
    them -- can dot-source one file instead of redefining the same helpers.

    Dot-source it (from a step script or the orchestrator):
        . (Join-Path -Path $PSScriptRoot -ChildPath '_Common.ps1')

    Every scan walks the repo with Get-TemplateTextFile, which skips VCS
    metadata, build output, and other excluded folders so a step never rewrites
    or reports files it should leave alone.

.EXAMPLE
    . (Join-Path -Path $PSScriptRoot -ChildPath '_Common.ps1')
    foreach ($File in (Get-TemplateTextFile -RepoRoot $RepoRoot)) { ... }

    Dot-source the helpers, then walk every candidate text file under the repo.

.OUTPUTS
    None. Dot-sourcing defines helper functions and shared constants in the
    caller's scope; the functions themselves write to the host.

.NOTES
    Standard-library only (no module dependencies), so these scripts run against
    a bare clone before anything is installed. ASCII output only.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseDeclaredVarsMoreThanAssignments', '')]
param()

Set-StrictMode -Version Latest

# Text files eligible for in-place string replacement / scanning.
$script:TextExtensions = @(
    '.ps1', '.psd1', '.psm1', '.md', '.yml', '.yaml', '.json', '.code-workspace', '.txt'
)
# Folders never scanned, regardless of depth.
$script:ExcludedFolders = @('.git', '.local', 'Output', '.staging', 'site')

# --- output helpers ---------------------------------------------------------

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

function Write-Warn {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host $Message -ForegroundColor Yellow
}

function Write-Success {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host $Message -ForegroundColor Green
}

# Ask the user a yes/no question. With -AssumeYes it returns $true without
# prompting, printing the auto-answer so the transcript still shows the step
# (the orchestrator confirms once, then drives each step with -AssumeYes).
function Confirm-Step {
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter()][switch]$AssumeYes
    )
    if ($AssumeYes) {
        Write-Host "$Prompt [y/n] y " -NoNewline
        Write-Host '(auto: -Yes)' -ForegroundColor DarkGray
        return $true
    }
    while ($true) {
        $Answer = (Read-Host "$Prompt [y/n]").Trim().ToLowerInvariant()
        if ($Answer -in @('y', 'yes')) { return $true }
        if ($Answer -in @('n', 'no')) { return $false }
        Write-Host "  Please answer 'y' or 'n'."
    }
}

# --- filesystem walk --------------------------------------------------------

# Every readable, non-empty text file under $RepoRoot worth scanning, skipping
# the excluded folders above. A zero-length file can never carry the template
# name, a banner, or a FIXME placeholder; excluding it also sidesteps
# Get-Content -Raw's $null-for-empty-file quirk in every caller.
function Get-TemplateTextFile {
    param([Parameter(Mandatory)][string]$RepoRoot)
    $ExcludePattern = ($script:ExcludedFolders |
            ForEach-Object { [regex]::Escape("\$_\") }) -join '|'
    Get-ChildItem -Path $RepoRoot -Recurse -File |
        Where-Object { $_.Extension -in $script:TextExtensions -and $_.Length -gt 0 } |
        Where-Object { "$($_.FullName)\" -notmatch $ExcludePattern }
}
