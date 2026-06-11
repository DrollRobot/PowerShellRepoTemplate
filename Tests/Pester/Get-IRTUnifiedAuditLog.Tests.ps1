#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Offline tests for Get-IRTUnifiedAuditLog paging and ResultLimit behaviour.

.DESCRIPTION
    All tests are offline. External Exchange cmdlets (Search-UnifiedAuditLog,
    Get-AcceptedDomain) and internal IRT helpers (Update-IRTToken, Write-IRT,
    Resolve-DateRange, Show-IRTUnifiedAuditLog) are mocked so no network I/O
    occurs.

    Get-AcceptedDomain and Search-UnifiedAuditLog are EXO proxy cmdlets that
    only materialise after Connect-ExchangeOnline. Global stubs are created in
    BeforeAll so Mock can discover them via the regular (global) session state.
    All Mocks use -ModuleName M365IncidentResponseTools so the intercepts apply
    to calls made from within the module (rather than InModuleScope, which
    discovers commands only through the module's own session state and cannot
    find external commands that were never imported by the module itself).

    New-UALPage is a test-only factory that creates minimal UAL record objects.
    Each record gets a unique Identity so the deduplication pass inside the
    function does not collapse the set.

-- paging stops at ResultLimit ------------------------------------------

    The paging while loop condition is ($QueryLogCount -lt $ResultLimit).
    When the first page returns exactly 5000 records and ResultLimit is 5000,
    $QueryLogCount equals $ResultLimit before the loop body runs, so
    Search-UnifiedAuditLog is called once per query and a Warn is written.

-- paging continues naturally -------------------------------------------

    When the first Search-UnifiedAuditLog call returns a full 5000-record page
    and the continuation call (SessionId present) returns fewer than 5000, the
    function pages twice and no ResultLimit warning is written.
    The two separate mocks use ParameterFilter on $SessionId to distinguish
    first calls (no SessionId) from continuation calls (SessionId present).

-- no logs across all queries -------------------------------------------

    When Search-UnifiedAuditLog returns empty for every query, $AllLogs stays
    at 0 and the function writes a warning then returns without calling
    Show-IRTUnifiedAuditLog.

-- UserObject query count -----------------------------------------------

    The UserObject parameter set runs 4 queries per user by default: a UserIds
    query plus three FreeText queries. This context verifies the loop iterates
    all four entries.

-- Excel export ---------------------------------------------------------

    When logs are found and -Excel $true is passed, Show-IRTUnifiedAuditLog
    is called exactly once.
#>

# EXO proxy cmdlets only exist after Connect-ExchangeOnline. Create thin global
# stubs so Mock can discover them via Get-Command in the test session.
# New-UALPage is also global so it is accessible inside Mock body scriptblocks.
BeforeAll {
    function global:Get-AcceptedDomain { }
    function global:Search-UnifiedAuditLog { }

    function global:New-UALPage {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
            'PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test-only factory; ShouldProcess is not applicable.')]
        param(
            [int]    $Count,
            [string] $SessionId = 'test-session-1'
        )
        $Base = [datetime]'2024-01-01'
        0..($Count - 1) | ForEach-Object {
            [pscustomobject]@{
                Identity     = [string][guid]::NewGuid()
                SessionId    = $SessionId
                CreationDate = $Base.AddSeconds($_)
            }
        }
    }
}

AfterAll {
    @('Get-AcceptedDomain', 'Search-UnifiedAuditLog', 'New-UALPage') | ForEach-Object {
        Remove-Item -Path "Function:\$_" -ErrorAction SilentlyContinue
    }
}

Describe 'Get-IRTUnifiedAuditLog' {

    BeforeEach {
        $Mod = 'M365IncidentResponseTools'
        Mock Update-IRTToken { } -ModuleName $Mod
        Mock Write-IRT { } -ModuleName $Mod
        Mock Write-PSFMessage { } -ModuleName $Mod
        Mock Get-AcceptedDomain {
            [pscustomobject]@{ Default = $true; DomainName = 'contoso.com' }
        } -ModuleName $Mod
        Mock Resolve-DateRange {
            [pscustomobject]@{
                Days     = 30
                StartUtc = [datetime]::UtcNow.AddDays(-30)
                EndUtc   = [datetime]::UtcNow
            }
        } -ModuleName $Mod
        Mock Show-IRTUnifiedAuditLog { } -ModuleName $Mod
    }

    # -------------------------------------------------------------------
    Context 'paging stops at ResultLimit' {

        BeforeEach {
            Mock Search-UnifiedAuditLog {
                New-UALPage -Count 5000
            } -ModuleName M365IncidentResponseTools
        }

        It 'calls Search-UnifiedAuditLog exactly once when ResultLimit equals the page size' {
            $Params = @{
                AllUsers    = $true
                ResultLimit = 5000
                Excel       = $false
                Xml         = $false
            }
            Get-IRTUnifiedAuditLog @Params
            $InvokeArgs = @{ ModuleName = 'M365IncidentResponseTools' }
            Should -Invoke Search-UnifiedAuditLog -Times 1 -Exactly @InvokeArgs
        }

        It 'writes a Warn containing ResultLimit when paging is cut short' {
            $Params = @{
                AllUsers    = $true
                ResultLimit = 5000
                Excel       = $false
                Xml         = $false
            }
            Get-IRTUnifiedAuditLog @Params
            $Filter = { $Level -eq 'Warn' -and $Message -match 'ResultLimit' }
            Should -Invoke Write-IRT -ModuleName M365IncidentResponseTools -ParameterFilter $Filter
        }
    }

    # -------------------------------------------------------------------
    Context 'paging continues until the page is not full' {

        BeforeEach {
            # First call returns a full page to trigger paging; subsequent
            # calls return a partial page to signal end of results.
            # $script: scope persists across the BeforeEach/Mock boundary.
            $script:UALPageCallCount = 0
            Mock Search-UnifiedAuditLog {
                $script:UALPageCallCount++
                if ($script:UALPageCallCount -eq 1) { New-UALPage -Count 5000 }
                else { New-UALPage -Count 200 }
            } -ModuleName M365IncidentResponseTools
        }

        It 'calls Search-UnifiedAuditLog twice for a single query' {
            $Params = @{
                AllUsers    = $true
                ResultLimit = 50000
                Excel       = $false
                Xml         = $false
            }
            Get-IRTUnifiedAuditLog @Params
            $InvokeArgs = @{ ModuleName = 'M365IncidentResponseTools' }
            Should -Invoke Search-UnifiedAuditLog -Times 2 -Exactly @InvokeArgs
        }

        It 'does not write a ResultLimit warning when paging ends naturally' {
            $Params = @{
                AllUsers    = $true
                ResultLimit = 50000
                Excel       = $false
                Xml         = $false
            }
            Get-IRTUnifiedAuditLog @Params
            $Filter = { $Level -eq 'Warn' -and $Message -match 'ResultLimit' }
            $InvokeArgs = @{ ModuleName = 'M365IncidentResponseTools'; ParameterFilter = $Filter }
            Should -Invoke Write-IRT -Times 0 @InvokeArgs
        }
    }

    # -------------------------------------------------------------------
    Context 'no logs returned across all queries' {

        BeforeEach {
            Mock Search-UnifiedAuditLog { @() } -ModuleName M365IncidentResponseTools
        }

        It 'writes a zero-logs warning' {
            $Params = @{
                AllUsers = $true
                Excel    = $false
                Xml      = $false
            }
            Get-IRTUnifiedAuditLog @Params
            $Filter = { $Level -eq 'Warn' -and $Message -match '0 total logs' }
            Should -Invoke Write-IRT -ModuleName M365IncidentResponseTools -ParameterFilter $Filter
        }

        It 'does not call Show-IRTUnifiedAuditLog when there are no logs' {
            $Params = @{
                AllUsers = $true
                Excel    = $true
                Xml      = $false
            }
            Get-IRTUnifiedAuditLog @Params
            Should -Invoke Show-IRTUnifiedAuditLog -Times 0 -ModuleName M365IncidentResponseTools
        }
    }

    # -------------------------------------------------------------------
    Context 'UserObject parameter set runs 4 queries per user' {

        BeforeEach {
            Mock Search-UnifiedAuditLog { @() } -ModuleName M365IncidentResponseTools
        }

        It 'makes 4 Search-UnifiedAuditLog calls for a single UserObject' {
            $User = [pscustomobject]@{
                Id                = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
                UserPrincipalName = 'user@contoso.com'
            }
            $Params = @{
                UserObject = $User
                Excel      = $false
                Xml        = $false
            }
            Get-IRTUnifiedAuditLog @Params
            $InvokeArgs = @{ ModuleName = 'M365IncidentResponseTools' }
            Should -Invoke Search-UnifiedAuditLog -Times 4 -Exactly @InvokeArgs
        }
    }

    # -------------------------------------------------------------------
    Context 'Excel export is called when logs are found' {

        BeforeEach {
            Mock Search-UnifiedAuditLog {
                New-UALPage -Count 100
            } -ModuleName M365IncidentResponseTools
        }

        It 'calls Show-IRTUnifiedAuditLog exactly once when Excel is enabled' {
            $Params = @{
                AllUsers = $true
                Excel    = $true
                Xml      = $false
            }
            Get-IRTUnifiedAuditLog @Params
            $InvokeArgs = @{ ModuleName = 'M365IncidentResponseTools' }
            Should -Invoke Show-IRTUnifiedAuditLog -Times 1 -Exactly @InvokeArgs
        }
    }
}
