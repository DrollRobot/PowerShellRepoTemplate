#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Online tests for Add-IpInfoToSheet.

.DESCRIPTION
    These tests require a live internet connection and the ip_info CLI tool to
    be installed. ip_info is NOT mocked; calls go to the real tool so the full
    query-parse-cache-rewrite pipeline is exercised end-to-end.

    Copy-ConditionalFormatting and Write-IRT are still mocked to avoid file I/O
    and console side-effects.

    Well-known stable public IPs used: 1.1.1.1 (Cloudflare), 8.8.8.8 (Google),
    9.9.9.9 (Quad9).

    $Global:IRT_Config and $Global:IRT_IpInfo are saved before each test and
    restored afterwards so the suite is safe to run in a live session.

-- live ip_info query ---------------------------------------------------

    'populates the global cache with live data for a queried IP'
        After calling the function, $Global:IRT_IpInfo must contain an entry
        keyed by the queried IP address. Confirms ip_info was called and its
        JSON output was parsed and stored.

    'rewrites the cell with live enrichment data'
        The cell value must change from the bare IP string to a longer value
        that contains both the IP address and additional ip_info content.

    'preserves the 20-space padding on the IP header line'
        The first section (before the first double-newline) must end with
        exactly 20 trailing spaces, consistent with the offline format tests.

    'preserves the double-newline separator between header and enrichment'
        Splitting the cell value on the double-newline sequence must yield at
        least two sections.

    'enriches a multi-IP cell with live data for both IPs'
        When a cell contains two IPs (comma-separated), both addresses must
        appear in the rewritten cell value.

    'serves a cached IP from memory on a subsequent call'
        After a live call populates $Global:IRT_IpInfo, a second call in the
        same test (no BeforeEach reset between calls) must produce identical
        enrichment content, confirming the cache entry is used.
#>

InModuleScope M365IncidentResponseTools {

    Describe 'Add-IpInfoToSheet' -Tag 'Online' {

        BeforeAll {
            # Fail fast with a clear message if the tool is not installed.
            if (-not (Get-Command ip_info -ErrorAction SilentlyContinue)) {
                throw 'ip_info CLI tool not found. Run Install-Dependencies.ps1 first.'
            }

            Mock Write-IRT {}
            Mock Copy-ConditionalFormatting {}
            # ip_info is NOT mocked; the real CLI tool is invoked.

            function New-TestWorksheet {
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
                    'PSUseShouldProcessForStateChangingFunctions', '',
                    Justification = 'Test-only factory helper; ShouldProcess is not applicable.')]
                param(
                    [Parameter(Mandatory)]
                    [string[]]    $ColumnNames,

                    [hashtable[]] $Rows = @()
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

                $endColLetter = [char](64 + $ColumnNames.Count)
                [void]$ws.Tables.Add($ws.Cells["A1:${endColLetter}${endRow}"], 'TestTable')

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
        Context 'live ip_info query' {

            It 'populates the global cache with live data for a queried IP' {
                $wb = New-TestWorksheet -ColumnNames 'IpAddress' -Rows @(
                    @{ IpAddress = '1.1.1.1' }
                )
                try {
                    Add-IpInfoToSheet -Worksheet $wb.Ws -ColumnName 'IpAddress'
                    $Global:IRT_IpInfo.ContainsKey('1.1.1.1') | Should -BeTrue
                    $Global:IRT_IpInfo['1.1.1.1'] | Should -Not -BeNullOrEmpty
                } finally { $wb.Pkg.Dispose() }
            }

            It 'rewrites the cell with live enrichment data' {
                $wb = New-TestWorksheet -ColumnNames 'IpAddress' -Rows @(
                    @{ IpAddress = '8.8.8.8' }
                )
                try {
                    Add-IpInfoToSheet -Worksheet $wb.Ws -ColumnName 'IpAddress'
                    $cell = $wb.Ws.Cells['A2'].Value
                    $cell | Should -BeLike '*8.8.8.8*'
                    $cell.Length | Should -BeGreaterThan '8.8.8.8'.Length
                } finally { $wb.Pkg.Dispose() }
            }

            It 'preserves the 20-space padding on the IP header line' {
                $wb = New-TestWorksheet -ColumnNames 'IpAddress' -Rows @(
                    @{ IpAddress = '1.1.1.1' }
                )
                try {
                    Add-IpInfoToSheet -Worksheet $wb.Ws -ColumnName 'IpAddress'
                    $firstSection = ($wb.Ws.Cells['A2'].Value -split "`n`n")[0]
                    $firstSection | Should -Be ('1.1.1.1' + (' ' * 20))
                } finally { $wb.Pkg.Dispose() }
            }

            It 'preserves the double-newline separator between header and enrichment' {
                $wb = New-TestWorksheet -ColumnNames 'IpAddress' -Rows @(
                    @{ IpAddress = '1.1.1.1' }
                )
                try {
                    Add-IpInfoToSheet -Worksheet $wb.Ws -ColumnName 'IpAddress'
                    $sections = $wb.Ws.Cells['A2'].Value -split "`n`n"
                    $sections.Count | Should -BeGreaterOrEqual 2
                } finally { $wb.Pkg.Dispose() }
            }

            It 'enriches a multi-IP cell with live data for both IPs' {
                $wb = New-TestWorksheet -ColumnNames 'IpAddress' -Rows @(
                    @{ IpAddress = '1.1.1.1, 8.8.8.8' }
                )
                try {
                    Add-IpInfoToSheet -Worksheet $wb.Ws -ColumnName 'IpAddress'
                    $cell = $wb.Ws.Cells['A2'].Value
                    $cell | Should -BeLike '*1.1.1.1*'
                    $cell | Should -BeLike '*8.8.8.8*'
                } finally { $wb.Pkg.Dispose() }
            }

            It 'serves a cached IP from memory on a subsequent call' {
                # First call: live ip_info query; cache is populated as a side-effect.
                $wb1 = New-TestWorksheet -ColumnNames 'IpAddress' -Rows @(
                    @{ IpAddress = '9.9.9.9' }
                )
                try {
                    Add-IpInfoToSheet -Worksheet $wb1.Ws -ColumnName 'IpAddress'
                    $firstResult = $wb1.Ws.Cells['A2'].Value
                    $Global:IRT_IpInfo.ContainsKey('9.9.9.9') | Should -BeTrue
                } finally { $wb1.Pkg.Dispose() }

                # Second call in the same It block: BeforeEach has not reset the cache,
                # so 9.9.9.9 is already present. The cell must be enriched identically.
                $wb2 = New-TestWorksheet -ColumnNames 'IpAddress' -Rows @(
                    @{ IpAddress = '9.9.9.9' }
                )
                try {
                    Add-IpInfoToSheet -Worksheet $wb2.Ws -ColumnName 'IpAddress'
                    $wb2.Ws.Cells['A2'].Value | Should -Be $firstResult
                } finally { $wb2.Pkg.Dispose() }
            }
        }
    }
}
