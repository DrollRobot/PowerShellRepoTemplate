function global:ConvertTo-StandaloneScript {
    <#
    .SYNOPSIS
        A ModuleBuilder Script Generator that emits a standalone .ps1 with the
        built module inlined as plain script text.

    .DESCRIPTION
        Function-injection counterpart to ConvertTo-InlineModuleScript (Part 2
        of the standalone-script plan). Where that generator embeds the built
        .psm1 in a single-quoted here-string and imports it through
        New-Module and [scriptblock]::Create, this one writes the module
        content directly into the script body as ordinary top-level code:

          * the target function's comment-based help and param block are
            hoisted, so the script exposes the same parameters and help as
            the function it wraps;
          * the entire built .psm1 follows verbatim -- function definitions,
            classes, and top-level initialization code (such as this module's
            Suffix.ps1 statements) run in the script scope in the exact order
            they run at module import; and
          * the script ends by invoking the target function with the script's
            own bound parameters.

        The output contains no here-string wrapper, no [scriptblock]::Create,
        and no New-Module -- the plainest shape available. It is immune to the
        here-string closer collision that forces ConvertTo-InlineModuleScript
        to refuse some modules, and it natively supports PowerShell classes.

        Two module shapes cannot be inlined and fail the build loudly:
          * a top-level using statement is only legal at the start of a
            script, so any found are hoisted above the script's param block
            (spliced out of the body, deduplicated, re-emitted at the top);
          * a top-level Export-ModuleMember call cannot run outside a module.
            ModuleBuilder builds drive exports from the manifest, so a
            compliant build never contains one; if present, the generator
            throws and points at ConvertTo-InlineModuleScript, whose dynamic
            module honors the call.

        The PSScriptInfo header block is written directly with the real module
        version and script GUID, so no Update-ScriptFileInfo call (and no
        PowerShellGet dependency) is involved.

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
                Generator = 'ConvertTo-StandaloneScript'
                Function  = 'Repair-Sysmon'
                GUID      = '350d7c58-6a19-48e6-84f2-63f315fb0f15'
            }
        )

    .OUTPUTS
        None. The generator writes <FunctionName>.ps1 relative to the built
        module manifest and returns nothing. (The TextReplacement OutputType
        below only satisfies Invoke-ScriptGenerator's discovery filter.)
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

        # Hoist the target function's help and param block so the script has
        # the same parameters, attributes, and help as the function it wraps.
        $FunctionAst = $ScriptModule.FindAll({
                param($Node)
                $Node -is [System.Management.Automation.Language.FunctionDefinitionAst]
            }, $true) |
            Where-Object -Property Name -EQ -Value $FunctionName |
            Select-Object -First 1
        if (-not $FunctionAst) {
            throw ("ConvertTo-StandaloneScript: function '$FunctionName' was not found " +
                "in '$Path'.")
        }

        # Export-ModuleMember only runs inside a module; inlined at the top
        # level of a script it throws at run time. ModuleBuilder builds export
        # via the manifest, so a compliant build never contains one. Never
        # emit a script that is broken by design: fail the build and point at
        # the here-string generator, whose dynamic module honors the call.
        $ExportCalls = $ScriptModule.FindAll({
                param($Node)
                $Node -is [System.Management.Automation.Language.CommandAst] -and
                $Node.GetCommandName() -eq 'Export-ModuleMember'
            }, $true) |
            Where-Object {
                $Parent = $_.Parent
                $TopLevel = $true
                while ($Parent) {
                    $IsFunction = $Parent -is
                    [System.Management.Automation.Language.FunctionDefinitionAst]
                    if ($IsFunction) {
                        $TopLevel = $false
                        break
                    }
                    $Parent = $Parent.Parent
                }
                $TopLevel
            }
        if ($ExportCalls) {
            $Message = "ConvertTo-StandaloneScript: the built module '$Path' calls " +
            'Export-ModuleMember at the top level, which cannot run outside a module. ' +
            'Drive exports from the module manifest instead, or use the here-string ' +
            'generator (ConvertTo-InlineModuleScript), whose dynamic module honors the call.'
            throw $Message
        }

        # A using statement is only legal at the start of a script, not in the
        # middle of one. Splice any out of the module body (highest offset
        # first, so earlier offsets stay valid) and re-emit them,
        # deduplicated, ahead of the script's param block.
        $UsingBlock = ''
        $UsingStatements = @()
        $IsScriptBlockAst = $ScriptModule -is
        [System.Management.Automation.Language.ScriptBlockAst]
        if ($IsScriptBlockAst -and $ScriptModule.UsingStatements) {
            $UsingStatements = @($ScriptModule.UsingStatements)
        }
        if ($UsingStatements.Count -gt 0) {
            $Sorted = $UsingStatements |
                Sort-Object -Property { $_.Extent.StartOffset } -Descending
            foreach ($UsingAst in $Sorted) {
                $Start = $UsingAst.Extent.StartOffset
                $Length = $UsingAst.Extent.EndOffset - $Start
                $ModuleContent = $ModuleContent.Remove($Start, $Length)
            }
            $UsingBlock = @($UsingStatements |
                    ForEach-Object { $_.Extent.Text.Trim() } |
                    Select-Object -Unique) -join "`n"
        }

        $ParamBlockAst = $FunctionAst.Body.ParamBlock
        if (-not $ParamBlockAst) {
            throw ("ConvertTo-StandaloneScript: function '$FunctionName' has no param " +
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

        # The module body is emitted untrimmed so the built .psm1 appears in
        # the script byte-for-byte (tests assert containment); its trailing
        # newline separates it from the closing invocation.
        $ScriptParts = @(
            $Header
            if ($UsingBlock) { $UsingBlock }
            ''
            $HelpBlock
            $HoistedParams
            ''
            $ModuleContent
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
            throw ("ConvertTo-StandaloneScript: generated script '$OutputPath' has parse " +
                "errors: $($ParseErrors[0].Message)")
        }
    }
}
