# Getting Started

## Prerequisites

- PowerShell 7.5 or later
- FIXME: list any services, accounts, or external tools your module needs.

## Module Install

### Clone from Github

```powershell
# install the module to a folder in $env:PSModulePath
# if not sure, use C:\Users\USER\(OneDrive??)\Documents\PowerShell\Modules\
$Documents = [environment]::getfolderpath('MyDocuments')
Set-Location "$Documents\PowerShell\Modules\"

# clone module from github
git clone https://github.com/FIXME/FIXME.git
```

### Install Dependencies

On the first import of the module (`Import-Module FIXME`),
Confirm-Dependency.ps1 verifies you have the required modules installed.
If any are missing, it tells you to run a command similar to:

```powershell
& "C:\Users\USER\Documents\PowerShell\Modules\FIXME\Install-Dependency.ps1"
```

The script installs every module listed in `RequiredModules` in the module
manifest.
