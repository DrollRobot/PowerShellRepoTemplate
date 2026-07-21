<#
.SYNOPSIS
    Pester tests for Scripts\Find-ScriptCommand.ps1.

.DESCRIPTION
    Dot-sources the script to load Find-ScriptCommand -- a pure, AST-based
    function with no top-level execution, so no child-process isolation is
    needed. NotLive; no tag.
#>

BeforeAll {
    $SutParams = @{
        Path      = $PSScriptRoot
        ChildPath = '..\..\Scripts\Find-ScriptCommand.ps1'
    }
    . (Resolve-Path (Join-Path @SutParams)).Path
}

Describe 'Find-ScriptCommand' -Tag 'unit', 'functional' {

    Context '-Text input' {
        It 'returns the unique, sorted command names invoked' {
            $Result = Find-ScriptCommand -Text 'Get-MgUser | Where-Object Enabled'
            $Result | Should -Be @('Get-MgUser', 'Where-Object')
        }

        It 'de-duplicates repeated invocations of the same command' {
            $Result = Find-ScriptCommand -Text 'Get-B; Get-A; Get-B'
            $Result | Should -Be @('Get-A', 'Get-B')
        }

        It 'returns nothing for text with no command invocations' {
            $Result = Find-ScriptCommand -Text '$x = 1 + 2'
            $Result | Should -BeNullOrEmpty
        }
    }

    Context '-Path input' {
        It 'parses a file and returns the same result -Text would for equivalent content' {
            $ScratchParams = @{
                Path      = [System.IO.Path]::GetTempPath()
                ChildPath = [System.IO.Path]::GetRandomFileName() + '.ps1'
            }
            $ScratchFile = Join-Path @ScratchParams
            Set-Content -LiteralPath $ScratchFile -Value 'Get-MgUser | Where-Object Enabled'
            try {
                $Result = Find-ScriptCommand -Path $ScratchFile
                $Result | Should -Be @('Get-MgUser', 'Where-Object')
            }
            finally {
                Remove-Item -LiteralPath $ScratchFile -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'dynamic invocations' {
        It 'skips a call through a variable with no static command name' {
            $Result = Find-ScriptCommand -Text '$cmd = "Get-Process"; & $cmd'
            $Result | Should -BeNullOrEmpty
        }

        It 'still finds a static command alongside a skipped dynamic one' {
            $Result = Find-ScriptCommand -Text '$cmd = "Get-Process"; & $cmd; Get-Item .'
            $Result | Should -Be @('Get-Item')
        }
    }

    Context '-ExcludeLocalFunctions' {
        It 'includes locally defined functions by default' {
            $Text = 'function Get-Local { 1 }; Get-Local; Get-Other'
            $Result = Find-ScriptCommand -Text $Text
            $Result | Should -Be @('Get-Local', 'Get-Other')
        }

        It 'omits a locally defined function when -ExcludeLocalFunctions is set' {
            $Text = 'function Get-Local { 1 }; Get-Local; Get-Other'
            $Result = Find-ScriptCommand -Text $Text -ExcludeLocalFunctions
            $Result | Should -Be @('Get-Other')
        }

        It 'omits a nested helper function defined inside another function' {
            $Text = 'function Outer { function Inner { Get-Nested }; Inner }'
            $Result = Find-ScriptCommand -Text $Text -ExcludeLocalFunctions
            $Result | Should -Be @('Get-Nested')
        }
    }
}
