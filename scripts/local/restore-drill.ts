// The restore drill (Stage 5): proves a backup really rebuilds Big Bucks.
//
//   npm run restore:drill -- <backup folder>
//
// <backup folder> is the backup/ folder of a backup: your clone of the
// big-bucks-backups repo (C:\BigBucksBackup\big-bucks-backups\backup), or one made on
// this computer by npm run backup:local.
//
// It never connects to production: it reads only the backup's files. It:
//   1. starts a separate, throwaway local Supabase (scripts/local/restore-drill:
//      its own name and ports, so the normal local copy isn't touched);
//   2. loads the backup's schema.sql, auth.sql and data.sql into it, the way a
//      restore into a new project does (RUNBOOK, "Rebuilding production");
//   3. runs after_restore(), which puts back what a dump leaves out;
//   4. compares every table (rows and a checksum of every row), the logins, and
//      every account's balances with what the backup recorded at the time;
//   5. removes the throwaway copy again.
// It prints PASS or FAIL for each table group and each account, and exits 1 on any FAIL.
//
// --keep leaves the throwaway copy running (port 55322) to look around.
// --tamper changes one ledger row after the restore, to prove the drill notices (it must FAIL).

import { execSync, spawnSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  compareRestore,
  parseCsv,
  type BalanceLine,
  type Summary,
} from '../../ops/backup-repo/scripts/guards.ts';
import {
  balances,
  closeSnapshot,
  openSnapshot,
  summarise,
} from '../../ops/backup-repo/scripts/snapshot.ts';

const here = dirname(fileURLToPath(import.meta.url));
const WORKDIR = join(here, 'restore-drill');
const CONTAINER = 'supabase_db_big-bucks-drill';
export const DRILL_DB_URL = 'postgresql://postgres:postgres@127.0.0.1:55322/postgres';

const FILES = ['schema.sql', 'auth.sql', 'data.sql', 'counts.json', 'balances.csv'];

/** Why this folder can't be drilled, or null when it can. */
export function folderProblem(dir: string): string | null {
  const missing = FILES.filter((f) => !existsSync(join(dir, f)));
  if (missing.length)
    return `${dir} isn't a backup folder: it has no ${missing.join(', ')}. Give the backup/ folder of a backup.`;
  if (readFileSync(join(dir, 'data.sql'), 'utf8').includes('\r\n'))
    return 'data.sql has Windows line endings, so git changed it on the way (the repo needs its .gitattributes). Stop and ask.';
  return null;
}

function run(cmd: string, args: string[], what: string, input?: string): string {
  const r = spawnSync(cmd, args, { encoding: 'utf8', input, maxBuffer: 1024 * 1024 * 1024 });
  if (r.status !== 0)
    throw new Error(
      `${what} failed:\n${(r.stderr || r.stdout || r.error?.message || '').trim().slice(-1500)}`,
    );
  return r.stdout;
}

/** The Supabase CLI for the drill copy only (always its own --workdir). */
function supabase(args: string, what: string): void {
  try {
    execSync(`npx supabase ${args} --workdir "${WORKDIR}"`, {
      stdio: ['ignore', 'pipe', 'pipe'],
      encoding: 'utf8',
    });
  } catch (e) {
    const err = e as { stderr?: string; stdout?: string };
    throw new Error(`${what} failed:\n${(err.stderr || err.stdout || '').trim().slice(-1500)}`, {
      cause: e,
    });
  }
}

function psql(args: string[], what: string): string {
  return run(
    'docker',
    [
      'exec',
      CONTAINER,
      'psql',
      '-U',
      'postgres',
      '-d',
      'postgres',
      '-v',
      'ON_ERROR_STOP=1',
      ...args,
    ],
    what,
  );
}

function readBalances(file: string): BalanceLine[] {
  const [header, ...rows] = parseCsv(readFileSync(file, 'utf8'));
  return rows.map(
    (r) => Object.fromEntries(header.map((h, i) => [h, r[i]])) as unknown as BalanceLine,
  );
}

const PRELUDE = `
-- What a new Supabase project doesn't have yet: the backup login (the schema's grants
-- name it) and the two extensions Big Bucks turns on itself.
do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'backup_reader') then
    create role backup_reader nologin bypassrls;
  end if;
end $$;
create extension if not exists pg_cron with schema pg_catalog;
create extension if not exists pg_net with schema extensions;
`;

export async function drill(
  dir: string,
  opts: { keep: boolean; tamper: boolean },
): Promise<boolean> {
  const bad = folderProblem(dir);
  if (bad) throw new Error(bad);
  const backup = JSON.parse(readFileSync(join(dir, 'counts.json'), 'utf8')) as Summary;
  const backupBalances = readBalances(join(dir, 'balances.csv'));

  console.log(
    `Backup taken ${backup.taken_at}. Starting a throwaway local Supabase for the drill…`,
  );
  // Always from empty: any copy left over from an earlier drill is removed first.
  try {
    supabase('stop --no-backup', 'Clearing an earlier drill copy');
  } catch {
    // Nothing was running.
  }
  supabase('start', 'Starting the drill copy');

  try {
    run('docker', ['exec', CONTAINER, 'mkdir', '-p', '/tmp/drill'], 'Preparing the drill copy');
    for (const f of ['schema.sql', 'auth.sql', 'data.sql'])
      run('docker', ['cp', resolve(dir, f), `${CONTAINER}:/tmp/drill/${f}`], `Copying ${f}`);
    run(
      'docker',
      ['exec', '-i', CONTAINER, 'sh', '-c', 'cat > /tmp/drill/prelude.sql'],
      'Copying the prelude',
      PRELUDE,
    );

    console.log('Restoring schema.sql, auth.sql and data.sql (one transaction)…');
    psql(
      [
        '-q',
        '-1',
        '-f',
        '/tmp/drill/prelude.sql',
        '-f',
        '/tmp/drill/schema.sql',
        '-c',
        'set session_replication_role = replica',
        '-f',
        '/tmp/drill/auth.sql',
        '-f',
        '/tmp/drill/data.sql',
      ],
      'The restore',
    );
    const after = psql(
      ['-At', '-F', ': ', '-c', 'select step, result from public.after_restore()'],
      'after_restore()',
    );
    console.log('after_restore():');
    for (const line of after.trim().split('\n')) console.log(`  ${line}`);

    if (opts.tamper) {
      psql(
        [
          '-c',
          `set session_replication_role = replica;
                   update public.transactions set amount_cents = amount_cents + 1
                    where id = (select min(id) from public.transactions)`,
        ],
        'Tampering',
      );
      console.log(
        '(--tamper: one ledger row was changed by 1 cent after the restore. The drill must FAIL.)',
      );
    }

    const snap = await openSnapshot(DRILL_DB_URL);
    let restored: Summary;
    let restoredBalances: BalanceLine[];
    try {
      restored = (await summarise(snap.client, backup)).summary;
      restoredBalances = await balances(snap.client);
    } finally {
      await closeSnapshot(snap);
    }

    const result = compareRestore(backup, restored, backupBalances, restoredBalances);
    console.log('');
    for (const line of result.lines) console.log(line);
    console.log('');
    console.log(result.ok ? 'RESTORE DRILL: PASS' : 'RESTORE DRILL: FAIL');
    return result.ok;
  } finally {
    if (opts.keep)
      console.log(
        '--keep: the drill copy is still running at 127.0.0.1:55322 (npx supabase stop --no-backup --workdir scripts/local/restore-drill).',
      );
    else {
      supabase('stop --no-backup', 'Removing the drill copy');
      console.log('The drill copy is removed.');
    }
  }
}

async function main(): Promise<void> {
  const args = process.argv.slice(2);
  const dir = args.find((a) => !a.startsWith('--'));
  if (!dir) throw new Error('Usage: npm run restore:drill -- <backup folder> [--keep] [--tamper]');
  const ok = await drill(resolve(dir), {
    keep: args.includes('--keep'),
    tamper: args.includes('--tamper'),
  });
  process.exit(ok ? 0 : 1);
}

if (process.argv[1]?.endsWith('restore-drill.ts')) {
  main().catch((e: Error) => {
    console.error(e.message);
    process.exit(1);
  });
}
