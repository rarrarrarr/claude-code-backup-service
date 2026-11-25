# Notes for working on this repo

See README.md for what this does. Things that are easy to get wrong:

- Never add `/MIR` or `/PURGE` to robocopy. The head mirror must only add and
  update files, or sessions that Claude Code prunes would vanish from it.
- robocopy exit codes 0-7 are success, 8+ is failure. Don't treat non-zero
  as failure.
- Keep the `.ps1` files ASCII-only and compatible with Windows PowerShell 5.1:
  the scheduled task runs `powershell.exe`, which misreads UTF-8 files that
  have no BOM, and has no PowerShell 7 syntax (`??`, `?:`, `&&`).
- Archives are read-only on purpose. Clear `IsReadOnly` before deleting one.
- Test by hand with `.\Backup-ClaudeTranscripts.ps1 -BackupRoot <scratch dir>`
  rather than against the real backup folder.
