<#
.SYNOPSIS
    Offline Pester tests for Resolve-EnvParameter.

.DESCRIPTION
    Exercises the fallback resolution a command relies on when a deployment
    platform injects parameter values as env_<ParameterName> variables instead
    of passing arguments: precedence (a bound parameter always wins, then the
    configured scopes in order), the string-to-boolean conversion for switch
    names, and the rejection of malformed switch values. Global-scope and
    process-environment injection are both real here -- no mocks -- with every
    injected variable removed again after each test.

    The function is dot-sourced from Source\Private\Lib\ rather than reached
    through the built module, so the tests run without a build.
#>
# Template file version, read by Scripts\Compare-Template.ps1, which keeps a
# child repo's copy of this test in sync by version.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseDeclaredVarsMoreThanAssignments', 'ScriptVersion')]
$ScriptVersion = '1.0.0'


Describe 'Resolve-EnvParameter' -Tag 'unit' {

    BeforeAll {
        $SourceRelative = Join-Path -Path '..\..\Source' -ChildPath 'Private\Lib'
        $SourceDir = Join-Path -Path $PSScriptRoot -ChildPath $SourceRelative
        . (Join-Path -Path $SourceDir -ChildPath 'Resolve-EnvParameter.ps1')
    }

    AfterAll {
        Remove-Item -Path 'Function:\Resolve-EnvParameter' -ErrorAction SilentlyContinue
    }

    AfterEach {
        # remove every injection channel a test may have used
        foreach ($Name in @('env_TenantId', 'env_ForceReinstall', 'env_LogPath')) {
            Remove-Variable -Name $Name -Scope Global -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath "Env:\$Name" -ErrorAction SilentlyContinue
        }
    }

    It 'returns an empty hashtable when nothing is injected' {
        $Resolved = Resolve-EnvParameter -BoundParameters @{} -ParameterName 'LogPath'
        $Resolved | Should -BeOfType [hashtable]
        $Resolved.Count | Should -Be 0
    }

    It 'resolves a string parameter from an injected global variable' {
        $global:env_TenantId = 'tenant-from-global'
        $ResolveParams = @{
            BoundParameters = @{}
            ParameterName   = 'TenantId'
        }
        $Resolved = Resolve-EnvParameter @ResolveParams
        $Resolved['TenantId'] | Should -Be 'tenant-from-global'
    }

    It 'resolves a string parameter from the process environment' {
        $env:env_TenantId = 'tenant-from-env'
        $ResolveParams = @{
            BoundParameters = @{}
            ParameterName   = 'TenantId'
        }
        $Resolved = Resolve-EnvParameter @ResolveParams
        $Resolved['TenantId'] | Should -Be 'tenant-from-env'
    }

    It 'prefers the earlier scope when both carry a value' {
        # the default order checks variable scopes before the process
        # environment; assert the behavior, not the default literal
        $global:env_TenantId = 'tenant-from-global'
        $env:env_TenantId = 'tenant-from-env'
        $ResolveParams = @{
            BoundParameters = @{}
            ParameterName   = 'TenantId'
        }
        $Resolved = Resolve-EnvParameter @ResolveParams
        $Resolved['TenantId'] | Should -Be 'tenant-from-global'
    }

    It 'searches the scopes given in Scope, in order' {
        $global:env_TenantId = 'tenant-from-global'
        $env:env_TenantId = 'tenant-from-env'
        $ResolveParams = @{
            BoundParameters = @{}
            ParameterName   = 'TenantId'
            Scope           = 'Environment', 'Global'
        }
        $Resolved = Resolve-EnvParameter @ResolveParams
        $Resolved['TenantId'] | Should -Be 'tenant-from-env'
    }

    It 'ignores a scope that carries no value and falls through to the next' {
        $env:env_TenantId = 'tenant-from-env'
        $ResolveParams = @{
            BoundParameters = @{}
            ParameterName   = 'TenantId'
            Scope           = 'Global', 'Environment'
        }
        $Resolved = Resolve-EnvParameter @ResolveParams
        $Resolved['TenantId'] | Should -Be 'tenant-from-env'
    }

    It 'never resolves a name that was bound directly' {
        $global:env_TenantId = 'tenant-from-global'
        $ResolveParams = @{
            BoundParameters = @{ TenantId = 'tenant-bound' }
            ParameterName   = 'TenantId'
        }
        $Resolved = Resolve-EnvParameter @ResolveParams
        $Resolved.ContainsKey('TenantId') | Should -BeFalse
    }

    It 'ignores a blank injected value' {
        $global:env_TenantId = '   '
        $ResolveParams = @{
            BoundParameters = @{}
            ParameterName   = 'TenantId'
        }
        $Resolved = Resolve-EnvParameter @ResolveParams
        $Resolved.ContainsKey('TenantId') | Should -BeFalse
    }

    It 'converts an injected switch value to a boolean in both directions' {
        $global:env_ForceReinstall = 'true'
        $ResolveParams = @{
            BoundParameters = @{}
            SwitchName      = 'ForceReinstall'
        }
        (Resolve-EnvParameter @ResolveParams)['ForceReinstall'] | Should -BeTrue

        $global:env_ForceReinstall = 'false'
        (Resolve-EnvParameter @ResolveParams)['ForceReinstall'] | Should -BeFalse
    }

    It 'accepts switch values case-insensitively' {
        $global:env_ForceReinstall = 'TRUE'
        $ResolveParams = @{
            BoundParameters = @{}
            SwitchName      = 'ForceReinstall'
        }
        (Resolve-EnvParameter @ResolveParams)['ForceReinstall'] | Should -BeTrue
    }

    It 'throws on an injected switch value other than true or false' {
        $global:env_ForceReinstall = 'yes'
        $ResolveParams = @{
            BoundParameters = @{}
            SwitchName      = 'ForceReinstall'
        }
        { Resolve-EnvParameter @ResolveParams } |
            Should -Throw -ExpectedMessage "*must be 'true' or 'false'*"
    }

    It 'resolves strings and switches together in one call' {
        $global:env_TenantId = 'tenant-from-global'
        $global:env_ForceReinstall = 'true'
        $ResolveParams = @{
            BoundParameters = @{}
            ParameterName   = 'TenantId', 'LogPath'
            SwitchName      = 'ForceReinstall'
        }
        $Resolved = Resolve-EnvParameter @ResolveParams
        $Resolved['TenantId'] | Should -Be 'tenant-from-global'
        $Resolved['ForceReinstall'] | Should -BeTrue
        $Resolved.ContainsKey('LogPath') | Should -BeFalse
    }
}
