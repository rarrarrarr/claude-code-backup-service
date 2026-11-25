<#
.SYNOPSIS
    Removes the scheduled task. Leaves all backups in place.
#>
$ErrorActionPreference = 'Stop'
Unregister-ScheduledTask -TaskPath '\ClaudeCode\' -TaskName 'Claude Code transcript backup' -Confirm:$false
Write-Host 'Task removed. Backups were not touched.'
