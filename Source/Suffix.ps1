# ModuleBuilder Notes: Code in this file will be appended to the built .psm1 file.

# Scopes Resolve-EnvParameter searches for injected env_<ParameterName>
# variables, in priority order; the first non-blank value wins. Uncomment and
# edit to override its 'Global', 'Environment' default -- which scope a
# deployment platform injects into varies by platform. 'Environment' means the
# process environment ($env:env_<ParameterName>); any other entry is a scope
# name understood by Get-Variable -Scope.
#
# $envScopeParams = @{
#     Name   = 'EnvParameterScopes'
#     Value  = @('Global', 'Environment')
#     Scope  = 'Script'
#     Option = 'ReadOnly'
#     Force  = $true
# }
# New-Variable @envScopeParams
