<#
.SYNOPSIS
    Pre-import dependency check. Should be added to ScriptsToProcess in the module manifest
    to run automatically when the module is imported.
    Designed to be used in conjunction with Install-Dependencies.ps1.

.DESCRIPTION
    Dynamically locates the module root by walking up the directory tree from this script's
    location until a .psd1 manifest is found. Then recursively searches that root for
    Install-Dependencies.ps1 and delegates to it with -Check -Quiet.

    If all required modules are present, no output is produced. If any are missing,
    Install-Dependencies.ps1 is called again without -Quiet to display remediation guidance,
    then this script throws to abort the import cleanly. This prevents PowerShell's built-in
    "required module not found" error from appearing alongside the guidance already printed.

    No hardcoded paths are used — this script can be placed anywhere within the module tree.

.NOTES
Version 1.1.0
1.1.0 - Added dynamic module root discovery allowing putting scripts in any folder.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '')]
param()

# Walk up from this script's directory to find the .psd1 manifest, which is the
# canonical marker of the module root. This works regardless of where this script
# sits within the module tree (root, scripts/, etc.).
$ModuleRoot = $null
$SearchDir = $PSScriptRoot
while ($SearchDir) {
    if (@(Get-ChildItem -Path $SearchDir -Filter '*.psd1' -File).Count -gt 0) {
        $ModuleRoot = $SearchDir
        break
    }
    $Parent = Split-Path -Path $SearchDir -Parent
    if ($Parent -eq $SearchDir) { break }   # reached filesystem root
    $SearchDir = $Parent
}

if (-not $ModuleRoot) { return }

# Recursively search the module root for Install-Dependencies.ps1.
$InstallScript = Get-ChildItem -Path $ModuleRoot -Filter 'Install-Dependencies.ps1' -Recurse -File |
    Select-Object -First 1 -ExpandProperty FullName

if (-not $InstallScript) { return }

try {
    & $InstallScript -Check -Quiet
} catch {
    & $InstallScript -Check
    throw 'Import aborted. Required module(s) missing. See above for remediation guidance.'
}
