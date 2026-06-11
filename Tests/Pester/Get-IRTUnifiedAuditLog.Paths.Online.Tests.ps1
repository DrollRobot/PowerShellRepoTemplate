#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Online parameter-path tests for Get-IRTUnifiedAuditLog.

.DESCRIPTION
    Covers the parameter sets and filter switches not exercised by the AllUsers /
    date-range tests in Get-IRTUnifiedAuditLog.Online.Tests.ps1.

    Prerequisites:
      - Connect-IRT must have completed (Exchange and Graph sessions active).
      - IRT_TEST_USER_ID environment variable must be set to a valid user GUID.
      - The Microsoft Graph Command Line Tools service principal
        (AppId 14d82eec-204b-4c2f-b7e8-296a70dab67e) must exist in the tenant.

    The Describe-level BeforeAll fetches the test user and the Graph CLT service
    principal once via the live Graph API. Each Context then makes exactly one UAL
    query in its own BeforeAll, caching results in $script: variables for the It
    blocks. Total live Exchange calls: 6.

    Show-IRTUnifiedAuditLog is mocked in each Context to capture -Log without
    writing an Excel file. Write-IRT and Write-PSFMessage suppress console noise.

-- -UserObject, 7-day query -----------------------------------------------

    Issues 4 queries per user: UserIds (email, GUID, GUID-no-dashes) plus 3
    FreeText variants. Tests the date-filter and output pipeline for this path.

    'returns at least 1 log for the test user'
        Connect-IRT itself generates sign-in UAL events, so the test user should
        always have recent activity.

    'all records fall within the 7-day window'
        StartDate/EndDate are shared across all 4 queries. A record outside the
        window means a date parameter was not propagated to Search-UnifiedAuditLog.

-- -SignInLog, AllUsers, 7-day query --------------------------------------

    The -SignInLog switch activates the SignInLogs profile, which passes
    Operations = UserLoggedIn | UserLoggedOff | UserLoginFailed to Exchange.

    'returns at least 1 sign-in record'
        Sign-in events occur continuously in any active M365 tenant.

    'every record has a sign-in Operations value'
        Verifies the Operations filter reached Exchange correctly: a record whose
        Operations field is outside the three sign-in values means the filter was
        dropped or overwritten.

-- -ServicePrincipal (Graph Command Line Tools) ---------------------------

    Fetches the Graph CLT SPN via Graph API and queries the UAL via the
    ServicePrincipal parameter set, which runs 5 queries (UserIds with 4 ID
    variants plus 4 FreeText queries). Uses Days=7.

    'returns at least 1 record for Graph Command Line Tools'
        Any operator running Graph-based cmdlets against this tenant generates
        Graph CLT audit events. Seven days should always contain activity.

    'every record has a non-empty Identity'
        Structural check confirming the ServicePrincipal query path returns
        well-formed UAL records.

-- -RiskyOperation, test user, 180-day query ------------------------------

    Exercises the RiskyOperations profile, which imports the AllOperations Excel
    file (AllOperationsSheetPath) and filters on rows marked Risk=High. If that
    import fails the function throws and BeforeAll surfaces the error immediately.

    'Show-IRTUnifiedAuditLog is called only when logs are returned'
        Always-running test that verifies the no-logs guard: Show must be called
        exactly once when logs were found, and zero times when none were found.

    'every record has a non-empty Identity if risky logs were found'
        Skipped (not failed) when the test user has no risky operations in 180
        days; high-risk operations are infrequent and may genuinely not exist for
        a lab test account.

-- -FreeText with AllUsers, 7-day query -----------------------------------

    Passes FreeText = 'Microsoft','Graph','Exchange' with -AllUsers, causing one
    query per term (3 total). Results are merged and deduplicated.

    'returns at least 1 record across all three FreeText terms'
        These strings appear in virtually every M365 audit event AuditData payload.

    'every record has a non-empty Identity'
        Structural check for the FreeText + AllUsers query path.

-- -Operation filter, AllUsers, 30-day query ------------------------------

    Passes a list of common Azure AD operations via -Operation. Exercises the
    OperationsSet.Count > 0 branch that adds -Operations to Search-UnifiedAuditLog.

    'returns at least 1 record for the specified operations'
        These admin operations occur in any tenant with active management activity.

    'every record Operations matches the requested set'
        Key filter-correctness check: Exchange must honor the -Operations parameter.
        A record with an operation outside the requested set means the filter was
        not forwarded to Search-UnifiedAuditLog.

-- date chunking: 364-day query, UserLoggedIn, test user ------------------

    Queries the test user's UserLoggedIn events for the past 364 days -- two
    182-day chunks. Specifically exercises the date-chunking code path that
    splits ranges longer than 182 days. ResultLimit=5000 keeps run time short.

    'returns at least 1 UserLoggedIn record over 364 days'
        Any user who has signed in at least once in the past year will have at
        least one record. A zero-count here means chunking or the Operation
        filter broke the query.

    'all records fall within the 364-day window'
        Verifies both chunks used the correct StartDate/EndDate. A record older
        than 365 days would mean the chunk boundary math is wrong.

    'every record Operations is UserLoggedIn'
        Verifies the -Operation filter survived across both chunks.
#>

InModuleScope M365IncidentResponseTools {

    Describe 'Get-IRTUnifiedAuditLog parameter paths (live)' -Tag 'Online' {

        BeforeAll {
            if (-not ($Global:IRT_Session -and $Global:IRT_Session.Exchange)) {
                throw 'Exchange Online session required.'
            }
            if (-not ($Global:IRT_Session -and $Global:IRT_Session.Graph)) {
                throw 'Graph session required to retrieve test objects.'
            }
            if (-not $env:IRT_TEST_USER_ID) {
                throw 'IRT_TEST_USER_ID not set. Run Tests/.env.ps1 first.'
            }

            $script:TestUser = Get-MgUser -UserId $env:IRT_TEST_USER_ID

            $GraphCLTFilter = "appId eq '14d82eec-204b-4c2f-b7e8-296a70dab67e'"
            $script:GraphCLT = Get-MgServicePrincipal -Filter $GraphCLTFilter -Top 1
        }

        # -------------------------------------------------------------------
        Context '-UserObject, 7-day query' {

            BeforeAll {
                Mock Write-IRT { }
                Mock Write-PSFMessage { }

                $script:CapturedUser = $null
                Mock Show-IRTUnifiedAuditLog { $script:CapturedUser = $Log }

                $Params = @{
                    UserObject  = $script:TestUser
                    Days        = 7
                    ResultLimit = 5000
                    Excel       = $true
                    Xml         = $false
                }
                Get-IRTUnifiedAuditLog @Params
                $script:UserLogs = @(
                    $script:CapturedUser | Where-Object { $_ -and -not $_.Metadata }
                )
            }

            It 'returns at least 1 log for the test user' {
                if ($script:UserLogs.Count -eq 0) {
                    throw 'No UAL logs for the test user in 7 days; likely a script error'
                }
                $script:UserLogs.Count | Should -BeGreaterThan 0
            }

            It 'all records fall within the 7-day window' {
                $WindowStart = [datetime]::UtcNow.AddDays(-8)
                $WindowEnd = [datetime]::UtcNow.AddDays(1)
                foreach ($Entry in $script:UserLogs) {
                    $Entry.CreationDate | Should -BeGreaterOrEqual $WindowStart
                    $Entry.CreationDate | Should -BeLessOrEqual $WindowEnd
                }
            }
        }

        # -------------------------------------------------------------------
        Context '-SignInLog, AllUsers, 7-day query' {

            BeforeAll {
                Mock Write-IRT { }
                Mock Write-PSFMessage { }

                $script:CapturedSignIn = $null
                Mock Show-IRTUnifiedAuditLog { $script:CapturedSignIn = $Log }

                $Params = @{
                    AllUsers    = $true
                    SignInLog   = $true
                    Days        = 7
                    ResultLimit = 5000
                    Excel       = $true
                    Xml         = $false
                }
                Get-IRTUnifiedAuditLog @Params
                $script:SignInLogs = @(
                    $script:CapturedSignIn | Where-Object { $_ -and -not $_.Metadata }
                )
            }

            It 'returns at least 1 sign-in record' {
                if ($script:SignInLogs.Count -eq 0) {
                    throw 'No sign-in logs found; M365 tenants always have sign-in activity'
                }
                $script:SignInLogs.Count | Should -BeGreaterThan 0
            }

            It 'every record has a sign-in Operations value' {
                $ValidOps = @('UserLoggedIn', 'UserLoggedOff', 'UserLoginFailed')
                foreach ($Entry in $script:SignInLogs) {
                    $Entry.Operations | Should -BeIn $ValidOps
                }
            }
        }

        # -------------------------------------------------------------------
        Context '-ServicePrincipal (Graph Command Line Tools)' {

            BeforeAll {
                if (-not $script:GraphCLT) {
                    throw 'Graph CLT service principal not found; cannot run this context'
                }
                Mock Write-IRT { }
                Mock Write-PSFMessage { }

                $script:CapturedSPN = $null
                Mock Show-IRTUnifiedAuditLog { $script:CapturedSPN = $Log }

                $Params = @{
                    ServicePrincipal = $script:GraphCLT
                    Days             = 7
                    ResultLimit      = 5000
                    Excel            = $true
                    Xml              = $false
                }
                Get-IRTUnifiedAuditLog @Params
                $script:SPNLogs = @($script:CapturedSPN | Where-Object { $_ -and -not $_.Metadata })
            }

            It 'returns at least 1 record for Graph Command Line Tools' {
                if ($script:SPNLogs.Count -eq 0) {
                    throw 'No UAL records for Graph CLT in 7 days; likely a script error'
                }
                $script:SPNLogs.Count | Should -BeGreaterThan 0
            }

            It 'every record has a non-empty Identity' {
                foreach ($Entry in $script:SPNLogs) {
                    $Entry.Identity | Should -Not -BeNullOrEmpty
                }
            }
        }

        # -------------------------------------------------------------------
        Context '-RiskyOperation (test user, 180 days)' {

            BeforeAll {
                Mock Write-IRT { }
                Mock Write-PSFMessage { }

                $script:CapturedRisky = $null
                Mock Show-IRTUnifiedAuditLog { $script:CapturedRisky = $Log }

                $Params = @{
                    UserObject     = $script:TestUser
                    RiskyOperation = $true
                    Days           = 180
                    ResultLimit    = 5000
                    Excel          = $true
                    Xml            = $false
                }
                Get-IRTUnifiedAuditLog @Params
                $script:RiskyLogs = @(
                    $script:CapturedRisky | Where-Object { $_ -and -not $_.Metadata }
                )
            }

            It 'Show-IRTUnifiedAuditLog is called only when logs are returned' {
                if ($script:RiskyLogs.Count -gt 0) {
                    Should -Invoke Show-IRTUnifiedAuditLog -Times 1 -Exactly -Scope Context
                } else {
                    Should -Invoke Show-IRTUnifiedAuditLog -Times 0 -Exactly -Scope Context
                }
            }

            It 'every record has a non-empty Identity if risky logs were found' {
                if ($script:RiskyLogs.Count -eq 0) {
                    Set-ItResult -Skipped -Because 'no risky operations for test user in 180 days'
                    return
                }
                foreach ($Entry in $script:RiskyLogs) {
                    $Entry.Identity | Should -Not -BeNullOrEmpty
                }
            }
        }

        # -------------------------------------------------------------------
        Context '-FreeText with AllUsers, 7-day query' {

            BeforeAll {
                Mock Write-IRT { }
                Mock Write-PSFMessage { }

                $script:CapturedFT = $null
                Mock Show-IRTUnifiedAuditLog { $script:CapturedFT = $Log }

                $Params = @{
                    AllUsers    = $true
                    FreeText    = @('Microsoft', 'Graph', 'Exchange')
                    Days        = 7
                    ResultLimit = 5000
                    Excel       = $true
                    Xml         = $false
                }
                Get-IRTUnifiedAuditLog @Params
                $script:FreeTextLogs = @(
                    $script:CapturedFT | Where-Object { $_ -and -not $_.Metadata }
                )
            }

            It 'returns at least 1 record across all three FreeText terms' {
                if ($script:FreeTextLogs.Count -eq 0) {
                    throw 'No FreeText results; Microsoft/Graph/Exchange appear in every M365 log'
                }
                $script:FreeTextLogs.Count | Should -BeGreaterThan 0
            }

            It 'every record has a non-empty Identity' {
                foreach ($Entry in $script:FreeTextLogs) {
                    $Entry.Identity | Should -Not -BeNullOrEmpty
                }
            }
        }

        # -------------------------------------------------------------------
        Context '-Operation filter, AllUsers, 30-day query' {

            BeforeAll {
                Mock Write-IRT { }
                Mock Write-PSFMessage { }

                $script:CapturedOp = $null
                Mock Show-IRTUnifiedAuditLog { $script:CapturedOp = $Log }

                $Params = @{
                    AllUsers    = $true
                    Operation   = @(
                        'Consent to application.'
                        'Update user.'
                        'Add delegated permission grant.'
                    )
                    Days        = 30
                    ResultLimit = 5000
                    Excel       = $true
                    Xml         = $false
                }
                Get-IRTUnifiedAuditLog @Params
                $script:OperationLogs = @(
                    $script:CapturedOp | Where-Object { $_ -and -not $_.Metadata }
                )
            }

            It 'returns at least 1 record for the specified operations' {
                if ($script:OperationLogs.Count -eq 0) {
                    throw 'No records for the specified operations in 30 days'
                }
                $script:OperationLogs.Count | Should -BeGreaterThan 0
            }

            It 'every record Operations matches the requested set' {
                $RequestedOps = @(
                    'Consent to application.'
                    'Update user.'
                    'Add delegated permission grant.'
                )
                foreach ($Entry in $script:OperationLogs) {
                    $Entry.Operations | Should -BeIn $RequestedOps
                }
            }
        }

        # -------------------------------------------------------------------
        Context 'date chunking: 364-day query, UserLoggedIn, test user' {

            BeforeAll {
                Mock Write-IRT { }
                Mock Write-PSFMessage { }

                $script:CapturedChunked = $null
                Mock Show-IRTUnifiedAuditLog { $script:CapturedChunked = $Log }

                $Params = @{
                    UserObject  = $script:TestUser
                    Operation   = @('UserLoggedIn')
                    Days        = 364
                    ResultLimit = 5000
                    Excel       = $true
                    Xml         = $false
                }
                Get-IRTUnifiedAuditLog @Params
                $script:ChunkedLogs = @(
                    $script:CapturedChunked | Where-Object { $_ -and -not $_.Metadata }
                )
            }

            It 'returns at least 1 UserLoggedIn record over 364 days' {
                if ($script:ChunkedLogs.Count -eq 0) {
                    throw ('No UserLoggedIn records for the test user in 364 days; ' +
                        'likely a script or chunking error')
                }
                $script:ChunkedLogs.Count | Should -BeGreaterThan 0
            }

            It 'all records fall within the 364-day window' {
                $WindowStart = [datetime]::UtcNow.AddDays(-365)
                $WindowEnd = [datetime]::UtcNow.AddDays(1)
                foreach ($Entry in $script:ChunkedLogs) {
                    $Entry.CreationDate | Should -BeGreaterOrEqual $WindowStart
                    $Entry.CreationDate | Should -BeLessOrEqual $WindowEnd
                }
            }

            It 'every record Operations is UserLoggedIn' {
                foreach ($Entry in $script:ChunkedLogs) {
                    $Entry.Operations | Should -Be 'UserLoggedIn'
                }
            }
        }
    }
}
