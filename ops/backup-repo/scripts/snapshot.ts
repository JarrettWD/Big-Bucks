// Reading a Big Bucks database for a backup, or for the restore drill: one
// read-only snapshot holding every table's rows, columns and checksum, every table
// as CSV, the logins, and every account's balances. The daily backup runs pg_dump
// inside the same snapshot (pg_export_snapshot), so the dump and counts.json describe
// exactly the same moment.
//
// Every value comes back as Postgres's own text: no number is ever turned into a
// JavaScript number, so no cent or fund unit can be rounded.

import { createHash } from 'node:crypto';
import pg from 'pg';
import type { BalanceLine, Summary, TableSummary } from './guards.ts';

/** Every value as text, exactly as Postgres writes it. */
const asText = { getTypeParser: () => (v: string) => v } as unknown as pg.CustomTypesConfig;

const q = (ident: string) => `"${ident.replaceAll('"', '""')}"`;
const qname = (name: string) => name.split('.').map(q).join('.');

export interface Snapshot {
  client: pg.Client;
  /** For pg_dump --snapshot. */
  id: string;
}

/** Opens one read-only snapshot. Times are in UTC, sorting is byte order, the same everywhere. */
export async function openSnapshot(config: pg.ClientConfig | string): Promise<Snapshot> {
  const base = typeof config === 'string' ? { connectionString: config } : config;
  const client = new pg.Client({ ...base, types: asText });
  await client.connect();
  await client.query(
    "set timezone = 'UTC'; set datestyle = 'ISO, MDY'; set intervalstyle = 'postgres'",
  );
  await client.query('begin isolation level repeatable read read only');
  const r = await client.query<{ id: string }>('select pg_export_snapshot() as id');
  return { client, id: r.rows[0].id };
}

export async function closeSnapshot(s: Snapshot): Promise<void> {
  try {
    await s.client.query('commit');
  } finally {
    await s.client.end();
  }
}

/** Every table in public and private, with its columns in order. */
export async function listTables(
  client: pg.Client,
): Promise<{ name: string; columns: string[] }[]> {
  const r = await client.query<{ name: string; columns: string[] | string }>(
    `select n.nspname || '.' || c.relname as name,
            array_agg(a.attname::text order by a.attnum) as columns
       from pg_class c
       join pg_namespace n on n.oid = c.relnamespace
       join pg_attribute a on a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped
      where c.relkind in ('r', 'p') and n.nspname in ('public', 'private')
      group by 1 order by 1`,
  );
  return r.rows.map((row) => ({ name: row.name, columns: pgArray(row.columns) }));
}

/** A Postgres text[] written as text ({a,b,"c d"}), as a list. */
export function pgArray(v: string[] | string): string[] {
  if (Array.isArray(v)) return v;
  const inner = v.replace(/^\{/, '').replace(/\}$/, '');
  if (inner === '') return [];
  const out: string[] = [];
  let cur = '';
  let quoted = false;
  for (let i = 0; i < inner.length; i++) {
    const ch = inner[i];
    if (quoted) {
      if (ch === '\\') cur += inner[++i];
      else if (ch === '"') quoted = false;
      else cur += ch;
    } else if (ch === '"') quoted = true;
    else if (ch === ',') {
      out.push(cur);
      cur = '';
    } else cur += ch;
  }
  out.push(cur);
  return out;
}

/** The row expression for a table's columns, and its sort key (byte order, so it's the same everywhere). */
const rowExpr = (columns: string[]) => `row(${columns.map((c) => `x.${q(c)}`).join(', ')})::text`;

/** Rows and a checksum of every row, over the given columns. */
export async function tableSummary(
  client: pg.Client,
  name: string,
  columns: string[],
): Promise<TableSummary> {
  const r = await client.query<{ rows: string; md5: string }>(
    `select count(*) as rows,
            md5(coalesce(string_agg(${rowExpr(columns)}, E'\\n' order by ${rowExpr(columns)} collate "C"), '')) as md5
       from ${qname(name)} x`,
  );
  return { rows: Number(r.rows[0].rows), md5: r.rows[0].md5, columns };
}

/** A table's rows as text, in the same order as its checksum. */
export async function tableRows(
  client: pg.Client,
  name: string,
  columns: string[],
): Promise<(string | null)[][]> {
  const r = await client.query({
    text: `select ${columns.map((c) => `x.${q(c)}::text`).join(', ')}
             from ${qname(name)} x order by ${rowExpr(columns)} collate "C"`,
    rowMode: 'array',
  });
  return r.rows as (string | null)[][];
}

export interface AuthTable {
  name: string;
  rows: number;
  /** The rows as JSON text (null for the storage counts). */
  json: string | null;
  /** The columns a restore may write (generated columns can't be). */
  columns: string[];
}

/** The login tables a restore needs, and the storage counts, through private.backup_auth(). */
export async function authTables(client: pg.Client): Promise<AuthTable[]> {
  const r = await client.query<{ table_name: string; row_count: string; rows_json: string | null }>(
    'select table_name, row_count, rows_json from private.backup_auth()',
  );
  const out: AuthTable[] = [];
  for (const row of r.rows) {
    let columns: string[] = [];
    if (row.rows_json !== null) {
      const c = await client.query<{ columns: string[] | string }>(
        // By name, not ::regclass: the backup login has no access to the auth schema itself.
        `select array_agg(a.attname::text order by a.attnum) as columns
           from pg_attribute a
           join pg_class c on c.oid = a.attrelid
           join pg_namespace n on n.oid = c.relnamespace
          where n.nspname = split_part($1, '.', 1) and c.relname = split_part($1, '.', 2)
            and a.attnum > 0 and not a.attisdropped and a.attgenerated = ''`,
        [row.table_name],
      );
      columns = pgArray(c.rows[0].columns);
    }
    out.push({ name: row.table_name, rows: Number(row.row_count), json: row.rows_json, columns });
  }
  return out;
}

/** Every account's balances, worked out by the database itself (private.backup_balances()). */
export async function balances(client: pg.Client): Promise<BalanceLine[]> {
  const r = await client.query<BalanceLine>(
    'select account_id, account_name, is_test::text as is_test, item, amount from private.backup_balances()',
  );
  return r.rows;
}

/** The whole summary for counts.json. Columns come from `columnsFrom` when given (the drill uses the backup's). */
export async function summarise(
  client: pg.Client,
  columnsFrom?: Summary,
): Promise<{ summary: Summary; auth: AuthTable[] }> {
  // The snapshot's own time, for the record only: no money depends on it (the
  // backup login can't call app_now()).
  const now = await client.query<{ now: string }>(
    `select to_char(now() at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') as now`,
  );
  const tables: Record<string, TableSummary> = {};
  for (const t of await listTables(client)) {
    const columns = columnsFrom?.tables[t.name]?.columns ?? t.columns;
    tables[t.name] = await tableSummary(client, t.name, columns);
  }
  const auth = await authTables(client);
  const appendOnly = await client.query<{ name: string }>(
    `select distinct t.tgrelid::regclass::text as name
       from pg_trigger t
      where not t.tgisinternal and t.tgfoid = 'public.reject_append_only_change()'::regprocedure
      order by 1`,
  );
  const reset = await client.query<{ at: string | null; cleared: string | null }>(
    `select to_char(r.done_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') as at, r.cleared::text as cleared
       from public.prelaunch_resets r order by r.id desc limit 1`,
  );
  const last = reset.rows[0];
  return {
    summary: {
      taken_at: now.rows[0].now,
      tables,
      other: Object.fromEntries(auth.map((a) => [a.name, a.rows])),
      other_md5: Object.fromEntries(
        auth
          .filter((a) => a.json !== null)
          .map((a) => [a.name, createHash('md5').update(a.json!).digest('hex')]),
      ),
      append_only: appendOnly.rows.map((r) => (r.name.includes('.') ? r.name : `public.${r.name}`)),
      prelaunch_reset_at: last?.at ?? null,
      prelaunch_cleared: last?.cleared
        ? Object.keys(JSON.parse(last.cleared) as object).sort()
        : [],
    },
    auth,
  };
}

/**
 * auth.sql: the login tables, loaded after the schema (session_replication_role =
 * replica, as for data.sql). json_populate_recordset keeps every value exact.
 */
export function authSql(auth: AuthTable[]): string {
  const parts = [
    '-- Big Bucks backup: the logins (auth.users, auth.identities, auth.mfa_factors).',
    '-- Load after schema.sql, with session_replication_role = replica (RUNBOOK, "Restore drill").',
    '',
  ];
  for (const a of auth) {
    if (a.json === null) continue;
    if (a.json.includes('$bigbucks$'))
      throw new Error(`${a.name} holds the quoting marker; can't write auth.sql.`);
    const cols = a.columns.map(q).join(', ');
    parts.push(
      `insert into ${qname(a.name)} (${cols})`,
      `select ${cols} from json_populate_recordset(null::${qname(a.name)}, $bigbucks$${a.json}$bigbucks$);`,
      '',
    );
  }
  return parts.join('\n');
}
