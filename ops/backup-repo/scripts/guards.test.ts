import { describe, expect, it } from 'vitest';
import {
  afterReset,
  backupProblems,
  compareRestore,
  countsForRecord,
  csvField,
  parseCsv,
  restorableSchema,
  toCsv,
  type BalanceLine,
  type Summary,
} from './guards.ts';

const table = (rows: number, md5 = `md5-${rows}`) => ({ rows, md5, columns: ['id'] });

function summary(over: Partial<Summary> = {}): Summary {
  return {
    taken_at: '2026-10-11T14:30:00.000000Z',
    tables: {
      'public.transactions': table(100),
      'public.rates': table(5),
      'public.alerts': table(3),
      'private.kid_pin_resets': table(1),
    },
    other: { 'auth.users': 3, 'storage.buckets': 0, 'storage.objects': 0 },
    other_md5: { 'auth.users': 'abc' },
    append_only: ['public.rates', 'public.transactions'],
    prelaunch_reset_at: null,
    prelaunch_cleared: [],
    ...over,
  };
}

describe('CSV', () => {
  it('leaves plain values alone and quotes the rest', () => {
    expect(csvField('12.34567891')).toBe('12.34567891');
    expect(csvField(null)).toBe('');
    expect(csvField('a,b')).toBe('"a,b"');
    expect(csvField('say "hi"')).toBe('"say ""hi"""');
    expect(csvField('two\nlines')).toBe('"two\nlines"');
    expect(csvField(' edge')).toBe('" edge"');
  });

  it('reads back exactly what it wrote', () => {
    const rows = [
      ['1', 'Savings, 2%', null],
      ['2', 'He said "wow"\r\nthen left', '-0.00000001'],
    ];
    const text = toCsv(['id', 'note', 'units'], rows);
    expect(parseCsv(text)).toEqual([
      ['id', 'note', 'units'],
      ['1', 'Savings, 2%', ''],
      ['2', 'He said "wow"\r\nthen left', '-0.00000001'],
    ]);
  });
});

describe('when a backup fails on purpose', () => {
  it('passes the first backup, and one that only grew', () => {
    expect(backupProblems(null, summary())).toEqual([]);
    const grew = summary({ tables: { ...summary().tables, 'public.transactions': table(101) } });
    expect(backupProblems(summary(), grew)).toEqual([]);
  });

  it('fails when the export is empty', () => {
    const empty = summary({
      tables: Object.fromEntries(Object.keys(summary().tables).map((k) => [k, table(0)])),
    });
    expect(backupProblems(null, empty)).toEqual(['The export is empty: no table has any rows.']);
    expect(backupProblems(null, summary({ tables: {} }))[0]).toMatch(/empty/);
  });

  it('fails when the ledger has fewer rows than the day before', () => {
    const fewer = summary({ tables: { ...summary().tables, 'public.transactions': table(99) } });
    expect(backupProblems(summary(), fewer)).toEqual([
      'public.transactions has fewer rows than in the last backup (99 now, 100 then). It is append-only, so rows can never go away: stop and ask.',
    ]);
  });

  it('lets an ordinary table shrink (alerts, PIN resets)', () => {
    const fewer = summary({
      tables: {
        ...summary().tables,
        'public.alerts': table(0),
        'private.kid_pin_resets': table(0),
      },
    });
    expect(backupProblems(summary(), fewer)).toEqual([]);
  });

  it('fails when a table disappears', () => {
    const { 'public.alerts': _gone, ...rest } = summary().tables;
    void _gone;
    expect(backupProblems(summary(), summary({ tables: rest }))).toEqual([
      'The table public.alerts was in the last backup and is gone now.',
    ]);
  });

  it('fails when storage holds anything (the backup would miss it)', () => {
    const s = summary({ other: { ...summary().other, 'storage.objects': 2 } });
    expect(backupProblems(null, s)).toEqual([
      "storage.objects has 2 rows, which this backup doesn't hold.",
    ]);
  });

  it('allows a smaller ledger once, right after a pre-launch reset that cleared it', () => {
    const reset = summary({
      tables: { ...summary().tables, 'public.transactions': table(0) },
      prelaunch_reset_at: '2026-10-11T15:00:00.000000Z',
      prelaunch_cleared: ['public.transactions'],
    });
    // The export isn't empty: the rates are still there.
    expect(backupProblems(summary(), reset)).toEqual([]);
    expect(afterReset(summary(), reset)).toBe(true);
    // The next day, the same reset doesn't excuse a shrink.
    const later = summary({
      ...reset,
      tables: { ...reset.tables, 'public.transactions': table(0) },
    });
    expect(afterReset(reset, later)).toBe(false);
    const shrankAgain = summary({
      ...reset,
      tables: { ...reset.tables, 'public.rates': table(4) },
    });
    expect(backupProblems(reset, shrankAgain)[0]).toMatch(/^public.rates has fewer rows/);
  });

  it("a reset never excuses a table it didn't clear", () => {
    const reset = summary({
      tables: { ...summary().tables, 'public.rates': table(4) },
      prelaunch_reset_at: '2026-10-11T15:00:00.000000Z',
      prelaunch_cleared: ['public.transactions'],
    });
    expect(backupProblems(summary(), reset)[0]).toMatch(/^public.rates has fewer rows/);
  });

  it('records rows per table for prelaunch_reset to check', () => {
    expect(countsForRecord(summary())).toEqual({
      taken_at: '2026-10-11T14:30:00.000000Z',
      counts: {
        'public.transactions': 100,
        'public.rates': 5,
        'public.alerts': 3,
        'private.kid_pin_resets': 1,
      },
    });
  });
});

describe('the schema file', () => {
  it('loads into a new project: public exists, Supabase sets its own defaults', () => {
    const sql = [
      'CREATE SCHEMA "private";',
      'CREATE SCHEMA "public";',
      'ALTER SCHEMA "public" OWNER TO "pg_database_owner";',
      `COMMENT ON SCHEMA "public" IS 'standard public schema';`,
      'ALTER DEFAULT PRIVILEGES FOR ROLE "supabase_admin" IN SCHEMA "public" GRANT ALL ON TABLES TO "anon";',
      'ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT SELECT ON TABLES TO "backup_reader";',
    ].join('\n');
    expect(restorableSchema(sql).split('\n')).toEqual([
      'CREATE SCHEMA IF NOT EXISTS "private";',
      'CREATE SCHEMA IF NOT EXISTS "public";',
      '-- ALTER SCHEMA "public" OWNER TO "pg_database_owner";',
      `-- COMMENT ON SCHEMA "public" IS 'standard public schema';`,
      '-- ALTER DEFAULT PRIVILEGES FOR ROLE "supabase_admin" IN SCHEMA "public" GRANT ALL ON TABLES TO "anon";',
      'ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT SELECT ON TABLES TO "backup_reader";',
    ]);
  });
});

describe('the restore drill', () => {
  const line = (item: string, amount: string, id = 'a1', name = 'Kid A'): BalanceLine => ({
    account_id: id,
    account_name: name,
    is_test: 'false',
    item,
    amount,
  });
  const bal = [line('savings_cents', '12345'), line('units:dow', '1.23456789')];

  it('passes when every table, login and balance matches', () => {
    const r = compareRestore(summary(), summary(), bal, [...bal]);
    expect(r.ok).toBe(true);
    expect(r.lines).toEqual([
      'PASS  7 of 7 tables match, row for row',
      'PASS  Kid A: all 2 balances match to the cent and unit',
    ]);
  });

  it('fails on one cent, one unit, a changed row or a missing table', () => {
    const cent = compareRestore(summary(), summary(), bal, [
      line('savings_cents', '12346'),
      bal[1],
    ]);
    expect(cent.ok).toBe(false);
    expect(cent.lines).toContain('FAIL  Kid A: savings_cents 12346, backup 12345');

    const unit = compareRestore(summary(), summary(), bal, [
      bal[0],
      line('units:dow', '1.23456788'),
    ]);
    expect(unit.lines).toContain('FAIL  Kid A: units:dow 1.23456788, backup 1.23456789');

    const changed = summary({
      tables: { ...summary().tables, 'public.transactions': table(100, 'other') },
    });
    const c = compareRestore(summary(), changed, bal, bal);
    expect(c.ok).toBe(false);
    expect(c.lines[0]).toBe('FAIL  6 of 7 tables match, row for row');
    expect(c.lines).toContain('FAIL  public.transactions: same 100 rows, but the contents differ');

    const { 'public.rates': _r, ...rest } = summary().tables;
    void _r;
    const missing = compareRestore(summary(), summary({ tables: rest }), bal, bal);
    expect(missing.lines).toContain('FAIL  public.rates: missing from the restored copy');
  });

  it('fails when the logins differ', () => {
    const r = compareRestore(summary(), summary({ other_md5: { 'auth.users': 'zzz' } }), bal, bal);
    expect(r.lines).toContain('FAIL  auth.users: same 3 rows, but the contents differ');
  });

  it('fails on a balance only in the restored copy, or missing from it', () => {
    const extra = compareRestore(summary(), summary(), bal, [...bal, line('gic_cents', '500')]);
    expect(extra.lines).toContain('FAIL  Kid A: gic_cents 500 only in the restored copy');
    const gone = compareRestore(summary(), summary(), bal, [bal[0]]);
    expect(gone.lines).toContain('FAIL  Kid A: units:dow missing (backup: 1.23456789)');
  });
});
