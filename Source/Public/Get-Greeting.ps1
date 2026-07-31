function Get-Greeting {
    <#
    .SYNOPSIS
        Returns a greeting for the supplied name.

    .DESCRIPTION
        Sample public function demonstrating the conventions in AGENTS.md: one
        function per file, full comment-based help, approved verb, and a Pester
        test in Tests\Pester. Replace it with your module's real functions.

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
        Delete this file once your module has real public functions.

    .LINK
        https://github.com/FIXME/FIXME/blob/main/Docs/PowershellRepoTemplate/Get-Greeting.md
    #>
    [Alias()]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [string] $Name = 'World'
    )

    return "Hello, $($Name)!"
}
