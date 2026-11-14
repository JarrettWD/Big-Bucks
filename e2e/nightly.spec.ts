// The nightly run end to end on the LOCAL Supabase (Stage 4, Part A): the nightly
// Edge Function with the made-up price source catches up after a skipped day, and the
// database kicks it by itself (nightly_kick, then the one sender through pg_net), as
// pg_cron does on production. Runs last: it moves the app clock two months on (firstNight).
// Since the price fix (Nov 2026) a day's close is confirmed at 9:00 pm Alberta time, so the
// evening's work is done by the 9:30 pm run; the 4:30 pm run does what needs no price.
import { expect, test } from '@playwright/test';
import { LocalDb } from '../scripts/timemachine/db.ts';
import { parentSignIn } from './helpers';

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
 * The first test night, the same on any day of the month (Dad, 2026-10-29): from the 8th of
 * the month after next, the first day whose next day both markets trade (so the skipped night
 * has real closes to fill in). Every test day then falls between about the 8th and the 28th:
 * never on the 1st (when the month's interest is paid), a quarter's dividend day or a month's
 * end. The first run always catches up across exactly two 1sts and at least 38 days, whatever
 * today's date (the price fix's long gap, 2b), so the state these tests leave behind never
 * depends on when they run. (The clock only moves forward, so the 1st can't be avoided
 * altogether: what matters is that it's always the same.)
 */
async function firstNight(db: LocalDb): Promise<string> {
  const [r] = await db.q<{ d: string }>(
    `select min(g)::date::text as d
       from generate_series((date_trunc('month', public.app_today()) + interval '2 months 7 days')::date,
                            (date_trunc('month', public.app_today()) + interval '2 months 21 days')::date,
                            interval '1 day') g
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

// The price fix, 2b (Dad, 2026-11-06): the timer off for 38 days or more, then one evening.
// Each call does its jobs and checks a few days at a time (each database call stays far inside
// production's 8-second limit) and keeps calling within its own time; the next call carries on.
test('a long gap (38+ days) catches up in bounded steps, each day once', async () => {
  test.setTimeout(600_000);
  await withDb(async (db) => {
    const d1 = await firstNight(db);
    const eve = await plus(db, d1, -1);
    const [{ d: from }] = await db.q<{ d: string }>(
      `select coalesce(max(run_for_date) + 1, public.app_today())::text as d from public.job_runs
        where job = 'expire' and status = 'ok'`,
    );
    const [{ n: gap }] = await db.q<{ n: number }>(`select ($1::date - $2::date + 1)::int as n`, [
      eve,
      from,
    ]);
    expect(gap, `${from} to ${eve}`).toBeGreaterThanOrEqual(35);
    try {
      await db.setClock(`${eve} 21:30`);
      const runs: Record<string, unknown>[] = [];
      for (let i = 0; i < 6; i++) {
        const r = await nightly();
        runs.push(r);
        if (r.done === true) break;
      }
      const last = runs.at(-1)!;
      expect(last.done, JSON.stringify(last).slice(0, 800)).toBe(true);
      // Bounded: at most 5 days per database call, so a gap this long took several calls.
      const calls = runs.reduce((n, r) => n + ((r.jobs as { calls: number }).calls ?? 0), 0);
      expect(calls).toBeGreaterThanOrEqual(Math.ceil(gap / 5));
      for (const r of runs)
        expect(
          (r.reconciled as { days_with_problems: number | null }).days_with_problems ?? 0,
        ).toBe(0);

      // Every day's jobs exactly once, every day checked once, and nothing posted twice.
      const days = await db.q<{ d: string; n: number }>(
        `select g::date::text as d,
                (select count(*)::int from public.job_runs jr
                  where jr.job = 'expire' and jr.status = 'ok' and jr.run_for_date = g::date) as n
           from generate_series($1::date, $2::date, interval '1 day') g`,
        [from, eve],
      );
      expect(days.filter((x) => x.n !== 1)).toEqual([]);
      const checked = await db.q<{ d: string; n: number }>(
        `select g::date::text as d,
                (select count(*)::int from public.job_runs jr
                  where jr.job = 'reconcile' and jr.run_for_date = g::date) as n
           from generate_series($1::date, $2::date, interval '1 day') g`,
        [from, eve],
      );
      expect(checked.filter((x) => x.n !== 1)).toEqual([]);
      const twice = await db.q(
        `select posting_key from public.transactions where posting_key is not null
          group by posting_key having count(*) > 1`,
      );
      expect(twice).toEqual([]);
      const problems = await db.q(
        `select 1 from public.job_runs where job = 'reconcile' and status <> 'ok' and run_for_date between $1 and $2`,
        [from, eve],
      );
      expect(problems).toEqual([]);
    } finally {
      await db.setClock('');
    }
  });
});

test('the nightly run catches up after a skipped day', async () => {
  test.setTimeout(300_000);
  await withDb(async (db) => {
    const d1 = await firstNight(db);
    const [d2, d3] = [await plus(db, d1, 1), await plus(db, d1, 2)];
    try {
      // Tonight, at 9:30 pm (the closes are confirmed at 9:00 pm).
      await db.setClock(`${d1} 21:30`);
      const first = await nightly();
      expect(first.target).toBe(d1);
      expect(first.done).toBe(true);

      // The next night, a trading day, is skipped (a paused project, a failed run). The night after:
      await db.setClock(`${d3} 21:30`);
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

      // pg_net records the function's reply a moment after the function's own work has been
      // saved, so "done" can come first (Nov 6, 2026): wait for the latest call's reply, up to 30 s.
      const reply = async () =>
        (
          await db.q<{ status_code: number | null }>(
            `select r.status_code from public.outbox o
               left join net._http_response r on r.id = o.net_request_id
              where o.kind = 'http' and o.payload ->> 'target' = 'nightly'
              order by o.id desc limit 1`,
          )
        )[0]?.status_code ?? null;

      // pg_cron's own command, at 4:30 pm: the work that needs no price.
      await db.setClock(`${d4} 16:30`);
      const [kick] = await db.q<{ k: string }>(`select public.nightly_kick() as k`);
      expect(kick.k).toBe('queued');
      const [sent] = await db.q<{ n: number }>(`select public.send_outbox() as n`);
      expect(sent.n).toBe(1);
      await expect.poll(reply, { timeout: 90_000, intervals: [1000] }).toBe(200);

      // 5:00 pm: only today's closes (confirmed at 9:00 pm) and the fund work wait. No call.
      await db.setClock(`${d4} 17:00`);
      const [wait] = await db.q<{ k: string }>(`select public.nightly_kick() as k`);
      expect(wait.k).toBe("waiting: today's closes are confirmed at 9:00 pm");

      // 9:00 pm: a call for the confirmed closes.
      await db.setClock(`${d4} 21:00`);
      const [kick2] = await db.q<{ k: string }>(`select public.nightly_kick() as k`);
      expect(kick2.k).toBe('queued');
      const [sent2] = await db.q<{ n: number }>(`select public.send_outbox() as n`);
      expect(sent2.n).toBe(1);

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
      await expect.poll(reply, { timeout: 30_000, intervals: [500] }).toBe(200);

      // Done: the next kick does nothing.
      await db.setClock(`${d4} 21:30`);
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
      await db.setClock(`${before} 21:30`);
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

      // 9:30 pm, the price service down. First the missing-close alerts (nightly_kick raises
      // them from 10:00 pm; here they're raised directly and the call is made directly so it
      // can carry the switch).
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
      await db.setClock(`${next} 21:30`);
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

// The price fix (Dad, 2026-11-05): the made-up price source switched to "snapshot" holds, for
// today, a price from a few minutes before the close until 9:00 pm (as the real provider's did
// on Nov 5, 2026): a little above the close for the TSX fund, a little below for the Nasdaq-100.
// Her buy and sale wait through the evening and settle at the confirmed close, never the snapshot.
async function nightlySnapshot(): Promise<Record<string, unknown>> {
  const r = await fetch(URL, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'x-nightly-key': KEY,
      'x-fake-prices': 'snapshot',
    },
    body: JSON.stringify({ mode: 'nightly' }),
  });
  const body = (await r.json()) as Record<string, unknown>;
  expect(r.status, JSON.stringify(body)).toBe(200);
  return body;
}

let snapDay = '';
let snapBuy = 0;

test('a pre-close snapshot at 4:30 pm is never used: the trades settle at the 9:00 pm close', async () => {
  test.setTimeout(180_000);
  await withDb(async (db) => {
    // After every earlier test day, and after any trade she has already asked for (one trade
    // per fund per day: the outage test's buy can fall on firstNight + 8).
    const [{ d: from }] = await db.q<{ d: string }>(
      `select greatest($1::date,
                       (select max(public.edmonton_local(r.created_at))::date + 2 from public.requests r
                         join public.profiles p on p.account_id = r.account_id
                        where p.username = 'demo_robin'))::text as d`,
      [await plus(db, await firstNight(db), 8)],
    );
    const [{ d: day }] = await db.q<{ d: string }>(
      `select min(g)::date::text as d
         from generate_series($1::date, $1::date + 14, interval '1 day') g
        where public.is_trading_day('nyse', g::date) and public.is_trading_day('tsx', g::date)
          and public.is_trading_day('nyse', (g - interval '1 day')::date)`,
      [from],
    );
    snapDay = day;
    const before = await plus(db, day, -1);
    const [robin] = await db.q<{ user_id: string; account_id: string }>(
      `select user_id::text, account_id::text from public.profiles where username = 'demo_robin'`,
    );
    const ROBIN = { role: 'authenticated' as const, sub: robin.user_id, aal: 'aal1' as const };
    try {
      await db.setClock(`${before} 21:30`);
      expect((await nightly()).done).toBe(true);
      await db.q(
        `insert into public.settings (key, value, effective_date) values ('price_mismatch_check', 'on', '2026-01-01')`,
      );

      // That morning: $10.00 of the TSX fund, and $1.00 of her Nasdaq-100 sold.
      await db.setClock(`${day} 09:00`);
      const [held] = await db.q<{ u: string }>(
        `select coalesce(sum(units), 0)::text as u from public.transactions
          where account_id = $1 and fund_id = 'nasdaq100' and vehicle = 'stock'`,
        [robin.account_id],
      );
      expect(Number(held.u), 'Robin holds some Nasdaq-100 to sell').toBeGreaterThan(0.01);
      for (const sql of [
        `select public.request_trade('tsx', 'buy', 1000, false)`,
        `select public.request_trade('nasdaq100', 'sell', 100, false)`,
      ]) {
        const r = await db.call(ROBIN, sql);
        expect(r.ok, JSON.stringify(r)).toBe(true);
      }
      const reqs = await db.q<{ id: number; fund_id: string }>(
        `select id::int, fund_id from public.requests where account_id = $1 and status = 'pending'
            and fund_id in ('tsx', 'nasdaq100') order by id`,
        [robin.account_id],
      );
      expect(reqs.map((r) => r.fund_id)).toEqual(['tsx', 'nasdaq100']);
      snapBuy = reqs[0].id;

      // 4:30 pm: the provider's bar for today holds a pre-close price. It's offered, refused,
      // and only kept in the provider log.
      await db.setClock(`${day} 16:30`);
      const early = await nightlySnapshot();
      for (const p of early.prices as { fund: string; stored: { counts?: { refused: number } } }[])
        expect(p.stored?.counts?.refused, p.fund).toBe(1);
      const stored = await db.q(`select 1 from public.fund_prices where price_date = $1::date`, [
        day,
      ]);
      expect(stored, 'nothing stored for today before 9:00 pm').toEqual([]);
      const snaps = await db.q<{ fund_id: string; close: string }>(
        `select fund_id, close::text from public.price_observations where price_date = $1::date order by fund_id`,
        [day],
      );
      expect(snaps.map((x) => x.fund_id)).toEqual(['dow', 'nasdaq100', 'tsx']);
      const pending = await db.q<{ status: string }>(
        `select status::text from public.requests where id = any ($1::bigint[])`,
        [reqs.map((r) => r.id)],
      );
      expect(pending.every((r) => r.status === 'pending')).toBe(true);
      // Her history says what it's waiting for.
      const [line] = await db.q<{ note: string }>(
        `select note from public.my_activity($1::uuid) where kind = 'request_pending' and request_id = $2`,
        [robin.account_id, snapBuy],
      );
      expect(line.note).toMatch(
        /^Waiting for today's close to be confirmed \(\w{3} \d{1,2}\) · asked \w{3} \d{1,2}$/,
      );

      // 9:30 pm: the confirmed closes, and both trades settle at them.
      await db.setClock(`${day} 21:30`);
      const late = await nightlySnapshot();
      expect(late.done).toBe(true);
      for (const r of reqs) {
        const [t] = await db.q<{ price: string; close: string; snap: string; status: string }>(
          `select t.unit_price::text as price, fp.close::text as close,
                  (select po.close::text from public.price_observations po
                    where po.fund_id = $2 and po.price_date = $3::date order by po.id limit 1) as snap,
                  (select status::text from public.requests where id = $1) as status
             from public.transactions t
             join public.fund_prices fp on fp.fund_id = t.fund_id and fp.price_date = $3::date
            where t.request_id = $1 and t.vehicle = 'stock'`,
          [r.id, r.fund_id, day],
        );
        expect(t.status).toBe('settled');
        expect(Number(t.price), r.fund_id).toBe(Number(t.close));
        expect(Number(t.price), `${r.fund_id}: never the snapshot`).not.toBe(Number(t.snap));
      }
      // Above for the TSX fund, below for the Nasdaq-100: the snapshot was off both ways.
      const [dir] = await db.q<{ tsx: boolean; nasdaq: boolean }>(
        `select (select po.close > fp.close from public.price_observations po join public.fund_prices fp
                  on fp.fund_id = po.fund_id and fp.price_date = po.price_date
                 where po.fund_id = 'tsx' and po.price_date = $1::date order by po.id limit 1) as tsx,
                (select po.close < fp.close from public.price_observations po join public.fund_prices fp
                  on fp.fund_id = po.fund_id and fp.price_date = po.price_date
                 where po.fund_id = 'nasdaq100' and po.price_date = $1::date order by po.id limit 1) as nasdaq`,
        [day],
      );
      expect(dir).toEqual({ tsx: true, nasdaq: true });
      // The safety net, on, raised nothing: the 4:30 pm snapshot doesn't count.
      const mism = await db.q(`select 1 from public.alerts where kind = 'price_mismatch'`);
      expect(mism).toEqual([]);
    } finally {
      await db.q(
        `insert into public.settings (key, value, effective_date) values ('price_mismatch_check', 'off', '2026-01-01')`,
      );
      await db.setClock('');
    }
  });
});

// The parent "Fix a close" screen (built with the price fix): Dad corrects the TSX close her
// buy just settled at, to one 10¢ lower. Her buy gets its missing units, at no cost, with a
// notice that leads with money; the preview listed it first; the log has it.
test('Fix a close: the preview lists her buy, and Yes adds her missing units', async ({ page }) => {
  test.setTimeout(180_000);
  expect(snapDay, 'the snapshot test ran first').not.toBe('');
  const [{ close, units }] = await withDb((db) =>
    db.q<{ close: string; units: string }>(
      `select fp.close::text as close,
              (select t.units::text from public.transactions t where t.request_id = $2 and t.vehicle = 'stock') as units
         from public.fund_prices fp where fp.fund_id = 'tsx' and fp.price_date = $1::date`,
      [snapDay, snapBuy],
    ),
  );
  const lower = (Math.round(Number(close) * 100) - 10) / 100;
  await withDb((db) => db.setClock(`${snapDay} 22:00`));
  try {
    await parentSignIn(page);
    await page.goto(`./parent/fix-close?fund=tsx&date=${snapDay}`);
    await expect(page.getByRole('heading', { name: 'Fix a close' })).toBeVisible();
    await expect(page.getByText(/^Stored close for /)).toBeVisible();
    await page.getByLabel('The official close').fill(lower.toFixed(2));
    await page.getByLabel('Where it comes from').fill('Test: the exchange’s closing price');
    await expect(page.getByText(/^Robin’s buy: Adds 0\.\d{8} units, worth/)).toBeVisible();
    await page.getByRole('button', { name: 'Yes, fix the close' }).click();
    await expect(page.getByText(/^Done\. The TSX close for /)).toBeVisible();

    const [fix] = await withDb((db) =>
      db.q<{ units: string; cents: string; title: string; body: string; summary: string }>(
        `select t.units::text, t.amount_cents::text as cents, n.title, n.body,
                (select summary from public.parent_actions where action = 'correct_fund_price' order by id desc limit 1) as summary
           from public.transactions t
           join public.notifications n on n.dedupe_key = t.posting_key
          where t.posting_key = $1`,
        [`fix:close:tsx:${snapDay}:${snapBuy}`],
      ),
    );
    const [{ should }] = await withDb((db) =>
      db.q<{ should: string }>(
        `select (ceil(10.00 / $1::numeric * 100000000) / 100000000 - $2::numeric)::numeric(20,8)::text as should`,
        [lower.toFixed(2), units],
      ),
    );
    expect(fix.units).toBe(should);
    expect(fix.cents).toBe('0');
    expect(fix.title).toBe('A price was fixed');
    expect(fix.body).toMatch(
      /^The TSX fund's \w{3} \d{1,2} close was really \$[\d.]+, not \$[\d.]+, so your buy should have got a little more\. We added the missing bit — worth (about \d+¢|less than 1¢)\. A fix like this can only add, never take away\.$/,
    );
    expect(fix.summary).toMatch(/^Fixed the TSX close for .*1 trade corrected/);
  } finally {
    await withDb((db) => db.setClock(''));
  }
});
