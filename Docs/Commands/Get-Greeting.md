---
external help file: PowershellRepoTemplate-help.xml
Module Name: PowershellRepoTemplate
online version:
schema: 2.0.0
---

# Get-Greeting

## SYNOPSIS
Returns a greeting for the supplied name.

## SYNTAX

```
Get-Greeting [[-Name] <String>] [-ProgressAction <ActionPreference>] [<CommonParameters>]
```

## DESCRIPTION
Sample public function demonstrating the conventions in AGENTS.md: one
function per file, full comment-based help, approved verb, and a Pester
test in Tests\Pester.
Replace it with your module's real functions.

## EXAMPLES

### EXAMPLE 1
```
Get-Greeting
```

Returns 'Hello, World!'.

### EXAMPLE 2
```
Get-Greeting -Name 'PowerShell'
```

Returns 'Hello, PowerShell!'.

## PARAMETERS

### -Name
The name to greet.
Defaults to 'World'.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: 1
Default value: World
Accept pipeline input: False
Accept wildcard characters: False
```

### -ProgressAction
{{ Fill ProgressAction Description }}

```yaml
Type: ActionPreference
Parameter Sets: (All)
Aliases: proga

Required: False
Position: Named
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### CommonParameters
This cmdlet supports the common parameters: -Debug, -ErrorAction, -ErrorVariable, -InformationAction, -InformationVariable, -OutVariable, -OutBuffer, -PipelineVariable, -Verbose, -WarningAction, and -WarningVariable. For more information, see [about_CommonParameters](http://go.microsoft.com/fwlink/?LinkID=113216).

## INPUTS

## OUTPUTS

### System.String. The greeting text.
## NOTES
Delete this file once your module has real public functions.

## RELATED LINKS
