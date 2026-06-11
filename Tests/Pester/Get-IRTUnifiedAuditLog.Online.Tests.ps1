#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Online tests for Get-IRTUnifiedAuditLog.

.DESCRIPTION
    These tests require an active Exchange Online session established by
    Connect-IRT. Search-UnifiedAuditLog and Get-AcceptedDomain are NOT mocked;
    all queries go to the real Exchange endpoint.

    Show-IRTUnifiedAuditLog is mocked in each Context's BeforeAll to capture
    the -Log argument without producing Excel output. Write-IRT and
    Write-PSFMessage are mocked to suppress console noise.

    Each Context makes exactly one live UAL query in BeforeAll and caches the
    results in $script: variables so that all It blocks in that Context share
    the same query result, keeping the total number of Exchange calls to a
    minimum.

-- AllUsers with ResultLimit 5000 ---------------------------------------

    One -AllUsers query over 30 days with ResultLimit=5000. With a page size
    of 5000 and a matching ResultLimit, exactly one Search-UnifiedAuditLog
    call is made regardless of whether the tenant has more than 5000 records.

    'returns at least 1 log record'
        Verifies the tenant has UAL data in the last 30 days and that the
        query, deduplication, and capture pipeline are working end-to-end.

    'returns no more than 5000 records'
        Verifies the ResultLimit cap is enforced: the caller asked for at most
        5000 records and must never receive more.

    'every record has a non-empty Identity'
        UAL records always carry a unique Identity. An empty Identity would
        indicate a parsing problem or a broken Formatted=true result.

    'all CreationDate values fall within the 30-day query window'
        The StartDate/EndDate filter passed to Search-UnifiedAuditLog must
        constrain results. A record outside the window would mean the date
        filter is being ignored or misformatted.

-- Date range: -Days ----------------------------------------------------

    One -AllUsers query with -Days 7. Verifies that the -Days parameter
    shrinks the query window and that returned records respect it.

    'every record falls within the last 7 days'
        The oldest record in the result set must not predate the window.
        A record older than 8 days would indicate the -Days parameter is not
        being applied to StartDate.

-- Date range: -Start / -End --------------------------------------------

    One -AllUsers query with explicit -Start and -End strings. Verifies that
    absolute date strings are parsed and forwarded correctly.

    'every record falls within the specified absolute date range'
        Window: 14 days ago to 7 days ago. Any record outside that window
        (with a 1-day tolerance for UTC/local conversion) would indicate the
        -Start or -End parameter is being ignored or misformatted.
#>

InModuleScope M365IncidentResponseTools {

    Describe 'Get-IRTUnifiedAuditLog (live)' -Tag 'Online' {

        BeforeAll {
            if (-not ($Global:IRT_Session -and $Global:IRT_Session.Exchange)) {
                throw ('Get-IRTUnifiedAuditLog online tests require an active Exchange ' +
                    'Online session. Ensure Connect-IRT ran successfully first.')
            }
        }

        # -------------------------------------------------------------------
        Context '-AllUsers with ResultLimit 5000' {

            BeforeAll {
                Mock Write-IRT { }
                Mock Write-PSFMessage { }

                $script:Captured30d = $null
                Mock Show-IRTUnifiedAuditLog { $script:Captured30d = $Log }

                $Params = @{
                    AllUsers    = $true
                    Days        = 30
                    ResultLimit = 5000
                    Excel       = $true
                    Xml         = $false
                }
                Get-IRTUnifiedAuditLog @Params
                $script:Logs30d = @($script:Captured30d | Where-Object { $_ -and -not $_.Metadata })
            }

            It 'returns at least 1 log record over 30 days' {
                $script:Logs30d.Count | Should -BeGreaterThan 0
            }

            It 'returns no more than 5000 records' {
                $script:Logs30d.Count | Should -BeLessOrEqual 5000
            }

            It 'every record has a non-empty Identity' {
                foreach ($Entry in $script:Logs30d) {
                    $Entry.Identity | Should -Not -BeNullOrEmpty
                }
            }

            It 'all CreationDate values fall within the 30-day query window' {
                $WindowStart = [datetime]::UtcNow.AddDays(-31)
                $WindowEnd = [datetime]::UtcNow.AddDays(1)
                foreach ($Entry in $script:Logs30d) {
                    $Entry.CreationDate | Should -BeGreaterOrEqual $WindowStart
                    $Entry.CreationDate | Should -BeLessOrEqual $WindowEnd
                }
            }
        }

        # -------------------------------------------------------------------
        Context 'date range: -Days parameter' {

            BeforeAll {
                Mock Write-IRT { }
                Mock Write-PSFMessage { }

                $script:Captured7d = $null
                Mock Show-IRTUnifiedAuditLog { $script:Captured7d = $Log }

                $Params = @{
                    AllUsers    = $true
                    Days        = 7
                    ResultLimit = 5000
                    Excel       = $true
                    Xml         = $false
                }
                Get-IRTUnifiedAuditLog @Params
                $script:Logs7d = @($script:Captured7d | Where-Object { $_ -and -not $_.Metadata })
            }

            It 'every record falls within the last 7 days' {
                if ($script:Logs7d.Count -eq 0) {
                    throw 'No UAL records found in 7-day window; likely a script error'
                }
                $OldestAllowed = [datetime]::UtcNow.AddDays(-8)
                foreach ($Entry in $script:Logs7d) {
                    $Entry.CreationDate | Should -BeGreaterOrEqual $OldestAllowed
                }
            }
        }

        # -------------------------------------------------------------------
        Context 'date range: -Start and -End parameters' {

            BeforeAll {
                Mock Write-IRT { }
                Mock Write-PSFMessage { }

                $script:CapturedAbs = $null
                Mock Show-IRTUnifiedAuditLog { $script:CapturedAbs = $Log }

                # Query from 14 days ago to 7 days ago -- a window that is fully
                # in the past so the boundary is stable over the duration of the test.
                $script:AbsStart = [datetime]::UtcNow.AddDays(-14).ToString('yyyy-MM-dd')
                $script:AbsEnd = [datetime]::UtcNow.AddDays(-7).ToString('yyyy-MM-dd')

                $Params = @{
                    AllUsers    = $true
                    Start       = $script:AbsStart
                    End         = $script:AbsEnd
                    ResultLimit = 5000
                    Excel       = $true
                    Xml         = $false
                }
                Get-IRTUnifiedAuditLog @Params
                $script:LogsAbs = @($script:CapturedAbs | Where-Object { $_ -and -not $_.Metadata })
            }

            It 'every record falls within the specified absolute date range' {
                if ($script:LogsAbs.Count -eq 0) {
                    throw 'No UAL records found in absolute range; likely a script error'
                }
                $LowerBound = ([datetime]$script:AbsStart).AddDays(-1)
                $UpperBound = ([datetime]$script:AbsEnd).AddDays(1)
                foreach ($Entry in $script:LogsAbs) {
                    $Entry.CreationDate | Should -BeGreaterOrEqual $LowerBound
                    $Entry.CreationDate | Should -BeLessOrEqual $UpperBound
                }
            }
        }
    }
}
