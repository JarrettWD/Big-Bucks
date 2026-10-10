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

export class LocalDb {
  readonly client: pg.Client;

  private constructor(client: pg.Client) {
    this.client = client;
  }

  static async connect(url = process.env.TIMEMACHINE_DB_URL ?? LOCAL_DB_URL): Promise<LocalDb> {
    const u = new URL(url);
    if (!['127.0.0.1', 'localhost', '[::1]'].includes(u.hostname) || u.port !== '54322') {
      throw new Error(
        `Refusing to run: the time machine only runs against the local database (127.0.0.1:54322), not ${u.hostname}:${u.port}.`,
      );
    }
    if (/supabase\.(co|com|net)/i.test(url))
      throw new Error('Refusing to run: that looks like a hosted Supabase project.');
    const client = new pg.Client({ connectionString: url });
    await client.connect();
    const db = new LocalDb(client);
    const r = await client.query(
      `select value from public.settings where key = 'is_local_dev' order by id desc limit 1`,
    );
    if (r.rows[0]?.value !== 'true') {
      await client.end();
      throw new Error('Refusing to run: this database does not say is_local_dev = true.');
    }
    // Production marks itself for good (mark_production, pre-launch audit 2026-10-08).
    const prod = await client.query(`select 1 from public.settings where key = 'is_production'`);
    if (prod.rows.length > 0) {
      await client.end();
      throw new Error('Refusing to run: this database is marked as production.');
    }
    return db;
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
