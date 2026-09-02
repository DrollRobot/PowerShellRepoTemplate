# ModuleBuilder Notes: Code in this file will be appended to the built .psm1 file.

# Configure internal logging first: Set-LogConfig owns the logging defaults and
# must run before anything in this module logs (there is no lazy fallback).
# Every value below restates a default; edit it to change that setting
# module-wide. The event source and id are pinned here rather than derived at
# run time so a standalone script built from this module -- where no module
# name exists to derive a default source from -- writes the same events as the
# module does. File logging stays off until a command turns it on
# (Set-LogConfig -LogPath); the event log target stays off until a command arms
# it (Set-LogConfig -EventLogEnabled $true). Scripts\TemplateSetup\
# Remove-WriteLog.ps1 drops this block when [Features].WriteLog is declined.
$logConfigParams = @{
    MemoryMaxEntries     = 1000
    EventLogSource       = 'PowershellRepoTemplate'
    EventLogId           = 1000
    EventLogMinimumLevel = 'Information'
}
Set-LogConfig @logConfigParams

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
