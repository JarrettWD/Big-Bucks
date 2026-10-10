// The time machine's connection to the LOCAL database, with the guards that
// stop it ever touching production.
//
// Each app call runs in its own transaction as the right Postgres role
// (authenticated for kids and the parent, service_role for the jobs), with the
// same signed-in claims Supabase Auth would give, so the real permission checks
// and grants are exercised.

import pg from 'pg';

export const LOCAL_DB_URL = 'postgresql://postgres:postgres@127.0.0.1:54322/postgres';

export type Who =
  { role: 'authenticated'; sub: string; aal: 'aal1' | 'aal2' } | { role: 'service_role' };

/** Why this address isn't the local database, or null when it is. */
export function addressProblem(url: string): string | null {
  let u: URL;
  try {
    u = new URL(url);
  } catch {
    return `Refusing to run: "${url}" isn't a database address.`;
  }
  if (!['127.0.0.1', 'localhost', '[::1]'].includes(u.hostname) || u.port !== '54322')
    return `Refusing to run: the time machine only runs against the local database (127.0.0.1:54322), not ${u.hostname}:${u.port}.`;
  if (/supabase\.(co|com|net)/i.test(url))
    return 'Refusing to run: that looks like a hosted Supabase project.';
  return null;
}

/**
 * Why this database isn't a local copy the time machine may use, or null when it is:
 * the newest is_local_dev row must say 'true', and it must never have been marked as
 * production (mark_production, pre-launch audit 2026-10-08).
 */
export function databaseProblem(
  localDev: string | undefined,
  markedProduction: boolean,
): string | null {
  if (markedProduction) return 'Refusing to run: this database is marked as production.';
  if (localDev !== 'true')
    return 'Refusing to run: this database does not say is_local_dev = true.';
  return null;
}

export class LocalDb {
  readonly client: pg.Client;

  private constructor(client: pg.Client) {
    this.client = client;
  }

  static async connect(url = process.env.TIMEMACHINE_DB_URL ?? LOCAL_DB_URL): Promise<LocalDb> {
    const bad = addressProblem(url);
    if (bad) throw new Error(bad);
    const client = new pg.Client({ connectionString: url });
    await client.connect();
    const r = await client.query<{ local_dev: string | null; production: boolean }>(
      `select (select value from public.settings where key = 'is_local_dev' order by id desc limit 1) as local_dev,
              exists (select 1 from public.settings where key = 'is_production') as production`,
    );
    const problem = databaseProblem(
      r.rows[0]?.local_dev ?? undefined,
      r.rows[0]?.production ?? false,
    );
    if (problem) {
      await client.end();
      throw new Error(problem);
    }
    return new LocalDb(client);
  }

  async close(): Promise<void> {
    await this.client.end();
  }

  /** A plain query as the database owner (setup, clock, prices, and inspection). */
  async q<T extends pg.QueryResultRow = Record<string, unknown>>(
    sql: string,
    params: unknown[] = [],
  ): Promise<T[]> {
    return (await this.client.query<T>(sql, params)).rows;
  }

  /** Call one app function as someone, in its own transaction. Errors come back as values. */
  async call(
    who: Who,
    sql: string,
    params: unknown[] = [],
  ): Promise<{ ok: true; value: unknown } | { ok: false; error: string }> {
    const c = this.client;
    await c.query('begin');
    try {
      if (who.role === 'service_role') {
        await c.query(`select set_config('request.jwt.claims', '{"role":"service_role"}', true)`);
        await c.query('set local role service_role');
      } else {
        await c.query(`select set_config('request.jwt.claims', $1, true)`, [
          JSON.stringify({ sub: who.sub, role: 'authenticated', aal: who.aal }),
        ]);
        await c.query('set local role authenticated');
      }
      const r = await c.query(sql, params);
      await c.query('commit');
      const row = r.rows[0];
      return { ok: true, value: row ? Object.values(row)[0] : null };
    } catch (e) {
      await c.query('rollback');
      return { ok: false, error: (e as Error).message };
    }
  }

  /** Move the app clock (local development only; production ignores the override). */
  async setClock(moment: string): Promise<void> {
    await this.client.query(
      `insert into public.settings (key, value, effective_date, note) values ('clock_override', $1, date '2026-01-01', 'time machine')`,
      [moment],
    );
  }
}
