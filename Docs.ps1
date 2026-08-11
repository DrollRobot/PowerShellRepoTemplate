#Requires -Version 7.5
#Requires -Modules @{ ModuleName = 'Microsoft.PowerShell.PlatyPS'; ModuleVersion = '1.0.3' }

<#
.SYNOPSIS
    Regenerates the markdown command help for all exported functions.

.DESCRIPTION
    Rebuilds every markdown help file under 'Docs\<ModuleName>' from the
    comment-based help in 'Source\', discarding whatever was there. Pages whose
    function no longer exists are removed as part of the rebuild.

    Microsoft.PowerShell.PlatyPS stubs several fields with '{{ ... }}' placeholder
    text that comment-based help has no way to supply, so this script fills them
    from the source before the pages are published:

    - ALIASES: read from the [Alias()] attribute through the function's abstract
      syntax tree. The module populates this field from neither [Alias()] nor the
      module's exported aliases, and the source manifest keeps AliasesToExport
      empty for ModuleBuilder, so the attribute is the only source available.
    - OUTPUTS description: comment-based help has no syntax for one, so the
      placeholder is blanked rather than published.
    - Syntax: the generated syntax item leaves HasCmdletBinding false even when
      the command has it, which drops [<CommonParameters>] from the syntax line.
    - '### __AllParameterSets': PowerShell's internal name for the implicit
      parameter set a command gets when it declares none. Only ever emitted when
      there is exactly one set, so the heading is stripped after export. Commands
      with named parameter sets keep their headings.

    Authoring notes for the comment-based help this reads:

    - Fill in every required help field. New-CommandHelp throws when one is
      missing (.DESCRIPTION, for example), reporting only that
      string.IsNullOrEmpty got invalid arguments.
    - Fence .EXAMPLE code with a powershell code fence. Unlike PlatyPS 0.14, this
      version emits example bodies verbatim, so unfenced code renders as prose.
    - Write .OUTPUTS as a bare type name. Any trailing prose is parsed as part of
      the type name and produces a duplicate OUTPUTS entry.
    - Add .LINK to populate RELATED LINKS and the HelpUri front matter field.

    Must be run from the repo root in a pwsh session where the module is not yet
    imported, or it reloads it.

.EXAMPLE
    .\Docs.ps1

    Rebuilds 'Docs\<ModuleName>' from the functions exported by 'Source\',
    removing any page whose function no longer exists.

.OUTPUTS
    None. Writes markdown files to 'Docs\<ModuleName>' and reports progress.

.NOTES
    2.3.1 - Trim the trailing blank line PlatyPS leaves on pages whose related
        links are the placeholder. The end-of-file-fixer pre-commit hook
        stripped it on every commit, so each docs run produced a diff the hook
        then had to undo.
    2.3.0 - Import the modules declared in RequiredModules.psd1 before the
        module itself. The source manifest declares no RequiredModules
        (Confirm-Dependency.ps1 only checks that dependencies are installed),
        so importing the module loads none of them.
    2.2.1 - Name the real cause of the IsNullOrEmpty failure: help missing a
        required field. The previous wording blamed a section returning a list.
    2.2.0 - Delete 'Docs\<ModuleName>' before generating rather than removing
        orphaned pages after, and report failures as a table instead of one
        long exception message.
    2.1.0 - Report which command New-CommandHelp failed on, and which file it
        came from, instead of surfacing the module's own exception with no
        context. All failures are collected and thrown together at the end.
    2.0.0 - Move from PlatyPS 0.14 to Microsoft.PowerShell.PlatyPS. Pages are
        written to 'Docs\<ModuleName>' instead of 'Docs\Commands', the folder
        the new module creates on its own. Orphaned pages are always removed, so
        -DeleteOrphaned is gone. The 'Log' alias workaround is gone with it: the
        new module is compiled, so it has no internal 'log' function for a module
        alias to shadow.
    1.1.1 - Write docs to 'Docs\Commands' instead of 'docs\commands' for *nix
        compatibility.
    1.1.0 - Import the module from Source\ instead of built module.
    1.0.0 - Found PlaytPS 'Log' alias was conflicting with local alias. Script
        now captures, removes, then restores local alises to prevent conflict.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '')]
[CmdletBinding()]
param()

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseDeclaredVarsMoreThanAssignments', 'ScriptVersion')]
$ScriptVersion = '2.3.1'

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-DeclaredAlias {
    <#
    .SYNOPSIS
        Returns the alias names declared by [Alias()] on a function.

    .DESCRIPTION
        Reads the alias names out of the function's abstract syntax tree. The
        source manifest keeps AliasesToExport empty because ModuleBuilder fills
        it at build time, so the aliases are never exported and are invisible to
        Get-Alias and to PlatyPS when the module is imported from Source\.

    .PARAMETER CommandInfo
        The function to inspect.

    .EXAMPLE
        Get-DeclaredAlias -CommandInfo (Get-Command -Name Get-Greeting)

        Returns 'Greet' when the function declares [Alias('Greet')].

    .OUTPUTS
        System.String. One alias name per declared alias.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.FunctionInfo] $CommandInfo
    )

    $ParamBlock = $CommandInfo.ScriptBlock.Ast.Body.ParamBlock
    if (-not $ParamBlock) { return }

    $AliasType = [System.Management.Automation.AliasAttribute]
    $ParamBlock.Attributes |
        Where-Object { $_.TypeName.GetReflectionType() -eq $AliasType } |
        ForEach-Object { $_.PositionalArguments } |
        ForEach-Object { $_.Value }
}

function Build-CommandMarkdown {
    <#
    .SYNOPSIS
        Generates the markdown help pages for a module.

    .DESCRIPTION
        Builds a CommandHelp object for every exported function, fills the fields
        Microsoft.PowerShell.PlatyPS would otherwise stub with placeholder text,
        exports the markdown, and strips the implicit parameter set heading.

        A command whose help New-CommandHelp cannot read is recorded and skipped
        rather than ending the run, so a single pass names every function that
        needs fixing. Once the loop finishes the recorded failures are printed
        as a table and the run ends with a one-line error.

        Strict mode is disabled for this scope on purpose. New-CommandHelp fails
        under Set-StrictMode -Version 2.0 or later with "The property
        'inputTypes' cannot be found on this object.", and the fault is inside
        the compiled module. Turning it off here keeps the rest of the script
        under -Version Latest.

    .PARAMETER ModuleName
        The name of the imported module to document.

    .PARAMETER OutputFolder
        The folder to export into. PlatyPS creates a subfolder named for the
        module beneath it, so the pages land in '<OutputFolder>\<ModuleName>'.

    .EXAMPLE
        Build-CommandMarkdown -ModuleName 'MyModule' -OutputFolder '.\Docs'

        Writes one markdown page per exported function to '.\Docs\MyModule'.

    .OUTPUTS
        System.IO.FileInfo. One object per generated markdown page.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $ModuleName,

        [Parameter(Mandatory)]
        [string] $OutputFolder
    )

    Set-StrictMode -Off

    $Failures = [System.Collections.Generic.List[object]]::new()

    $Commands = Get-Command -Module $ModuleName -CommandType Function
    # loop files one at a time so it's clear which file fails.
    foreach ($Command in $Commands) {
        try {
            $Help = New-CommandHelp -CommandInfo $Command
        }
        catch {
            # Trim the repo root so the File column stays readable in the table.
            $SourceFile = $Command.ScriptBlock.File
            if (-not $SourceFile) {
                $SourceFile = 'unknown file'
            }
            elseif ($SourceFile.StartsWith($PSScriptRoot)) {
                $SourceFile = $SourceFile.Substring($PSScriptRoot.Length).TrimStart('\', '/')
            }

            # A function whose help lacks a required field makes New-CommandHelp
            # call string.IsNullOrEmpty on a value that is not a string, and the
            # resulting overload-resolution error says nothing about help.
            $Reason = $_.Exception.Message
            if ($Reason -match 'IsNullOrEmpty') {
                $Reason = 'Help is missing a required field, such as .DESCRIPTION.'
            }

            $Failures.Add([PSCustomObject]@{
                    Command = $Command.Name
                    File    = $SourceFile
                    Reason  = $Reason
                })
            continue
        }

        $Aliases = @(Get-DeclaredAlias -CommandInfo $Command)
        $Help.Aliases = if ($Aliases.Count) { $Aliases -join ', ' } else { 'None.' }

        foreach ($Output in $Help.Outputs) {
            if ($Output.Description -match '{{') { $Output.Description = '' }
        }

        foreach ($SyntaxItem in $Help.Syntax) {
            $SyntaxItem.HasCmdletBinding = $Help.HasCmdletBinding
        }

        $ExportParams = @{
            CommandHelp  = $Help
            OutputFolder = $OutputFolder
            Force        = $true
        }
        $Exported = Export-MarkdownCommandHelp @ExportParams

        $Markdown = Get-Content -Path $Exported.FullName -Raw
        $Markdown = $Markdown -replace '(?m)^### __AllParameterSets\r?\n\r?\n', ''
        # PlatyPS ends a page whose related links are the placeholder with a blank
        # line; the end-of-file-fixer pre-commit hook wants exactly one trailing
        # newline. Normalize here so a docs run and the hook do not undo each other.
        $Markdown = $Markdown.TrimEnd() + "`n"
        Set-Content -Path $Exported.FullName -Value $Markdown -NoNewline

        $Exported
    }

    if ($Failures.Count) {
        # Out-Host keeps the formatting objects out of the pipeline, which
        # otherwise returns them alongside the generated files.
        Write-Host ''
        Write-Host "New-CommandHelp failed for $($Failures.Count) command(s):"
        $Failures | Format-Table -Property Command, File, Reason -AutoSize -Wrap | Out-Host

        throw "Doc generation failed for $($Failures.Count) command(s). Read authoring" +
            " notes in Docs.ps1's help."
    }
}

$DocsRoot = Join-Path -Path $PSScriptRoot -ChildPath 'Docs'

# Generate docs from the source tree, not a build: the comment-based help is
# identical (the build only concatenates the same function files), and importing
# source removes any dependency on where a build happens to live. The source
# manifest is the module-name source of truth (exclude ModuleBuilder's Build.psd1),
# matching how Build.ps1 and Tests.ps1 resolve it.
$SourcePath = Join-Path -Path $PSScriptRoot -ChildPath 'Source'
$SrcManifest = Get-ChildItem -Path $SourcePath -Filter '*.psd1' |
    Where-Object Name -ne 'Build.psd1' |
    Select-Object -First 1
if (-not $SrcManifest) { throw "No source manifest found under $($SourcePath)" }
$ModuleName = $SrcManifest.BaseName

# The source manifest declares no RequiredModules (dependencies live in
# RequiredModules.psd1, and Confirm-Dependency.ps1 only checks that they are
# installed), so importing the module loads none of its dependencies. Import
# them here first so the module's commands resolve against them. Entry shapes
# match what Confirm-Dependency.ps1 accepts: a bare name, or a hashtable with
# ModuleName plus optional RequiredVersion / ModuleVersion / MaximumVersion.
$DepsDataPath = Join-Path -Path $SourcePath -ChildPath 'ScriptsToProcess'
$DepsDataPath = Join-Path -Path $DepsDataPath -ChildPath 'RequiredModules.psd1'
if (Test-Path -LiteralPath $DepsDataPath) {
    $DepsData = Import-PowerShellDataFile -Path $DepsDataPath
    $RequiredModules = @()
    if ($DepsData.ContainsKey('RequiredModules')) {
        $RequiredModules = @($DepsData['RequiredModules'])
    }

    foreach ($Entry in $RequiredModules) {
        $ImportParams = @{}
        if ($Entry -is [hashtable]) {
            if (-not $Entry.ContainsKey('ModuleName')) { continue }
            $ImportParams['Name'] = $Entry.ModuleName
            if ($Entry.ContainsKey('RequiredVersion')) {
                $ImportParams['RequiredVersion'] = $Entry.RequiredVersion
            }
            else {
                if ($Entry.ContainsKey('ModuleVersion')) {
                    $ImportParams['MinimumVersion'] = $Entry.ModuleVersion
                }
                if ($Entry.ContainsKey('MaximumVersion')) {
                    $ImportParams['MaximumVersion'] = $Entry.MaximumVersion
                }
            }
        }
        else {
            $ImportParams['Name'] = [string]$Entry
        }
        if (-not $ImportParams['Name']) { continue }

        Import-Module @ImportParams
        Write-Host "Imported dependency $($ImportParams['Name'])"
    }
}

Import-Module $SrcManifest.FullName -Force
Import-Module -Name 'Microsoft.PowerShell.PlatyPS'

# Export-MarkdownCommandHelp writes into a subfolder named for the module, so the
# pages land in Docs\<ModuleName> and the top-level Docs\ pages are untouched.
$DocsPath = Join-Path -Path $DocsRoot -ChildPath $ModuleName

# Clear the folder first so pages for functions that no longer exist go with it.
# Every page is rebuilt from source on every run, so nothing here is worth
# keeping, and the folder is generated output tracked in git: if a run fails part
# way, the missing pages show up as deletions and are restored with git checkout.
if (Test-Path -Path $DocsPath) {
    Remove-Item -Path $DocsPath -Recurse -Force
    Write-Host "Cleared $($DocsPath)"
}

$Generated = @(Build-CommandMarkdown -ModuleName $ModuleName -OutputFolder $DocsRoot)
Write-Host "Generated $($Generated.Count) doc file(s)."

Write-Host "Docs updated at $($DocsPath)"
