<#
.SYNOPSIS
    Project-specific build steps that run after ModuleBuilder is invoked.

.DESCRIPTION
    Build.ps1 is intentionally generic and reusable across any ModuleBuilder project.
    Put anything that depends on the finished build output here: copying extra files
    into the build, post-processing the built manifest, refreshing generated docs, etc.

    This script is invoked automatically by Build.ps1 after the build if it exists in
    the repo root. Delete or rename it to skip the post-build phase entirely.
#>

$ErrorActionPreference = 'Stop'

# FIXME: add project-specific post-build steps here, or delete this file.
