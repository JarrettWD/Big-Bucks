# Big Bucks: the copy of the backups on Dad's computer (Stage 5).
#
# Task Scheduler runs the INSTALLED copy, C:\BigBucksBackup\sync-backup.ps1, never the
# one in the clone (Guard 1, Dad 2026-10-10): nothing that arrives with a pull ever
# runs on this computer by itself. The repo's scripts/sync-backup.ps1 is only offered;
# Dad reviews it and installs it (RUNBOOK, backup setup step 9).
#
# Once a day it:
#   1. pulls the private big-bucks-backups repo into a normal folder (not OneDrive:
#      a sync app can damage a git folder). A pull only copies files: git runs nothing
#      from a repo;
#   2. copies the latest backup into OneDrive, under "latest";
#   3. writes big-bucks-history.bundle into OneDrive: one file holding every day's
#      backup, which git can restore from (git clone big-bucks-history.bundle);
#   4. writes last-sync.txt there: when, which backup, and whether this installed
#      copy matches the repo's (compared by content, which can't be faked).
#
# When something needs a look, it says so in last-sync.txt and shows a Windows
# pop-up, and Task Scheduler's result isn't 0x0:
#   - a newer sync script is in the repo and isn't installed (result 0x3; it still syncs);
#   - the newest backup is more than 2 days old (result 0x3);
#   - the sync failed (result 0x1).
# When all is well: no pop-up, result 0x0.
#
# Run it by hand to check it:
#   powershell -ExecutionPolicy Bypass -File C:\BigBucksBackup\sync-backup.ps1
# -NoPopup writes last-sync.txt without the pop-up (for tests).

param(
  [string]$RepoPath = 'C:\BigBucksBackup\big-bucks-backups',
  [string]$CloudFolder = '',
  [switch]$NoPopup,
  # How long the pop-up waits before closing by itself, so a run never hangs for good.
  [int]$PopupSeconds = 43200
)

$ErrorActionPreference = 'Stop'
$stamp = Get-Date -Format 'yyyy-MM-dd HH:mm'
if (-not $CloudFolder -and $env:OneDrive) { $CloudFolder = Join-Path $env:OneDrive 'Big Bucks backup' }
$statusFile = if ($CloudFolder) { Join-Path $CloudFolder 'last-sync.txt' } else { '(no OneDrive folder)' }

function Write-Status([string]$text) {
  if ($CloudFolder) {
    if (-not (Test-Path $CloudFolder)) { New-Item -ItemType Directory -Force $CloudFolder | Out-Null }
    Set-Content -Path $statusFile -Value $text -Encoding utf8
  }
  Write-Output $text
}

# A built-in Windows pop-up (WScript.Shell, part of Windows): no modules to install.
# It closes by itself after $PopupSeconds, so a run never waits for good.
function Show-Popup([string]$headline) {
  if ($NoPopup) { return }
  try {
    $shell = New-Object -ComObject WScript.Shell
    # 48 = the warning icon; 4096 = keep it in front of other windows.
    [void]$shell.Popup("$headline`r`n`r`nDetails: $statusFile", $PopupSeconds, 'Big Bucks backup copy', 48 + 4096)
  } catch {
    # No desktop to show it on (the task ran while nobody was signed in): last-sync.txt still says it.
  }
}

function Get-TextHash([string]$path) {
  $text = [IO.File]::ReadAllText($path) -replace "`r`n", "`n"
  $sha = [Security.Cryptography.SHA256]::Create()
  return [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($text)))
}

function Invoke-Git([string[]]$GitArgs) {
  # Git writes progress to stderr; only its exit code says whether it worked.
  $ErrorActionPreference = 'Continue'
  $out = & git -C $RepoPath @GitArgs 2>&1
  if ($LASTEXITCODE -ne 0) { throw "git $($GitArgs -join ' ') failed: $out" }
  return $out
}

try {
  if (-not $CloudFolder) { throw 'OneDrive is not set up on this computer. Pass -CloudFolder with the folder to copy into.' }
  if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw 'Git is not installed.' }
  if (-not (Test-Path (Join-Path $RepoPath '.git'))) {
    throw "No clone of big-bucks-backups at $RepoPath (RUNBOOK, backup setup step 9)."
  }
  if ($RepoPath.StartsWith($CloudFolder, [StringComparison]::OrdinalIgnoreCase) -or
      ($env:OneDrive -and $RepoPath.StartsWith($env:OneDrive, [StringComparison]::OrdinalIgnoreCase))) {
    throw 'Keep the clone outside OneDrive (for example C:\BigBucksBackup): OneDrive can damage a git folder.'
  }
  if ($PSCommandPath.StartsWith($RepoPath, [StringComparison]::OrdinalIgnoreCase)) {
    throw "This is the clone's copy, which only waits for review. Task Scheduler must run the installed copy, C:\BigBucksBackup\sync-backup.ps1 (RUNBOOK, backup setup step 9)."
  }

  # 1. The newest backups from GitHub.
  Invoke-Git @('pull', '--ff-only', '--quiet') | Out-Null
  # The newest commit that changed backup/ (other commits, like workflow fixes, aren't backups).
  $latest = (Invoke-Git @('log', '-1', '--format=%cs %s', '--', 'backup')) -join ''
  if (-not $latest) { throw 'The clone has no backup commit yet.' }
  $latestDay = [datetime]::ParseExact($latest.Substring(0, 10), 'yyyy-MM-dd', $null)

  # Is this installed copy the same as the repo's? Compared by content (SHA-256),
  # ignoring line endings, which git on Windows may change on its own.
  $offered = Join-Path $RepoPath 'scripts\sync-backup.ps1'
  $offeredCommit = (Invoke-Git @('log', '-1', '--format=%h of %cs', '--', 'scripts/sync-backup.ps1')) -join ''
  $mine = Get-TextHash $PSCommandPath
  $newer = (Test-Path $offered) -and ((Get-TextHash $offered) -ne $mine)
  $version = if ($newer) { 'installed copy differs from the repo''s' } else { "installed copy matches the repo's ($offeredCommit)" }

  # 2. The latest backup's files. Robocopy codes below 8 mean success.
  $source = Join-Path $RepoPath 'backup'
  if (-not (Test-Path (Join-Path $source 'counts.json'))) { throw "The clone has no backup yet ($source)." }
  New-Item -ItemType Directory -Force $CloudFolder | Out-Null
  & robocopy $source (Join-Path $CloudFolder 'latest') /MIR /R:2 /W:5 /NFL /NDL /NJH /NJS /NP | Out-Null
  if ($LASTEXITCODE -ge 8) { throw "Copying into OneDrive failed (robocopy code $LASTEXITCODE)." }

  # 3. Every day's backup in one file, checked before it replaces yesterday's.
  $bundle = Join-Path $CloudFolder 'big-bucks-history.bundle'
  $newBundle = "$bundle.new"
  Invoke-Git @('bundle', 'create', $newBundle, '--all') | Out-Null
  Invoke-Git @('bundle', 'verify', '--quiet', $newBundle) | Out-Null
  Move-Item -Force $newBundle $bundle

  # 4. Done, with anything that needs a look first.
  $warnings = @()
  if ($newer) {
    $warnings += "A newer sync script is in the repo ($offeredCommit). It has NOT been installed. Review it on GitHub (big-bucks-backups, scripts/sync-backup.ps1, History), then install it (RUNBOOK, backup setup step 9)."
  }
  if (((Get-Date).Date - $latestDay).TotalDays -gt 2) {
    $warnings += 'The newest backup is more than 2 days old. Check the Backup workflow in big-bucks-backups on GitHub (RUNBOOK, "A backup failed").'
  }
  $line = "Synced $stamp. Newest backup: $latest. Script: $version."
  if ($warnings.Count -gt 0) {
    Write-Status ((@("NEEDS A LOOK. $line") + $warnings) -join "`r`n")
    Show-Popup ($warnings -join "`r`n`r`n")
    exit 3
  }
  Write-Status $line
  exit 0
}
catch {
  $why = $_.Exception.Message
  Write-Status "Sync FAILED $stamp`r`n$why"
  Show-Popup "The backup copy on this computer failed:`r`n$why"
  exit 1
}
