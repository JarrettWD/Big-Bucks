// `npm run rollback:check`: proves the price fix's rollback on the LOCAL Supabase (Dad's review,
// 2026-11-14). The rollback is "redeploy nightly v4": the function deployed before the price fix,
// left running against the new database. This puts v4's exact code (from main at b99aac8, the
// commit v4 was deployed from) in place of the local nightly function, runs one evening with it
// against the price-fix database, checks the money came out right, then puts v5 back.
//
// Needs the demo (npm run demo): Robin buys $10.00 of the TSX fund that morning.
// One evening, the way production would run with v4 after the migrations:
//   4:30 pm  v4 asks for nothing for today (the database lists today's close only from 9:00 pm),
//            runs the jobs that need no price; her buy waits;
//   9:30 pm  v4 fetches today's closes, they're stored and final, her buy settles at today's
//            close, every job is done, reconcile finds nothing wrong.
// v4 doesn't have the price fix's extras (bounded catch-up, the provider log, the price check):
// with v4 back, a long gap catches up the old way, as before the price fix.

import { execSync } from 'node:child_process';
import { readFileSync, writeFileSync } from 'node:fs';
import { LocalDb } from '../timemachine/db.ts';
import { LOCAL_API_URL } from './local.ts';

const V4_COMMIT = 'b99aac8';
const FILES = ['supabase/functions/nightly/index.ts', 'supabase/functions/_shared/lib.ts'];
const URL = `${LOCAL_API_URL}/functions/v1/nightly`;
const KEY = 'local-nightly-key-for-this-computer-only'; // supabase/config.toml, this computer only

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

/** The local runtime doesn't always notice changed files on Windows: restart its container. */
const restartFunctions = () =>
  execSync('docker restart supabase_edge_runtime_big-bucks', { stdio: 'ignore' });

/** One nightly call; the first after a restart can get a 502 while the worker starts, so up to 3 tries. */
async function call(): Promise<{ status: number; body: Record<string, unknown> }> {
  let last = { status: 0, body: {} as Record<string, unknown> };
  for (let i = 0; i < 3; i++) {
    const r = await fetch(URL, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'x-nightly-key': KEY },
      body: JSON.stringify({ mode: 'nightly' }),
    });
    last = { status: r.status, body: (await r.json()) as Record<string, unknown> };
    if (last.status !== 502) return last;
    await sleep(2000);
  }
  return last;
}

/**
 * Waits until the restarted runtime answers a wrong key (401), which runs nothing. Calling the
 * function for real here would run tonight's work on the real clock. Which version answered is
 * checked from the first real call: v5's answer has a "mismatches" field, v4's doesn't.
 */
async function waitForRuntime(): Promise<void> {
  for (let i = 0; i < 60; i++) {
    try {
      const r = await fetch(URL, {
        method: 'POST',
        headers: { 'x-nightly-key': 'wrong' },
        body: '{}',
      });
      if (r.status === 401) return;
    } catch {
      // still starting
    }
    await sleep(1000);
  }
  throw new Error('The local functions never came back after the restart.');
}

const checks: { what: string; ok: boolean; detail: string }[] = [];
const check = (what: string, ok: boolean, detail = '') => {
  checks.push({ what, ok, detail });
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${what}${detail ? ` (${detail})` : ''}`);
};

async function main(): Promise<void> {
  const db = await LocalDb.connect();
  const saved = FILES.map((f) => ({ f, text: readFileSync(f, 'utf8') }));
  try {
    // An evening after every job already run and every close already stored, both markets trading.
    const [{ d: day }] = await db.q<{ d: string }>(
      `select min(g)::date::text as d
         from generate_series(greatest(public.app_today(),
                                       (select max(run_for_date) + 1 from public.job_runs where status = 'ok'),
                                       (select max(price_date) + 1 from public.fund_prices)),
                              public.app_today() + 30, interval '1 day') g
        where public.is_trading_day('nyse', g::date) and public.is_trading_day('tsx', g::date)`,
    );
    const [robin] = await db.q<{ user_id: string; account_id: string }>(
      `select user_id::text, account_id::text from public.profiles where username = 'demo_robin'`,
    );
    if (!robin) throw new Error('No demo kid: run "npm run demo" first.');
    console.log(
      `Rollback check: nightly v4 (main ${V4_COMMIT}) against the price-fix database, on ${day}.`,
    );

    for (const f of FILES) writeFileSync(f, execSync(`git show ${V4_COMMIT}:${f}`));
    restartFunctions();
    await waitForRuntime();

    // Morning: Robin buys $10.00 of the TSX fund.
    await db.setClock(`${day} 09:00`);
    const buy = await db.call(
      { role: 'authenticated', sub: robin.user_id, aal: 'aal1' },
      `select public.request_trade('tsx', 'buy', 1000, false)`,
    );
    check('her buy is accepted', buy.ok, buy.ok ? '' : buy.error);
    const [{ id: req }] = await db.q<{ id: number }>(
      `select max(id)::int as id from public.requests where account_id = $1 and fund_id = 'tsx'`,
      [robin.account_id],
    );

    // 4:30 pm with v4.
    await db.setClock(`${day} 16:30`);
    const early = await call();
    check(
      '4:30 pm: v4 runs without an error',
      early.status === 200,
      JSON.stringify(early.body).slice(0, 300),
    );
    check(
      'it is v4 answering (no price-fix fields in its reply)',
      early.body.mode === 'nightly' && !('mismatches' in early.body),
    );
    const prices = (early.body.prices ?? []) as { missing: string[] }[];
    check(
      "4:30 pm: v4 isn't asked for today's closes (not ready until 9:00 pm)",
      prices.every((p) => !p.missing.includes(day)),
      JSON.stringify(prices).slice(0, 200),
    );
    const [{ n: stored }] = await db.q<{ n: number }>(
      `select count(*)::int as n from public.fund_prices where price_date = $1::date`,
      [day],
    );
    check('4:30 pm: nothing stored for today', stored === 0, `${stored} closes`);
    const [{ s: waiting }] = await db.q<{ s: string }>(
      `select status::text as s from public.requests where id = $1`,
      [req],
    );
    check('4:30 pm: her buy waits', waiting === 'pending', waiting);
    const core = await db.q<{ job: string }>(
      `select job::text from public.job_runs where run_for_date = $1::date and status = 'ok'
          and job::text in ('expire', 'gic_maturity', 'auto_move', 'monthly', 'rate_notices')`,
      [day],
    );
    check(
      '4:30 pm: the jobs that need no price ran',
      core.length === 5,
      core.map((c) => c.job).join(', '),
    );

    // 9:30 pm with v4.
    await db.setClock(`${day} 21:30`);
    const late = await call();
    check(
      '9:30 pm: v4 runs without an error',
      late.status === 200,
      JSON.stringify(late.body).slice(0, 300),
    );
    check('9:30 pm: tonight is done', late.body.done === true);
    const finals = await db.q<{ fund: string; c: string | null }>(
      `select f.id as fund, public.final_close(f.id, $1::date)::text as c from public.funds f order by f.id`,
      [day],
    );
    check(
      "9:30 pm: today's three closes are stored and final",
      finals.every((r) => r.c !== null),
      finals.map((r) => `${r.fund} ${r.c}`).join(', '),
    );
    const [settled] = await db.q<{
      status: string;
      price: string | null;
      close: string | null;
      units: string | null;
      want: string | null;
    }>(
      `select r.status::text,
              (select t.unit_price::text from public.transactions t where t.request_id = r.id and t.vehicle = 'stock') as price,
              public.final_close('tsx', $2::date)::text as close,
              (select t.units::text from public.transactions t where t.request_id = r.id and t.vehicle = 'stock') as units,
              (ceil(10.00 / public.final_close('tsx', $2::date) * 100000000) / 100000000)::numeric(20,8)::text as want
         from public.requests r where r.id = $1`,
      [req, day],
    );
    check(
      "9:30 pm: her buy settled at today's confirmed close, units rounded up",
      settled.status === 'settled' &&
        settled.price === settled.close &&
        settled.units === settled.want,
      `${settled.status}, ${settled.units} units at ${settled.price}`,
    );
    const rec = late.body.reconciled as { days_with_problems?: number } | undefined;
    check(
      '9:30 pm: reconcile finds nothing wrong',
      (rec?.days_with_problems ?? -1) === 0,
      JSON.stringify(rec),
    );
    const twice = await db.q(
      `select posting_key from public.transactions where posting_key is not null group by posting_key having count(*) > 1`,
    );
    check('nothing posted twice', twice.length === 0);
  } finally {
    for (const s of saved) writeFileSync(s.f, s.text);
    await db.setClock('');
    await db.close();
  }
  restartFunctions();
  await waitForRuntime();
  console.log('v5 is back in place (supabase/functions as committed).');
  const failed = checks.filter((c) => !c.ok);
  console.log(
    failed.length === 0
      ? `Rollback check passed: ${checks.length} of ${checks.length}.`
      : `Rollback check FAILED: ${failed.length} of ${checks.length}.`,
  );
  if (failed.length) process.exit(1);
}

main().catch((e) => {
  console.error(e instanceof Error ? e.message : e);
  process.exit(1);
});
