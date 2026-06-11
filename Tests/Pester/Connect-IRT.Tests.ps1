#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Tests for the token-expiry helpers and Connect-IRT orchestration logic.

.DESCRIPTION
    This file contains unit tests for two private module helpers and the
    public Connect-IRT function. The private-helper tests run entirely
    offline using synthetic JWTs. The Connect-IRT unit tests mock all
    downstream connect functions so no network I/O occurs. Live integration
    tests are in a separate Online-tagged Describe block and require an
    active tenant connection.

-- Get-TokenExpiry ---------------------------------------------------

    Decodes a JWT payload, extracts the 'exp' Unix timestamp, and returns
    a UTC DateTime. Returns $null (never throws) when the token cannot be
    parsed, so callers can treat unreadable tokens as expired.

    'returns a UTC DateTime matching the exp value'
        Verifies the full round-trip from a known Unix epoch value through
        base64url encoding to a DateTime, using a fixed future timestamp
        (2033) so the test is not time-sensitive.

    'returns a DateTime with UTC kind'
        Confirms the returned DateTime has DateTimeKind.Utc, not Local or
        Unspecified, which would cause incorrect comparisons on machines
        outside UTC.

    'returns $null when exp is absent from the payload'
        Graceful handling of non-standard tokens that carry no 'exp' claim
        (some Exchange Online opaque tokens omit it).

    'returns $null for a string with no dot separators'
        Graceful handling of non-JWT bearer strings passed by mistake.

    'returns $null when the payload segment is not valid base64url'
        Graceful handling of corrupted or truncated tokens.

    'returns $null when the payload decodes to non-JSON'
        Graceful handling of tokens whose payload is valid base64 but not
        a JSON object (e.g. legacy or third-party token formats).

-- Test-TokenExpired -----------------------------------------------------

    Wraps Get-TokenExpiry and adds a configurable buffer window
    (default 300 s / 5 min). Returns $true when the token is within or
    past the buffer, $true for unparseable tokens (fail-safe), and $false
    when the token is comfortably fresh.

    'returns $true for a token that expired an hour ago'
        Clearly-expired case; no ambiguity from the buffer window.

    'returns $false for a token that expires two hours from now'
        Clearly-fresh case; well outside the 5-minute buffer.

    'returns $true for a malformed / unparseable token'
        Conservative fallback: when expiry cannot be determined the
        function treats the token as expired to force re-authentication.

    'returns $true when expiry is within 3 minutes (inside buffer)'
        Tests the lower bracket of the boundary: 3 min < 5 min buffer,
        so the token must be treated as expired.

    'returns $false when expiry is 7 minutes away (outside buffer)'
        Tests the upper bracket: 7 min > 5 min buffer, so the token must
        be treated as still valid.

    'treats a 30-minute token as expired when buffer is 1 hour'
        Confirms that a custom -BufferSeconds value (3600) actually
        overrides the default rather than being silently ignored.

    'treats a 30-second token as fresh when buffer is 0'
        Confirms that a buffer of 0 disables the safety window entirely,
        so tokens are only expired when they have literally passed.

-- Connect-IRT: -Refresh (no active session) -----------------------------

    'writes a non-terminating error'
        -Refresh with $Global:IRT_Session = $null must emit a
        non-terminating error (not throw) so the caller can decide
        how to handle the failure.

    'error message mentions "no active IRT session"'
        The error text must be human-readable and direct the operator
        to run Connect-IRT -TenantId first.

-- Connect-IRT: -Refresh (session exists, no services) -------------------

    'writes a non-terminating error'
        A partially-constructed session with all service slots $null has
        nothing to refresh; must write an error distinct from the missing-
        session case.

    'error message mentions "no service connections"'
        Error text distinguishes this state from a completely absent
        session so the operator knows the session object exists but is
        empty.

-- Connect-IRT: -Refresh (Graph-only session, mocked) --------------------

    Connect-IRTGraph, Connect-IRTExchange, Connect-IRTIPPS, and
    Test-IRTConnection are all mocked; no real network traffic occurs.

    'invokes Connect-IRTGraph exactly once'
        -Refresh must call Connect-IRTGraph exactly once; not zero times
        (skipping the refresh) and not multiple times (retry loop).

    'passes the session TenantId to Connect-IRTGraph'
        -Refresh reads TenantId from the existing session instead of
        requiring the caller to supply it again; verifies it is forwarded.

    'passes Cloud = Commercial to Connect-IRTGraph'
        The cloud environment stored in the session must be forwarded so
        the token is acquired against the correct authority, not silently
        defaulted.

    'does not invoke Connect-IRTExchange when Exchange is absent from session'
        Only services that were previously established should be refreshed.
        Creating a new Exchange connection here would be unexpected behaviour.

    'does not invoke Connect-IRTIPPS when IPPS is absent from session'
        Same principle as the Exchange case.

    'stores the refreshed Graph result back into the session'
        The new connection object from Connect-IRTGraph must replace the
        stale one so subsequent module calls use the fresh token.

    'stores the refreshed TokenExpiry in the session'
        TokenExpiry must be updated so the prompt function and
        Test-IRTConnection see the correct next-expiry time.

-- Connect-IRT session state (live) [Tag: Online] ------------------------

    Full integration tests against a real tenant. Require -Online flag on
    tests.ps1. This file runs first in the two-pass online strategy:
    its BeforeAll clears $Global:IRT_Session and calls Connect-IRT from
    scratch, genuinely testing the function. On success the session stays
    in global scope for all subsequent online test files. Auth uses an
    isolated test token cache so the operator's primary cache is never
    affected.

    In interactive mode (-Online without -CachedAuth) the BeforeAll signs
    in once to populate the cache, clears the session, then reconnects
    silently to verify the full cache round-trip in a single run.
    In agent mode (-Online -CachedAuth) only a silent refresh is attempted.

    'Graph TokenExpiry is a future UTC DateTime'
        Confirms a real Graph access token was acquired and its expiry was
        correctly parsed; a past expiry would mean every API call would
        immediately trigger a re-auth.

    'Exchange TokenExpiry is a future UTC DateTime'
        Same assertion for Exchange; validates the separate MSAL client ID
        and scope path through the token acquisition code.

    'Connect-IRT -Refresh preserves the session TenantId'
        A live -Refresh call must not overwrite the session identity that
        the prompt function and other callers depend on.

    'Test-IRTConnection -Quiet returns $true when both services are connected'
        Validates that Test-IRTConnection correctly reads the live session
        and returns a boolean $true rather than writing to the console.
#>

# ---------------------------------------------------------------------------
# Private helpers (Get-TokenExpiry, Test-TokenExpired)
# These are not exported; InModuleScope is required to access them.
#
# Both helpers exist to give Connect-IRT* functions a reliable, testable
# way to decide whether a cached access token is still usable. They are
# tested here in isolation (pure unit tests, no network I/O) so that any
# breakage in token-expiry logic surfaces with a precise failure message
# rather than a cryptic "token expired" error in a live connect test.
# ---------------------------------------------------------------------------
InModuleScope M365IncidentResponseTools {

    BeforeAll {
        # New-TestJwt produces the minimal three-segment JWT structure
        # (header.payload.signature) that Get-TokenExpiry expects to
        # parse. Only the payload's 'exp' field matters; the header and
        # signature segments are not validated by the helper.
        # -OmitExp produces a payload with no 'exp' key, used to verify
        # graceful handling of non-standard or opaque tokens.
        # The signature segment is deliberately empty -- these tokens are
        # never passed to MSAL or any validation endpoint.
        function New-TestJwt {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
                'PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Test-only factory helper; ShouldProcess is not applicable.')]
            param(
                [long]   $Exp,
                [switch] $OmitExp
            )
            $ToBase64Url = {
                param([string] $Text)
                [System.Convert]::ToBase64String(
                    [System.Text.Encoding]::UTF8.GetBytes($Text)
                ).TrimEnd('=').Replace('+', '-').Replace('/', '_')
            }
            $Header = & $ToBase64Url '{"alg":"none","typ":"JWT"}'
            $Payload = if ($OmitExp) {
                & $ToBase64Url '{"sub":"test"}'
            } else {
                & $ToBase64Url "{`"sub`":`"test`",`"exp`":$Exp}"
            }
            return "$Header.$Payload."
        }
    }

    Describe 'Get-TokenExpiry' {
        # Get-TokenExpiry decodes the JWT payload, reads the 'exp' Unix
        # timestamp, and converts it to a UTC DateTime. It is intentionally
        # lenient: if the token cannot be parsed for any reason it returns
        # $null rather than throwing, so callers can treat an unreadable
        # token the same way as a missing token (i.e. force re-authentication).

        Context 'valid JWT with exp claim' {
            # Verifies the round-trip: Unix epoch -> base64url payload -> DateTime.
            # The constant 2000000000 is ~2033-05-18, comfortably in the future
            # so this test won't accidentally become time-sensitive.
            It 'returns a UTC DateTime matching the exp value' {
                $UnixExp = 2000000000L
                $Token = New-TestJwt -Exp $UnixExp
                $Expected = [System.DateTimeOffset]::FromUnixTimeSeconds($UnixExp).UtcDateTime
                Get-TokenExpiry -Token $Token | Should -Be $Expected
            }
            It 'returns a DateTime with UTC kind' {
                $Token = New-TestJwt -Exp 2000000000L
                $Result = Get-TokenExpiry -Token $Token
                $Result.Kind | Should -Be ([System.DateTimeKind]::Utc)
            }
        }

        Context 'tokens without a usable exp claim' {
            # These cases represent real-world situations: Exchange Online
            # tokens that omit 'exp', opaque bearer strings from third-party
            # services, network errors that return non-JWT payloads, etc.
            # In all cases Get-TokenExpiry must return $null silently so
            # the caller can decide what to do (typically: treat as expired).
            It 'returns $null when exp is absent from the payload' {
                Get-TokenExpiry -Token (New-TestJwt -OmitExp) | Should -BeNullOrEmpty
            }
            It 'returns $null for a string with no dot separators' {
                Get-TokenExpiry -Token 'notajwt' | Should -BeNullOrEmpty
            }
            It 'returns $null when the payload segment is not valid base64url' {
                Get-TokenExpiry -Token 'header.!!!BAD!!!.sig' | Should -BeNullOrEmpty
            }
            It 'returns $null when the payload decodes to non-JSON' {
                $BadPayload = [System.Convert]::ToBase64String(
                    [System.Text.Encoding]::UTF8.GetBytes('not json at all')
                ).TrimEnd('=').Replace('+', '-').Replace('/', '_')
                Get-TokenExpiry -Token "header.$BadPayload.sig" | Should -BeNullOrEmpty
            }
        }
    }

    Describe 'Test-TokenExpired' {
        # Test-TokenExpired wraps Get-TokenExpiry and adds a configurable
        # buffer window (default 300 seconds / 5 minutes). A token is
        # considered "expired" if its expiry time is within the buffer,
        # giving the caller time to acquire a fresh token before the current
        # one actually expires mid-operation. If the token cannot be parsed,
        # the function conservatively returns $true (treat as expired).

        Context 'clearly expired or clearly fresh' {
            # Straightforward cases: tokens well outside the buffer window
            # in either direction, plus the unparseable-token safety net.
            It 'returns $true for a token that expired an hour ago' {
                $Exp = [long][System.DateTimeOffset]::UtcNow.AddHours(-1).ToUnixTimeSeconds()
                $Token = New-TestJwt -Exp $Exp
                Test-TokenExpired -Token $Token | Should -BeTrue
            }
            It 'returns $false for a token that expires two hours from now' {
                $Exp = [long][System.DateTimeOffset]::UtcNow.AddHours(2).ToUnixTimeSeconds()
                $Token = New-TestJwt -Exp $Exp
                Test-TokenExpired -Token $Token | Should -BeFalse
            }
            It 'returns $true for a malformed / unparseable token' {
                Test-TokenExpired -Token 'garbage' | Should -BeTrue
            }
        }

        Context 'default 300-second buffer window' {
            # The 5-minute buffer prevents a race where a token that looks
            # valid at the start of a long operation has expired by the time
            # it's actually sent. These tests bracket the boundary: 3 minutes
            # (inside buffer -> treated as expired) vs 7 minutes (outside
            # buffer -> treated as fresh).
            It 'returns $true when expiry is within 3 minutes (inside buffer)' {
                $Exp = [long][System.DateTimeOffset]::UtcNow.AddMinutes(3).ToUnixTimeSeconds()
                $Token = New-TestJwt -Exp $Exp
                Test-TokenExpired -Token $Token | Should -BeTrue
            }
            It 'returns $false when expiry is 7 minutes away (outside buffer)' {
                $Exp = [long][System.DateTimeOffset]::UtcNow.AddMinutes(7).ToUnixTimeSeconds()
                $Token = New-TestJwt -Exp $Exp
                Test-TokenExpired -Token $Token | Should -BeFalse
            }
        }

        Context 'custom BufferSeconds' {
            # Callers that need a larger safety margin (e.g. long-running
            # runspace operations) can supply their own buffer. These tests
            # confirm the parameter is actually honoured and not silently
            # ignored in favour of the default.
            It 'treats a 30-minute token as expired when buffer is 1 hour' {
                $Exp = [long][System.DateTimeOffset]::UtcNow.AddMinutes(30).ToUnixTimeSeconds()
                $Token = New-TestJwt -Exp $Exp
                Test-TokenExpired -Token $Token -BufferSeconds 3600 | Should -BeTrue
            }
            It 'treats a 30-second token as fresh when buffer is 0' {
                $Exp = [long][System.DateTimeOffset]::UtcNow.AddSeconds(30).ToUnixTimeSeconds()
                $Token = New-TestJwt -Exp $Exp
                Test-TokenExpired -Token $Token -BufferSeconds 0 | Should -BeFalse
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Connect-IRT: exported function -- guard conditions and orchestration
#
# Connect-IRT is the public entry point that orchestrates Graph, Exchange,
# and IPPS connections. These tests focus on the -Refresh parameter set,
# which re-uses an existing $Global:IRT_Session to re-acquire tokens
# without requiring the caller to re-specify TenantId, Cloud, etc.
#
# All downstream connect functions (Connect-IRTGraph, Connect-IRTExchange,
# Connect-IRTIPPS) are mocked so these tests exercise orchestration logic
# only -- no network I/O, no MSAL, no browser prompts.
# ---------------------------------------------------------------------------
InModuleScope M365IncidentResponseTools {
    Describe 'Connect-IRT' {

        Context '-Refresh: no active session' {
            # -Refresh is only meaningful when a session already exists.
            # If $Global:IRT_Session is $null there is nothing to refresh,
            # so the function must write a non-terminating error (not throw)
            # to preserve the caller's ability to handle the failure gracefully.
            # BeforeEach/AfterEach save and restore the real session so this
            # test is safe to run while the developer is actively connected.
            BeforeEach {
                $script:SavedSession = (
                    Get-Variable -Name IRT_Session -Scope Global -ErrorAction SilentlyContinue
                )?.Value
                $Global:IRT_Session = $null
            }
            AfterEach {
                $Global:IRT_Session = $script:SavedSession
            }

            It 'writes a non-terminating error' {
                # -ErrorAction SilentlyContinue prevents the error from
                # propagating up and failing the test itself; we capture it
                # in -ErrorVariable instead to assert on it directly.
                $Errors = @()
                Connect-IRT -Refresh -ErrorVariable Errors -ErrorAction SilentlyContinue
                $Errors | Should -Not -BeNullOrEmpty
            }
            It 'error message mentions "no active IRT session"' {
                # The error text must be user-readable and guide the operator
                # to run Connect-IRT -TenantId first.
                $Errors = @()
                Connect-IRT -Refresh -ErrorVariable Errors -ErrorAction SilentlyContinue
                $Errors[0].Exception.Message | Should -Match 'no active IRT session'
            }
        }

        Context '-Refresh: session exists but no services recorded' {
            # A session object can exist (e.g. partially constructed) with no
            # service connections recorded -- Graph, Exchange, and IPPS are all
            # $null. There is nothing to refresh in this state, so the function
            # must again write a non-terminating error with a distinct message
            # that distinguishes this case from a completely absent session.
            BeforeEach {
                $script:SavedSession = (
                    Get-Variable -Name IRT_Session -Scope Global -ErrorAction SilentlyContinue
                )?.Value
                $Global:IRT_Session = [pscustomobject]@{
                    TenantId    = 'aaaaaaaa-0000-0000-0000-aaaaaaaaaaaa'
                    Cloud = 'Commercial'
                    Graph       = $null
                    Exchange    = $null
                    IPPS        = $null
                }
            }
            AfterEach {
                $Global:IRT_Session = $script:SavedSession
            }

            It 'writes a non-terminating error' {
                $Errors = @()
                Connect-IRT -Refresh -ErrorVariable Errors -ErrorAction SilentlyContinue
                $Errors | Should -Not -BeNullOrEmpty
            }
            It 'error message mentions "no service connections"' {
                $Errors = @()
                Connect-IRT -Refresh -ErrorVariable Errors -ErrorAction SilentlyContinue
                $Errors[0].Exception.Message | Should -Match 'no service connections'
            }
        }

        Context '-Refresh: Graph-only session (mocked downstream)' {
            # The happy path for -Refresh: a session exists with only Graph
            # connected. The function should identify which services are present,
            # call the corresponding connect function for each one (Graph only,
            # in this case), and store the result back into the session.
            #
            # Connect-IRTGraph, Connect-IRTExchange, Connect-IRTIPPS, and
            # Test-IRTConnection are all mocked to eliminate any real network
            # calls. The mock for Connect-IRTGraph returns a synthetic connection
            # object with a predictable Token and TokenExpiry so the session
            # state can be asserted on after the call.
            BeforeEach {
                $script:SavedSession = (
                    Get-Variable -Name IRT_Session -Scope Global -ErrorAction SilentlyContinue
                )?.Value
                $script:RefreshedExpiry = [System.DateTime]::UtcNow.AddHours(1)
                $Global:IRT_Session = [pscustomobject]@{
                    TenantId    = 'bbbbbbbb-0000-0000-0000-bbbbbbbbbbbb'
                    Cloud = 'Commercial'
                    Graph       = [pscustomobject]@{
                        Token                   = 'old-graph-token'
                        TokenExpiry             = [System.DateTime]::UtcNow.AddMinutes(5)
                        Account                 = $null
                        PublicClientApplication = $null
                    }
                    Exchange    = $null
                    IPPS        = $null
                }
                Mock Connect-IRTGraph {
                    [pscustomobject]@{
                        Token                   = 'refreshed-graph-token'
                        TokenExpiry             = $script:RefreshedExpiry
                        Account                 = $null
                        PublicClientApplication = $null
                    }
                }
                Mock Connect-IRTExchange { }
                Mock Connect-IRTIPPS { }
                Mock Test-IRTConnection { }
                Mock Get-DefaultDomain { $null }
            }
            AfterEach {
                $Global:IRT_Session = $script:SavedSession
            }

            It 'invokes Connect-IRTGraph exactly once' {
                # Confirms -Refresh delegates to Connect-IRTGraph and does
                # not call it multiple times (e.g. in a retry loop).
                Connect-IRT -Refresh
                Should -Invoke Connect-IRTGraph -Times 1 -Exactly
            }
            It 'passes the session TenantId to Connect-IRTGraph' {
                # -Refresh reads TenantId from the session rather than requiring
                # the caller to supply it again. Verifies the value flows through.
                Connect-IRT -Refresh
                $Assert = @{
                    Times           = 1
                    ParameterFilter = { $TenantId -eq 'bbbbbbbb-0000-0000-0000-bbbbbbbbbbbb' }
                }
                Should -Invoke Connect-IRTGraph @Assert
            }
            It 'passes Cloud = Commercial to Connect-IRTGraph' {
                # The cloud environment recorded in the session (Commercial here)
                # must be forwarded so the token is acquired against the correct
                # authority endpoint, not defaulted to Commercial accidentally.
                Connect-IRT -Refresh
                $Assert = @{
                    Times           = 1
                    ParameterFilter = { $Cloud -eq 'Commercial' }
                }
                Should -Invoke Connect-IRTGraph @Assert
            }
            It 'does not invoke Connect-IRTExchange when Exchange is absent from session' {
                # -Refresh should only reconnect services that were previously
                # established. Calling Connect-IRTExchange when Exchange was
                # never connected would create an unintended new connection.
                Connect-IRT -Refresh
                Should -Invoke Connect-IRTExchange -Times 0
            }
            It 'does not invoke Connect-IRTIPPS when IPPS is absent from session' {
                # Same rationale as the Exchange case above.
                Connect-IRT -Refresh
                Should -Invoke Connect-IRTIPPS -Times 0
            }
            It 'stores the refreshed Graph result back into the session' {
                # The fresh connection object returned by Connect-IRTGraph must
                # replace the stale one in $Global:IRT_Session.Graph so that
                # subsequent module calls use the new token.
                Connect-IRT -Refresh
                $Global:IRT_Session.Graph.Token | Should -Be 'refreshed-graph-token'
            }
            It 'stores the refreshed TokenExpiry in the session' {
                # TokenExpiry is used by Test-IRTConnection and the prompt
                # function to decide whether a re-authentication is needed.
                # A stale expiry would cause unnecessary re-auth prompts.
                Connect-IRT -Refresh
                $Global:IRT_Session.Graph.TokenExpiry | Should -Be $script:RefreshedExpiry
            }
        }
    }
} # end InModuleScope

# ---------------------------------------------------------------------------
# Online tests -- connect automatically via $env:IRT_TEST_TENANT_ID
# Run with: .\tests.ps1 -Online
#
# These tests exercise the full authentication stack against a live tenant
# (real MSAL token acquisition, real Graph/Exchange endpoints). They are
# tagged 'Online' so the offline test run never executes them.
#
# tests.ps1 overrides $Global:IRT_Config.MsalCachePath to an
# isolated test cache (irt-testing-cache.bin) before running this suite,
# so live runs never pollute the operator's primary token cache.
#
# Two auth modes (controlled by $env:IRT_TEST_SILENT_AUTH, set by tests.ps1):
#   '0' / unset -- Interactive: the test cache is deleted first, Connect-IRT
#                  prompts the user once to populate the cache, then the session
#                  is cleared and Connect-IRT reconnects silently to verify the
#                  cache round-trip in the same run.
#   '1'         -- Cached (-CachedAuth flag): MSAL attempts a silent refresh
#                  from the existing test cache only. No interactive prompt.
#                  Fails immediately if no cached credentials are present.
#
# The BeforeAll clears $Global:IRT_Session before calling Connect-IRT so
# the tests genuinely verify that Connect-IRT establishes the session from
# scratch, not that a pre-existing session already looks healthy.
# ---------------------------------------------------------------------------
Describe 'Connect-IRT session state (live)' -Tag 'Online' {

    BeforeAll {
        # Clear any pre-existing session so Connect-IRT is tested from scratch.
        # Without this, assertions like 'TenantId is non-empty' would pass even
        # if Connect-IRT were broken, as long as something else had set the session.
        $Global:IRT_Session = $null

        # Resolve the tenant ID from the environment or the .env.ps1 file.
        # .env.ps1 is gitignored and contains developer-local settings
        # (e.g. $env:IRT_TEST_TENANT_ID = 'your-tenant-guid-here').
        $TenantId = $env:IRT_TEST_TENANT_ID
        if (-not $TenantId) {
            $EnvFile = Join-Path -Path $PSScriptRoot -ChildPath '..\.env.ps1'
            if (Test-Path $EnvFile) { . $EnvFile }
            $TenantId = $env:IRT_TEST_TENANT_ID
        }
        if (-not $TenantId) {
            throw ('Set $env:IRT_TEST_TENANT_ID or create tests/.env.ps1 ' +
                'before running online tests.')
        }

        $ConnectParams = @{ TenantId = $TenantId }
        if ($env:IRT_TEST_SILENT_AUTH -eq '1') {
            # -CachedAuth mode: no browser prompt allowed. If MSAL cannot find
            # a valid cached token it will throw, which we catch here to
            # provide a more actionable error message than the raw MSAL output.
            $ConnectParams['Silent'] = $true
            try {
                Connect-IRT @ConnectParams
            }
            catch {
                throw (
                    'No cached test credentials found for silent auth. ' +
                    "Run '.\tests.ps1 online -Interactive' to sign in " +
                    "interactively and populate the test token cache first. " +
                    "Original error: $_"
                )
            }
        }
        else {
            # Interactive mode: sign in once to populate the cache, then
            # immediately verify the round-trip by clearing the session and
            # reconnecting silently. The final session is established via
            # silent auth, proving the cache was correctly written.
            Connect-IRT @ConnectParams
            $Global:IRT_Session = $null
            try {
                $ConnectParams['Silent'] = $true
                Connect-IRT @ConnectParams
            }
            catch {
                throw (
                    'Interactive sign-in succeeded but silent cache reconnect failed. ' +
                    'The MSAL token cache may not have been written correctly. ' +
                    "Original error: $_"
                )
            }
        }
    }

    It 'session has a non-empty TenantId' {
        # Basic sanity check: Connect-IRT must populate $Global:IRT_Session
        # with the TenantId it connected to. A null or empty value here
        # would indicate the session object was not initialised at all.
        $Global:IRT_Session.TenantId | Should -Not -BeNullOrEmpty
    }

    It 'Graph TokenExpiry is a future UTC DateTime' {
        # Confirms that a real access token was obtained and that its expiry
        # was correctly parsed and stored. A past expiry would mean the
        # token is already considered expired before a single API call is made.
        if (-not $Global:IRT_Session.Graph) {
            Set-ItResult -Skipped -Because 'Graph is not connected in this session'
        }
        $Global:IRT_Session.Graph.TokenExpiry | Should -BeOfType [System.DateTime]
        $Global:IRT_Session.Graph.TokenExpiry | Should -BeGreaterThan ([System.DateTime]::UtcNow)
    }

    It 'Exchange TokenExpiry is a future UTC DateTime' {
        # Same assertion as the Graph case; Exchange uses a separate MSAL
        # client ID and scope so token parsing is exercised independently.
        if (-not $Global:IRT_Session.Exchange) {
            Set-ItResult -Skipped -Because 'Exchange is not connected in this session'
        }
        $Global:IRT_Session.Exchange.TokenExpiry | Should -BeOfType [System.DateTime]
        $Global:IRT_Session.Exchange.TokenExpiry | Should -BeGreaterThan ([System.DateTime]::UtcNow)
    }

    It 'Connect-IRT -Refresh preserves the session TenantId' {
        # -Refresh must not reset or overwrite the TenantId stored in the
        # session. If it did, the prompt function and other callers that
        # read $Global:IRT_Session.TenantId would silently lose context.
        $OriginalTenantId = $Global:IRT_Session.TenantId
        Connect-IRT -Refresh
        $Global:IRT_Session.TenantId | Should -Be $OriginalTenantId
    }

    It 'Test-IRTConnection -Quiet returns $true when both services are connected' {
        # Validates that Test-IRTConnection correctly reads the live session
        # state and reports connectivity. -Quiet suppresses console output
        # and returns a boolean, which is easier to assert on in tests.
        if (-not ($Global:IRT_Session.Graph -and $Global:IRT_Session.Exchange)) {
            Set-ItResult -Skipped -Because 'requires both Graph and Exchange connections'
        }
        Test-IRTConnection -Quiet | Should -BeTrue
    }
}

# ---------------------------------------------------------------------------
# Admin consent workflow (live) [Tag: Online]
#
# Verifies that Connect-IRT detects missing tenant-wide consent and drives
# the /adminconsent flow to completion. The test is intentionally destructive:
# it revokes all oauth2PermissionGrants for the Graph CLI Tools app, then
# forces a Graph reconnect, which must detect the missing consent, open the
# admin consent URL in a browser, and re-grant tenant-wide consent.
#
# This test REQUIRES interactive auth - the user must sign in as a Global
# Administrator in the browser and click Accept. It is skipped automatically
# when running in -CachedAuth (silent) mode.
#
# Depends on the session established by 'Connect-IRT session state (live)'
# earlier in this file - run order within a file is guaranteed by Pester.
#
# 'revoking consent removes at least one grant'
#     Confirms the revoke helper actually found and removed grants. If this
#     fails it means consent was already absent (nothing to test) or the
#     helper failed silently.
#
# 'admin consent is re-granted after forced reconnect'
#     The core assertion. After Connect-IRT -Force drives the browser consent
#     flow, at least one AllPrincipals grant must exist for the Graph CLI
#     Tools app. An empty result means the flow did not complete or the
#     grant was not written.
#
# 'Graph token is valid after consent re-grant'
#     Confirms the forced reconnect produced a fresh, usable token and that
#     the session was updated correctly alongside the consent grant.
# ---------------------------------------------------------------------------
Describe 'Connect-IRT admin consent workflow (live)' -Tag 'Online' {

    BeforeAll {
        # This test requires browser interaction for the consent prompt.
        # Skip the entire block when running in silent/cached-auth mode.
        $script:SkipConsentTests = $env:IRT_TEST_SILENT_AUTH -eq '1'
        if ($script:SkipConsentTests) { return }

        if (-not ($Global:IRT_Session -and $Global:IRT_Session.Graph)) {
            throw ('Admin consent tests require an active Graph connection. ' +
                "Run '.\tests.ps1 -Online' so the session is established first.")
        }

        . (Join-Path -Path $PSScriptRoot -ChildPath '..\..\Scripts\Revoke-IRTGraphConsent.ps1')

        Write-Output ''
        Write-Output '--- Admin Consent Test Setup ---'
        Write-Output (
            'Revoking all consent grants for the Graph CLI Tools app...'
        )
        $script:RevokedCount = Revoke-IRTGraphConsent
        Write-Output "$($script:RevokedCount) grant(s) removed."
        Write-Output ''
        Write-Output (
            'Forcing a Graph reconnect. A browser window will open for admin consent.'
        )
        Write-Output (
            'Sign in as a Global Administrator and click Accept to continue.'
        )
        Write-Output '--------------------------------'
        Write-Output ''

        Connect-IRT -TenantId $Global:IRT_Session.TenantId -Graph -Force
    }

    It 'revoking consent removes at least one grant' {
        if ($script:SkipConsentTests) {
            Set-ItResult -Skipped -Because (
                'admin consent workflow requires interactive auth ' +
                '(-CachedAuth not supported)')
            return
        }
        $script:RevokedCount | Should -BeGreaterThan 0 -Because (
            'the Graph CLI Tools app must have had at least ' +
            'one consent grant to revoke')
    }

    It 'admin consent is re-granted after forced reconnect' {
        if ($script:SkipConsentTests) {
            Set-ItResult -Skipped -Because 'admin consent workflow requires interactive auth'
            return
        }
        # Entra ID replication for oauth2PermissionGrants can lag up to ~60 seconds
        # after the browser consent flow completes, so poll until the grant is visible
        # rather than asserting immediately. Connect-IRT already warned if replication
        # was still in flight when it returned.
        $AppId = '14d82eec-204b-4c2f-b7e8-296a70dab67e'
        $SpRequest = @{
            Method      = 'GET'
            Uri         = "v1.0/servicePrincipals(appId='$AppId')?`$select=id"
            ErrorAction = 'Stop'
        }
        $Sp = Invoke-MgGraphRequest @SpRequest

        $Grants = $null
        $Deadline = [datetime]::UtcNow.AddSeconds(120)
        while (-not $Grants -and [datetime]::UtcNow -lt $Deadline) {
            $GrantRequest = @{
                Method      = 'GET'
                Uri         = (
                    'v1.0/oauth2PermissionGrants?' +
                    "`$filter=clientId eq '$($Sp.id)' " +
                    "and consentType eq 'AllPrincipals'")
                ErrorAction = 'Stop'
            }
            $Grants = (Invoke-MgGraphRequest @GrantRequest).value
            if (-not $Grants) {
                Write-Output '  Waiting for grant replication...'
                Start-Sleep -Seconds 5
            }
        }

        $Grants | Should -Not -BeNullOrEmpty -Because (
            'Connect-IRT must re-grant tenant-wide consent ' +
            'after the browser flow completes')
    }

    It 'Graph token is valid after consent re-grant' {
        if ($script:SkipConsentTests) {
            Set-ItResult -Skipped -Because 'admin consent workflow requires interactive auth'
            return
        }
        $Global:IRT_Session.Graph | Should -Not -BeNullOrEmpty
        $Global:IRT_Session.Graph.TokenExpiry | Should -BeOfType [System.DateTime]
        $Global:IRT_Session.Graph.TokenExpiry | Should -BeGreaterThan (
            [System.DateTime]::UtcNow
        ) -Because 'the forced reconnect must produce a fresh token'
    }
}


