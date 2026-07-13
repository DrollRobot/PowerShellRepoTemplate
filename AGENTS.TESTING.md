# Testing

In-domain: All code in Source/, except functions in Lib/ folders and Build.psd1.
Non-domain: Dev/Test/Build/Debug/Lib code.

Ignore built code, such as *.psm1 and *.psd1, ScriptsToProcess/, Data/, Build/, in
the module root.

## Testing after changes
After making changes, ask the user if we're ready to move on to tests.

**First: Pester tests**
```powershell
# run offline pester tests for rapid feedback
.\Tests.ps1 Offline
# then run online tests (requires a live session to the module's external service)
.\Tests.ps1 Online
```
Do not move on to formatting until all Pester tests are passing.

**Second: Autoformatting and Formatting tests**
**Always fix every formatting finding immediately. Do not ask the user if they should be fixed.**
```powershell
# run AutoFormat first to apply automatic fixes
.\Tests.ps1 AutoFormat

# run the following tests one by one, fixing any findings before moving on to the next
.\Tests.ps1 ExplicitModuleImport
.\Tests.ps1 FindUnwantedStrings
.\Tests.ps1 PSSA
```

**Always use `Tests.ps1`**
- Run all tests through the `.\Tests.ps1 <Category>` orchestrator. Do not 

**Checking a single file or folder**
- `.\Tests.ps1 <Category>` scans all in-scope files. To check just one file or folder,
    add `-Path`.
    .\Tests.ps1 LineLength -Path .\Scripts\Invoke-RandomEmailTraffic.ps1
    .\Tests.ps1 PSSA -Path .\Source\Public

**Quick pass/fail for agents**
Add `-Quiet` to any formatting check for single line output.