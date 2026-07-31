# Comment-based help format for Microsoft.PowerShell.PlatyPS

Microsoft.PowerShell.PlatyPS reads three help sections differently than PlatyPS 0.14.
Comment-based help written for 0.14 needs the edits below. Applies to every exported
function; private functions are not documented.

## .EXAMPLE -- fence the code

0.14 added the code fence for you. The new version emits the example body verbatim, so
unfenced code renders as a paragraph instead of a code block.

Wrong:

```powershell
.EXAMPLE
    Get-Greeting -Name 'PowerShell'

    Returns 'Hello, PowerShell!'.
```

Right:

````powershell
.EXAMPLE
    ```powershell
    Get-Greeting -Name 'PowerShell'
    ```

    Returns 'Hello, PowerShell!'.
````

Fence the code only. Leave the explanation below it unfenced.

Side effect to accept: `Get-Help <Command> -Examples` prints the backticks literally in
the console.

## .OUTPUTS -- bare type name only

The whole body is parsed as a type name. Trailing prose becomes part of that name, and
since `[OutputType()]` contributes its own entry, the page gets two OUTPUTS headings.

Wrong:

```powershell
.OUTPUTS
    System.String. The greeting text.
```

Right:

```powershell
.OUTPUTS
    System.String
```

One type per line for multiple types:

```powershell
.OUTPUTS
    System.String
    System.Int32
```

There is no way to describe an output. Comment-based help has no syntax for it, so put
nothing there beyond type names.

## .LINK -- required

Omitting it leaves `{{ Fill in the related links here }}` on the page and an empty
`HelpUri` field. One URI per `.LINK` block, no link text:

```powershell
.LINK
    https://github.com/<owner>/<repo>/blob/main/Docs/<ModuleName>/Get-Greeting.md

.LINK
    https://learn.microsoft.com/powershell/scripting/developer/help/
```

## Unchanged sections

`.SYNOPSIS`, `.DESCRIPTION`, `.PARAMETER`, and `.NOTES` are read the same as before.
Leave them alone.

## Complete example

````powershell
function Get-Greeting {
    <#
    .SYNOPSIS
        Returns a greeting for the supplied name.

    .DESCRIPTION
        Longer description of what the function does.

    .PARAMETER Name
        The name to greet. Defaults to 'World'.

    .EXAMPLE
        ```powershell
        Get-Greeting
        ```

        Returns 'Hello, World!'.

    .EXAMPLE
        ```powershell
        Get-Greeting -Name 'PowerShell'
        ```

        Returns 'Hello, PowerShell!'.

    .OUTPUTS
        System.String

    .NOTES
        Any additional notes.

    .LINK
        https://github.com/<owner>/<repo>/blob/main/Docs/<ModuleName>/Get-Greeting.md
    #>
````

## Finding help that still needs converting

```powershell
Select-String -Path Source\Public\*.ps1 -Pattern '\.EXAMPLE' -Context 0, 3
Select-String -Path Source\Public\*.ps1 -Pattern '(?m)^\s*\.OUTPUTS' -Context 0, 1
Get-ChildItem -Path Source\Public\*.ps1 |
    Where-Object { (Get-Content -Path $_.FullName -Raw) -notmatch '\.LINK' }
```

After converting, regenerate and confirm no placeholder text is left:

```powershell
Select-String -Path Docs\<ModuleName>\*.md -Pattern '\{\{'
```

Any `{{ ... }}` hit points back to a help section that still needs one of the edits
above.
