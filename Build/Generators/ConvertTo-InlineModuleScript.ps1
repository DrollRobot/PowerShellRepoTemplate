function global:ConvertTo-InlineModuleScript {
    <#
    .SYNOPSIS
        A ModuleBuilder Script Generator that emits a standalone .ps1 with the
        module embedded verbatim (no base64 or compression).

    .DESCRIPTION
        Drop-in replacement for ModuleBuilder's built-in ConvertTo-Script
        generator. That generator embeds the compiled module as a base64,
        Deflate-compressed payload expanded through
        [System.Reflection.Assembly]::Load-style plumbing, which Windows
        Defender's obfuscation heuristics quarantine. This module is pure
        PowerShell, so no binary embedding is needed at all.

        Instead, this generator writes a <FunctionName>.ps1 next to the built
        module that:
          * carries the target function's comment-based help and param block,
            so the script exposes the same parameters and help as the function;
          * embeds the built .psm1 content verbatim inside a single-quoted
            here-string;
          * imports that content as a dynamic module via New-Module; and
          * ends by invoking the target function with the script's own bound
            parameters.

        The PSScriptInfo header block is written directly with the real module
        version and script GUID, so no Update-ScriptFileInfo call (and no
        PowerShellGet dependency) is involved.

        A single-quoted here-string terminates on any line that begins with
        the two characters '@. If the built module ever contains such a line
        (i.e. it uses a single-quoted here-string of its own), the wrapper
        would be silently truncated -- so this generator scans for that
        pattern first and fails the build loudly, directing the operator to
        the function-injection fallback generator described in the handoff
        plan (Part 2, ConvertTo-StandaloneScript).

        Contract notes (ModuleBuilder 3.2.x): Invoke-ScriptGenerator discovers
        generators with Get-Command, requiring an [Ast]-typed parameter and an
        OutputType of TextReplacement. The TextReplacement class is internal
        to the ModuleBuilder module, so the OutputType below uses the string
        form. Like the built-in ConvertTo-Script, this generator only creates
        a new file; it returns no TextReplacement objects. The function is
        declared global: so that ModuleBuilder's module scope (which chains to
        the global scope) can discover it after Build.ps1 dot-sources this
        file.

    .PARAMETER ScriptModule
        The AST of the built script module, bound from the ParseResults object
        that Invoke-ScriptGenerator pipes to every generator.

    .PARAMETER FunctionName
        Name of the public function the standalone script wraps and invokes.
        Supplied as the 'Function' key of the generator entry in Build.psd1.

    .PARAMETER Guid
        The script GUID stamped into the PSScriptInfo header block. Pass a
        fixed GUID (the 'GUID' key in Build.psd1) so every build of the script
        keeps the same identity. Defaults to a new GUID.

    .PARAMETER Path
        Path to the built .psm1, bound from the piped ParseResults object. The
        module manifest is expected next to it, and the generated script is
        written relative to that directory (see Destination).

    .PARAMETER Destination
        Directory to write the generated script to, resolved relative to the
        built module directory (the manifest's folder). Defaults to '.' (the
        module directory itself, matching the built-in generator). Set it to
        '..' in Build.psd1 to emit the script into the output root, above the
        module folder. Created if it does not exist.

    .PARAMETER Encoding
        File encoding for the generated script. Defaults to UTF8 with a BOM on
        both Windows PowerShell and PowerShell 7+ (where the default name is
        UTF8Bom), matching the built-in generator.

    .EXAMPLE
        # Registered in Source/Build.psd1; Build-Module invokes it at the end
        # of every build:
        Generators = @(
            @{
                Generator = 'ConvertTo-InlineModuleScript'
                Function  = 'Repair-Sysmon'
                GUID      = '350d7c58-6a19-48e6-84f2-63f315fb0f15'
            }
        )

    .OUTPUTS
        None. The generator writes <FunctionName>.ps1 beside the built module
        manifest and returns nothing. (The TextReplacement OutputType below
        only satisfies Invoke-ScriptGenerator's generator-discovery filter.)
    #>
    [CmdletBinding()]
    [OutputType('TextReplacement')]
    param(
        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [Alias('Ast')]
        [System.Management.Automation.Language.Ast]$ScriptModule,

        [Parameter(Mandatory)]
        [string]$FunctionName,

        [guid]$Guid = [guid]::NewGuid(),

        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [string]$Path,

        [string]$Destination = '.',

        [ValidateSet('UTF8', 'UTF8Bom', 'UTF8NoBom', 'UTF7', 'ASCII', 'Unicode', 'UTF32')]
        [string]$Encoding = $(
            if ($PSVersionTable.PSEdition -eq 'Core') { 'UTF8Bom' } else { 'UTF8' })
    )

    process {
        Write-Host "   Generating standalone script $FunctionName.ps1" -ForegroundColor Cyan

        $GetContentParams = @{
            Path     = $Path
            Raw      = $true
            Encoding = 'UTF8'
        }
        $ModuleContent = Get-Content @GetContentParams

        # A single-quoted here-string ends on any line beginning with '@ -- if
        # the module itself contains one, the wrapper below would be truncated
        # at that line. Never emit a silently broken script: fail the build
        # and point at the fallback.
        if ($ModuleContent -match "(?m)^'@") {
            $Message = "ConvertTo-InlineModuleScript: the built module '$Path' contains a " +
            "line beginning with '@ (a single-quoted here-string closer). Embedding it in " +
            'the standalone wrapper''s here-string would truncate the script. Use the ' +
            'function-injection fallback generator instead (Part 2, ' +
            'ConvertTo-StandaloneScript, in standalone-script-generator-plan.md).'
            throw $Message
        }

        # Hoist the target function's help and param block so the script has
        # the same parameters, attributes, and help as the function it wraps.
        $FunctionAst = $ScriptModule.FindAll({
                param($Node)
                $Node -is [System.Management.Automation.Language.FunctionDefinitionAst]
            }, $true) |
            Where-Object -Property Name -EQ -Value $FunctionName |
            Select-Object -First 1
        if (-not $FunctionAst) {
            throw ("ConvertTo-InlineModuleScript: function '$FunctionName' was not found " +
                "in '$Path'.")
        }

        $ParamBlockAst = $FunctionAst.Body.ParamBlock
        if (-not $ParamBlockAst) {
            throw ("ConvertTo-InlineModuleScript: function '$FunctionName' has no param " +
                'block to hoist into the standalone script.')
        }
        $HoistedParams = @(
            @($ParamBlockAst.Attributes.Extent.Text) + $ParamBlockAst.Extent.Text
        ) -join "`n"

        # GetCommentBlock() RECONSTRUCTS the help (doubled blank lines,
        # uppercased parameter names, lost indentation), so prefer lifting the
        # original comment block out of the token stream verbatim; the
        # reconstruction is only the fallback (e.g. line-comment-style help).
        $HelpInfo = $FunctionAst.GetHelpContent()
        $HelpBlock = if ($HelpInfo) { $HelpInfo.GetCommentBlock() } else { '' }
        if ($HelpInfo) {
            $HelpTokens = $null
            $HelpParseErrors = $null
            $null = [System.Management.Automation.Language.Parser]::ParseFile(
                $Path, [ref]$HelpTokens, [ref]$HelpParseErrors)
            $HelpToken = $HelpTokens |
                Where-Object {
                    $_.Kind -eq [System.Management.Automation.Language.TokenKind]::Comment -and
                    $_.Extent.StartOffset -ge $FunctionAst.Extent.StartOffset -and
                    $_.Extent.EndOffset -le $FunctionAst.Extent.EndOffset -and
                    $_.Text.StartsWith('<#') -and
                    $_.Text -match '(?im)^\s*\.SYNOPSIS'
                } |
                Select-Object -First 1
            if ($HelpToken) {
                $HelpBlock = $HelpToken.Text
            }
        }

        # Real metadata written directly (no Update-ScriptFileInfo): version
        # from the built manifest, identity from the fixed GUID in Build.psd1.
        $ModuleManifest = [System.IO.Path]::ChangeExtension($Path, '.psd1')
        $Manifest = Import-PowerShellDataFile -Path $ModuleManifest
        $ModuleName = [System.IO.Path]::GetFileNameWithoutExtension($ModuleManifest)
        $Author = if ($Manifest.ContainsKey('Author')) { $Manifest['Author'] } else { '' }
        $Company = if ($Manifest.ContainsKey('CompanyName')) {
            $Manifest['CompanyName']
        } else { '' }
        $Copyright = if ($Manifest.ContainsKey('Copyright')) {
            $Manifest['Copyright']
        } else { '' }

        $Header = @(
            '<#PSScriptInfo'
            ".VERSION $($Manifest['ModuleVersion'])"
            ".GUID $Guid"
            ".AUTHOR $Author"
            ".COMPANYNAME $Company"
            ".COPYRIGHT $Copyright"
            '#>'
        ) -join "`n"

        # Build the '@ delimiters by concatenation so this generator's own
        # source never contains a line beginning with the closer sequence.
        $OpenHereString = '$ModuleContent = @' + "'"
        $CloseHereString = "'" + '@'
        $ImportLine = "New-Module -Name $ModuleName -ScriptBlock " +
        '([scriptblock]::Create($ModuleContent)) |'

        $ModuleDirectory = Split-Path -Path $ModuleManifest -Parent
        $OutputDirectory = [System.IO.Path]::GetFullPath(
            (Join-Path -Path $ModuleDirectory -ChildPath $Destination))
        if (-not (Test-Path -Path $OutputDirectory)) {
            $null = New-Item -Path $OutputDirectory -ItemType Directory
        }
        $OutputPath = Join-Path -Path $OutputDirectory -ChildPath "$FunctionName.ps1"
        if (Test-Path -Path $OutputPath) {
            Write-Warning "Overwriting existing script $OutputPath"
        }

        $ScriptParts = @(
            $Header
            ''
            $HelpBlock
            $HoistedParams
            ''
            $OpenHereString
            $ModuleContent
            $CloseHereString
            ''
            $ImportLine
            '    Import-Module -Scope Global'
            ''
            "$FunctionName @PSBoundParameters"
        )

        $SetContentParams = @{
            Path     = $OutputPath
            Value    = $ScriptParts
            Encoding = $Encoding
        }
        Microsoft.PowerShell.Management\Set-Content @SetContentParams

        # Last line of defense: a generated script that does not parse must
        # fail the build here, not on the first host that runs it.
        $ParseErrors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile(
            $OutputPath, [ref]$null, [ref]$ParseErrors)
        if ($ParseErrors) {
            throw ("ConvertTo-InlineModuleScript: generated script '$OutputPath' has parse " +
                "errors: $($ParseErrors[0].Message)")
        }
    }
}
