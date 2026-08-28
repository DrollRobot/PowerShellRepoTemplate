<#
.SYNOPSIS
    Offline Pester tests for the ConvertTo-ScriptVariant build helper.

.DESCRIPTION
    Exercises the helper against a fake standalone script shaped like the
    output of ConvertTo-StandaloneScript. Verifies the baked defaults land
    in the param block and reach the wrapped function, that explicit
    arguments still win, that the derived GUID is stable and distinct, and
    that bad inputs fail loudly.
#>

Describe 'ConvertTo-ScriptVariant' -Tag 'unit' {

    BeforeAll {
        $GeneratorRelative = Join-Path -Path '..\..\Build' -ChildPath 'Generators'
        $GeneratorDir = Join-Path -Path $PSScriptRoot -ChildPath $GeneratorRelative
        . (Join-Path -Path $GeneratorDir -ChildPath 'ConvertTo-ScriptVariant.ps1')

        $FixtureRoot = Join-Path -Path $TestDrive -ChildPath 'Fixture'
        $null = New-Item -Path $FixtureRoot -ItemType Directory -Force

        $GenericScript = Join-Path -Path $FixtureRoot -ChildPath 'Install-Thing.ps1'
        Set-Content -Path $GenericScript -Value @(
            '<#PSScriptInfo'
            '.VERSION 1.2.3'
            '.GUID ae3274bc-01bf-4f1f-871e-a8a3e60300a0'
            '.AUTHOR Tester'
            '#>'
            ''
            '<#'
            '.SYNOPSIS'
            '    Fake.'
            '#>'
            '[CmdletBinding()]'
            'param('
            '    [Alias(''Tenant'')]'
            '    [string] $TenantId,'
            ''
            '    [switch] $Flag,'
            ''
            '    [string] $Mode = ''fast'','
            ''
            '    [string] $LogPath'
            ')'
            ''
            '# Stand-in for the inlined module helper: env_<Name> process variables only.'
            'function Resolve-EnvParameter {'
            '    param($BoundParameters, [string[]]$ParameterName)'
            '    $Found = @{}'
            '    foreach ($Name in $ParameterName) {'
            '        if ($BoundParameters.ContainsKey($Name)) { continue }'
            '        $Value = [Environment]::GetEnvironmentVariable("env_$Name")'
            '        if ($Value) { $Found[$Name] = $Value }'
            '    }'
            '    $Found'
            '}'
            ''
            'function Install-Thing {'
            '    param([string]$TenantId, [switch]$Flag, [string]$Mode, [string]$LogPath)'
            '    [pscustomobject]@{'
            '        Tenant = $TenantId'
            '        Flag   = [bool]$Flag'
            '        Mode   = $Mode'
            '        Log    = $LogPath'
            "        Bound  = @(`$PSBoundParameters.Keys | Sort-Object) -join ','"
            '    }'
            '}'
            ''
            'Install-Thing @PSBoundParameters'
        )

        function Invoke-Variant {
            param([hashtable]$Override = @{})
            $Params = @{
                Path        = $GenericScript
                VariantName   = 'acme'
                Defaults    = [ordered]@{
                    TenantId = 'tenant-acme'
                    LogPath         = 'C:\Logs\it''s.log'
                }
                Destination = Join-Path -Path $FixtureRoot -ChildPath 'Out'
                EnvResolver = 'Resolve-EnvParameter'
            }
            foreach ($Key in $Override.Keys) { $Params[$Key] = $Override[$Key] }
            ConvertTo-ScriptVariant @Params
        }
    }

    AfterAll {
        Remove-Item -Path 'Function:\ConvertTo-ScriptVariant' -ErrorAction SilentlyContinue
    }

    Context 'output' {
        BeforeAll {
            $Script:OutPath = Invoke-Variant
            $Script:Text = Get-Content -Path $Script:OutPath -Raw
        }

        It 'writes BaseName-VariantName.ps1 into Destination' {
            $Script:OutPath | Should -BeLike '*\Out\Install-Thing-acme.ps1'
            Test-Path -Path $Script:OutPath | Should -BeTrue
        }

        It 'bakes each default into the param block as a quoted literal' {
            $Script:Text | Should -Match "\[string\] \`$TenantId = 'tenant-acme'"
            $Script:Text | Should -Match "\[string\] \`$LogPath = 'C:\\Logs\\it''s.log'"
        }

        It 'bakes a boolean default as a bare $true or $false literal' {
            $Override = @{ VariantName = 'flag'; Defaults = @{ Flag = $true } }
            $Out = Get-Content -Path (Invoke-Variant $Override) -Raw
            $Out | Should -Match '\[switch\] \$Flag = \$true'
        }

        It 'leaves untouched parameters alone' {
            $Script:Text | Should -Match "\[string\] \`$Mode = 'fast'"
            $Script:Text | Should -Match '\[switch\] \$Flag,'
        }

        It 'passes the baked values to the wrapped function when not supplied' {
            $Result = & $Script:OutPath
            $Result.Tenant | Should -Be 'tenant-acme'
            $Result.Log | Should -Be "C:\Logs\it's.log"
            $Result.Bound | Should -Be 'LogPath,TenantId'
        }

        It 'lets explicit arguments win over baked values' {
            $Result = & $Script:OutPath -TenantId 'override' -Flag
            $Result.Tenant | Should -Be 'override'
            $Result.Log | Should -Be "C:\Logs\it's.log"
            $Result.Flag | Should -BeTrue
        }

        It 'leaves a parameter unbound when an env variable supplies it' {
            $env:env_TenantId = 'from-env'
            try {
                $Result = & $Script:OutPath
            } finally {
                Remove-Item -Path 'Env:\env_TenantId'
            }
            # Unbound here: the wrapped function resolves env_<Name> itself.
            $Result.Bound | Should -Be 'LogPath'
            $Result.Log | Should -Be "C:\Logs\it's.log"
        }

        It 'lets an explicit argument win over an env variable' {
            $env:env_TenantId = 'from-env'
            try {
                $Result = & $Script:OutPath -TenantId 'override'
            } finally {
                Remove-Item -Path 'Env:\env_TenantId'
            }
            $Result.Tenant | Should -Be 'override'
        }

        It 'replaces the GUID with one derived from the original and VariantName' {
            $Guid = [regex]::Match($Script:Text, '(?m)^\.GUID (\S+)\r?$').Groups[1].Value
            $Guid | Should -Not -Be 'ae3274bc-01bf-4f1f-871e-a8a3e60300a0'
            { [guid]::Parse($Guid) } | Should -Not -Throw

            $Again = Get-Content -Path (Invoke-Variant) -Raw
            [regex]::Match($Again, '(?m)^\.GUID (\S+)\r?$').Groups[1].Value |
                Should -Be $Guid

            $Other = Get-Content -Path (Invoke-Variant @{ VariantName = 'beta' }) -Raw
            [regex]::Match($Other, '(?m)^\.GUID (\S+)\r?$').Groups[1].Value |
                Should -Not -Be $Guid
        }

        It 'emits a script that parses' {
            $ParseErrors = $null
            $null = [System.Management.Automation.Language.Parser]::ParseFile(
                $Script:OutPath, [ref]$null, [ref]$ParseErrors)
            @($ParseErrors).Count | Should -Be 0
        }
    }

    Context 'failures' {
        It 'rejects a VariantName with upper-case or other characters' {
            { Invoke-Variant @{ VariantName = 'Acme' } } | Should -Throw
            { Invoke-Variant @{ VariantName = 'ac me' } } | Should -Throw
        }

        It 'emits a Baked defaults region calling the EnvResolver' {
            $Script:Text | Should -Match '(?m)^#region Baked defaults'
            $Script:Text |
                Should -Match '(?m)^\$BakedInjected = Resolve-EnvParameter @BakedInjectedParams'
        }

        It 'rejects a missing script' {
            $Missing = Join-Path -Path $FixtureRoot -ChildPath 'Nope.ps1'
            { Invoke-Variant @{ Path = $Missing } } | Should -Throw '*was not found*'
        }

        It 'rejects an empty Defaults table' {
            { Invoke-Variant @{ Defaults = @{} } } | Should -Throw '*at least one*'
        }

        It 'rejects a default for a parameter the script does not have' {
            { Invoke-Variant @{ Defaults = @{ Missing = 'x' } } } |
                Should -Throw "*no parameter 'Missing'*"
        }

        It 'replaces a default the parameter already has' {
            $Override = @{ VariantName = 'mode'; Defaults = @{ Mode = 'slow' } }
            $Out = Get-Content -Path (Invoke-Variant $Override) -Raw
            $Out | Should -Match "\[string\] \`$Mode = 'slow'"
            $Out | Should -Not -Match "'fast'"
        }

        It 'merges into an existing Baked defaults block instead of adding a second' {
            $First = Invoke-Variant
            $Override = @{ Path = $First; VariantName = 'again'; Defaults = @{ Mode = 'slow' } }
            $Out = Get-Content -Path (Invoke-Variant $Override) -Raw
            ([regex]::Matches($Out, '#region Baked defaults')).Count | Should -Be 1
            $Out | Should -Match "\`$BakedDefaultNames = @\('TenantId', 'LogPath', 'Mode'\)"
            $Result = & (Join-Path -Path $FixtureRoot -ChildPath 'Out\Install-Thing-acme-again.ps1')
            $Result.Bound | Should -Be 'LogPath,Mode,TenantId'
            $Result.Mode | Should -Be 'slow'
        }

        It 'rejects a script without the closing splat invocation' {
            $NoSplat = Join-Path -Path $FixtureRoot -ChildPath 'NoSplat.ps1'
            Set-Content -Path $NoSplat -Value @(
                '<#PSScriptInfo'
                '.GUID ae3274bc-01bf-4f1f-871e-a8a3e60300a0'
                '#>'
                'param([string]$TenantId, [string]$LogPath)'
                'Write-Output $TenantId'
            )
            { Invoke-Variant @{ Path = $NoSplat } } |
                Should -Throw '*closing*@PSBoundParameters*'
        }
    }
}
