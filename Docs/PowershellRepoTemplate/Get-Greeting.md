---
document type: cmdlet
external help file: PowershellRepoTemplate-Help.xml
HelpUri: https://github.com/FIXME/FIXME/blob/main/Docs/PowershellRepoTemplate/Get-Greeting.md
Locale: en-US
Module Name: PowershellRepoTemplate
ms.date: 07/31/2026
PlatyPS schema version: 2024-05-01
title: Get-Greeting
---

# Get-Greeting

## SYNOPSIS

Returns a greeting for the supplied name.

## SYNTAX

```
Get-Greeting [[-Name] <string>] [<CommonParameters>]
```

## ALIASES

None.

## DESCRIPTION

Sample public function demonstrating the conventions in AGENTS.md: one
function per file, full comment-based help, approved verb, and a Pester
test in Tests\Pester.
Replace it with your module's real functions.

## EXAMPLES

### EXAMPLE 1

```powershell
Get-Greeting
```

Returns 'Hello, World!'.

### EXAMPLE 2

```powershell
Get-Greeting -Name 'PowerShell'
```

Returns 'Hello, PowerShell!'.

## PARAMETERS

### -Name

The name to greet.
Defaults to 'World'.

```yaml
Type: System.String
DefaultValue: World
SupportsWildcards: false
Aliases: []
ParameterSets:
- Name: (All)
  Position: 0
  IsRequired: false
  ValueFromPipeline: false
  ValueFromPipelineByPropertyName: false
  ValueFromRemainingArguments: false
DontShow: false
AcceptedValues: []
HelpMessage: ''
```

### CommonParameters

This cmdlet supports the common parameters: -Debug, -ErrorAction, -ErrorVariable,
-InformationAction, -InformationVariable, -OutBuffer, -OutVariable, -PipelineVariable,
-ProgressAction, -Verbose, -WarningAction, and -WarningVariable. For more information, see
[about_CommonParameters](https://go.microsoft.com/fwlink/?LinkID=113216).

## INPUTS

## OUTPUTS

### System.String

## NOTES

Delete this file once your module has real public functions.


## RELATED LINKS

- [](https://github.com/FIXME/FIXME/blob/main/Docs/PowershellRepoTemplate/Get-Greeting.md)
