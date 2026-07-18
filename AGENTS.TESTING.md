# Testing

In-domain: All code in Source/, except functions in Lib/ folders and Build.psd1.
Non-domain: Scripts/, Tests/, **/Lib/, Build/, Output/, Docs/Commands/, and any
built artifacts in module root.


## Writing tests

- All new code should have unit and integration tests, and e2e and/or live tests
    wherever possible/appropriate.
- All tests should use the tag system described below. Tests MUST have at least
    one Scope tag (`unit`, `integration`, or `e2e`).

### Test Tags

| Tag | Axis | Description |
|------|------|-------------|
| `unit` | Scope | Single function/class in isolation; all dependencies mocked or stubbed. |
| `integration` | Scope | Multiple real components wired together across a boundary. |
| `e2e` | Scope | Whole application end to end, driven like a real user. |
| `smoke` | Purpose | Fast "is it fundamentally broken" check. |
| `regression` | Purpose | Guards against reintroduction of a previously fixed bug. |
| `acceptance` | Purpose | Verifies behavior against a requirement or user-facing spec. |
| `functional` | Purpose | Tests behavior/output of a feature without regard to internal structure. |
| `live` | Dependency | Requires a real external resource — network, live tenant, secrets, third-party API. |
| `destructive` | Dependency | Mutates device/host state. Skipped by default. |
| `slow` | Performance | Long-running. |


## Running tests

**First: Pester tests**
```powershell
# run offline pester tests for rapid feedback
.\Tests.ps1 NonLive # runs all non-live, non-destructive tests
# then run tests with dependencies (where applicable)
.\Tests.ps1 Live # run all live, non-destructive tests
```
Do not move on to formatting until all Pester tests are passing.

**Second: Autoformatting and Formatting tests**
**Always fix every formatting finding immediately. Do not ask the user.**
```powershell
# run AutoFormat first to apply automatic fixes
.\Tests.ps1 AutoFormat

# verify the precommit tests pass
pre-commit run --all-files

# if any of the precommit lint tests fail, run the equivalent test to see the full output
.\Tests.ps1 ModuleSyntax
.\Tests.ps1 ExplicitModuleImport
.\Tests.ps1 FormatOperator
.\Tests.ps1 JoinPath
.\Tests.ps1 NonASCIICharacters
.\Tests.ps1 WriteVerboseDebug
.\Tests.ps1 LineLength
.\Tests.ps1 BacktickContinuation

# run the following tests one by one, fixing any findings before moving on to the next
.\Tests.ps1 FindUnwantedStrings
.\Tests.ps1 PSSA
```

**Always use `Tests.ps1`**
- Run all tests through the `.\Tests.ps1 <Category>` orchestrator. Do not run Pester tests directly

**Checking a single file or folder**
- `.\Tests.ps1 <Category>` scans all in-scope files. To check just one file or folder,
    add `-Path`.
    .\Tests.ps1 LineLength -Path .\Scripts\Invoke-RandomEmailTraffic.ps1
    .\Tests.ps1 PSSA -Path .\Source\Public

**Quick pass/fail for agents**
Add `-Quiet` to any formatting check for single line output.

## Destructive tests

If the package contains destructive tests, check the `DISPOSABLE_ENVIRONMENT`
environment variable.
- `0` = User says this system is not disposable; never run destructive tests.
- `1` = User has decided this system is disposable; ask user once per session if
    destructive tests should be run.
- Not set = the system has not been assessed. Do NOT run destructive tests.
    Provide the user the commands below and ask them to set the variable. Any
    value other than `1` (including typos or an unset variable) is treated as
    non-disposable.
```
The DISPOSABLE_ENVIRONMENT environment variable is not set. Please set it to
indicate whether it's save to run destructive tests.
Use `0` on a normal machine.
Use `1` ONLY on a disposable VM/container/envi you are willing to have mutated. The commands below
show `0`; change it to `1` only on a throwaway host. Each takes effect in new
sessions, not the shell that runs it.

Windows:
[Environment]::SetEnvironmentVariable('DISPOSABLE_ENVIRONMENT','0','Machine')

Linux:
echo 'DISPOSABLE_ENVIRONMENT=0' | sudo tee -a /etc/environment

MacOS:
echo 'export DISPOSABLE_ENVIRONMENT=0' | sudo tee -a /etc/zprofile
```

**Agents must NEVER set `DISPOSABLE_ENVIRONMENT` themselves.**

If the package contains destructive tests, the variable is set, and the
user has approved running destructive tests in this session, run:
```
.\Tests.ps1 Destructive
```
