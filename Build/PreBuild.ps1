<#
.SYNOPSIS
    Project-specific build steps that run before ModuleBuilder is invoked.

.DESCRIPTION
    Build.ps1 is intentionally generic and reusable across any ModuleBuilder project.
    Put anything specific to this project here: generating files, updating version metadata,
    copying assets into the source tree, etc.

    This script is invoked automatically by Build.ps1 if it exists in the repo root.
    Delete or rename it to skip the pre-build phase entirely.
#>

$ErrorActionPreference = 'Stop'

# FIXME: add project-specific pre-build steps here, or delete this file.
