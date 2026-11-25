<#
.SYNOPSIS
    Backs up Claude Code session transcripts: an additive "head" mirror plus
    dated, read-only 7-Zip archives (nightly and weekly).

.DESCRIPTION
    1. head:    robocopy the live ~/.claude folders into <BackupRoot>\head.
                Additive only (no /MIR, no /PURGE): sessions that Claude Code
                later deletes (cleanupPeriodDays) stay in head forever.
    2. nightly: compress head into nightly\claude-code-transcripts-<date>.7z,
                test the archive, then mark it read-only.
    3. weekly:  the first successful nightly of each Monday-Sunday week is
                copied to weekly\ (a copy, not a re-compress). Using "first of
                the week" instead of "every Sunday" means a week isn't missed
                when the laptop was off on Sunday.
    4. offsite: optionally copy each new weekly archive to -OffsiteDir.
    5. prune:   optionally delete archives older than the keep settings.
                0 (the default) means keep forever.

    Written for Windows PowerShell 5.1 (always present, and safe for scheduled
    tasks) and also runs under PowerShell 7. Keep this file ASCII-only:
    PowerShell 5.1 misreads UTF-8 files that have no BOM.

.EXAMPLE
    .\Backup-ClaudeTranscripts.ps1
    .\Backup-ClaudeTranscripts.ps1 -NightlyKeepDays 90
#>
[CmdletBinding()]
param(
    # The live Claude Code data folder.
    [string]$SourceRoot = (Join-Path $env:USERPROFILE '.claude'),

    # Where head\, nightly\, weekly\ and logs\ live.
    [string]$BackupRoot = 'D:\_backups\claude-code-transcripts',

    # Delete nightly archives older than this many days. 0 = keep forever.
    [int]$NightlyKeepDays = 0,

    # Delete weekly archives older than this many weeks. 0 = keep forever.
    [int]$WeeklyKeepWeeks = 0,

    # Optional second location (e.g. a Google Drive or OneDrive folder) that
    # receives a copy of each new weekly archive. Empty = off.
    [string]$OffsiteDir = '',

    [string]$SevenZip = 'C:\Program Files\7-Zip\7z.exe',

    # Rebuild today's nightly archive even if it already exists.
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Folders/files under $SourceRoot to back up. Missing ones are skipped.
#   projects      - the session transcripts (*.jsonl, plus subagents\ folders)
#   file-history  - Claude's undo checkpoints for edited files
#   history.jsonl - prompt history (not present on every install/version)
$Folders = @('projects', 'file-history')
$Files   = @('history.jsonl')

$ArchivePrefix = 'claude-code-transcripts'
$HeadDir    = Join-Path $BackupRoot 'head'
$NightlyDir = Join-Path $BackupRoot 'nightly'
$WeeklyDir  = Join-Path $BackupRoot 'weekly'
$LogDir     = Join-Path $BackupRoot 'logs'
$LogFile    = Join-Path $LogDir 'backup.log'
$Today      = Get-Date

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
    Write-Host $line
}

function Invoke-Robocopy {
    # robocopy exit codes are a bit field: 0-7 mean success (with or without
    # files copied); 8 and above mean at least one failure.
    param([string]$From, [string]$To, [string[]]$Extra, [string]$Name)
    $log = Join-Path $LogDir "robocopy-last-$Name.log"
    $rcArgs = @($From, $To) + $Extra + @('/COPY:DAT', '/DCOPY:T', '/XJ', '/R:2', '/W:5', '/NP', "/LOG:$log")
    & robocopy.exe @rcArgs | Out-Null
    $code = $LASTEXITCODE
    if ($code -ge 8) { throw "robocopy $Name failed with exit code $code (see $log)" }
    Write-Log "robocopy $Name ok (exit $code)"
}

function Get-ArchiveDate {
    # Parses the date out of claude-code-transcripts-yyyy-MM-dd.7z
    param([System.IO.FileInfo]$File)
    if ($File.Name -match '(\d{4}-\d{2}-\d{2})\.7z$') {
        return [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd', $null)
    }
    return $null
}

function Remove-OldArchives {
    param([string]$Dir, [datetime]$Cutoff)
    Get-ChildItem -Path $Dir -Filter "$ArchivePrefix-*.7z" -File | ForEach-Object {
        $d = Get-ArchiveDate $_
        if ($d -and $d -lt $Cutoff) {
            $_.IsReadOnly = $false
            Remove-Item -LiteralPath $_.FullName -Force
            Write-Log "pruned $($_.FullName)"
        }
    }
}

foreach ($d in @($HeadDir, $NightlyDir, $WeeklyDir, $LogDir)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d | Out-Null }
}

try {
    Write-Log "backup start (source $SourceRoot)"
    if (-not (Test-Path $SourceRoot)) { throw "source not found: $SourceRoot" }
    if (-not (Test-Path $SevenZip))   { throw "7-Zip not found: $SevenZip" }

    # 1. head: additive mirror. /E copies subfolders; robocopy's default rule
    #    copies a file when its size or timestamp differs, which suits
    #    transcripts that only ever grow.
    foreach ($f in $Folders) {
        $src = Join-Path $SourceRoot $f
        if (Test-Path $src) {
            Invoke-Robocopy -From $src -To (Join-Path $HeadDir $f) -Extra @('/E') -Name $f
        } else {
            Write-Log "skip folder (not present): $src"
        }
    }
    foreach ($f in $Files) {
        if (Test-Path (Join-Path $SourceRoot $f)) {
            Invoke-Robocopy -From $SourceRoot -To $HeadDir -Extra @($f) -Name $f
        }
    }

    # 2. nightly archive. Build to a .partial file and rename on success, so an
    #    interrupted run can never leave a truncated archive that looks valid.
    $stamp   = $Today.ToString('yyyy-MM-dd')
    $name    = "$ArchivePrefix-$stamp.7z"
    $nightly = Join-Path $NightlyDir $name

    if ((Test-Path $nightly) -and -not $Force) {
        Write-Log "nightly already exists, skipping: $nightly"
    } else {
        if (Test-Path $nightly) { (Get-Item $nightly).IsReadOnly = $false; Remove-Item $nightly -Force }
        $partial = "$nightly.partial"
        if (Test-Path $partial) { Remove-Item $partial -Force }

        & $SevenZip a -t7z -mx=9 -bso0 -bsp0 $partial (Join-Path $HeadDir '*')
        if ($LASTEXITCODE -ne 0) { throw "7z create failed with exit code $LASTEXITCODE" }
        & $SevenZip t -bso0 -bsp0 $partial
        if ($LASTEXITCODE -ne 0) { throw "7z test failed with exit code $LASTEXITCODE" }

        Rename-Item -LiteralPath $partial -NewName $name
        (Get-Item $nightly).IsReadOnly = $true
        $mb = [math]::Round((Get-Item $nightly).Length / 1MB, 1)
        Write-Log "nightly created: $nightly ($mb MB)"
    }

    # 3. weekly: copy if no weekly archive exists yet for this Mon-Sun week.
    $weekStart = $Today.Date.AddDays( - (([int]$Today.DayOfWeek + 6) % 7) )
    $haveThisWeek = Get-ChildItem -Path $WeeklyDir -Filter "$ArchivePrefix-*.7z" -File |
        Where-Object { $d = Get-ArchiveDate $_; $d -and $d -ge $weekStart }
    if ((Test-Path $nightly) -and -not $haveThisWeek) {
        $weekly = Join-Path $WeeklyDir $name
        Copy-Item -LiteralPath $nightly -Destination $weekly
        (Get-Item $weekly).IsReadOnly = $true   # Copy-Item keeps it, but be explicit
        Write-Log "weekly created: $weekly"

        # 4. offsite copy of the new weekly archive.
        if ($OffsiteDir) {
            if (Test-Path $OffsiteDir) {
                Copy-Item -LiteralPath $weekly -Destination (Join-Path $OffsiteDir $name) -Force
                Write-Log "offsite copy: $OffsiteDir\$name"
            } else {
                Write-Log "offsite folder not found, skipped: $OffsiteDir" 'WARN'
            }
        }
    }

    # 5. retention (0 = keep forever).
    if ($NightlyKeepDays -gt 0) { Remove-OldArchives $NightlyDir $Today.Date.AddDays(-$NightlyKeepDays) }
    if ($WeeklyKeepWeeks -gt 0) { Remove-OldArchives $WeeklyDir  $Today.Date.AddDays(-7 * $WeeklyKeepWeeks) }

    Write-Log 'backup finished OK'
    exit 0
}
catch {
    Write-Log "backup FAILED: $($_.Exception.Message)" 'ERROR'
    exit 1
}
