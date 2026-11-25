<#
.SYNOPSIS
    Creates (or updates) the scheduled task that runs Backup-ClaudeTranscripts.ps1
    every night. Safe to re-run: it replaces the existing task.

.DESCRIPTION
    - Runs as you, with logon type S4U ("run whether user is logged on or not",
      without storing your password). No window flashes up. S4U has no access
      to network shares, which is fine because every path here is local.
    - StartWhenAvailable: if the laptop was asleep or off at the scheduled
      time, the task runs as soon as the machine is back.
    - WakeToRun: wakes the machine from sleep for the run. Windows only
      honors this where the power plan's "Allow wake timers" is enabled
      (check with: powercfg /q SCHEME_CURRENT SUB_SLEEP RTCWAKE). It never
      starts a machine that is shut down.
    - Runs on battery, one instance at a time, killed after 1 hour.
    - Turns on Task Scheduler history (the TaskScheduler/Operational event
      log). That is a machine-wide switch, off by default in Windows, and
      covers every task, not just this one.
    - Calls the backup script where it sits in this repo, so committed changes
      take effect on the next run.

    Creating an S4U task needs an elevated (Run as administrator) PowerShell.

.EXAMPLE
    # From an elevated PowerShell, in this folder:
    .\Register-BackupTask.ps1
    .\Register-BackupTask.ps1 -At 02:30 -NightlyKeepDays 90
#>
[CmdletBinding()]
param(
    [string]$At = '03:00',
    [string]$BackupRoot = 'D:\_backups\claude-code-transcripts',
    [int]$NightlyKeepDays = 0,
    [int]$WeeklyKeepWeeks = 0,
    [string]$OffsiteDir = ''
)

$ErrorActionPreference = 'Stop'

$TaskPath = '\ClaudeCode\'
$TaskName = 'Claude Code transcript backup'

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).
    IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { throw 'Run this from an elevated PowerShell (Run as administrator); S4U tasks need it.' }

$script = Join-Path $PSScriptRoot 'Backup-ClaudeTranscripts.ps1'
if (-not (Test-Path $script)) { throw "backup script not found: $script" }

# Resolve the source now, as the registering user, rather than relying on the
# task's environment at run time.
$source = Join-Path $env:USERPROFILE '.claude'

$argList = @(
    '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
    '-File', "`"$script`"",
    '-SourceRoot', "`"$source`"",
    '-BackupRoot', "`"$BackupRoot`"",
    '-NightlyKeepDays', $NightlyKeepDays,
    '-WeeklyKeepWeeks', $WeeklyKeepWeeks
)
if ($OffsiteDir) { $argList += @('-OffsiteDir', "`"$OffsiteDir`"") }

# Windows PowerShell 5.1 (powershell.exe) is used on purpose: it is always at
# this path, unlike PowerShell 7 installed from the Store, whose app alias
# may not resolve for a task running without an interactive logon.
$action = New-ScheduledTaskAction `
    -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
    -Argument ($argList -join ' ') `
    -WorkingDirectory $PSScriptRoot

$trigger = New-ScheduledTaskTrigger -Daily -At $At

$settings = New-ScheduledTaskSettingsSet `
    -StartWhenAvailable `
    -WakeToRun `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Hours 1) `
    -MultipleInstances IgnoreNew

$principal = New-ScheduledTaskPrincipal `
    -UserId "$env:USERDOMAIN\$env:USERNAME" `
    -LogonType S4U `
    -RunLevel Limited

Register-ScheduledTask `
    -TaskPath $TaskPath -TaskName $TaskName `
    -Action $action -Trigger $trigger -Settings $settings -Principal $principal `
    -Description "Backs up $source to $BackupRoot (repo: $PSScriptRoot)" `
    -Force | Out-Null

# Task Scheduler's "History" tab reads this event log, which Windows ships
# disabled. Same as "Enable All Tasks History" in the Task Scheduler GUI.
$historyLog = 'Microsoft-Windows-TaskScheduler/Operational'
$log = Get-WinEvent -ListLog $historyLog
if (-not $log.IsEnabled) {
    & wevtutil.exe set-log $historyLog /enabled:true
    if ($LASTEXITCODE -ne 0) { throw "could not enable $historyLog (wevtutil exit $LASTEXITCODE)" }
    Write-Host 'Enabled Task Scheduler history (machine-wide).'
}

Write-Host "Registered '$TaskPath$TaskName', daily at $At."
Write-Host "Run it now with:  Start-ScheduledTask -TaskPath '$TaskPath' -TaskName '$TaskName'"
Write-Host "Check it with:    Get-ScheduledTaskInfo -TaskPath '$TaskPath' -TaskName '$TaskName'"
