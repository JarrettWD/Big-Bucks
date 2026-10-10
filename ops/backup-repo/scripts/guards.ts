// The backup's plain logic, with no database or files in it, so Vitest can check it
// (guards.test.ts): CSV, the checks that make a backup fail on purpose, and the
// restore drill's comparison. Every number from the database stays text, so no cent
// or fund unit is ever rounded on the way.

/** One table in a backup: how many rows, its columns, and a checksum of every row. */
export interface TableSummary {
  rows: number;
  md5: string;
  columns: string[];
}

/** counts.json: what a backup holds, taken in the same snapshot as the dump. */
export interface Summary {
  taken_at: string;
  /** Every table in public and private, by "schema.table". */
  tables: Record<string, TableSummary>;
  /** Login tables (auth.users, …) and the storage counts, by name: row counts only. */
  other: Record<string, number>;
  /** A checksum of each login table's rows. */
  other_md5: Record<string, string>;
  /** Tables the database itself keeps append-only (they can never shrink). */
  append_only: string[];
  /** The latest pre-launch reset, if any, and which tables it cleared. */
  prelaunch_reset_at: string | null;
  prelaunch_cleared: string[];
}

/** One line of balances.csv. */
export interface BalanceLine {
  account_id: string;
  account_name: string;
  is_test: string;
  item: string;
  amount: string;
}

/** One CSV field: empty for null, quoted when it holds a comma, a quote, a line break or edge spaces. */
export function csvField(value: string | null): string {
  if (value === null) return '';
  if (/[",\r\n]/.test(value) || value !== value.trim()) return `"${value.replaceAll('"', '""')}"`;
  return value;
}

/** A whole CSV file: a header line, then one line per row, each ending in a line break. */
export function toCsv(columns: string[], rows: (string | null)[][]): string {
  return [columns, ...rows].map((r) => r.map(csvField).join(',') + '\n').join('');
}

/** Reads a CSV file written by toCsv (quoted fields, doubled quotes, line breaks inside quotes). */
export function parseCsv(text: string): string[][] {
  const out: string[][] = [];
  let row: string[] = [];
  let field = '';
  let quoted = false;
  for (let i = 0; i < text.length; i++) {
    const ch = text[i];
    if (quoted) {
      if (ch === '"' && text[i + 1] === '"') {
        field += '"';
        i++;
      } else if (ch === '"') quoted = false;
      else field += ch;
    } else if (ch === '"') quoted = true;
    else if (ch === ',') {
      row.push(field);
      field = '';
    } else if (ch === '\n') {
      row.push(field);
      out.push(row);
      row = [];
      field = '';
    } else if (ch !== '\r') field += ch;
  }
  if (field !== '' || row.length > 0) {
    row.push(field);
    out.push(row);
  }
  return out;
}

/**
 * pg_dump's schema, made to load into a new Supabase project (as `supabase db dump`
 * does): every project already has the public schema, owned by Supabase, so it isn't
 * created again, nor its owner or comment changed; and Supabase's own default
 * privileges (FOR ROLE supabase_admin) are already in place and only Supabase may set them.
 */
export function restorableSchema(sql: string): string {
  return sql
    .replace(/^CREATE SCHEMA "/gm, 'CREATE SCHEMA IF NOT EXISTS "')
    .replace(/^(ALTER SCHEMA "public" OWNER TO )/gm, '-- $1')
    .replace(/^(COMMENT ON SCHEMA "public" IS )/gm, '-- $1')
    .replace(/^(ALTER DEFAULT PRIVILEGES FOR ROLE "supabase_admin" )/gm, '-- $1');
}

const plural = (n: number, one: string, many = `${one}s`) => `${n} ${n === 1 ? one : many}`;

/**
 * Why this backup must fail on purpose, compared with the one before it (an empty
 * list when it's fine):
 * - the export is empty;
 * - a table that was there is gone;
 * - an append-only table (the ledger, rates, settings, …) has fewer rows, unless a
 *   pre-launch reset newer than the last backup cleared that table;
 * - storage holds something (Big Bucks doesn't use it, so the backup would miss it).
 */
export function backupProblems(prev: Summary | null, now: Summary): string[] {
  const problems: string[] = [];
  const total = Object.values(now.tables).reduce((n, t) => n + t.rows, 0);
  if (Object.keys(now.tables).length === 0 || total === 0)
    problems.push('The export is empty: no table has any rows.');
  if (!now.tables['public.transactions'])
    problems.push('The export has no ledger (public.transactions).');
  for (const name of ['storage.buckets', 'storage.objects'])
    if ((now.other[name] ?? 0) > 0)
      problems.push(
        `${name} has ${plural(now.other[name], 'row')}, which this backup doesn't hold.`,
      );
  if (!prev) return problems;

  for (const name of Object.keys(prev.tables))
    if (!now.tables[name])
      problems.push(`The table ${name} was in the last backup and is gone now.`);

  const newReset =
    now.prelaunch_reset_at !== null &&
    (prev.prelaunch_reset_at === null ||
      Date.parse(now.prelaunch_reset_at) > Date.parse(prev.prelaunch_reset_at));
  const guarded = new Set([...prev.append_only, ...now.append_only]);
  for (const name of [...guarded].sort()) {
    const before = prev.tables[name]?.rows;
    const after = now.tables[name]?.rows;
    if (before === undefined || after === undefined || after >= before) continue;
    if (newReset && now.prelaunch_cleared.includes(name)) continue;
    problems.push(
      `${name} has fewer rows than in the last backup (${after} now, ${before} then). ` +
        'It is append-only, so rows can never go away: stop and ask.',
    );
  }
  return problems;
}

/** Whether a newer pre-launch reset explains this backup's smaller tables (for the commit message). */
export function afterReset(prev: Summary | null, now: Summary): boolean {
  if (!prev || now.prelaunch_reset_at === null) return false;
  return (
    prev.prelaunch_reset_at === null ||
    Date.parse(now.prelaunch_reset_at) > Date.parse(prev.prelaunch_reset_at)
  );
}

/** The counts record_backup() keeps, which prelaunch_reset() checks: rows per table. */
export function countsForRecord(now: Summary): {
  taken_at: string;
  counts: Record<string, number>;
} {
  return {
    taken_at: now.taken_at,
    counts: Object.fromEntries(Object.entries(now.tables).map(([k, t]) => [k, t.rows])),
  };
}

export interface DrillResult {
  ok: boolean;
  lines: string[];
}

/**
 * The restore drill's verdict: every table's rows and checksum, every login table's
 * rows, and every account's balances, restored copy against the backup's own record.
 */
export function compareRestore(
  backup: Summary,
  restored: Summary,
  backupBalances: BalanceLine[],
  restoredBalances: BalanceLine[],
): DrillResult {
  const lines: string[] = [];
  let ok = true;
  const fail = (s: string) => {
    ok = false;
    lines.push(`FAIL  ${s}`);
  };

  let tablesOk = 0;
  for (const [name, t] of Object.entries(backup.tables).sort()) {
    const r = restored.tables[name];
    if (!r) fail(`${name}: missing from the restored copy`);
    else if (r.rows !== t.rows) fail(`${name}: ${r.rows} rows restored, ${t.rows} in the backup`);
    else if (r.md5 !== t.md5)
      fail(`${name}: same ${plural(t.rows, 'row')}, but the contents differ`);
    else tablesOk++;
  }
  for (const [name, n] of Object.entries(backup.other).sort()) {
    const r = restored.other[name];
    if (r !== n) fail(`${name}: ${r ?? 'no'} rows restored, ${n} in the backup`);
    else if ((backup.other_md5[name] ?? '') !== (restored.other_md5[name] ?? ''))
      fail(`${name}: same ${plural(n, 'row')}, but the contents differ`);
    else tablesOk++;
  }
  lines.unshift(
    `${tablesOk === Object.keys(backup.tables).length + Object.keys(backup.other).length ? 'PASS' : 'FAIL'}  ` +
      `${tablesOk} of ${Object.keys(backup.tables).length + Object.keys(backup.other).length} tables match, row for row`,
  );

  const key = (b: BalanceLine) => `${b.account_id}|${b.item}`;
  const restoredBy = new Map(restoredBalances.map((b) => [key(b), b]));
  const accounts = new Map<string, { name: string; test: boolean; bad: string[]; items: number }>();
  for (const b of backupBalances) {
    const a = accounts.get(b.account_id) ?? {
      name: b.account_name,
      test: b.is_test === 'true' || b.is_test === 't',
      bad: [],
      items: 0,
    };
    a.items++;
    const r = restoredBy.get(key(b));
    if (!r) a.bad.push(`${b.item} missing (backup: ${b.amount})`);
    else if (r.amount !== b.amount) a.bad.push(`${b.item} ${r.amount}, backup ${b.amount}`);
    restoredBy.delete(key(b));
    accounts.set(b.account_id, a);
  }
  for (const r of restoredBy.values()) {
    const a = accounts.get(r.account_id) ?? {
      name: r.account_name,
      test: r.is_test === 'true' || r.is_test === 't',
      bad: [],
      items: 0,
    };
    a.bad.push(`${r.item} ${r.amount} only in the restored copy`);
    accounts.set(r.account_id, a);
  }
  for (const a of [...accounts.values()].sort((x, y) => x.name.localeCompare(y.name))) {
    const label = `${a.name}${a.test ? ' (test)' : ''}`;
    if (a.bad.length) fail(`${label}: ${a.bad.join('; ')}`);
    else lines.push(`PASS  ${label}: all ${a.items} balances match to the cent and unit`);
  }
  if (accounts.size === 0) lines.push('NOTE  The backup has no accounts yet.');
  return { ok, lines };
}
