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
.\Tests.ps1 ModuleSyntax
.\Tests.ps1 ExplicitModuleImport
.\Tests.ps1 FormatOperator
.\Tests.ps1 JoinPath
.\Tests.ps1 NonASCIICharacters
.\Tests.ps1 FindUnwantedStrings
.\Tests.ps1 WriteVerboseDebug
.\Tests.ps1 LineLength
.\Tests.ps1 BacktickContinuation
.\Tests.ps1 PSSA
# once you're done, run them all again to be sure fixes didn't create any new problems. 
```

**Checking a single file**
`.\Tests.ps1 <Category>` scans all in-scope files. To check just one file , call the standalone
check directly with `-Path`. Prefer this over hand-rolling grep/regex checks:

    .\Tests\Test-LineLength.ps1 -Path .\Source\Public\Get-Greeting.ps1

These standalone checks accept `-Path` (a file or folder): Test-LineLength,
Test-BacktickContinuation, Test-FormatOperator, Test-JoinPath, Test-ModuleSyntax,
Test-NonASCIICharacters, Test-WriteVerboseDebug, Test-FindUnwantedStrings,
Test-FixmeComments, Test-ExplicitModuleImport, Test-PSSA.

**Quick pass/fail for agents**
Add `-Quiet` to any formatting check -- standalone (`Test-LineLength.ps1 -Path . -Recurse
-Quiet`) or via the orchestrator (`.\Tests.ps1 LineLength -Quiet`) -- to suppress the
detail table and finding notes and print only the one-line summary (files scanned +
finding count). Read that single line to decide pass/fail, then re-run without `-Quiet`
to see the full findings when a check fails. Operational notes (e.g. Test-PSSA's "this can
take minutes; do not poll") are still shown in quiet mode.