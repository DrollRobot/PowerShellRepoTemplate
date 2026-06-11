#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Offline tests for Copy-ConditionalFormatting.

.DESCRIPTION
    All tests create disposable temp .xlsx files and inspect the EPPlus object model directly.
    No network calls are made. ImportExcel (and therefore EPPlus) must be available; it is loaded
    automatically when tests.ps1 imports the module manifest.

-- single ContainsText rule, path -> path --------------------------------

    The most common usage: source and destination are both file paths.
    The function opens and closes both packages internally; the destination is
    saved on exit.

    'copies exactly one rule'
        Confirms the destination worksheet has no extra or missing rules.

    'preserves the rule type'
        The EPPlus type enum value must round-trip as 'ContainsText'.

    'preserves the condition text'
        The Text property ("vpn") must appear unchanged in the destination rule.

    'preserves StopIfTrue'
        The flag must be carried across; omitting it would change evaluation order.

-- range clipping --------------------------------------------------------

    When SourceRange does not cover the full rule address, the copied rule's
    address is clipped to the intersection. Only the rows that fall inside
    SourceRange should appear in the destination.

    'clips the destination address end row to 50'
        Rule lives on A1:A100; SourceRange is A1:A50 -> destination end row is 50.

    'preserves start row at 1'
        The start of the clipped range must not be shifted.

-- column offset ---------------------------------------------------------

    When DestinationRange starts on a different column than SourceRange, every
    rule address is shifted by the column delta. Row positions are unchanged.

    'places the rule on column C (index 3)'
        Source A1:A100 -> destination C1 -> rule must land on column 3.

    'retains the row range after offset'
        Rows 1-100 stay 1-100; only the column shifts.

-- multiple rules --------------------------------------------------------

    All rules whose addresses intersect SourceRange must be copied, not just
    the first one.

    'copies all three rules'
        Three ContainsText rules on A1:A100 -> three rules in destination.

    'preserves the Text values of all rules'
        The copied Text strings must match the originals (order-independent).

-- rule outside SourceRange is not copied --------------------------------

    A rule whose address has no overlap with SourceRange must be silently
    skipped -- no error, no partial copy.

    'copies no rules when the source rule is entirely outside SourceRange'
        Rule on A50:A100 with SourceRange A1:A10 -> destination has zero rules.

-- destination passed as an open ExcelPackage ---------------------------

    When Destination is an ExcelPackage object the caller owns it: the
    function must NOT save or close it. The rules must be visible in the
    in-memory package immediately after the call.

    'the package is still open after the call'
        Accessing $pkg.Workbook must not throw (package was not disposed).

    'the rule is visible in the in-memory package'
        One rule must appear in the worksheet CF collection without a
        round-trip through disk.

-- error handling --------------------------------------------------------

    'throws when the source file does not exist'
        A non-existent source path must produce a terminating error whose
        message contains "not found".

    'throws when SourceSheet names a sheet that does not exist'
        resolveSheet must throw with a message containing "not found" so the
        caller knows which sheet was missing.

    'throws when the source workbook has multiple sheets and SourceSheet is omitted'
        The single-sheet auto-select path must not silently pick the wrong
        sheet; instead it throws with "specify the sheet name".
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseShouldProcessForStateChangingFunctions', '',
    Justification = 'New-TempXlsxPath is a Pester test helper; ShouldProcess is not applicable.')]
param()

InModuleScope M365IncidentResponseTools {

    Describe 'Copy-ConditionalFormatting' {

        BeforeAll {
            # -----------------------------------------------------------------------
            # Helper: create a minimal xlsx at $Path. $ConfigureSheet is a scriptblock
            # that receives the worksheet as its sole argument.
            # -----------------------------------------------------------------------
            function New-TestWorkbook {
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
                    'PSUseShouldProcessForStateChangingFunctions', '',
                    Justification = 'Test-only factory; ShouldProcess is not applicable.')]
                param(
                    [Parameter(Mandatory)]
                    [string]      $Path,

                    [string]      $SheetName = 'Sheet1',

                    [scriptblock] $ConfigureSheet = {}
                )
                $pkg = [OfficeOpenXml.ExcelPackage]::new()
                $ws = $pkg.Workbook.Worksheets.Add($SheetName)
                & $ConfigureSheet $ws
                $pkg.SaveAs([System.IO.FileInfo]$Path)
                $pkg.Dispose()
            }

            # -----------------------------------------------------------------------
            # Helper: returns a temp .xlsx path (file not yet created).
            # -----------------------------------------------------------------------
            function New-TempXlsxPath {
                $dir = [System.IO.Path]::GetTempPath()
                $name = [System.Guid]::NewGuid().ToString() + '.xlsx'
                Join-Path -Path $dir -ChildPath $name
            }
            # -----------------------------------------------------------------------
            # Standard source: one ContainsText rule on A1:A100 with StopIfTrue.
            $script:StdSrcPath = New-TempXlsxPath
            New-TestWorkbook -Path $script:StdSrcPath -ConfigureSheet {
                param($ws)
                $addr = [OfficeOpenXml.ExcelAddress]::new('A1:A100')
                $r = $ws.ConditionalFormatting.AddContainsText($addr)
                $r.Text = 'vpn'
                $r.StopIfTrue = $true
            }
        }

        AfterAll {
            Remove-Item -LiteralPath $script:StdSrcPath -ErrorAction SilentlyContinue
        }

        # -------------------------------------------------------------------
        Context 'single ContainsText rule, path -> path' {

            BeforeAll {
                $script:SingleDstPath = New-TempXlsxPath
                New-TestWorkbook -Path $script:SingleDstPath

                $CfParams = @{
                    Source           = $script:StdSrcPath
                    SourceRange      = 'A1:A100'
                    Destination      = $script:SingleDstPath
                    DestinationRange = 'A1'
                }
                Copy-ConditionalFormatting @CfParams

                $pkg = Open-ExcelPackage -Path $script:SingleDstPath
                $script:SingleRules = @($pkg.Workbook.Worksheets[1].ConditionalFormatting)
                Close-ExcelPackage -ExcelPackage $pkg -NoSave
            }

            AfterAll {
                Remove-Item -LiteralPath $script:SingleDstPath -ErrorAction SilentlyContinue
            }

            It 'copies exactly one rule' {
                $script:SingleRules.Count | Should -Be 1
            }

            It 'preserves the rule type' {
                $script:SingleRules[0].Type.ToString() | Should -Be 'ContainsText'
            }

            It 'preserves the condition text' {
                $script:SingleRules[0].Text | Should -Be 'vpn'
            }

            It 'preserves StopIfTrue' {
                $script:SingleRules[0].StopIfTrue | Should -BeTrue
            }
        }

        # -------------------------------------------------------------------
        Context 'range clipping' {

            BeforeAll {
                $script:ClipDstPath = New-TempXlsxPath
                New-TestWorkbook -Path $script:ClipDstPath

                # Source rule covers A1:A100 but SourceRange only includes A1:A50.
                $CfParams = @{
                    Source           = $script:StdSrcPath
                    SourceRange      = 'A1:A50'
                    Destination      = $script:ClipDstPath
                    DestinationRange = 'A1'
                }
                Copy-ConditionalFormatting @CfParams

                $pkg = Open-ExcelPackage -Path $script:ClipDstPath
                $script:ClipRule = @($pkg.Workbook.Worksheets[1].ConditionalFormatting)[0]
                Close-ExcelPackage -ExcelPackage $pkg -NoSave
            }

            AfterAll {
                Remove-Item -LiteralPath $script:ClipDstPath -ErrorAction SilentlyContinue
            }

            It 'clips the destination address end row to 50' {
                $script:ClipRule.Address.End.Row | Should -Be 50
            }

            It 'preserves start row at 1' {
                $script:ClipRule.Address.Start.Row | Should -Be 1
            }
        }

        # -------------------------------------------------------------------
        Context 'column offset' {

            BeforeAll {
                $script:OffsetDstPath = New-TempXlsxPath
                New-TestWorkbook -Path $script:OffsetDstPath

                # DestinationRange starts at C1: two-column offset to the right.
                # -WarningAction SilentlyContinue suppresses the expected "offset" warning
                # so it doesn't leak to the test console output.
                $CfParams = @{
                    Source           = $script:StdSrcPath
                    SourceRange      = 'A1:A100'
                    Destination      = $script:OffsetDstPath
                    DestinationRange = 'C1'
                }
                Copy-ConditionalFormatting @CfParams -WarningAction SilentlyContinue

                $pkg = Open-ExcelPackage -Path $script:OffsetDstPath
                $script:OffsetRule = @($pkg.Workbook.Worksheets[1].ConditionalFormatting)[0]
                Close-ExcelPackage -ExcelPackage $pkg -NoSave
            }

            AfterAll {
                Remove-Item -LiteralPath $script:OffsetDstPath -ErrorAction SilentlyContinue
            }

            It 'places the rule on column C (index 3)' {
                $script:OffsetRule.Address.Start.Column | Should -Be 3
            }

            It 'retains the row range after offset' {
                $script:OffsetRule.Address.Start.Row | Should -Be 1
                $script:OffsetRule.Address.End.Row | Should -Be 100
            }
        }

        # -------------------------------------------------------------------
        Context 'multiple rules' {

            BeforeAll {
                $script:MultiSrcPath = New-TempXlsxPath
                $script:MultiDstPath = New-TempXlsxPath

                New-TestWorkbook -Path $script:MultiSrcPath -ConfigureSheet {
                    param($ws)
                    $addr = [OfficeOpenXml.ExcelAddress]::new('A1:A100')
                    foreach ($text in 'vpn', 'tor', 'proxy') {
                        $r = $ws.ConditionalFormatting.AddContainsText($addr)
                        $r.Text = $text
                    }
                }
                New-TestWorkbook -Path $script:MultiDstPath

                $CfParams = @{
                    Source           = $script:MultiSrcPath
                    SourceRange      = 'A1:A100'
                    Destination      = $script:MultiDstPath
                    DestinationRange = 'A1'
                }
                Copy-ConditionalFormatting @CfParams

                $pkg = Open-ExcelPackage -Path $script:MultiDstPath
                $script:MultiRules = @($pkg.Workbook.Worksheets[1].ConditionalFormatting)
                Close-ExcelPackage -ExcelPackage $pkg -NoSave
            }

            AfterAll {
                Remove-Item -LiteralPath $script:MultiSrcPath -ErrorAction SilentlyContinue
                Remove-Item -LiteralPath $script:MultiDstPath -ErrorAction SilentlyContinue
            }

            It 'copies all three rules' {
                $script:MultiRules.Count | Should -Be 3
            }

            It 'preserves the Text values of all rules' {
                $texts = $script:MultiRules | ForEach-Object Text | Sort-Object
                $texts | Should -Be @('proxy', 'tor', 'vpn')
            }
        }

        # -------------------------------------------------------------------
        Context 'rule outside SourceRange is not copied' {

            BeforeAll {
                $script:OobSrcPath = New-TempXlsxPath
                $script:OobDstPath = New-TempXlsxPath

                # Rule lives entirely on A50:A100 -- outside SourceRange A1:A10.
                New-TestWorkbook -Path $script:OobSrcPath -ConfigureSheet {
                    param($ws)
                    $addr = [OfficeOpenXml.ExcelAddress]::new('A50:A100')
                    $r = $ws.ConditionalFormatting.AddContainsText($addr)
                    $r.Text = 'out-of-range'
                }
                New-TestWorkbook -Path $script:OobDstPath

                $CfParams = @{
                    Source           = $script:OobSrcPath
                    SourceRange      = 'A1:A10'
                    Destination      = $script:OobDstPath
                    DestinationRange = 'A1'
                }
                Copy-ConditionalFormatting @CfParams

                $pkg = Open-ExcelPackage -Path $script:OobDstPath
                $script:OobRules = @($pkg.Workbook.Worksheets[1].ConditionalFormatting)
                Close-ExcelPackage -ExcelPackage $pkg -NoSave
            }

            AfterAll {
                Remove-Item -LiteralPath $script:OobSrcPath -ErrorAction SilentlyContinue
                Remove-Item -LiteralPath $script:OobDstPath -ErrorAction SilentlyContinue
            }

            It 'copies no rules when the source rule is entirely outside SourceRange' {
                $script:OobRules.Count | Should -Be 0
            }
        }

        # -------------------------------------------------------------------
        Context 'destination passed as an open ExcelPackage' {

            BeforeAll {
                $script:PkgDstPath = New-TempXlsxPath
                New-TestWorkbook -Path $script:PkgDstPath

                $script:OpenPkg = Open-ExcelPackage -Path $script:PkgDstPath

                $CfParams = @{
                    Source           = $script:StdSrcPath
                    SourceRange      = 'A1:A100'
                    Destination      = $script:OpenPkg
                    DestinationRange = 'A1'
                }
                Copy-ConditionalFormatting @CfParams
            }

            AfterAll {
                if ($script:OpenPkg) {
                    Close-ExcelPackage -ExcelPackage $script:OpenPkg -NoSave
                }
                Remove-Item -LiteralPath $script:PkgDstPath -ErrorAction SilentlyContinue
            }

            It 'the package is still open after the call (not closed by the function)' {
                { $script:OpenPkg.Workbook | Out-Null } | Should -Not -Throw
            }

            It 'the rule is visible in the in-memory package without a disk round-trip' {
                $rules = @($script:OpenPkg.Workbook.Worksheets[1].ConditionalFormatting)
                $rules.Count | Should -Be 1
            }
        }

        # -------------------------------------------------------------------
        Context 'error handling' {

            BeforeAll {
                # Reusable empty destination for error tests (throws should prevent any writes).
                $script:ErrDstPath = New-TempXlsxPath
                New-TestWorkbook -Path $script:ErrDstPath
            }

            AfterAll {
                Remove-Item -LiteralPath $script:ErrDstPath -ErrorAction SilentlyContinue
            }

            It 'throws when the source file does not exist' {
                {
                    $CfParams = @{
                        Source           = 'C:\IRT_test_nonexistent_xyz.xlsx'
                        SourceRange      = 'A1:A10'
                        Destination      = $script:ErrDstPath
                        DestinationRange = 'A1'
                    }
                    Copy-ConditionalFormatting @CfParams
                } | Should -Throw '*not found*'
            }

            It 'throws when SourceSheet names a sheet that does not exist' {
                {
                    $CfParams = @{
                        Source           = $script:StdSrcPath
                        SourceSheet      = 'NoSuchSheet'
                        SourceRange      = 'A1:A10'
                        Destination      = $script:ErrDstPath
                        DestinationRange = 'A1'
                    }
                    Copy-ConditionalFormatting @CfParams
                } | Should -Throw '*not found*'
            }

            It 'throws when the source has multiple sheets and SourceSheet is omitted' {
                $multiSrc = New-TempXlsxPath
                $pkg = [OfficeOpenXml.ExcelPackage]::new()
                $null = $pkg.Workbook.Worksheets.Add('Sheet1')
                $null = $pkg.Workbook.Worksheets.Add('Sheet2')
                $pkg.SaveAs([System.IO.FileInfo]$multiSrc)
                $pkg.Dispose()

                try {
                    {
                        $CfParams = @{
                            Source           = $multiSrc
                            SourceRange      = 'A1:A10'
                            Destination      = $script:ErrDstPath
                            DestinationRange = 'A1'
                        }
                        Copy-ConditionalFormatting @CfParams
                    } | Should -Throw '*specify the sheet name*'
                }
                finally {
                    Remove-Item -LiteralPath $multiSrc -ErrorAction SilentlyContinue
                }
            }
        }

        # -------------------------------------------------------------------
        Context 'fill style copy (PatternType=None upgrade)' {
            <#
                Excel encodes solid CF fills without a patternType attribute, which EPPlus
                reads back as PatternType=None. Copy-ConditionalFormatting must upgrade
                None -> Solid when a fill color is present; otherwise EPPlus omits the fill
                from XML entirely, causing white/missing fills in the output.

                These tests verify that fills survive the copy and save/reload cycle.
            #>

            BeforeAll {
                # Source with PatternType=None + BackgroundColor (simulates Excel-created CF).
                $script:FillSrcPath = New-TempXlsxPath
                New-TestWorkbook -Path $script:FillSrcPath -ConfigureSheet {
                    param($ws)
                    $ws.Cells['A1'].Value = 'test'
                    $r = $ws.ConditionalFormatting.AddContainsText('A1:A100')
                    $r.Text = 'test'
                    # Set BackgroundColor but leave PatternType at default (None).
                    $r.Style.Fill.BackgroundColor.Color = (
                        [System.Drawing.Color]::FromArgb(255, 173, 216, 230))
                }

                # Destination for fill copy.
                $script:FillDstPath = New-TempXlsxPath
                New-TestWorkbook -Path $script:FillDstPath

                $CfParams = @{
                    Source           = $script:FillSrcPath
                    SourceRange      = 'A1:A100'
                    Destination      = $script:FillDstPath
                    DestinationRange = 'A1'
                }
                Copy-ConditionalFormatting @CfParams

                # Reload the destination and verify fill properties.
                $pkg = Open-ExcelPackage -Path $script:FillDstPath
                $script:FillDstRule = @($pkg.Workbook.Worksheets[1].ConditionalFormatting)[0]
                Close-ExcelPackage -ExcelPackage $pkg -NoSave
            }

            AfterAll {
                Remove-Item -LiteralPath $script:FillSrcPath -ErrorAction SilentlyContinue
                Remove-Item -LiteralPath $script:FillDstPath -ErrorAction SilentlyContinue
            }

            It 'upgrades PatternType from None to Solid when BackgroundColor is set' {
                $script:FillDstRule.Style.Fill.PatternType | Should -Be 'Solid'
            }

            It 'copies BackgroundColor.Color correctly' {
                $c = $script:FillDstRule.Style.Fill.BackgroundColor.Color
                $c.A | Should -Be 255
                $c.R | Should -Be 173
                $c.G | Should -Be 216
                $c.B | Should -Be 230
            }

            It 'the fill survives save/reload (EPPlus persists it to XML)' {
                # This is the core regression test: without the None->Solid upgrade,
                # EPPlus omits the fill from XML and it disappears on reload.
                $script:FillDstRule.Style.Fill.PatternType | Should -Not -BeNullOrEmpty
                $script:FillDstRule.Style.Fill.BackgroundColor.Color | Should -Not -BeNullOrEmpty
            }
        }

        # -------------------------------------------------------------------
        Context 'fill style copy (PatternColor)' {
            <#
                Verify that PatternColor (foreground) is also copied correctly when
                present alongside BackgroundColor.
            #>

            BeforeAll {
                $script:PatSrcPath = New-TempXlsxPath
                New-TestWorkbook -Path $script:PatSrcPath -ConfigureSheet {
                    param($ws)
                    $ws.Cells['A1'].Value = 'data'
                    $r = $ws.ConditionalFormatting.AddContainsText('A1:A50')
                    $r.Text = 'data'
                    # Set both PatternColor and BackgroundColor.
                    $r.Style.Fill.PatternColor.Color = (
                        [System.Drawing.Color]::FromArgb(255, 255, 255, 0))
                    $r.Style.Fill.BackgroundColor.Color = (
                        [System.Drawing.Color]::FromArgb(255, 0, 128, 0))
                }

                $script:PatDstPath = New-TempXlsxPath
                New-TestWorkbook -Path $script:PatDstPath

                $CfParams = @{
                    Source           = $script:PatSrcPath
                    SourceRange      = 'A1:A50'
                    Destination      = $script:PatDstPath
                    DestinationRange = 'B1'
                }
                Copy-ConditionalFormatting @CfParams

                $pkg = Open-ExcelPackage -Path $script:PatDstPath
                $script:PatDstRule = @($pkg.Workbook.Worksheets[1].ConditionalFormatting)[0]
                Close-ExcelPackage -ExcelPackage $pkg -NoSave
            }

            AfterAll {
                Remove-Item -LiteralPath $script:PatSrcPath -ErrorAction SilentlyContinue
                Remove-Item -LiteralPath $script:PatDstPath -ErrorAction SilentlyContinue
            }

            It 'copies PatternColor.Color (foreground)' {
                $c = $script:PatDstRule.Style.Fill.PatternColor.Color
                $c.A | Should -Be 255
                $c.R | Should -Be 255
                $c.G | Should -Be 255
                $c.B | Should -Be 0
            }

            It 'copies BackgroundColor.Color alongside PatternColor' {
                $c = $script:PatDstRule.Style.Fill.BackgroundColor.Color
                $c.A | Should -Be 255
                $c.R | Should -Be 0
                $c.G | Should -Be 128
                $c.B | Should -Be 0
            }

            It 'sets PatternType to Solid when colors are present' {
                $script:PatDstRule.Style.Fill.PatternType | Should -Be 'Solid'
            }
        }

        # -------------------------------------------------------------------
        Context 'IpAddressConditionalFormattingTemplate.xlsx integration' {
            <#
                Verify that the real production template (used by Add-IpInfoToSheet)
                works correctly. All nine rules in that template have PatternType=None
                with BackgroundColor set.
            #>

            BeforeAll {
                $templatePath = Join-Path -Path $PSScriptRoot -ChildPath (
                    '..\Data\IpAddressConditionalFormattingTemplate.xlsx')

                if (-not (Test-Path -LiteralPath $templatePath)) {
                    $templatePath = Join-Path -Path $PSScriptRoot -ChildPath (
                        '..\Source\Data\IpAddressConditionalFormattingTemplate.xlsx')
                }

                $script:TemplateExists = Test-Path -LiteralPath $templatePath
                $script:TemplatePath = $templatePath
            }

            It 'the IP formatting template file exists' -Skip:(-not $script:TemplateExists) {
                $script:TemplateExists | Should -BeTrue
            }

            It 'copies template CF rules with fills intact' -Skip:(-not $script:TemplateExists) {
                $tmpDst = New-TempXlsxPath
                New-TestWorkbook -Path $tmpDst

                try {
                    $CfParams = @{
                        Source           = $script:TemplatePath
                        SourceRange      = 'A1:A1048576'
                        Destination      = $tmpDst
                        DestinationRange = 'C1'
                    }
                    Copy-ConditionalFormatting @CfParams

                    $pkg = Open-ExcelPackage -Path $tmpDst
                    $rules = @($pkg.Workbook.Worksheets[1].ConditionalFormatting)
                    Close-ExcelPackage -ExcelPackage $pkg -NoSave

                    # Template has 9 CF rules, all should copy.
                    $rules.Count | Should -Be 9

                    # Every rule should have PatternType=Solid (upgraded from None).
                    $solidCount = ($rules | Where-Object {
                            $_.Style.Fill.PatternType -eq 'Solid'
                        }).Count
                    $solidCount | Should -Be 9

                    # Every rule should have a BackgroundColor.Color set.
                    $colorCount = ($rules | Where-Object {
                            $null -ne $_.Style.Fill.BackgroundColor.Color
                        }).Count
                    $colorCount | Should -Be 9
                }
                finally {
                    Remove-Item -LiteralPath $tmpDst -ErrorAction SilentlyContinue
                }
            }
        }
    }
}
