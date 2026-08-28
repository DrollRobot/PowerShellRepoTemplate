# global: so PostBuild.ps1 can call it after Build.ps1 dot-sources this file
# alongside the ModuleBuilder generators. It is not itself a ModuleBuilder
# generator (no [Ast] parameter), so Invoke-ScriptGenerator ignores it.
function global:ConvertTo-ScriptVariant {
    <#
    .SYNOPSIS
        Emits a named variant of a standalone script with parameter values
        baked in.

    .DESCRIPTION
        Takes a standalone script (a param block, a closing
        "<Function> @PSBoundParameters" invocation, and optionally a
        "#region Baked defaults" block as emitted by
        ConvertTo-StandaloneScript) and writes <BaseName>-<VariantName>.ps1
        with the values in Defaults baked into it:

          * each named parameter in the script's param block gets the value
            as its default, replacing any default it already has;
          * the "#region Baked defaults" block ahead of the closing
            invocation is rewritten (or added) to forward every baked
            parameter -- those already in the block plus those in Defaults
            -- unless the caller bound it or, with EnvResolver, an injected
            env_<Name> value exists for it. Precedence per parameter:
            command-line argument, injected env_<Name> value, baked default;
          * the PSScriptInfo GUID is replaced with one derived from the
            source script's GUID and VariantName, so every build of a given
            variant keeps the same identity without colliding with the
            source script or any other variant.

        Every name in Defaults must be a parameter of the script; anything
        else fails the build.

        One standalone script plus a table of per-variant values is the
        usual shape: a build emits the generic script through
        ConvertTo-StandaloneScript, then calls this once per row from
        Build\PostBuild.ps1. What a variant stands for -- a customer, a
        region, a deployment ring -- is the project's business; this
        generator only knows the name and the values.

    .PARAMETER Path
        Path to the standalone script to derive from.

    .PARAMETER VariantName
        Short name for this variant, appended to the script base name and
        mixed into the derived GUID. Lower-case letters, digits, and hyphens
        only.

    .PARAMETER Defaults
        Parameter name to value to bake in. Boolean values are emitted as
        $true/$false (for switch parameters); everything else is emitted as
        a single-quoted string literal, so any characters are safe.

    .PARAMETER Destination
        Directory to write the variant script to. Created if missing.

    .PARAMETER EnvResolver
        Name of a command in the script that the Baked defaults block calls
        to find injected env_<Name> values, so those beat baked defaults.
        It is called as
        <EnvResolver> -BoundParameters $PSBoundParameters -ParameterName <names>
        and must return a dictionary keyed by the parameter names it found
        values for. When omitted, baked defaults yield only to command-line
        arguments.

    .PARAMETER Encoding
        File encoding for the generated script. Defaults to UTF8 with a BOM
        on both Windows PowerShell and PowerShell 7+, matching the
        standalone-script generator.

    .EXAMPLE
        $Params = @{
            Path        = '.\Output\Repair-Sysmon.ps1'
            VariantName = 'acme'
            Defaults    = @{ TenantId = '<id>'; LogPath = 'C:\Logs\a.log' }
            Destination = '.\Output\Variants\acme'
            EnvResolver = 'Resolve-EnvParameter'
        }
        ConvertTo-ScriptVariant @Params

        Writes .\Output\Variants\acme\Repair-Sysmon-acme.ps1.

    .OUTPUTS
        System.String. The full path of the written variant script.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$VariantName,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Defaults,

        [Parameter(Mandatory)]
        [string]$Destination,

        [string]$EnvResolver,

        [ValidateSet('UTF8', 'UTF8Bom', 'UTF8NoBom', 'UTF7', 'ASCII', 'Unicode', 'UTF32')]
        [string]$Encoding = $(
            if ($PSVersionTable.PSEdition -eq 'Core') { 'UTF8Bom' } else { 'UTF8' })
    )

    # -cmatch: ValidatePattern and -match are case-insensitive, and the short
    # name must be lower-case to keep file and package names predictable.
    if ($VariantName -cnotmatch '^[a-z0-9][a-z0-9-]*$') {
        throw ("ConvertTo-ScriptVariant: VariantName '$VariantName' must be lower-case " +
            'letters, digits, and hyphens, starting with a letter or digit.')
    }
    if (-not (Test-Path -Path $Path -PathType Leaf)) {
        throw "ConvertTo-ScriptVariant: script '$Path' was not found."
    }
    if ($Defaults.Count -eq 0) {
        throw 'ConvertTo-ScriptVariant: Defaults must name at least one parameter.'
    }

    $BaseName = [System.IO.Path]::GetFileNameWithoutExtension($Path)
    $OutName = "$BaseName-$VariantName.ps1"
    Write-Host "   Generating variant script $OutName" -ForegroundColor Cyan

    $ParseErrors = $null
    $Ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $Path, [ref]$null, [ref]$ParseErrors)
    if ($ParseErrors) {
        throw ("ConvertTo-ScriptVariant: script '$Path' has parse errors: " +
            "$($ParseErrors[0].Message)")
    }
    $Content = Get-Content -Path $Path -Raw -Encoding UTF8

    # Collect every edit as (offset, length, replacement), then apply
    # highest offset first so earlier offsets stay valid.
    $Edits = [System.Collections.Generic.List[object]]::new()

    # --- Parameter defaults ---------------------------------------------
    $ParamBlock = $Ast.ParamBlock
    if (-not $ParamBlock) {
        throw "ConvertTo-ScriptVariant: script '$Path' has no param block."
    }
    foreach ($Name in $Defaults.Keys) {
        $Parameter = $ParamBlock.Parameters |
            Where-Object { $_.Name.VariablePath.UserPath -eq $Name } |
            Select-Object -First 1
        if (-not $Parameter) {
            throw ("ConvertTo-ScriptVariant: script '$Path' has no parameter " +
                "'$Name' to bake a value into.")
        }
        $Value = $Defaults[$Name]
        $Literal = if ($Value -is [bool]) {
            if ($Value) { '$true' } else { '$false' }
        } else {
            "'" + ("$Value" -replace "'", "''") + "'"
        }
        $EditStart = $Parameter.Name.Extent.EndOffset
        $EditEnd = if ($Parameter.DefaultValue) {
            $Parameter.DefaultValue.Extent.EndOffset
        } else { $EditStart }
        $Edits.Add(@{
                Offset      = $EditStart
                Length      = $EditEnd - $EditStart
                Replacement = " = $Literal"
            })
    }

    # --- Baked defaults block and closing invocation --------------------
    $Invocation = $Ast.EndBlock.Statements |
        Where-Object {
            $_ -is [System.Management.Automation.Language.PipelineAst] -and
            $_.PipelineElements.Count -eq 1 -and
            $_.PipelineElements[0] -is
            [System.Management.Automation.Language.CommandAst] -and
            $_.Extent.Text -match '^\S+ @PSBoundParameters$'
        } |
        Select-Object -Last 1
    if (-not $Invocation) {
        throw ("ConvertTo-ScriptVariant: script '$Path' has no closing " +
            "'<Function> @PSBoundParameters' invocation to rewrite.")
    }
    $FunctionName = $Invocation.PipelineElements[0].GetCommandName()

    # An existing block (from ConvertTo-StandaloneScript) is replaced whole;
    # its names carry over so already-baked defaults keep being forwarded.
    $ReplaceStart = $Invocation.Extent.StartOffset
    $ExistingNames = @()
    $RegionPattern = '(?ms)^#region Baked defaults\r?\n.*?^#endregion\r?\n'
    $Region = [regex]::Match($Content.Substring(0, $ReplaceStart), $RegionPattern)
    if ($Region.Success -and $Region.Index + $Region.Length -eq $ReplaceStart) {
        $ReplaceStart = $Region.Index
        $NameLine = [regex]::Match($Region.Value, '(?m)^\$BakedDefaultNames = @\((.*)\)\r?$')
        $ExistingNames = @([regex]::Matches($NameLine.Groups[1].Value, "'([^']+)'") |
                ForEach-Object { $_.Groups[1].Value })
    }
    $AllNames = @($ExistingNames + @($Defaults.Keys) | Select-Object -Unique)
    $NameList = @($AllNames | ForEach-Object { "'$_'" }) -join ', '
    $ResolveLines = if ($EnvResolver) {
        @(
            '$BakedInjectedParams = @{'
            '    BoundParameters = $PSBoundParameters'
            '    ParameterName   = $BakedDefaultNames'
            '}'
            "`$BakedInjected = $EnvResolver @BakedInjectedParams"
        )
    } else {
        @('$BakedInjected = @{}')
    }
    $NewInvocation = @(
        '#region Baked defaults'
        '# Values set at build time. Each is bound only when the caller passed no'
        '# argument for it and no injected env_<Name> value exists for it, so it'
        '# ranks below both: argument > env > baked.'
        "`$BakedDefaultNames = @($NameList)"
        $ResolveLines
        'foreach ($BakedName in $BakedDefaultNames) {'
        '    if (-not $PSBoundParameters.ContainsKey($BakedName) -and'
        '        -not $BakedInjected.ContainsKey($BakedName)) {'
        '        $PSBoundParameters[$BakedName] = Get-Variable -Name $BakedName -ValueOnly'
        '    }'
        '}'
        '#endregion'
        "$FunctionName @PSBoundParameters"
    ) -join "`n"
    $Edits.Add(@{
            Offset      = $ReplaceStart
            Length      = $Invocation.Extent.EndOffset - $ReplaceStart
            Replacement = $NewInvocation
        })

    # --- Derived GUID -----------------------------------------------------
    $GuidMatch = [regex]::Match($Content, '(?m)^\.GUID (\S+)\r?$')
    if (-not $GuidMatch.Success) {
        throw "ConvertTo-ScriptVariant: script '$Path' has no PSScriptInfo .GUID line."
    }
    $Seed = [System.Text.Encoding]::UTF8.GetBytes(
        "$($GuidMatch.Groups[1].Value)|$VariantName")
    $Md5 = [System.Security.Cryptography.MD5]::Create()
    try {
        $DerivedGuid = [guid]::new($Md5.ComputeHash($Seed))
    } finally {
        $Md5.Dispose()
    }
    $Edits.Add(@{
            Offset      = $GuidMatch.Groups[1].Index
            Length      = $GuidMatch.Groups[1].Length
            Replacement = "$DerivedGuid"
        })

    foreach ($Edit in ($Edits | Sort-Object -Property { $_.Offset } -Descending)) {
        $Content = $Content.Remove($Edit.Offset, $Edit.Length).Insert(
            $Edit.Offset, $Edit.Replacement)
    }

    # --- Write and verify -------------------------------------------------
    if (-not (Test-Path -Path $Destination)) {
        $null = New-Item -Path $Destination -ItemType Directory -Force
    }
    $OutputPath = Join-Path -Path $Destination -ChildPath $OutName
    $SetContentParams = @{
        Path      = $OutputPath
        Value     = $Content
        Encoding  = $Encoding
        NoNewline = $true
    }
    Microsoft.PowerShell.Management\Set-Content @SetContentParams

    $OutParseErrors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile(
        $OutputPath, [ref]$null, [ref]$OutParseErrors)
    if ($OutParseErrors) {
        throw ("ConvertTo-ScriptVariant: generated script '$OutputPath' has parse " +
            "errors: $($OutParseErrors[0].Message)")
    }

    $OutputPath
}
