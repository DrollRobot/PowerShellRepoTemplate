# Getting Started

## Prerequisites

- PowerShell 7.5 or later
- A Microsoft 365 tenant and a Global Admin account to sign in with.
- Recommended: ip_info installed as a uv tool - https://github.com/DrollRobot/ip_info

## Module Install

### Clone from Github

```powershell
# install the module to a folder in $env:PsModulePath
# if not sure, use C:\Users\USER\(OneDrive??)\Documents\Powershell\Modules\
$Documents = [environment]::getfolderpath('MyDocuments')
Set-Location "$Documents\Powershell\Modules\"

# clone module from github
git clone https://github.com/DrollRobot/M365IncidentResponseTools.git
```

### Install Dependencies

On the first import of the module, (`Import-Module M365IncidentResponseTools`) 
Install-Dependencies.ps1 will verify you have the required modules installed. If not, 
it will tell you to run a command similar to the one below:
```powershell
& "C:\Users\USER\Documents\Powershell\Modules\M365IncidentResponseTools\Install-Dependencies.ps1"
```

**The script will install the following modules:**
Microsoft.Graph.Applications
Microsoft.Graph.Authentication
Microsoft.Graph.Beta.Identity.Signins
Microsoft.Graph.Beta.Reports
Microsoft.Graph.DeviceManagement
Microsoft.Graph.DirectoryObjects
Microsoft.Graph.Groups
Microsoft.Graph.Identity.DirectoryManagement
Microsoft.Graph.Identity.Signins
Microsoft.Graph.Reports
Microsoft.Graph.Users
Microsoft.Graph.Users.Actions
ExchangeOnlineManagement
ImportExcel
PSToml
PSFramework

**Connecting to an M365 tenant:**
[Connect to M365](connect.md)