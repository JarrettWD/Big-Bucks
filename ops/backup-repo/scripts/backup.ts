// The daily backup (Stage 5). The Backup workflow runs:
//
//   node scripts/backup.ts take .      one snapshot of production into backup/
//   (git commit and push)
//   node scripts/backup.ts record .    tells the database the backup is safe on GitHub
//
// Both read the connection string from BACKUP_DB_URL: the read-only backup_reader
// login, through Supabase's session pooler (GitHub secret SUPABASE_DB_URL), with the
// server's certificate checked against supabase-ca.crt (verify-full). Nothing
// here can change a cent: that login can only read, and record its own result.
//
// take writes, all from the same moment:
//   backup/schema.sql    every table, function, rule and permission (pg_dump)
//   backup/data.sql      every row in public and private (pg_dump), except the photos
//   backup/auth.sql      the logins a restore needs (users, identities, MFA factors)
//   backup/csv/*.csv     each table as CSV, easy to open; the photos are restored from
//                        theirs (OWN_FILE_TABLES), which changes only when a photo does
//   backup/counts.json   rows and a checksum per table, for the restore drill
//   backup/balances.csv  every account's balances, worked out by the database
//   backup/manifest.json when, and with which pg_dump
// It fails on purpose, leaving yesterday's backup in place, when the export is empty
// or an append-only table (the ledger, rates, settings, …) has fewer rows than in the
// last backup (except right after a pre-launch reset).

import { spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, renameSync, rmSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import pg from 'pg';
import {
  afterReset,
  backupProblems,
  restorableSchema,
  countsForRecord,
  OWN_FILE_TABLES,
  toCsv,
  type BalanceLine,
  type Summary,
} from './guards.ts';
import {
  authSql,
  balances,
  closeSnapshot,
  openSnapshot,
  summarise,
  tableRows,
} from './snapshot.ts';

const PG_IMAGE = process.env.PG_DUMP_IMAGE ?? 'postgres:17-alpine';

/**
 * Supabase's published CA certificate (Database settings → SSL configuration →
 * Download certificate), kept in the backup repo's root as supabase-ca.crt. It's
 * public. Every connection to Supabase checks the server's certificate against it
 * and its name against the host (verify-full), so nobody can pose as the database.
 */
export const DEFAULT_CA_FILE =
  process.env.SUPABASE_CA_FILE ?? fileURLToPath(new URL('../supabase-ca.crt', import.meta.url));

/** The CA certificate's text, or why it can't be used. */
export function readCa(file: string): string {
  if (!existsSync(file))
    throw new Error(
      `Supabase's CA certificate is missing (${file}). Download it (RUNBOOK, "Backup setup", step 4) and keep it in the backup repo as supabase-ca.crt.`,
    );
  const pem = readFileSync(file, 'utf8');
  if (!pem.includes('-----BEGIN CERTIFICATE-----'))
    throw new Error(`${file} isn't a certificate (no BEGIN CERTIFICATE line).`);
  return pem;
}

export function isLocalHost(host: string): boolean {
  return ['127.0.0.1', 'localhost', '[::1]', '::1', 'host.docker.internal'].includes(host);
}

/**
 * The connection for anything but this computer: TLS, checked against Supabase's CA
 * certificate, with the server's name checked too (Node does that by default when
 * rejectUnauthorized is on: the same as verify-full).
 */
export function clientConfig(url: string, caFile = DEFAULT_CA_FILE): pg.ClientConfig {
  const u = new URL(url);
  u.searchParams.delete('sslmode');
  if (isLocalHost(u.hostname)) return { connectionString: u.toString() };
  return { connectionString: u.toString(), ssl: { ca: readCa(caFile), rejectUnauthorized: true } };
}

/** pg_dump, from the official Postgres 17 image, with the password passed in the environment, never on the command line. */
function pgDump(url: string, args: string[], outFile: string): string {
  const u = new URL(url);
  const windows = process.platform === 'win32';
  const local = isLocalHost(u.hostname);
  const ca = local ? null : resolve(DEFAULT_CA_FILE);
  if (ca) readCa(ca);
  const env = {
    ...process.env,
    PGHOST: local && windows ? 'host.docker.internal' : u.hostname,
    PGPORT: u.port || '5432',
    PGUSER: decodeURIComponent(u.username),
    PGPASSWORD: decodeURIComponent(u.password),
    PGDATABASE: u.pathname.replace(/^\//, '') || 'postgres',
    PGSSLMODE: local ? 'disable' : 'verify-full',
    ...(ca ? { PGSSLROOTCERT: '/certs/supabase-ca.crt' } : {}),
  };
  const docker = [
    'run',
    '--rm',
    ...(windows ? [] : ['--network', 'host']),
    ...['PGHOST', 'PGPORT', 'PGUSER', 'PGPASSWORD', 'PGDATABASE', 'PGSSLMODE']
      .concat(ca ? ['PGSSLROOTCERT'] : [])
      .flatMap((k) => ['-e', k]),
    ...(ca ? ['-v', `${ca}:/certs/supabase-ca.crt:ro`] : []),
    PG_IMAGE,
  ];
  const r = spawnSync('docker', [...docker, 'pg_dump', ...args], {
    env,
    encoding: 'utf8',
    maxBuffer: 1024 * 1024 * 1024,
  });
  if (r.status !== 0) {
    const why = (r.stderr || r.error?.message || '')
      .split('\n')
      .filter((l) => !/warning|hint|detail/i.test(l));
    throw new Error(`pg_dump failed: ${why.join(' ').trim().slice(0, 500)}`);
  }
  writeFileSync(outFile, r.stdout);
  const v = spawnSync('docker', [...docker, 'pg_dump', '--version'], { env, encoding: 'utf8' });
  return (v.stdout || '').trim();
}

function readSummary(file: string): Summary | null {
  return existsSync(file) ? (JSON.parse(readFileSync(file, 'utf8')) as Summary) : null;
}

function balancesCsv(lines: BalanceLine[]): string {
  return toCsv(
    ['account_id', 'account_name', 'is_test', 'item', 'amount'],
    lines.map((b) => [b.account_id, b.account_name, b.is_test, b.item, b.amount]),
  );
}

function githubOutput(key: string, value: string): void {
  const f = process.env.GITHUB_OUTPUT;
  if (f) writeFileSync(f, `${key}=${value.replace(/\n/g, ' ')}\n`, { flag: 'a' });
}

export async function take(
  url: string,
  repo: string,
): Promise<{ summary: Summary; message: string }> {
  const dest = join(repo, 'backup');
  const tmp = join(repo, '.backup-new');
  rmSync(tmp, { recursive: true, force: true });
  mkdirSync(join(tmp, 'csv'), { recursive: true });
  const prev = readSummary(join(dest, 'counts.json'));

  const snap = await openSnapshot(clientConfig(url));
  let summary: Summary;
  let pgDumpVersion: string;
  try {
    const s = await summarise(snap.client);
    summary = s.summary;
    for (const [name, t] of Object.entries(summary.tables))
      writeFileSync(
        join(tmp, 'csv', `${name}.csv`),
        toCsv(t.columns, await tableRows(snap.client, name, t.columns)),
      );
    writeFileSync(join(tmp, 'auth.sql'), authSql(s.auth));
    writeFileSync(join(tmp, 'balances.csv'), balancesCsv(await balances(snap.client)));

    // pg_dump inside the same snapshot: the dump and counts.json are the same moment.
    const common = ['--snapshot', snap.id, '--quote-all-identifiers', '--no-password'];
    pgDumpVersion = pgDump(
      url,
      [...common, '--schema-only', '-n', 'public', '-n', 'private'],
      join(tmp, 'schema.sql'),
    );
    pgDump(
      url,
      [
        ...common,
        '--data-only',
        '-t',
        'public.*',
        '-t',
        'private.*',
        ...OWN_FILE_TABLES.map((t) => `--exclude-table-data=${t}`),
      ],
      join(tmp, 'data.sql'),
    );
    writeFileSync(
      join(tmp, 'schema.sql'),
      restorableSchema(readFileSync(join(tmp, 'schema.sql'), 'utf8')),
    );
  } finally {
    await closeSnapshot(snap).catch(() => undefined);
  }

  const problems = backupProblems(prev, summary);
  const data = readFileSync(join(tmp, 'data.sql'), 'utf8');
  for (const name of Object.keys(summary.tables)) {
    const [s, t] = name.split('.');
    const inData = data.includes(`COPY "${s}"."${t}" (`);
    if (OWN_FILE_TABLES.includes(name)) {
      if (inData) problems.push(`data.sql holds ${name}, which belongs in its own file.`);
      if (!existsSync(join(tmp, 'csv', `${name}.csv`)))
        problems.push(`csv/${name}.csv is missing.`);
    } else if (!inData) problems.push(`data.sql has no rows section for ${name}.`);
  }
  if (
    !readFileSync(join(tmp, 'schema.sql'), 'utf8').includes('CREATE TABLE "public"."transactions"')
  )
    problems.push('schema.sql has no ledger table.');
  if (problems.length) {
    rmSync(tmp, { recursive: true, force: true });
    throw new Error(
      `The backup failed on purpose (yesterday's backup is left as it was):\n- ${problems.join('\n- ')}`,
    );
  }

  writeFileSync(join(tmp, 'counts.json'), JSON.stringify(summary, null, 2) + '\n');
  const rows = Object.values(summary.tables).reduce((n, t) => n + t.rows, 0);
  const reset = afterReset(prev, summary);
  writeFileSync(
    join(tmp, 'manifest.json'),
    JSON.stringify(
      {
        taken_at: summary.taken_at,
        pg_dump: pgDumpVersion,
        tables: Object.keys(summary.tables).length,
        rows,
        logins: summary.other['auth.users'] ?? 0,
        after_prelaunch_reset: reset,
      },
      null,
      2,
    ) + '\n',
  );
  rmSync(dest, { recursive: true, force: true });
  renameSync(tmp, dest);

  const message =
    `Backup ${summary.taken_at.slice(0, 10)}: ${Object.keys(summary.tables).length} tables, ${rows} rows, ` +
    `${summary.tables['public.transactions'].rows} ledger rows` +
    (reset ? ' (after the pre-launch reset)' : '');
  return { summary, message };
}

export async function record(url: string, repo: string): Promise<string> {
  const summary = readSummary(join(repo, 'backup', 'counts.json'));
  if (!summary) throw new Error('No backup/counts.json to record.');
  const client = new pg.Client(clientConfig(url));
  await client.connect();
  try {
    const r = await client.query<{ r: string }>('select public.record_backup($1::jsonb) as r', [
      JSON.stringify(countsForRecord(summary)),
    ]);
    return r.rows[0].r;
  } finally {
    await client.end();
  }
}

async function main(): Promise<void> {
  const [cmd, repo = '.'] = process.argv.slice(2);
  const url = process.env.BACKUP_DB_URL;
  if (!url) throw new Error('Set BACKUP_DB_URL (in GitHub: the SUPABASE_DB_URL secret).');
  if (cmd === 'take') {
    const { message } = await take(url, repo);
    console.log(message);
    githubOutput('message', message);
  } else if (cmd === 'record') {
    console.log(await record(url, repo));
  } else {
    throw new Error('Usage: node scripts/backup.ts take|record <repo folder>');
  }
}

if (process.argv[1]?.endsWith('backup.ts')) {
  main().catch((e: Error) => {
    for (const line of e.message.split('\n')) console.error(`::error::${line}`);
    process.exit(1);
  });
}
