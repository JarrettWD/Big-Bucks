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

// Dad, 2026-10-29 (ACCEPTANCE: "A simulated price-service outage makes trades wait rather than
// settle on an old price"). The made-up price source is switched "down" for one evening, with
// the test kid's buy waiting for that day's close. The switch is this computer's only:
// supabase/config.toml's PRICE_SOURCE_SWITCHES and the x-fake-prices header, both refused on
// hosted Supabase (priceSource in supabase/functions/_shared/lib.ts, and its unit tests).
async function nightlyDown(): Promise<Record<string, unknown>> {
  const r = await fetch(URL, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'x-nightly-key': KEY, 'x-fake-prices': 'down' },
    body: JSON.stringify({ mode: 'nightly' }),
  });
  const body = (await r.json()) as Record<string, unknown>;
  expect(r.status, JSON.stringify(body)).toBe(200);
  return body;
}

test('a price-service outage: the buy waits, never at an old close, and settles at its own', async () => {
  test.setTimeout(180_000);
  await withDb(async (db) => {
    // A day both markets trade, with the next day trading too, after the tests above.
    const from = await plus(db, await firstNight(db), 5);
    const [{ d: day }] = await db.q<{ d: string }>(
      `select min(g)::date::text as d
         from generate_series($1::date, $1::date + 14, interval '1 day') g
        where public.is_trading_day('nyse', g::date) and public.is_trading_day('tsx', g::date)
          and public.is_trading_day('nyse', (g + interval '1 day')::date)
          and public.is_trading_day('tsx', (g + interval '1 day')::date)`,
      [from],
    );
    const before = await plus(db, day, -1);
    const next = await plus(db, day, 1);
    const [robin] = await db.q<{ user_id: string; account_id: string }>(
      `select user_id::text, account_id::text from public.profiles where username = 'demo_robin'`,
    );
    try {
      // The evening before: everything done, so every earlier close is stored (the "old price").
      await db.setClock(`${before} 17:00`);
      expect((await nightly()).done).toBe(true);
      const [old] = await db.q<{ close: string | null }>(
        `select public.final_close('tsx', x.d)::text as close
           from (select max(price_date) as d from public.fund_prices
                  where fund_id = 'tsx' and price_date < $1::date) x`,
        [day],
      );
      expect(old.close, 'an earlier TSX close is there to be misused').not.toBeNull();

      // That morning she buys $10.00 of the TSX fund: it waits for that day's close.
      await db.setClock(`${day} 09:00`);
      const buy = await db.call(
        { role: 'authenticated', sub: robin.user_id, aal: 'aal1' },
        `select public.request_trade('tsx', 'buy', 1000)`,
      );
      expect(buy.ok, JSON.stringify(buy)).toBe(true);
      const [req] = await db.q<{ id: number }>(
        `select max(id)::int as id from public.requests where account_id = $1 and fund_id = 'tsx'`,
        [robin.account_id],
      );

      // 9:30 pm, the price service down. First the 9:00 pm check's alerts (nightly_kick raises
      // them before it calls; here the call is made directly so it can carry the switch).
      await db.setClock(`${day} 21:30`);
      await db.q(`select public.raise_missing_price_alerts($1::date)`, [day]);
      const [{ n: callsBefore }] = await db.q<{ n: number }>(
        `select coalesce(max(id), 0)::int as n from public.price_calls`,
      );
      const down = await nightlyDown();
      // Every fund's call failed (each with its one retry), and nothing was stored.
      const prices = down.prices as { fund: string; error?: string }[];
      expect(prices.length).toBe(3);
      for (const p of prices) expect(p.error, p.fund).toMatch(/No answer from the provider/);
      const [calls] = await db.q<{ n: number; ok: number }>(
        `select count(*)::int as n, count(*) filter (where ok)::int as ok
           from public.price_calls where id > $1`,
        [callsBefore],
      );
      expect(calls).toEqual({ n: 6, ok: 0 });
      const closes = await db.q<{ c: string | null }>(
        `select public.final_close(f.id, $1::date)::text as c from public.funds f`,
        [day],
      );
      expect(
        closes.every((r) => r.c === null),
        'no close for that day was stored or guessed',
      ).toBe(true);

      // The buy waits: not settled, nothing posted, its money still on hold. Never the old close.
      const [waiting] = await db.q<{ status: string; held: string }>(
        `select status::text, held_cents::text as held from public.requests where id = $1`,
        [req.id],
      );
      expect(waiting).toEqual({ status: 'pending', held: '1000' });
      const posted = await db.q(`select 1 from public.transactions where request_id = $1`, [
        req.id,
      ]);
      expect(posted).toEqual([]);
      const jobs = await db.q<{ job: string; status: string }>(
        `select job::text, status::text from public.job_runs
          where run_for_date = $1 and job::text in ('settle', 'expire', 'gic_maturity', 'auto_move',
                                                    'monthly', 'rate_notices')
          order by id`,
        [day],
      );
      expect(jobs, 'settle waits for the close').not.toContainEqual({
        job: 'settle',
        status: 'ok',
      });
      // The other nightly jobs still ran that night, and the day before's interest.
      for (const job of ['expire', 'gic_maturity', 'auto_move', 'monthly', 'rate_notices'])
        expect(jobs, job).toContainEqual({ job, status: 'ok' });
      const [interest] = await db.q<{ n: number }>(
        `select count(*)::int as n from public.job_runs
          where job = 'interest' and run_for_date = $1 and status = 'ok'`,
        [before],
      );
      expect(interest.n, 'the interest for the day before was worked out').toBe(1);
      expect(down.done).toBe(false);
      const open = await db.q<{ fund: string }>(
        `select details ->> 'fund_id' as fund from public.alerts
          where kind = 'missing_price' and details ->> 'date' = $1 and resolved_at is null
          order by 1`,
        [day],
      );
      expect(open.map((a) => a.fund)).toEqual(['dow', 'nasdaq100', 'tsx']);

      // The next evening, the price service is back: both days' closes come in, and the buy
      // settles at its own day's close.
      await db.setClock(`${next} 17:00`);
      const back = await nightly();
      expect(back.done).toBe(true);
      const [own] = await db.q<{ close: string | null }>(
        `select public.final_close('tsx', $1::date)::text as close`,
        [day],
      );
      expect(own.close).not.toBeNull();
      const [settled] = await db.q<{ status: string }>(
        `select status::text from public.requests where id = $1`,
        [req.id],
      );
      expect(settled.status).toBe('settled');
      const rows = await db.q<{
        vehicle: string;
        units: string | null;
        price: string | null;
        eff: string;
      }>(
        `select vehicle::text, units::text, unit_price::text as price,
                (effective_at at time zone 'America/Toronto')::date::text as eff
           from public.transactions where request_id = $1 order by id`,
        [req.id],
      );
      // Exactly two postings, once each, at that day's close (never the old one).
      expect(rows.map((r) => r.vehicle)).toEqual(['savings', 'stock']);
      const stock = rows[1];
      expect(Number(stock.price)).toBe(Number(own.close));
      if (Number(own.close) !== Number(old.close))
        expect(Number(stock.price)).not.toBe(Number(old.close));
      expect(stock.eff).toBe(day);
      const [units] = await db.q<{ u: string }>(
        `select (ceil(10.00 / $1::numeric * 100000000) / 100000000)::numeric(20,8)::text as u`,
        [own.close],
      );
      expect(stock.units).toBe(units.u);
      // Its alerts cleared themselves when the closes came in.
      const still = await db.q(
        `select 1 from public.alerts
          where kind = 'missing_price' and details ->> 'date' = $1 and resolved_at is null`,
        [day],
      );
      expect(still).toEqual([]);

      // Nothing twice: no posting key, interest day, or job-day (badges aside) more than once.
      const twice = await db.q<{ what: string }>(
        `select 'posting ' || posting_key as what from public.transactions
          where posting_key is not null group by posting_key having count(*) > 1
         union all
         select 'interest ' || account_id || ' ' || accrual_date from public.interest_accruals
          group by account_id, accrual_date having count(*) > 1
         union all
         select 'job ' || job || ' ' || run_for_date from public.job_runs
          where status = 'ok' and job::text not in ('backup', 'health', 'badges')
          group by job, run_for_date having count(*) > 1`,
      );
      expect(twice).toEqual([]);
    } finally {
      await db.setClock('');
    }
  });
});
