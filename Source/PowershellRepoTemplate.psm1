# Dev loader - used only when importing from source (testing, local iteration).
# Mirrors ModuleBuilder's build order: prefix -> Classes/Private/Public -> suffix,
# so source-import behaves like the built module (including init in suffix.ps1).

# Prefix (build.psd1 Prefix = 'prefix.ps1'), if present, runs before functions.
$prefix = Join-Path -Path $PSScriptRoot -ChildPath 'prefix.ps1'
if (Test-Path $prefix) { . $prefix }

# Functions: classes first (load-order-sensitive), then private, then public.
$folders = 'Classes', 'Private', 'Public'
foreach ($folder in $folders) {
    $root = Join-Path -Path $PSScriptRoot -ChildPath $folder
    if (Test-Path $root) {
        Get-ChildItem -Path $root -Filter *.ps1 -Recurse |
            Sort-Object FullName |
            ForEach-Object {
                try { . $_.FullName }
                catch { throw "Failed to dot-source $($_.FullName): $_" }
            }
    }
}

# Suffix (build.psd1 Suffix = 'suffix.ps1'): module init, runs after functions
# are defined so it can call them and populate $Global:IRT_* state.
$suffix = Join-Path -Path $PSScriptRoot -ChildPath 'suffix.ps1'
if (Test-Path $suffix) { . $suffix }

Export-ModuleMember -Function (
    Get-ChildItem -Path (Join-Path -Path $PSScriptRoot -ChildPath 'Public') -Filter *.ps1 -Recurse |
        Select-Object -ExpandProperty BaseName
) -Alias *
