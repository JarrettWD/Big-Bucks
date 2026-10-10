// The nightly run end to end on the LOCAL Supabase (Stage 4, Part A): the nightly
// Edge Function with the made-up price source catches up after a skipped day, and the
// database kicks it by itself (nightly_kick, then the one sender through pg_net), as
// pg_cron does on production. Runs last: it moves the app clock forward two days.
import { expect, test } from '@playwright/test';
import { LocalDb } from '../scripts/timemachine/db.ts';

test.describe.configure({ mode: 'serial' });

const URL = 'http://127.0.0.1:54321/functions/v1/nightly';
const KEY = 'local-nightly-key-for-this-computer-only'; // supabase/config.toml, this computer only
// The same function as the database container sees it.
const INSIDE_URL = 'http://supabase_kong_big-bucks:8000/functions/v1/nightly';

async function nightly(): Promise<Record<string, unknown>> {
  const r = await fetch(URL, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'x-nightly-key': KEY },
    body: JSON.stringify({ mode: 'nightly' }),
  });
  const body = (await r.json()) as Record<string, unknown>;
  expect(r.status, JSON.stringify(body)).toBe(200);
  return body;
}

async function withDb<T>(run: (db: LocalDb) => Promise<T>): Promise<T> {
  const db = await LocalDb.connect();
  try {
    return await run(db);
  } finally {
    await db.close();
  }
}

/**
 * Tonight's day, from which the skipped night (the day after) is a day both markets
 * trade, so the catch-up has real closes to fill in.
 */
async function firstNight(db: LocalDb): Promise<string> {
  const [r] = await db.q<{ d: string }>(
    `select min(g)::date::text as d
       from generate_series(public.app_today(), public.app_today() + 14, interval '1 day') g
      where public.is_trading_day('nyse', (g + interval '1 day')::date)
        and public.is_trading_day('tsx', (g + interval '1 day')::date)`,
  );
  return r.d;
}
const plus = (db: LocalDb, d: string, n: number) =>
  db.q<{ d: string }>(`select ($1::date + $2::int)::text as d`, [d, n]).then((r) => r[0].d);

test('a wrong key gets nothing', async () => {
  const r = await fetch(URL, { method: 'POST', headers: { 'x-nightly-key': 'nope' }, body: '{}' });
  expect(r.status).toBe(401);
});

test('the nightly run catches up after a skipped day', async () => {
  test.setTimeout(180_000);
  await withDb(async (db) => {
    const d1 = await firstNight(db);
    const [d2, d3] = [await plus(db, d1, 1), await plus(db, d1, 2)];
    try {
      // Tonight, at 5:00 pm.
      await db.setClock(`${d1} 17:00`);
      const first = await nightly();
      expect(first.target).toBe(d1);
      expect(first.done).toBe(true);

      // The next night, a trading day, is skipped (a paused project, a failed run). The night after:
      await db.setClock(`${d3} 17:00`);
      const second = await nightly();
      expect(second.target).toBe(d3);
      expect(second.done).toBe(true);
      expect(second.reconciled).toMatchObject({ days_with_problems: 0 });
      // The skipped day's closes came in with tonight's (one call per fund).
      for (const p of second.prices as { missing: string[] }[]) expect(p.missing).toContain(d2);
      expect((second.prices as unknown[]).length).toBe(3);

      // Every trading day has its real-looking daily close, final and never guessed.
      const gaps = await db.q<{ fund_id: string; d: string }>(
        `select f.id as fund_id, g::date::text as d
           from public.funds f, generate_series($1::date, $2::date, interval '1 day') g
          where public.is_trading_day(f.market, g::date)
            and public.final_close(f.id, g::date) is null`,
        [d1, d3],
      );
      expect(gaps).toEqual([]);

      // Every job finished the skipped day and the next, and both were checked.
      const jobs = await db.q<{ job: string; d: string }>(
        `select jr.job::text as job, jr.run_for_date::text as d from public.job_runs jr
          where jr.status = 'ok' and jr.run_for_date between $1 and $2`,
        [d2, d3],
      );
      for (const job of [
        'expire',
        'splits',
        'settle',
        'dividends',
        'gic_maturity',
        'monthly',
        'rate_notices',
      ])
        for (const d of [d2, d3]) expect(jobs, `${job} on ${d}`).toContainEqual({ job, d });
      expect(jobs, 'interest for the skipped day').toContainEqual({ job: 'interest', d: d2 });
      const checked = await db.q<{ d: string }>(
        `select run_for_date::text as d from public.job_runs where job = 'reconcile' and run_for_date between $1 and $2`,
        [d2, d3],
      );
      expect(checked.map((r) => r.d).sort()).toEqual([d2, d3]);

      // Again the same night: nothing is fetched twice.
      const calls = await db.q<{ n: number }>(`select count(*)::int as n from public.price_calls`);
      const again = await nightly();
      expect(again.prices).toEqual([]);
      expect(again.done).toBe(true);
      const after = await db.q<{ n: number }>(`select count(*)::int as n from public.price_calls`);
      expect(after[0].n).toBe(calls[0].n);
    } finally {
      await db.setClock('');
    }
  });
});

test('the database kicks the run by itself, through its one sender', async () => {
  test.setTimeout(120_000);
  await withDb(async (db) => {
    const d4 = await plus(db, await firstNight(db), 3);
    try {
      await db.q(`select vault.create_secret($1, 'nightly_function_url')`, [INSIDE_URL]);
      await db.q(`select vault.create_secret($1, 'nightly_function_key')`, [KEY]);
      await db.setClock(`${d4} 16:29`);
      const [early] = await db.q<{ k: string }>(`select public.nightly_kick() as k`);
      expect(early.k).toMatch(/^too early/);

      // pg_cron's own command, at 4:30 pm.
      await db.setClock(`${d4} 16:30`);
      const [kick] = await db.q<{ k: string }>(`select public.nightly_kick() as k`);
      expect(kick.k).toBe('queued');
      const [sent] = await db.q<{ n: number }>(`select public.send_outbox() as n`);
      expect(sent.n).toBe(1);

      // pg_net calls the function after that commits; it fetches, runs and checks.
      await expect
        .poll(
          async () =>
            (
              await db.q<{ done: boolean }>(
                `select (public.nightly_status($1) ->> 'done')::boolean as done`,
                [d4],
              )
            )[0].done,
          { timeout: 90_000, intervals: [1000] },
        )
        .toBe(true);
      const [reply] = await db.q<{ status_code: number }>(
        `select r.status_code from net._http_response r
           join public.outbox o on o.net_request_id = r.id
          order by o.id desc limit 1`,
      );
      expect(reply.status_code).toBe(200);

      // Done: the next kick does nothing.
      await db.setClock(`${d4} 17:00`);
      const [next] = await db.q<{ k: string }>(`select public.nightly_kick() as k`);
      expect(next.k).toMatch(/^done/);
    } finally {
      await db.q(
        `delete from vault.secrets where name in ('nightly_function_url', 'nightly_function_key')`,
      );
      await db.setClock('');
    }
  });
});
