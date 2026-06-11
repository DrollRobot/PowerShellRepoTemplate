#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Tests for Update-IRTToken token-expiry detection and refresh orchestration.

.DESCRIPTION
    All tests are offline. Connect-IRT and Write-IRT are mocked throughout so
    no network I/O occurs. $Global:IRT_Session is saved before each test and
    restored afterwards, so the test suite is safe to run while actively
    connected to a tenant.

    Session objects are constructed with New-SvcObject (a BeforeAll helper)
    using a signed ExpiresInMinutes value: positive = future, negative = past.
    This lets each context describe the token state declaratively without
    repeating DateTime arithmetic in every test.

-- no IRT session ($Global:IRT_Session is $null) -------------------------

    Update-IRTToken must detect a missing session before trying to read any
    service slot. When SkipIfNeverConnected is not set it must write one
    error per requested service so the operator knows exactly which services
    need connecting. When SkipIfNeverConnected is set it must return silently
    (the prompt calls it before any connection has been made).

    'writes an error for each requested service when SkipIfNeverConnected is not set'
        Verifies one Write-IRT -Level Error call per service in the -Service list.
        Bracketing with two services (Graph, Exchange) confirms the loop runs
        once per service rather than once per function call.

    'writes no output when SkipIfNeverConnected is set'
        Confirms the early-return path emits nothing at all -- no errors, no
        status messages.

    'returns nothing even with -PassThru'
        The function returns before reaching the PassThru block, so the caller
        must receive $null rather than an empty or partial hashtable.

    'does not call Connect-IRT'
        A missing session cannot be refreshed; calling Connect-IRT -Refresh
        would fail anyway because it also requires an existing session.

-- service slot is null in the session -----------------------------------

    A session object can exist while individual service slots are $null (e.g.
    the user connected Graph-only). The function must not treat a null slot as
    a reason to refresh -- there is nothing to refresh -- and it must not call
    Connect-IRT for a service that was never connected.

    'writes an error when SkipIfNeverConnected is not set'
        Verifies the "not connected to <svc>" error path for a null slot.

    'writes no error when SkipIfNeverConnected is set'
        Prompt-mode: null slots are silently skipped.

    '-PassThru returns $false for the missing service'
        A null slot means no valid token; PassThru must report it as $false.

    'does not call Connect-IRT when the only requested service is missing'
        A missing service sets continue on the loop without setting
        $needsRefresh, so the refresh block must not execute.

-- token is healthy (TokenExpiry > 5 minutes from now) ------------------

    The function should never call Connect-IRT when all requested tokens are
    well within their validity window. This is the hot path on every prompt
    render and every domain-function call; spurious refreshes here would cause
    unnecessary latency and could trigger MSAL rate limits.

    'does not call Connect-IRT -Refresh'
        The core assertion: a healthy token produces zero Connect-IRT calls.

    '-PassThru returns $true for the service'
        The token is valid; PassThru must report it as connected.

    '-PassThru returns a hashtable'
        Verifies the return type is [hashtable], not $null or another type,
        so callers can safely key into it with $result['Graph'].

-- token is expiring within the 5-minute threshold ----------------------

    MSAL's AcquireTokenSilent uses the refresh token (making a network call
    for a fresh access token) only when the cached token is within ~5 minutes
    of expiry. Update-IRTToken uses the same window so that the Connect-IRT
    -Refresh call actually yields a genuinely new token rather than the same
    near-expired cached one.

    'calls Connect-IRT -Refresh exactly once'
        The function must call Connect-IRT -Refresh exactly once -- not zero
        times (missing the refresh) and not more than once (retry loop).

    'writes a status message before refreshing'
        The "Token expiring soon - refreshing..." message warns the operator
        that a network round-trip is about to happen.

    '-PassThru returns $true because the token has not yet passed its expiry'
        The token expires in 3 minutes; it is stale by our threshold but still
        technically valid (TotalMinutes > 0). PassThru must reflect the actual
        expiry, not the threshold.

-- token is already expired (TokenExpiry in the past) -------------------

    An expired token has TotalMinutes < 0. The function must still trigger a
    refresh (expired < threshold) and PassThru must report $false unless the
    refresh mock actually updates the session.

    'calls Connect-IRT -Refresh'
        Expired tokens must trigger a refresh, same as near-expired tokens.

    '-PassThru returns $false when the session is not updated by the refresh'
        When the Connect-IRT mock does nothing, the session still holds the
        old expired TokenExpiry. PassThru (TotalMinutes > 0) must return $false
        so callers know the token is not usable.

    '-PassThru returns $true when the refresh updates the session with a fresh token'
        The mock sets $Global:IRT_Session.Graph.TokenExpiry to +1 hour, exactly
        as the real Connect-IRT -Refresh would. PassThru must return $true.

-- Connect-IRT -Refresh throws -------------------------------------------

    If Connect-IRT -Refresh raises a terminating error the try/catch must
    absorb it and write a human-readable "Token refresh failed" message.
    The exception must never propagate to the caller, because Update-IRTToken
    is called at the top of domain functions where an unhandled error would
    abort the entire operation.

    'writes a token-refresh-failed error'
        Verifies the catch block writes Write-IRT with -Level Error and a
        message that contains "refresh failed".

    'does not propagate the exception to the caller'
        { Update-IRTToken } | Should -Not -Throw.

-- Connect-IRT pipeline output is suppressed ----------------------------

    Test-IRTConnection (called at the end of Connect-IRT's non-Refresh path)
    writes PSCustomObjects to the pipeline via Format-Table. Without the
    $null = assignment those objects flow up through Update-IRTToken and mix
    with the PassThru hashtable. The caller then receives an Object[] and
    $result['Graph'] returns $null instead of a boolean -- the root cause of
    the "Connected: none" bug.

    The mock emits two PSCustomObjects to simulate that pipeline output.
    With $null = Connect-IRT, those objects are discarded and only the
    hashtable reaches the caller.

    '-PassThru returns a hashtable (not an array) when Connect-IRT emits pipeline output'
        Asserts the return type is [hashtable]. If the $null = were removed,
        Update-IRTToken would return an Object[] and this test would fail.

    '-PassThru hashtable keys are service names, not Connect-IRT pipeline properties'
        A mixed array would have no 'Graph' key and might have 'Service' or
        'Connected' as indices instead. This test confirms the correct keys.

-- -Service parameter scopes which services are checked -----------------

    The function must only examine and report on the services listed in
    -Service. Keys for unrequested services must not appear in the PassThru
    hashtable so callers can rely on the presence of a key to mean "I asked
    about this service".

    '-PassThru contains only the requested service key'
        Single-service call returns exactly one key.

    '-PassThru contains all three keys when all three are requested'
        Full default call returns Graph, Exchange, and IPPS keys.

-- one service expiring, another healthy --------------------------------

    $needsRefresh is a single boolean for the entire call: as soon as any
    service is within the threshold the function calls Connect-IRT -Refresh
    once for all services together. It must not refresh per-service (which
    would call Connect-IRT multiple times) and must not skip the refresh
    because another service is still healthy.

    'calls Connect-IRT -Refresh once regardless of which service triggers it'
        With Graph expiring and Exchange healthy, exactly one Connect-IRT
        call must be made.

    '-PassThru reports the healthy service as $true'
        Exchange has 60 minutes left; it must be reported as connected.

    '-PassThru reports the expiring (but not yet expired) service as $true'
        Graph expires in 2 minutes: within the threshold but TotalMinutes > 0,
        so PassThru must still return $true.
#>

# ---------------------------------------------------------------------------
# All tests run inside InModuleScope so that Mock intercepts Write-IRT and
# Connect-IRT as they are called from within Update-IRTToken, not from the
# outer session scope.
# ---------------------------------------------------------------------------
InModuleScope M365IncidentResponseTools {

    BeforeAll {
        # New-SvcObject creates a minimal service-session object for
        # $Global:IRT_Session.Graph / .Exchange / .IPPS. Update-IRTToken only
        # checks whether .Token and .TokenExpiry are non-null and reads
        # .TokenExpiry as a [datetime]; it never parses the JWT string itself,
        # so any non-empty token string is sufficient.
        # ExpiresInMinutes is signed: positive = future, negative = past.
        function New-SvcObject {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
                'PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Test-only factory helper; ShouldProcess is not applicable.')]
            param(
                [int]    $ExpiresInMinutes,
                [string] $Account = 'test@contoso.com'
            )
            [pscustomobject]@{
                Token             = 'fake-token'
                TokenExpiry       = [datetime]::UtcNow.AddMinutes($ExpiresInMinutes)
                Account           = $Account
                UserPrincipalName = $Account
            }
        }

        # New-IrtSession assembles a full $Global:IRT_Session object from
        # individual service objects (or $null for absent services).
        function New-IrtSession {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
                'PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Test-only factory helper; ShouldProcess is not applicable.')]
            param(
                [string] $TenantId = 'aaaaaaaa-0000-0000-0000-aaaaaaaaaaaa',
                [object] $Graph = $null,
                [object] $Exchange = $null,
                [object] $IPPS = $null
            )
            [pscustomobject]@{
                TenantId    = $TenantId
                Environment = 'Commercial'
                Graph       = $Graph
                Exchange    = $Exchange
                IPPS        = $IPPS
            }
        }
    }

    Describe 'Update-IRTToken' {

        # Save and restore $Global:IRT_Session around every test so the suite
        # is safe to run while the developer is actively connected to a tenant.
        BeforeEach {
            $script:SavedSession = (
                Get-Variable -Name IRT_Session -Scope Global -ErrorAction SilentlyContinue
            )?.Value
        }
        AfterEach {
            $Global:IRT_Session = $script:SavedSession
        }

        # -------------------------------------------------------------------
        Context 'no IRT session ($Global:IRT_Session is $null)' {

            BeforeEach { $Global:IRT_Session = $null }

            It 'writes an error for each requested service when SkipIfNeverConnected is not set' {
                # Two services requested -> exactly two Error-level Write-IRT calls.
                Mock Write-IRT { }
                Update-IRTToken -Service 'Graph', 'Exchange'
                Should -Invoke Write-IRT -Times 2 -ParameterFilter { $Level -eq 'Error' }
            }

            It 'writes no output when SkipIfNeverConnected is set' {
                Mock Write-IRT { }
                Update-IRTToken -SkipIfNeverConnected
                Should -Invoke Write-IRT -Times 0
            }

            It 'returns nothing even with -PassThru' {
                # The function hits an early return before the PassThru block.
                $result = Update-IRTToken -SkipIfNeverConnected -PassThru
                $result | Should -BeNullOrEmpty
            }

            It 'does not call Connect-IRT' {
                Mock Connect-IRT { }
                Update-IRTToken -SkipIfNeverConnected
                Should -Invoke Connect-IRT -Times 0
            }
        }

        # -------------------------------------------------------------------
        Context 'session exists but the requested service slot is $null' {

            BeforeEach {
                $Global:IRT_Session = New-IrtSession -Graph $null
            }

            It 'writes an error when SkipIfNeverConnected is not set' {
                Mock Write-IRT { }
                Update-IRTToken -Service 'Graph'
                Should -Invoke Write-IRT -Times 1 -ParameterFilter { $Level -eq 'Error' }
            }

            It 'writes no error when SkipIfNeverConnected is set' {
                Mock Write-IRT { }
                Update-IRTToken -Service 'Graph' -SkipIfNeverConnected
                Should -Invoke Write-IRT -Times 0
            }

            It '-PassThru returns $false for the missing service' {
                $result = Update-IRTToken -Service 'Graph' -SkipIfNeverConnected -PassThru
                $result.Graph | Should -BeFalse
            }

            It 'does not call Connect-IRT when the only requested service is missing' {
                # A null slot causes continue in the loop; $needsRefresh stays $false.
                Mock Connect-IRT { }
                Update-IRTToken -Service 'Graph' -SkipIfNeverConnected
                Should -Invoke Connect-IRT -Times 0
            }
        }

        # -------------------------------------------------------------------
        Context 'token is healthy (TokenExpiry more than 5 minutes away)' {

            BeforeEach {
                $Global:IRT_Session = New-IrtSession -Graph (New-SvcObject -ExpiresInMinutes 60)
                Mock Connect-IRT { }
            }

            It 'does not call Connect-IRT -Refresh' {
                Update-IRTToken -Service 'Graph'
                Should -Invoke Connect-IRT -Times 0
            }

            It '-PassThru returns $true for the service' {
                $result = Update-IRTToken -Service 'Graph' -PassThru
                $result.Graph | Should -BeTrue
            }

            It '-PassThru returns a hashtable' {
                # Callers key into the result with $result['Graph'], which requires
                # the return type to be [hashtable] and not $null or an array.
                $result = Update-IRTToken -Service 'Graph' -PassThru
                $result | Should -BeOfType [hashtable]
            }
        }

        # -------------------------------------------------------------------
        Context 'token is expiring within the 5-minute threshold' {

            # 3 minutes: within the 5-minute refresh window, but still future
            # (TotalMinutes > 0), so PassThru must report $true.
            BeforeEach {
                $Global:IRT_Session = New-IrtSession -Graph (New-SvcObject -ExpiresInMinutes 3)
                Mock Connect-IRT { }
                Mock Write-IRT { }
            }

            It 'calls Connect-IRT -Refresh exactly once' {
                Update-IRTToken -Service 'Graph'
                Should -Invoke Connect-IRT -Times 1 -Exactly -ParameterFilter { $Refresh }
            }

            It 'writes a status message before refreshing' {
                Update-IRTToken -Service 'Graph'
                Should -Invoke Write-IRT -Times 1 -ParameterFilter { $Message -match 'refreshing' }
            }

            It '-PassThru returns $true because the token has not yet passed its expiry' {
                $result = Update-IRTToken -Service 'Graph' -PassThru
                $result.Graph | Should -BeTrue
            }
        }

        # -------------------------------------------------------------------
        Context 'token is already expired (TokenExpiry in the past)' {

            BeforeEach {
                $Global:IRT_Session = New-IrtSession -Graph (New-SvcObject -ExpiresInMinutes -30)
                Mock Write-IRT { }
            }

            It 'calls Connect-IRT -Refresh' {
                Mock Connect-IRT { }
                Update-IRTToken -Service 'Graph'
                Should -Invoke Connect-IRT -Times 1 -ParameterFilter { $Refresh }
            }

            It '-PassThru returns $false when the session is not updated by the refresh' {
                # The mock does nothing; TokenExpiry remains -30 minutes in the past.
                # PassThru checks TotalMinutes > 0, which is $false.
                Mock Connect-IRT { }
                $result = Update-IRTToken -Service 'Graph' -PassThru
                $result.Graph | Should -BeFalse
            }

            It '-PassThru returns $true when the refresh updates the session with a fresh token' {
                # Simulate what Connect-IRT -Refresh does: write a new connection object
                # with a future TokenExpiry back into $Global:IRT_Session.Graph.
                Mock Connect-IRT {
                    $Global:IRT_Session.Graph = [pscustomobject]@{
                        Token       = 'refreshed-token'
                        TokenExpiry = [datetime]::UtcNow.AddHours(1)
                        Account     = 'test@contoso.com'
                    }
                }
                $result = Update-IRTToken -Service 'Graph' -PassThru
                $result.Graph | Should -BeTrue
            }
        }

        # -------------------------------------------------------------------
        Context 'Connect-IRT -Refresh throws' {

            BeforeEach {
                $Global:IRT_Session = New-IrtSession -Graph (New-SvcObject -ExpiresInMinutes 2)
                Mock Connect-IRT { throw 'MSAL auth failed' }
                Mock Write-IRT { }
            }

            It 'writes a token-refresh-failed error' {
                Update-IRTToken -Service 'Graph'
                Should -Invoke Write-IRT -Times 1 -ParameterFilter {
                    $Level -eq 'Error' -and $Message -match 'refresh failed'
                }
            }

            It 'does not propagate the exception to the caller' {
                { Update-IRTToken -Service 'Graph' } | Should -Not -Throw
            }
        }

        # -------------------------------------------------------------------
        Context 'Connect-IRT pipeline output is suppressed' {

            # Test-IRTConnection writes PSCustomObjects to the pipeline via
            # Format-Table. Without "$null = Connect-IRT -Refresh", those objects
            # flow into Update-IRTToken's own pipeline and mix with the PassThru
            # hashtable. The caller receives an Object[] instead of a hashtable,
            # and $result['Graph'] returns $null -- the "Connected: none" bug.
            # The mock below emits two objects to reproduce that scenario.
            BeforeEach {
                $Global:IRT_Session = New-IrtSession -Graph (New-SvcObject -ExpiresInMinutes 2)
                Mock Connect-IRT {
                    [pscustomobject]@{ Service = 'Graph'; Connected = $true }
                    [pscustomobject]@{ Service = 'Exchange'; Connected = $false }
                }
                Mock Write-IRT { }
            }

            It '-PassThru returns a hashtable even when Connect-IRT emits pipeline output' {
                $result = Update-IRTToken -Service 'Graph' -PassThru
                $result | Should -BeOfType [hashtable]
            }

            It '-PassThru hashtable keys are service names, not pipeline object properties' {
                $result = Update-IRTToken -Service 'Graph' -PassThru
                $result.Keys | Should -Contain 'Graph'
                $result.Keys | Should -HaveCount 1
                $result.ContainsKey('Service') | Should -BeFalse
                $result.ContainsKey('Connected') | Should -BeFalse
            }
        }

        # -------------------------------------------------------------------
        Context '-Service parameter scopes which services are checked' {

            BeforeEach {
                $IrtParams = @{
                    Graph    = New-SvcObject -ExpiresInMinutes 60
                    Exchange = New-SvcObject -ExpiresInMinutes 60
                    IPPS     = New-SvcObject -ExpiresInMinutes 60
                }
                $Global:IRT_Session = New-IrtSession @IrtParams
                Mock Connect-IRT { }
            }

            It '-PassThru contains only the requested service key when one service is specified' {
                $result = Update-IRTToken -Service 'Graph' -PassThru
                $result.Keys | Should -Contain 'Graph'
                $result.Keys | Should -HaveCount 1
                $result.ContainsKey('Exchange') | Should -BeFalse
                $result.ContainsKey('IPPS') | Should -BeFalse
            }

            It '-PassThru contains all three keys when all three services are requested' {
                $result = Update-IRTToken -Service 'Graph', 'Exchange', 'IPPS' -PassThru
                $result.ContainsKey('Graph') | Should -BeTrue
                $result.ContainsKey('Exchange') | Should -BeTrue
                $result.ContainsKey('IPPS') | Should -BeTrue
            }
        }

        # -------------------------------------------------------------------
        Context 'one service expiring, another healthy' {

            BeforeEach {
                $IrtParams = @{
                    Graph    = New-SvcObject -ExpiresInMinutes 2
                    Exchange = New-SvcObject -ExpiresInMinutes 60
                }
                $Global:IRT_Session = New-IrtSession @IrtParams
                Mock Connect-IRT { }
                Mock Write-IRT { }
            }

            It 'calls Connect-IRT -Refresh exactly once regardless of which service triggers it' {
                # $needsRefresh is a single flag; the loop sets it on the first
                # expiring service and the refresh block fires once for all services.
                Update-IRTToken -Service 'Graph', 'Exchange'
                Should -Invoke Connect-IRT -Times 1 -Exactly -ParameterFilter { $Refresh }
            }

            It '-PassThru reports the healthy service as $true' {
                $result = Update-IRTToken -Service 'Graph', 'Exchange' -PassThru
                $result.Exchange | Should -BeTrue
            }

            It '-PassThru reports the expiring (but not yet expired) service as $true' {
                $result = Update-IRTToken -Service 'Graph', 'Exchange' -PassThru
                $result.Graph | Should -BeTrue
            }
        }
    }
}
