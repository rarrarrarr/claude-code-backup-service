# claude-code-backup-service

Nightly backup of Claude Code session transcripts on Windows, using robocopy,
7-Zip and Task Scheduler. No other dependencies.

Claude Code keeps each session as a `.jsonl` file under
`%USERPROFILE%\.claude\projects\<folder>\`, only on the local machine, and
deletes sessions older than `cleanupPeriodDays` (default 30) when it starts.
This backup keeps them anyway.

## Layout

```text
D:\_backups\claude-code-transcripts\
  head\      additive mirror of the live data (uncompressed)
    projects\       session transcripts
    file-history\   Claude's undo checkpoints
  nightly\   claude-code-transcripts-YYYY-MM-DD.7z  (read-only)
  weekly\    first nightly of each Mon-Sun week     (read-only)
  logs\      backup.log (one line per step), robocopy-last-*.log
```

## What happens each run

1. **head**: `robocopy /E` from `.claude` into `head\`. Additive only, with no
   `/MIR` or `/PURGE`, so sessions that Claude Code deletes stay here.
   Compacting a session doesn't rewrite its file. It appends a
   `compact_boundary` marker and a summary, so nothing is lost there either.
2. **nightly**: compress `head\` (not the live folder, so a session being
   written can't produce a half-written snapshot), test the archive, mark it
   read-only. Built as `.partial` and renamed, so a crashed run never leaves
   a truncated archive behind. If today's archive already exists, it's skipped
   (use `-Force` to rebuild).
3. **weekly**: if there's no weekly archive yet for the current Mon-Sun week,
   copy today's nightly there. A week isn't missed if the laptop was off on
   any given day.
4. **offsite** (optional, `-OffsiteDir`): copy each new weekly archive to
   another folder, e.g. a Google Drive or OneDrive synced folder.
5. **retention**: `-NightlyKeepDays` / `-WeeklyKeepWeeks`, where 0 (the default)
   means keep forever. Each archive holds the *full* history, so they grow
   over time.

## Setup

```powershell
# 1. Try a run by hand (no admin needed):
.\Backup-ClaudeTranscripts.ps1

# 2. Register the nightly task, from an elevated PowerShell:
.\Register-BackupTask.ps1                       # daily 03:00, keep forever
.\Register-BackupTask.ps1 -NightlyKeepDays 90   # example: prune nightlies

# Run now / check status / remove:
Start-ScheduledTask   -TaskPath '\ClaudeCode\' -TaskName 'Claude Code transcript backup'
Get-ScheduledTaskInfo -TaskPath '\ClaudeCode\' -TaskName 'Claude Code transcript backup'
.\Unregister-BackupTask.ps1
```

You can also see the task in Task Scheduler under **Task Scheduler Library >
ClaudeCode**. Re-run `Register-BackupTask.ps1` after changing its parameters.
Changes to `Backup-ClaudeTranscripts.ps1` itself take effect on the next run.

## Task settings and why

| Setting | Why |
| --- | --- |
| Logon type S4U | Runs whether or not you're logged on, with no stored password and no window flashing up. It can't reach network shares, but everything here is local. |
| StartWhenAvailable | It's a laptop. A run missed while it was asleep or off happens when it comes back. |
| WakeToRun | Wakes the laptop from sleep (or hibernate, where the firmware allows it) to run. Windows only honors it where the power plan's "Allow wake timers" is on. On this machine that's on for AC and off for battery, so it wakes when plugged in and never in a bag; StartWhenAvailable covers the rest. It can't start a machine that's shut down. |
| Runs on battery | Same reason. |
| Task history enabled | The History tab reads the `Microsoft-Windows-TaskScheduler/Operational` event log, which Windows ships disabled. It's a machine-wide switch (all tasks), so the register script turns it on rather than this being a per-task setting. |
| 1 hour limit, no overlapping runs | A hung run can't pile up. |
| `powershell.exe` (5.1), not `pwsh` | Always at a fixed path. The Store-installed `pwsh` is an app alias that may not resolve without an interactive logon. |

## Restoring

Everything in `head\` is plain files: copy a session's `.jsonl` back into
`%USERPROFILE%\.claude\projects\<folder>\` to make it show up in that folder's
session history again. For an older state, extract a dated archive with 7-Zip.
