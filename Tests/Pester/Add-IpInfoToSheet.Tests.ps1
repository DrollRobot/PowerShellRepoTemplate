#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Offline tests for Add-IpInfoToSheet.

.DESCRIPTION
    All tests run entirely in-memory; no files are written to disk and no
    network calls are made. The external 'ip_info' CLI tool is mocked as a
    PowerShell function so its behaviour can be controlled per test.
    Copy-ConditionalFormatting and Write-IRT are mocked to eliminate file
    I/O and console side-effects.

    $Global:IRT_Config and $Global:IRT_IpInfo are saved before each test
    and restored afterwards so the suite is safe to run in a live session.

    Note on EPPlus cell access: ExcelRange implements IEnumerable, so
    PowerShell treats $ws.Cells[row, col] as an array slice rather than a
    2-argument indexer call. This file uses $ws.SetValue(row, col, value)
    for writing and $ws.Cells['A1'] string-address notation for reading.

-- early-exit conditions ------------------------------------------------

    The function has several guard clauses that cause it to return silently
    with no side-effects. Each guard is tested individually.

    'returns when IpInfoAvailable is false'
        Guard at line 1: the function is an opt-in feature controlled by
        the config flag. Cell content must be unchanged.

    'returns when Worksheet is null'
        Guard at line 2: defensive null check. Requires [AllowNull()] on
        the $Worksheet parameter so the binder allows null to reach the
        function body.

    'returns when the worksheet has no table'
        Guard at line 3: the function requires a named table to locate
        the target column; a raw range is not supported.

    'returns when the table has no data rows'
        Guard at line 4: DataEndRow < DataStartRow means the table contains
        only a header row. Nothing to enrich.

    'returns when no requested column exists in the table'
        ColMap.Count == 0 after the column-discovery loop causes an early
        return. Silently skipping missing columns is intentional.

    'returns when the column has no valid IP addresses'
        AllIps.Count == 0 after the first pass causes an early return. The
        function must not call ip_info or rewrite any cells.

-- cell enrichment with cached data -------------------------------------

    Tests that verify the cell-rewriting logic using pre-populated cache
    entries. ip_info is not needed because all IPs are already cached.

    'rewrites the cell with IP list and enrichment block'
        The new cell value must contain both the original IP string and the
        cached enrichment text.

    'appends 20-space padding to the IP header line'
        The first "section" (before the first double-newline) must end with
        exactly 20 spaces.

    'separates the IP header line from the enrichment block with a blank line'
        Sections are joined with "`n`n". Splitting on that sequence must
        produce at least two sections.

    'does not rewrite a cell when the IP has no cache entry'
        When IpInfoTable.ContainsKey returns false, CellLines.Count == 1
        (header line only) and the cell is left untouched.

    'enriches a comma-separated multi-IP cell with data for both IPs'
        Cells may contain "ip1, ip2" from UAL rows with multiple source
        addresses. Both IPs must be resolved and appended.

    'enriches multiple columns independently'
        When two column names are requested, both matching columns must be
        enriched without interfering with each other.

-- ip_info invocation ---------------------------------------------------

    Tests that cover the external tool invocation path -- when one or more
    IPs are not yet in the cache.

    'does not call ip_info when all IPs are already cached'
        The unseen-IPs filter must produce an empty list, and the function
        must skip the ip_info block entirely.

    'calls ip_info exactly once for unseen IPs'
        A single call is expected regardless of how many unseen IPs were
        found. The bulk query sends them all at once.

    'populates the global cache from ip_info JSON output'
        The parsed JSON is stored in $Global:IRT_IpInfo so subsequent calls
        can serve the same IPs from cache.

    'rewrites the cell when ip_info returns data for the IP'
        End-to-end: cache miss -> ip_info query -> cache populated ->
        cell rewritten with fresh data.

    'does not rewrite cells when ip_info exits with a non-zero code'
        On failure the function returns early; cell values must be unchanged
        and no exception must propagate to the caller.

    'writes an error message when ip_info fails'
        The failure message is written via Write-IRT at Error level so the
        operator is informed of the problem.

-- Copy-ConditionalFormatting per column --------------------------------

    The function applies CF rules from the template to every column in
    ColMap after the rewrite pass, regardless of whether individual cells
    were enriched.

    'calls Copy-ConditionalFormatting once for a single-column request'
        One column in ColMap -> one CF call.

    'calls Copy-ConditionalFormatting once per column for a two-column request'
        Two columns in ColMap -> two CF calls.

    'does not call Copy-ConditionalFormatting when there are no valid IPs'
        AllIps.Count == 0 causes an early return before the CF loop.

    'does not call Copy-ConditionalFormatting when IpInfoAvailable is false'
        The very first guard returns before the CF loop is ever reached.
#>

InModuleScope M365IncidentResponseTools {

    Describe 'Add-IpInfoToSheet' {

        BeforeAll {
            Mock Write-IRT {}
            Mock Copy-ConditionalFormatting {}
            # Default ip_info mock: succeeds with an empty result set.
            Mock ip_info {
                $global:LASTEXITCODE = 0
                '{}'
            }

            # -------------------------------------------------------------------
            # Helper: create an in-memory EPPlus worksheet with a table.
            # Uses SetValue(row, col, value) rather than Cells[row,col].Value =
            # because ExcelRange implements IEnumerable, causing PowerShell to
            # treat [row, col] as an array slice rather than a 2-arg indexer.
            # ColumnNames populates the header row and defines table columns.
            # Rows is an array of hashtables keyed by column name.
            # -NoTable omits the table object (for the "no table" guard test).
            # -------------------------------------------------------------------
            function New-TestWorksheet {
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
                    'PSUseShouldProcessForStateChangingFunctions', '',
                    Justification = 'Test-only factory helper; ShouldProcess is not applicable.')]
                param(
                    [Parameter(Mandatory)]
                    [string[]]    $ColumnNames,

                    [hashtable[]] $Rows = @(),

                    [switch]      $NoTable
                )
                $pkg = [OfficeOpenXml.ExcelPackage]::new()
                $ws = $pkg.Workbook.Worksheets.Add('Sheet1')

                for ($c = 0; $c -lt $ColumnNames.Count; $c++) {
                    $ws.SetValue(1, $c + 1, $ColumnNames[$c])
                }

                $endRow = 1
                for ($r = 0; $r -lt $Rows.Count; $r++) {
                    for ($c = 0; $c -lt $ColumnNames.Count; $c++) {
                        $name = $ColumnNames[$c]
                        if ($Rows[$r].ContainsKey($name)) {
                            $ws.SetValue($r + 2, $c + 1, $Rows[$r][$name])
                        }
                    }
                    $endRow = $r + 2
                }

                if (-not $NoTable) {
                    $endColLetter = [char](64 + $ColumnNames.Count)
                    [void]$ws.Tables.Add($ws.Cells["A1:${endColLetter}${endRow}"], 'TestTable')
                }

                [pscustomobject]@{ Pkg = $pkg; Ws = $ws }
            }
        }

        BeforeEach {
            $script:OrigConfig = $Global:IRT_Config
            $script:OrigIpInfo = $Global:IRT_IpInfo
            $Global:IRT_Config = @{
                IpInfoAvailable  = $true
                IPConditionalFormattingTemplatePath = 'C:\fake\template.xlsx'
            }
            $Global:IRT_IpInfo = @{}
        }

        AfterEach {
            $Global:IRT_Config = $script:OrigConfig
            $Global:IRT_IpInfo = $script:OrigIpInfo
        }

        # -----------------------------------------------------------------------
        Context 'early-exit conditions' {

            It 'returns when IpInfoAvailable is false' {
                $Global:IRT_Config = @{
                    IpInfoAvailable                    = $false
                    IPConditionalFormattingTemplatePath = ''
                }
                $wb = New-TestWorksheet -ColumnNames 'IpAddress' -Rows @(@{ IpAddress = '1.2.3.4' })
                try {
                    { Add-IpInfoToSheet -Worksheet $wb.Ws -ColumnName 'IpAddress' } |
                        Should -Not -Throw
                    $wb.Ws.Cells['A2'].Value | Should -Be '1.2.3.4'
                } finally { $wb.Pkg.Dispose() }
            }

            It 'returns when Worksheet is null' {
                { Add-IpInfoToSheet -Worksheet $null -ColumnName 'IpAddress' } |
                    Should -Not -Throw
            }

            It 'returns when the worksheet has no table' {
                $rows = @(@{ IpAddress = '1.2.3.4' })
                $wb = New-TestWorksheet -ColumnNames 'IpAddress' -Rows $rows -NoTable
                try {
                    { Add-IpInfoToSheet -Worksheet $wb.Ws -ColumnName 'IpAddress' } |
                        Should -Not -Throw
                    $wb.Ws.Cells['A2'].Value | Should -Be '1.2.3.4'
                } finally { $wb.Pkg.Dispose() }
            }

            It 'returns when the table has no data rows' {
                # Single-row table (header only): DataEndRow=1 < DataStartRow=2.
                $pkg = [OfficeOpenXml.ExcelPackage]::new()
                $ws = $pkg.Workbook.Worksheets.Add('Sheet1')
                $ws.SetValue(1, 1, 'IpAddress')
                [void]$ws.Tables.Add($ws.Cells['A1'], 'EmptyTable')
                try {
                    { Add-IpInfoToSheet -Worksheet $ws -ColumnName 'IpAddress' } |
                        Should -Not -Throw
                } finally { $pkg.Dispose() }
            }

            It 'returns when no requested column exists in the table' {
                $wb = New-TestWorksheet -ColumnNames 'User' -Rows @(@{ User = 'alice' })
                try {
                    { Add-IpInfoToSheet -Worksheet $wb.Ws -ColumnName 'IpAddress' } |
                        Should -Not -Throw
                } finally { $wb.Pkg.Dispose() }
            }

            It 'returns when the column has no valid IP addresses' {
                $rows = @(@{ IpAddress = 'not-an-ip' })
                $wb = New-TestWorksheet -ColumnNames 'IpAddress' -Rows $rows
                try {
                    { Add-IpInfoToSheet -Worksheet $wb.Ws -ColumnName 'IpAddress' } |
                        Should -Not -Throw
                    $wb.Ws.Cells['A2'].Value | Should -Be 'not-an-ip'
                } finally { $wb.Pkg.Dispose() }
            }
        }

        # -----------------------------------------------------------------------
        Context 'cell enrichment with cached data' {

            BeforeEach {
                $Global:IRT_IpInfo['10.0.0.1'] = '10.0.0.1' + "`n" + 'City: TestCity'
                $Global:IRT_IpInfo['10.0.0.2'] = 'multi1 data'
                $Global:IRT_IpInfo['10.0.0.3'] = 'multi2 data'
            }

            It 'rewrites the cell with IP list and enrichment block' {
                $rows = @(@{ IpAddress = '10.0.0.1' })
                $wb = New-TestWorksheet -ColumnNames 'IpAddress' -Rows $rows
                try {
                    Add-IpInfoToSheet -Worksheet $wb.Ws -ColumnName 'IpAddress'
                    $cell = $wb.Ws.Cells['A2'].Value
                    $cell | Should -BeLike '*10.0.0.1*'
                    $cell | Should -BeLike '*City: TestCity*'
                } finally { $wb.Pkg.Dispose() }
            }

            It 'appends 20-space padding to the IP header line' {
                $rows = @(@{ IpAddress = '10.0.0.1' })
                $wb = New-TestWorksheet -ColumnNames 'IpAddress' -Rows $rows
                try {
                    Add-IpInfoToSheet -Worksheet $wb.Ws -ColumnName 'IpAddress'
                    $firstSection = ($wb.Ws.Cells['A2'].Value -split "`n`n")[0]
                    $firstSection | Should -Be ('10.0.0.1' + (' ' * 20))
                } finally { $wb.Pkg.Dispose() }
            }

            It 'separates the IP header line from the enrichment block with a blank line' {
                $rows = @(@{ IpAddress = '10.0.0.1' })
                $wb = New-TestWorksheet -ColumnNames 'IpAddress' -Rows $rows
                try {
                    Add-IpInfoToSheet -Worksheet $wb.Ws -ColumnName 'IpAddress'
                    $sections = $wb.Ws.Cells['A2'].Value -split "`n`n"
                    $sections.Count | Should -BeGreaterOrEqual 2
                } finally { $wb.Pkg.Dispose() }
            }

            It 'does not rewrite a cell when the IP has no cache entry' {
                $rows = @(@{ IpAddress = '192.168.1.1' })
                $wb = New-TestWorksheet -ColumnNames 'IpAddress' -Rows $rows
                try {
                    Add-IpInfoToSheet -Worksheet $wb.Ws -ColumnName 'IpAddress'
                    $wb.Ws.Cells['A2'].Value | Should -Be '192.168.1.1'
                } finally { $wb.Pkg.Dispose() }
            }

            It 'enriches a comma-separated multi-IP cell with data for both IPs' {
                $rows = @(@{ IpAddress = '10.0.0.2, 10.0.0.3' })
                $wb = New-TestWorksheet -ColumnNames 'IpAddress' -Rows $rows
                try {
                    Add-IpInfoToSheet -Worksheet $wb.Ws -ColumnName 'IpAddress'
                    $cell = $wb.Ws.Cells['A2'].Value
                    $cell | Should -BeLike '*multi1 data*'
                    $cell | Should -BeLike '*multi2 data*'
                } finally { $wb.Pkg.Dispose() }
            }

            It 'enriches multiple columns independently' {
                $rows = @(@{ SrcIp = '10.0.0.1'; DstIp = '10.0.0.2' })
                $wb = New-TestWorksheet -ColumnNames 'SrcIp', 'DstIp' -Rows $rows
                try {
                    Add-IpInfoToSheet -Worksheet $wb.Ws -ColumnName 'SrcIp', 'DstIp'
                    $wb.Ws.Cells['A2'].Value | Should -BeLike '*City: TestCity*'
                    $wb.Ws.Cells['B2'].Value | Should -BeLike '*multi1 data*'
                } finally { $wb.Pkg.Dispose() }
            }
        }

        # -----------------------------------------------------------------------
        Context 'ip_info invocation' {

            It 'does not call ip_info when all IPs are already cached' {
                $Global:IRT_IpInfo['10.2.0.1'] = 'cached data'
                $rows = @(@{ IpAddress = '10.2.0.1' })
                $wb = New-TestWorksheet -ColumnNames 'IpAddress' -Rows $rows
                try {
                    Add-IpInfoToSheet -Worksheet $wb.Ws -ColumnName 'IpAddress'
                    Should -Not -Invoke ip_info
                } finally { $wb.Pkg.Dispose() }
            }

            It 'calls ip_info exactly once for unseen IPs' {
                $rows = @(@{ IpAddress = '10.3.0.1' })
                $wb = New-TestWorksheet -ColumnNames 'IpAddress' -Rows $rows
                try {
                    Add-IpInfoToSheet -Worksheet $wb.Ws -ColumnName 'IpAddress'
                    Should -Invoke ip_info -Times 1 -Exactly
                } finally { $wb.Pkg.Dispose() }
            }

            It 'populates the global cache from ip_info JSON output' {
                Mock ip_info {
                    $global:LASTEXITCODE = 0
                    '{"10.4.0.1": "info for 10.4.0.1"}'
                }
                $rows = @(@{ IpAddress = '10.4.0.1' })
                $wb = New-TestWorksheet -ColumnNames 'IpAddress' -Rows $rows
                try {
                    Add-IpInfoToSheet -Worksheet $wb.Ws -ColumnName 'IpAddress'
                    $Global:IRT_IpInfo.ContainsKey('10.4.0.1') | Should -BeTrue
                    $Global:IRT_IpInfo['10.4.0.1'] | Should -Be 'info for 10.4.0.1'
                } finally { $wb.Pkg.Dispose() }
            }

            It 'rewrites the cell when ip_info returns data for the IP' {
                Mock ip_info {
                    $global:LASTEXITCODE = 0
                    '{"10.5.0.1": "fresh data for 10.5.0.1"}'
                }
                $rows = @(@{ IpAddress = '10.5.0.1' })
                $wb = New-TestWorksheet -ColumnNames 'IpAddress' -Rows $rows
                try {
                    Add-IpInfoToSheet -Worksheet $wb.Ws -ColumnName 'IpAddress'
                    $wb.Ws.Cells['A2'].Value | Should -BeLike '*fresh data for 10.5.0.1*'
                } finally { $wb.Pkg.Dispose() }
            }

            It 'does not rewrite cells when ip_info exits with a non-zero code' {
                Mock ip_info { $global:LASTEXITCODE = 1 }
                $rows = @(@{ IpAddress = '10.6.0.1' })
                $wb = New-TestWorksheet -ColumnNames 'IpAddress' -Rows $rows
                try {
                    { Add-IpInfoToSheet -Worksheet $wb.Ws -ColumnName 'IpAddress' } |
                        Should -Not -Throw
                    $wb.Ws.Cells['A2'].Value | Should -Be '10.6.0.1'
                } finally { $wb.Pkg.Dispose() }
            }

            It 'writes an error message when ip_info fails' {
                Mock ip_info { $global:LASTEXITCODE = 1 }
                Mock Write-IRT {}
                $rows = @(@{ IpAddress = '10.7.0.1' })
                $wb = New-TestWorksheet -ColumnNames 'IpAddress' -Rows $rows
                try {
                    Add-IpInfoToSheet -Worksheet $wb.Ws -ColumnName 'IpAddress'
                    Should -Invoke Write-IRT -Times 1 -ParameterFilter { $Level -eq 'Error' }
                } finally { $wb.Pkg.Dispose() }
            }
        }

        # -----------------------------------------------------------------------
        Context 'Copy-ConditionalFormatting per column' {

            BeforeEach {
                $Global:IRT_IpInfo['10.8.0.1'] = 'cf-data-1'
                $Global:IRT_IpInfo['10.8.0.2'] = 'cf-data-2'
            }

            It 'calls Copy-ConditionalFormatting once for a single-column request' {
                Mock Copy-ConditionalFormatting {}
                $rows = @(@{ IpAddress = '10.8.0.1' })
                $wb = New-TestWorksheet -ColumnNames 'IpAddress' -Rows $rows
                try {
                    Add-IpInfoToSheet -Worksheet $wb.Ws -ColumnName 'IpAddress'
                    Should -Invoke Copy-ConditionalFormatting -Times 1 -Exactly
                } finally { $wb.Pkg.Dispose() }
            }

            It 'calls Copy-ConditionalFormatting once per column for a two-column request' {
                Mock Copy-ConditionalFormatting {}
                $rows = @(@{ SrcIp = '10.8.0.1'; DstIp = '10.8.0.2' })
                $wb = New-TestWorksheet -ColumnNames 'SrcIp', 'DstIp' -Rows $rows
                try {
                    Add-IpInfoToSheet -Worksheet $wb.Ws -ColumnName 'SrcIp', 'DstIp'
                    Should -Invoke Copy-ConditionalFormatting -Times 2 -Exactly
                } finally { $wb.Pkg.Dispose() }
            }

            It 'does not call Copy-ConditionalFormatting when there are no valid IPs' {
                Mock Copy-ConditionalFormatting {}
                $rows = @(@{ IpAddress = 'not-an-ip' })
                $wb = New-TestWorksheet -ColumnNames 'IpAddress' -Rows $rows
                try {
                    Add-IpInfoToSheet -Worksheet $wb.Ws -ColumnName 'IpAddress'
                    Should -Not -Invoke Copy-ConditionalFormatting
                } finally { $wb.Pkg.Dispose() }
            }

            It 'does not call Copy-ConditionalFormatting when IpInfoAvailable is false' {
                $Global:IRT_Config = @{
                    IpInfoAvailable                    = $false
                    IPConditionalFormattingTemplatePath = ''
                }
                Mock Copy-ConditionalFormatting {}
                $rows = @(@{ IpAddress = '10.8.0.1' })
                $wb = New-TestWorksheet -ColumnNames 'IpAddress' -Rows $rows
                try {
                    Add-IpInfoToSheet -Worksheet $wb.Ws -ColumnName 'IpAddress'
                    Should -Not -Invoke Copy-ConditionalFormatting
                } finally { $wb.Pkg.Dispose() }
            }
        }
    }
}
