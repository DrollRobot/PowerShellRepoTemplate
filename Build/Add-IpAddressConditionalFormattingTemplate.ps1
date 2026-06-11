<#
.SYNOPSIS
    Applies IP address category formatting rules to the template Excel file.

.DESCRIPTION
    Standalone build script that maintains the conditional formatting rules in
    IpAddressConditionalFormattingTemplate.xlsx. This ensures the template stays
    in sync with the formatting rules used by Add-IpInfoToSheet.

    Run this script whenever the IP address category formatting rules need to be
    updated in the template file. PreBuild.ps1 calls it automatically.

.PARAMETER Path
    Path to the template Excel file.

.PARAMETER ColumnName
    The header name of the column to format.

.PARAMETER ClearExisting
    When specified, removes existing conditional formatting rules before applying new ones.

.NOTES
    Requires the ImportExcel module.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Path,

    [Parameter(Mandatory)]
    [string]$ColumnName,

    [switch]$ClearExisting
)

$ErrorActionPreference = 'Stop'

# Helper function: Convert decimal column index to Excel column letter
function Convert-DecimalToExcelColumn {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline)]
        [ValidateRange(1, [int]::MaxValue)]
        [int] $Number
    )

    process {
        $ColumnLetters = [System.Collections.Generic.List[char]]::new()
        $Current = $Number
        while ( $Current -gt 0 ) {
            [int]$Remainder = ($Current - 1) % 26
            $Letter = [char]([int][char]'A' + $Remainder)
            $ColumnLetters.Insert(0, $Letter)
            $Current = [int][math]::Floor(($Current - 1) / 26)
        }
        return ($ColumnLetters -join '')
    }
}

# Verify file exists
if (-not (Test-Path -LiteralPath $Path)) {
    throw "File not found: $Path"
}

# Open the workbook
$package = Open-ExcelPackage -Path $Path
$wb = $package.Workbook

# Get the worksheet (assume single-sheet template)
if ($wb.Worksheets.Count -eq 1) {
    $Worksheet = $wb.Worksheets[1]
}
else {
    $available = ($wb.Worksheets | ForEach-Object Name) -join ', '
    Close-ExcelPackage -ExcelPackage $package -NoSave
    throw "Expected single-sheet workbook, found $($wb.Worksheets.Count). Available: $available"
}

# Find the column by name
$table = $Worksheet.Tables[0]
if (-not $table) {
    Close-ExcelPackage -ExcelPackage $package -NoSave
    throw "Worksheet '$($Worksheet.Name)' contains no tables."
}

$tableColNames = @($table.Columns | ForEach-Object Name)
$matchedColName = $tableColNames |
    Where-Object { $_ -ieq $ColumnName } |
    Select-Object -First 1

if (-not $matchedColName) {
    $available = $tableColNames -join ', '
    Close-ExcelPackage -ExcelPackage $package -NoSave
    throw "Column '$ColumnName' not found in table. Available columns: $available"
}

$tableColIdx = [array]::IndexOf($tableColNames, $matchedColName)
$col = ($table.Address.Start.Column + $tableColIdx) | Convert-DecimalToExcelColumn
$Address = "${col}:${col}"

# Clear existing rules if requested
if ($ClearExisting) {
    $targetCells = $Worksheet.Cells[$Address]
    $rulesToRemove = @(
        $Worksheet.ConditionalFormatting | Where-Object {
            $ruleCells = $Worksheet.Cells[$_.Address.ToString()]
            $ruleCells.Start.Column -le $targetCells.End.Column -and
            $ruleCells.End.Column -ge $targetCells.Start.Column -and
            $ruleCells.Start.Row -le $targetCells.End.Row -and
            $ruleCells.End.Row -ge $targetCells.Start.Row
        }
    )
    foreach ($rule in $rulesToRemove) {
        $null = $Worksheet.ConditionalFormatting.Remove($rule)
    }
}

# Apply IP address category formatting rules
# microsoft
$CFParams = @{
    Worksheet       = $WorkSheet
    Address         = $Address
    RuleType        = 'ContainsText'
    ConditionValue  = 'microsoft'
    BackgroundColor = 'LightBlue'
    StopIfTrue      = $true
}
Add-ConditionalFormatting @CFParams

# proofpoint
$CFParams = @{
    Worksheet       = $WorkSheet
    Address         = $Address
    RuleType        = 'ContainsText'
    ConditionValue  = 'proofpoint'
    BackgroundColor = [System.Drawing.ColorTranslator]::FromHtml('#59abf8')
    StopIfTrue      = $true
}
Add-ConditionalFormatting @CFParams

# vpn
$CFParams = @{
    Worksheet       = $WorkSheet
    Address         = $Address
    RuleType        = 'ContainsText'
    ConditionValue  = ' vpn'
    BackgroundColor = 'LightPink'
    StopIfTrue      = $true
}
Add-ConditionalFormatting @CFParams

# tor
$CFParams = @{
    Worksheet       = $WorkSheet
    Address         = $Address
    RuleType        = 'ContainsText'
    ConditionValue  = ' tor'
    BackgroundColor = 'LightPink'
    StopIfTrue      = $true
}
Add-ConditionalFormatting @CFParams

# proxy
$CFParams = @{
    Worksheet       = $WorkSheet
    Address         = $Address
    RuleType        = 'ContainsText'
    ConditionValue  = ' proxy'
    BackgroundColor = 'LightPink'
    StopIfTrue      = $true
}
Add-ConditionalFormatting @CFParams

# hosting
$CFParams = @{
    Worksheet       = $WorkSheet
    Address         = $Address
    RuleType        = 'ContainsText'
    ConditionValue  = ' hosting'
    BackgroundColor = [System.Drawing.ColorTranslator]::FromHtml('#FACD90')
    StopIfTrue      = $true
}
Add-ConditionalFormatting @CFParams

# cloud
$CFParams = @{
    Worksheet       = $WorkSheet
    Address         = $Address
    RuleType        = 'ContainsText'
    ConditionValue  = ' cloud'
    BackgroundColor = [System.Drawing.ColorTranslator]::FromHtml('#FACD90')
    StopIfTrue      = $true
}
Add-ConditionalFormatting @CFParams

# datacenter
$CFParams = @{
    Worksheet       = $WorkSheet
    Address         = $Address
    RuleType        = 'ContainsText'
    ConditionValue  = ' datacenter'
    BackgroundColor = [System.Drawing.ColorTranslator]::FromHtml('#FACD90')
    StopIfTrue      = $true
}
Add-ConditionalFormatting @CFParams

# mobile
$CFParams = @{
    Worksheet       = $WorkSheet
    Address         = $Address
    RuleType        = 'ContainsText'
    ConditionValue  = 'mobile'
    BackgroundColor = [System.Drawing.ColorTranslator]::FromHtml('#F2CEEF')
    StopIfTrue      = $true
}
Add-ConditionalFormatting @CFParams

# Save and close
Close-ExcelPackage -ExcelPackage $package
$msg = "Successfully updated IP address conditional formatting in template"
Write-Host $msg -ForegroundColor Green
