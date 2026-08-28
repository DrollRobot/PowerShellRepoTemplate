<#
.SYNOPSIS
    Offline Pester tests for the ConvertTo-StandaloneScript build generator.

.DESCRIPTION
    Runs the generator against a fake built module and verifies the emitted
    script: the function's help and param block are hoisted, the module body
    is inlined verbatim, and Defaults are baked into the param block and
    forwarded to the wrapped function with the documented precedence
    (argument, then EnvResolver-injected value, then baked default).
#>
# Template file version, read by Scripts\Compare-Template.ps1, which keeps a
# child repo's copy of this test in sync by version.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseDeclaredVarsMoreThanAssignments', 'ScriptVersion')]
$ScriptVersion = '1.0.0'


Describe 'ConvertTo-StandaloneScript' -Tag 'unit' {

    BeforeAll {
        $GeneratorRelative = Join-Path -Path '..\..\Build' -ChildPath 'Generators'
        $GeneratorDir = Join-Path -Path $PSScriptRoot -ChildPath $GeneratorRelative
        . (Join-Path -Path $GeneratorDir -ChildPath 'ConvertTo-StandaloneScript.ps1')

        $ModuleDir = Join-Path -Path $TestDrive -ChildPath 'Module'
        $null = New-Item -Path $ModuleDir -ItemType Directory -Force

        $PsmPath = Join-Path -Path $ModuleDir -ChildPath 'FakeModule.psm1'
        Set-Content -Path $PsmPath -Value @(
            '# Stand-in env resolver: env_<Name> process variables only.'
            'function Resolve-Fake {'
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
            '    <#'
            '    .SYNOPSIS'
            '        Fake entry point.'
            '    #>'
            '    [CmdletBinding()]'
            '    param('
            '        [string] $TenantId,'
            ''
            '        [switch] $Flag,'
            ''
            "        [string] `$Mode = 'fast',"
            ''
            '        [string] $LogPath'
            '    )'
            '    [pscustomobject]@{'
            '        Tenant = $TenantId'
            '        Flag   = [bool]$Flag'
            '        Mode   = $Mode'
            '        Log    = $LogPath'
            "        Bound  = @(`$PSBoundParameters.Keys | Sort-Object) -join ','"
            '    }'
            '}'
        )
        Set-Content -Path (Join-Path -Path $ModuleDir -ChildPath 'FakeModule.psd1') -Value @(
            '@{'
            "    RootModule    = 'FakeModule.psm1'"
            "    ModuleVersion = '1.2.3'"
            "    GUID          = '11111111-2222-3333-4444-555555555555'"
            "    Author        = 'Tester'"
            '}'
        )
        $ModuleAst = [System.Management.Automation.Language.Parser]::ParseFile(
            $PsmPath, [ref]$null, [ref]$null)

        function Invoke-Generator {
            param([hashtable]$Override = @{})
            $Params = @{
                ScriptModule = $ModuleAst
                Path         = $PsmPath
                FunctionName = 'Install-Thing'
                Guid         = 'ae3274bc-01bf-4f1f-871e-a8a3e60300a0'
                Destination  = 'Out'
            }
            foreach ($Key in $Override.Keys) { $Params[$Key] = $Override[$Key] }
            ConvertTo-StandaloneScript @Params 3> $null
            Join-Path -Path $ModuleDir -ChildPath "$($Params.Destination)\Install-Thing.ps1"
        }
    }

    AfterAll {
        Remove-Item -Path 'Function:\ConvertTo-StandaloneScript' -ErrorAction SilentlyContinue
    }

    Context 'without Defaults' {
        BeforeAll {
            $Script:Plain = Invoke-Generator @{ Destination = 'Plain' }
            $Script:PlainText = Get-Content -Path $Script:Plain -Raw
        }

        It 'hoists the help and param block and inlines the module' {
            $Script:PlainText | Should -Match '(?m)^\.GUID ae3274bc-01bf-4f1f-871e-a8a3e60300a0'
            $Script:PlainText | Should -Match '(?m)^\s+Fake entry point\.'
            $Script:PlainText.Contains((Get-Content -Path $PsmPath -Raw)) | Should -BeTrue
        }

        It 'ends with a plain splat and no Baked defaults block' {
            $Script:PlainText | Should -Not -Match 'Baked defaults'
            $Script:PlainText.TrimEnd() | Should -BeLike '*Install-Thing @PSBoundParameters'
        }

        It 'forwards only what the caller passed' {
            $Result = & $Script:Plain -TenantId 't'
            $Result.Bound | Should -Be 'TenantId'
            $Result.Log | Should -Be ''
        }
    }

    Context 'with Defaults' {
        BeforeAll {
            $Script:Baked = Invoke-Generator @{
                Destination = 'Baked'
                Defaults    = [ordered]@{
                    LogPath = 'C:\Logs\it''s.log'
                    Mode    = 'slow'
                    Flag    = $true
                }
                EnvResolver = 'Resolve-Fake'
            }
            $Script:BakedText = Get-Content -Path $Script:Baked -Raw
        }

        It 'bakes each default into the param block, replacing an existing one' {
            $Script:BakedText | Should -Match "\[string\] \`$LogPath = 'C:\\Logs\\it''s.log'"
            $Script:BakedText | Should -Match "\[string\] \`$Mode = 'slow'"
            $Script:BakedText | Should -Match '\[switch\] \$Flag = \$true'
            $Script:BakedText | Should -Match '\[string\] \$TenantId,'
        }

        It 'emits a Baked defaults region naming the baked parameters' {
            $Script:BakedText | Should -Match '(?m)^#region Baked defaults'
            $Script:BakedText |
                Should -Match "(?m)^\`$BakedDefaultNames = @\('LogPath', 'Mode', 'Flag'\)"
            $Script:BakedText |
                Should -Match '(?m)^\$BakedInjected = Resolve-Fake @BakedInjectedParams'
        }

        It 'forwards baked values when the caller passed nothing' {
            $Result = & $Script:Baked
            $Result.Log | Should -Be "C:\Logs\it's.log"
            $Result.Mode | Should -Be 'slow'
            $Result.Flag | Should -BeTrue
            $Result.Bound | Should -Be 'Flag,LogPath,Mode'
        }

        It 'lets a command-line argument win' {
            $Result = & $Script:Baked -LogPath 'C:\cli.log'
            $Result.Log | Should -Be 'C:\cli.log'
        }

        It 'leaves a parameter unbound when the EnvResolver reports an injected value' {
            $env:env_LogPath = 'C:\env.log'
            try {
                $Result = & $Script:Baked
            } finally {
                Remove-Item -Path 'Env:\env_LogPath'
            }
            $Result.Bound | Should -Be 'Flag,Mode'
        }

        It 'binds baked values regardless of env when no EnvResolver is given' {
            $NoResolver = Invoke-Generator @{
                Destination = 'NoResolver'
                Defaults    = @{ LogPath = 'C:\baked.log' }
            }
            $env:env_LogPath = 'C:\env.log'
            try {
                $Result = & $NoResolver
            } finally {
                Remove-Item -Path 'Env:\env_LogPath'
            }
            $Result.Log | Should -Be 'C:\baked.log'
        }

        It 'rejects a default for a parameter the function does not have' {
            { Invoke-Generator @{ Destination = 'Bad'; Defaults = @{ Nope = 'x' } } } |
                Should -Throw "*no parameter 'Nope'*"
        }
    }
}
