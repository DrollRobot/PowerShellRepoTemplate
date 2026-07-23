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
| `destructive` | Dependency | Mutates state outside the test itself. Skipped by default. |
| `local` | Destructive scope | Paired with `destructive`: mutates the host running Pester. Gated on `DISPOSABLE_ENVIRONMENT=1`. |
| `remote` | Destructive scope | Paired with `destructive`: mutates an external target. Gated on `Tests\Confirm-RemoteDisposable.ps1` confirming it (not throwing). |
| `slow` | Performance | Long-running. |

Every `destructive` test MUST also carry exactly one of `local` or `remote`. A
`destructive` test tagged with neither, or with both, causes
`.\Tests.ps1 Destructive` to refuse the entire category, fail-closed -- see
"Destructive tests" below.


## Running tests
**First: Pester tests**
```powershell
# run NotLive tests first, for rapid feedback
.\Tests.ps1 NotLive # runs all non-live, non-destructive tests
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
`.\Tests.ps1 Destructive` runs every test tagged `destructive`. Each such test
must also carry exactly one of `local` or `remote` (see the tag table above);
Tests.ps1 discovers the destructive tests first and refuses the entire category,
fail-closed, if any of them is missing that scope tag or carries both. The
`local` and `remote` subsets are then gated and run independently -- if only
one subset exists (or is cleared), that subset still runs even though the other
is refused or absent.

### Local destructive tests
If the package contains `destructive`,`local` tests, check the
`DISPOSABLE_ENVIRONMENT` environment variable.
- `0` = User says this system is not disposable; never run destructive tests.
- `1` = User has decided this system is disposable; ask user once per session if
    destructive tests should be run.
- Not set = the system has not been assessed. Do NOT run destructive tests.
    Provide the user the commands below and ask them to set the variable. Any
    value other than `1` (including typos or an unset variable) is treated as
    non-disposable.
```
The DISPOSABLE_ENVIRONMENT environment variable is not set. Please set it to
indicate whether it's safe to run destructive tests.
Use `0` on a normal machine.
Use `1` ONLY on a disposable VM/container/environment you are willing to have
mutated. The commands below show `0`; change it to `1` only on a throwaway
host. Each takes effect in new sessions, not the shell that runs it.

Windows:
[Environment]::SetEnvironmentVariable('DISPOSABLE_ENVIRONMENT','0','Machine')

Linux:
echo 'DISPOSABLE_ENVIRONMENT=0' | sudo tee -a /etc/environment

MacOS:
echo 'export DISPOSABLE_ENVIRONMENT=0' | sudo tee -a /etc/zprofile
```
**Agents must NEVER set `DISPOSABLE_ENVIRONMENT` themselves.**

### Remote destructive tests
If the package contains `destructive`,`remote` tests, `.\Tests.ps1 Destructive`
runs `Tests\Confirm-RemoteDisposable.ps1` before them. That script decides
whether the remote target this project is currently pointed at has been marked
disposable; the tests run only when it returns without throwing. Its counterpart,
`Scripts\Set-RemoteDisposable.ps1`, is the rare, human-run action that writes
that marker -- never run it automatically, and never on behalf of a user who
has not explicitly confirmed the target. Both scripts ship as fail-closed
stubs (they refuse until a project implements the FIXME in each); a project
must wire the marker mechanism (a resource tag, a database row, a file on a
reachable host, ...) to whatever kind of remote target its destructive tests
touch.
**Agents must NEVER run `Scripts\Set-RemoteDisposable.ps1` themselves.**

### Running destructive tests
If the package contains destructive tests and the relevant gate(s) above are
satisfied -- `DISPOSABLE_ENVIRONMENT` for the `local` subset, a confirmed
target for the `remote` subset -- and the user has approved running destructive
tests in this session, run:
```
.\Tests.ps1 Destructive
```
