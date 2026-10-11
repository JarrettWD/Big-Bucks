# big-bucks-backups (private)

The daily Big Bucks backup, and the daily health check. **This repo must stay private:** `backup/` holds the girls' names, the ledger and the logins.

The files here (everything except `backup/`) come from `ops/backup-repo/` in the Big-Bucks repo. Change them there first, then copy them over.

## What runs

| Workflow | When | What |
| --- | --- | --- |
| **Health check** | daily, 14:00 UTC (8:00 am Alberta in summer) | Asks production how it is. Fails, so GitHub emails Dad, on any open alert, a job falling behind, a big database, or a backup that stopped. Manual run: tick **Send test alert** to check the email. |
| **Backup** | daily, 14:30 UTC | One snapshot of production into `backup/`, then a commit. Fails on purpose if the export is empty or the ledger (or any append-only table) has fewer rows than yesterday. Also pings the API (the Free plan's keep-alive). |

The backup commits every day, so GitHub never switches these schedules off.

On Dad's computer, Task Scheduler runs `scripts/sync-backup.ps1` from his clone (`C:BigBucksBackupig-bucks-backups`) at 9:30 am. It pulls this repo, then copies the latest backup and `big-bucks-history.bundle` (every day's backup in one file) into OneDrive. A fix pushed here reaches his computer with that pull. Its `last-sync.txt` names the version that ran.

## What's in `backup/`

All from the same moment:

- `schema.sql`: every table, function, rule and permission (pg_dump).
- `data.sql`: every row in `public` and `private` (pg_dump).
- `auth.sql`: the logins a restore needs (users, identities, authenticator factors). Not sessions.
- `csv/`: each table as CSV, to open in Excel or Google Sheets.
- `counts.json`: rows and a checksum per table, which the restore drill checks.
- `balances.csv`: every account's savings, GICs, and fund units and cost, worked out by the database.
- `manifest.json`: when, and with which pg_dump.

Any past day: **Code** → **History** (the clock icon) → pick a day's commit → **Browse files**.

## Supabase's certificate

`supabase-ca.crt` is Supabase's published CA certificate (public, not a secret). Every connection the backup makes checks the database's certificate and name against it (`verify-full`), so nothing can pose as the database. The backup refuses to run without it.

## Settings it needs

**Settings** → **Secrets and variables** → **Actions**:

- Secrets: `SUPABASE_DB_URL` (the read-only `backup_reader` login, session pooler) and `HEALTH_CHECK_KEY`.
- Variables: `SUPABASE_URL` and `SUPABASE_ANON_KEY` (the anon key only).

To restore, or to practise a restore, see the RUNBOOK in the Big-Bucks repo: "Restore drill" and "Rebuilding production from a backup".
