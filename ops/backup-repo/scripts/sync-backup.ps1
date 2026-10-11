# Big Bucks: the copy of the backups on Dad's computer (Stage 5).
#
# It lives in the big-bucks-backups repo (scripts/), and Task Scheduler runs the copy
# inside Dad's clone (RUNBOOK, backup setup step 9). Each run pulls the clone, so a
# fix pushed to the repo reaches this computer by itself and runs from the next run
# on. last-sync.txt says which version ran.
#
# Once a day it:
#   1. pulls the private big-bucks-backups repo into a normal folder (not OneDrive:
#      a sync app can damage a git folder);
#   2. copies the latest backup into OneDrive, under "latest";
#   3. writes big-bucks-history.bundle into OneDrive: one file holding every day's
#      backup, which git can restore from (git clone big-bucks-history.bundle);
#   4. writes last-sync.txt there, saying when, which backup, and which version of
#      this script.
# It stops with exit code 1, and says why in last-sync.txt, if anything goes wrong.
# Task Scheduler then shows "Last Run Result" 0x1.
#
# Run it by hand to check it:
#   powershell -ExecutionPolicy Bypass -File C:\BigBucksBackup\big-bucks-backups\scripts\sync-backup.ps1
#
# -RepoPath defaults to the clone this script is in; -CloudFolder to OneDrive.

param(
  [string]$RepoPath = '',
  [string]$CloudFolder = ''
)

$ErrorActionPreference = 'Stop'
$stamp = Get-Date -Format 'yyyy-MM-dd HH:mm'
if (-not $RepoPath) { $RepoPath = Split-Path -Parent $PSScriptRoot }
$selfHashBefore = (Get-FileHash -Algorithm SHA256 $PSCommandPath).Hash
if (-not $CloudFolder) {
  if (-not $env:OneDrive) {
    Write-Output 'OneDrive is not set up on this computer. Pass -CloudFolder with the folder to copy into.'
    exit 1
  }
  $CloudFolder = Join-Path $env:OneDrive 'Big Bucks backup'
}

function Write-Status([string]$text) {
  if (-not (Test-Path $CloudFolder)) { New-Item -ItemType Directory -Force $CloudFolder | Out-Null }
  Set-Content -Path (Join-Path $CloudFolder 'last-sync.txt') -Value $text -Encoding utf8
  Write-Output $text
}

function Invoke-Git([string[]]$GitArgs) {
  # Git writes progress to stderr; only its exit code says whether it worked.
  $ErrorActionPreference = 'Continue'
  $out = & git -C $RepoPath @GitArgs 2>&1
  if ($LASTEXITCODE -ne 0) { throw "git $($GitArgs -join ' ') failed: $out" }
  return $out
}

try {
  if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw 'Git is not installed.' }
  if (-not (Test-Path (Join-Path $RepoPath '.git'))) {
    throw "No clone of big-bucks-backups at $RepoPath. Clone it first (RUNBOOK, backup setup step 9)."
  }
  if ($RepoPath.StartsWith($CloudFolder, [StringComparison]::OrdinalIgnoreCase) -or
      ($env:OneDrive -and $RepoPath.StartsWith($env:OneDrive, [StringComparison]::OrdinalIgnoreCase))) {
    throw 'Keep the clone outside OneDrive (for example C:\BigBucksBackup): OneDrive can damage a git folder.'
  }

  # 1. The newest backups from GitHub (and any newer version of this script).
  Invoke-Git @('pull', '--ff-only', '--quiet') | Out-Null
  # The newest commit that changed backup/ (other commits, like workflow fixes, aren't backups).
  $latest = (Invoke-Git @('log', '-1', '--format=%cs %s', '--', 'backup')) -join ''
  if (-not $latest) { throw 'The clone has no backup commit yet.' }
  $latestDay = [datetime]::ParseExact($latest.Substring(0, 10), 'yyyy-MM-dd', $null)

  # Which version of this script ran: its last commit, and whether the pull just
  # brought a newer one (that one runs from the next run on).
  $version = (Invoke-Git @('log', '-1', '--format=%h of %cs', '--', 'scripts/sync-backup.ps1')) -join ''
  if (-not $version) { $version = 'not committed yet' }
  if ((Invoke-Git @('status', '--porcelain', '--', 'scripts/sync-backup.ps1')) -join '') {
    $version += ', with changes not committed'
  }
  if ((Get-FileHash -Algorithm SHA256 $PSCommandPath).Hash -ne $selfHashBefore) {
    $version = "the one before $version (which just arrived and runs from the next run)"
  }

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

  # 4. Done. A backup older than 2 days means the daily Backup workflow has stopped.
  $note = ''
  if (((Get-Date).Date - $latestDay).TotalDays -gt 2) {
    $note = "`r`nNote: the newest backup is more than 2 days old. Check the Backup workflow on GitHub."
  }
  Write-Status "Synced $stamp. Newest backup: $latest. Script: $version.$note"
  exit 0
}
catch {
  Write-Status "Sync FAILED $stamp`r`n$($_.Exception.Message)"
  exit 1
}
