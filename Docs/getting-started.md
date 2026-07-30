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
