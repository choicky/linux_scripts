[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [ValidatePattern('^[0-9a-f]{40}$')][string]$Revision,
    [Parameter(Mandatory=$true)][string[]]$Targets,
    [switch]$ConfigOnly,
    [switch]$Apply
)
# Compatibility entry: one implementation for prompts, result codes and uploads.
& "$PSScriptRoot/Invoke-CaddyMigration.ps1" @PSBoundParameters
