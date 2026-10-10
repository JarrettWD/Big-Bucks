// nightly: the nightly run (Stage 4, plan approved by Dad 2026-10-09).
//
// The database decides when to call this (nightly_kick, every 30 minutes from 4:30
// pm Alberta time until tonight's work is done) and calls it through its one sender.
// In order:
//   1. Prices: one daily-series call per fund that has missing closes covers every
//      missing trading day. A failed call is retried once; nothing is ever guessed.
//      At most 20 provider calls a day (the database keeps count).
//   2. Splits: the provider's split list, once a week per fund.
//   3. Jobs: run_daily through tonight's day (today from 4:30 pm, else yesterday).
//   4. Check: reconcile every day not yet checked.
// All the rules (which days are missing, whether a close may be stored, what a split
// means) are in the database; this only fetches and hands over.
//
// mode "backfill" (the manual GitHub workflow, once): the daily series (about 100
// trading days) and, older than that, the weekly series back to 2 years, marked as
// weekly. The TSX fund goes first, so a wrong provider symbol costs one call.
//
// On Dad's computer (PRICE_SOURCE=fake, never on hosted Supabase) the closes are made
// up, so no provider key is needed to test it.
//
// Runs with verify_jwt = false (supabase/config.toml): callers prove themselves with
// the x-nightly-key header (NIGHTLY_KEY). It uses the service role inside, and its
// replies hold only prices and job results, never anything personal.

import { createClient, type SupabaseClient } from 'npm:@supabase/supabase-js@2';
import {
  fakeCloses,
  isHosted,
  keyProblem,
  parseDaily,
  parseSplits,
  parseWeekly,
  providerSymbol,
  sameKey,
  weeklyForBackfill,
  type Close,
  type Fetched,
  type Split,
} from '../_shared/lib.ts';

interface PlanFund {
  fund_id: string;
  symbol: string;
  market: string;
  missing: string[];
  last_close: { date: string; close: string } | null;
  splits_due: boolean;
}
interface Plan {
  target: string;
  today: string;
  backfill_from: string;
  funds: PlanFund[];
}

type Kind = 'daily' | 'weekly' | 'splits';

const PROVIDER = 'https://www.alphavantage.co/query';
// The free key also limits calls per minute, so they go out at most about 5 a minute.
const SPACING_MS = 12_500;
const RETRY_MS = 15_000;
// The platform stops a function after 150 seconds. Past this, no new calls: the
// next kick (half an hour later) carries on.
const CALLS_UNTIL_MS = 95_000;

function reply(status: number, body: Record<string, unknown>): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

async function rpc<T>(
  db: SupabaseClient,
  fn: string,
  args: Record<string, unknown> = {},
): Promise<T> {
  const { data, error } = await db.rpc(fn, args);
  if (error) throw new Error(`${fn}: ${error.message}`);
  return data as T;
}

/** Fetches from the price provider (or the made-up source), within the day's budget. */
class Prices {
  private last = 0;
  private readonly started = Date.now();
  /** The budget is used up, or this run is out of time: no more calls. */
  stopped = false;

  constructor(
    private db: SupabaseClient,
    private apiKey: string | null,
  ) {}

  get fake(): boolean {
    return this.apiKey === null;
  }

  private async once(kind: Kind, fund: PlanFund): Promise<Fetched<unknown>> {
    const symbol = providerSymbol(fund.symbol, fund.market);
    if (!this.fake && Date.now() + SPACING_MS - this.started > CALLS_UNTIL_MS) {
      this.stopped = true;
      return {
        ok: false,
        kind: 'limit',
        message: 'Out of time for this run; the next one carries on.',
      };
    }
    const id = await rpc<number | null>(this.db, 'claim_price_call', {
      p_kind: kind,
      p_symbol: fund.symbol,
    });
    if (id === null) {
      this.stopped = true;
      return { ok: false, kind: 'limit', message: "Today's 20 price calls are used up." };
    }
    let result: Fetched<unknown>;
    if (this.fake) {
      result = {
        ok: true,
        value:
          kind === 'daily'
            ? fakeCloses(fund.symbol, fund.last_close, fund.missing)
            : ([] as unknown[]),
      };
    } else {
      const wait = this.last + SPACING_MS - Date.now();
      if (wait > 0) await sleep(wait);
      this.last = Date.now();
      const fn = { daily: 'TIME_SERIES_DAILY', weekly: 'TIME_SERIES_WEEKLY', splits: 'SPLITS' }[
        kind
      ];
      const params = new URLSearchParams({ function: fn, symbol, apikey: this.apiKey! });
      if (kind === 'daily') params.set('outputsize', 'compact');
      try {
        // The address holds the key: it's never logged or returned.
        const res = await fetch(`${PROVIDER}?${params}`, { signal: AbortSignal.timeout(30_000) });
        if (!res.ok) {
          result = { ok: false, kind: 'network', message: `The provider answered ${res.status}.` };
        } else {
          const json = await res.json();
          result =
            kind === 'daily'
              ? parseDaily(json)
              : kind === 'weekly'
                ? parseWeekly(json)
                : parseSplits(json);
        }
      } catch (e) {
        result = {
          ok: false,
          kind: 'network',
          message: `No answer from the provider (${(e as Error).name}).`,
        };
      }
    }
    await rpc(this.db, 'finish_price_call', {
      p_id: id,
      p_ok: result.ok,
      p_note: result.ok
        ? `${symbol}: ${(result.value as unknown[]).length} rows`
        : `${symbol}: ${result.message}`,
    });
    return result;
  }

  /** One retry, except for a wrong symbol, a used-up budget or a run out of time. */
  async get<T>(kind: Kind, fund: PlanFund): Promise<Fetched<T>> {
    let r = await this.once(kind, fund);
    if (!r.ok && r.kind !== 'bad_symbol' && !this.stopped) {
      if (!this.fake) await sleep(RETRY_MS);
      r = await this.once(kind, fund);
    }
    return r as Fetched<T>;
  }
}

async function nightly(db: SupabaseClient, prices: Prices) {
  const plan = await rpc<Plan>(db, 'nightly_plan');
  const report: Record<string, unknown>[] = [];

  // 1. Prices.
  for (const fund of plan.funds) {
    if (fund.missing.length === 0) continue;
    const r = await prices.get<Close[]>('daily', fund);
    if (!r.ok) {
      report.push({ fund: fund.fund_id, missing: fund.missing, error: r.message });
      continue;
    }
    const wanted = r.value.filter((c) => fund.missing.includes(c.date));
    const stored = await rpc<unknown>(db, 'store_closes', {
      p_fund_id: fund.fund_id,
      p_closes: wanted,
      p_source: 'daily',
    });
    const still = fund.missing.filter((d) => !wanted.some((c) => c.date === d));
    report.push({ fund: fund.fund_id, missing: fund.missing, stored, not_published_yet: still });
  }

  // 2. Splits, once a week per fund.
  const splits: Record<string, unknown>[] = [];
  for (const fund of plan.funds) {
    if (!fund.splits_due || prices.stopped) continue;
    const r = await prices.get<Split[]>('splits', fund);
    if (!r.ok) {
      splits.push({ fund: fund.fund_id, error: r.message });
      continue;
    }
    for (const s of r.value) {
      // A split the database refuses is reported; it never stops tonight's jobs.
      try {
        const status = await rpc<string>(db, 'record_split', {
          p_fund_id: fund.fund_id,
          p_date: s.date,
          p_ratio_from: s.from,
          p_ratio_to: s.to,
          p_source: prices.fake ? 'made-up source' : 'Alpha Vantage',
        });
        if (status !== 'history' && status !== 'already')
          splits.push({ fund: fund.fund_id, ...s, status });
      } catch (e) {
        splits.push({ fund: fund.fund_id, ...s, error: (e as Error).message.slice(0, 200) });
      }
    }
  }

  // 3. Jobs, then 4. the check.
  const jobs = await rpc<Record<string, unknown>>(db, 'run_daily', { p_through: plan.target });
  const reconciled = await rpc<Record<string, unknown>>(db, 'reconcile_through', {
    p_through: plan.target,
  });
  const status = await rpc<Record<string, unknown>>(db, 'nightly_status', { p_date: plan.target });

  return {
    mode: 'nightly',
    target: plan.target,
    prices: report,
    splits,
    jobs: {
      status: jobs.status,
      completed_through: jobs.completed_through,
      core_completed_through: jobs.core_completed_through,
    },
    reconciled,
    done: status.done,
  };
}

async function backfill(db: SupabaseClient, prices: Prices) {
  const plan = await rpc<Plan>(db, 'nightly_plan');
  const funds = [...plan.funds].sort((a, b) =>
    a.market === 'tsx' ? -1 : b.market === 'tsx' ? 1 : 0,
  );
  const report: Record<string, unknown>[] = [];
  for (const [i, fund] of funds.entries()) {
    const daily = await prices.get<Close[]>('daily', fund);
    if (!daily.ok) {
      report.push({
        fund: fund.fund_id,
        symbol: providerSymbol(fund.symbol, fund.market),
        error: daily.message,
      });
      // The first fund checks the provider symbol and the key: stop rather than waste calls.
      if (i === 0)
        return { mode: 'backfill', ok: false, stopped: 'the first fund failed', funds: report };
      continue;
    }
    const d = await rpc<unknown>(db, 'store_closes', {
      p_fund_id: fund.fund_id,
      p_closes: daily.value,
      p_source: 'daily',
    });
    let w: unknown = null;
    if (!prices.fake) {
      const weekly = await prices.get<Close[]>('weekly', fund);
      w = weekly.ok
        ? await rpc<unknown>(db, 'store_closes', {
            p_fund_id: fund.fund_id,
            p_closes: weeklyForBackfill(weekly.value, daily.value, plan.backfill_from),
            p_source: 'weekly_backfill',
          })
        : { error: weekly.message };
    }
    report.push({
      fund: fund.fund_id,
      symbol: providerSymbol(fund.symbol, fund.market),
      daily_from: daily.value[0]?.date,
      daily_to: daily.value.at(-1)?.date,
      daily: d,
      weekly: w,
    });
  }
  const ok = report.every(
    (r) => !('error' in r) && !(r.weekly && typeof r.weekly === 'object' && 'error' in r.weekly),
  );
  return { mode: 'backfill', ok, funds: report };
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return reply(405, { error: 'method' });

  const url = Deno.env.get('SUPABASE_URL') ?? '';
  const hosted = isHosted(url);
  const expected = Deno.env.get('NIGHTLY_KEY') ?? '';
  const bad = keyProblem(expected, hosted);
  if (bad) return reply(500, { error: bad });
  if (!sameKey(req.headers.get('x-nightly-key') ?? '', expected))
    return reply(401, { error: 'key' });

  let mode = 'nightly';
  try {
    const body = await req.json();
    if (body?.mode === 'backfill') mode = 'backfill';
  } catch {
    // An empty body means the nightly run.
  }

  const fake = Deno.env.get('PRICE_SOURCE') === 'fake';
  if (fake && hosted)
    return reply(500, { error: 'The made-up price source only runs on your own computer.' });
  const apiKey = fake ? null : (Deno.env.get('ALPHAVANTAGE_API_KEY') ?? '');
  if (apiKey === '') return reply(500, { error: 'ALPHAVANTAGE_API_KEY is not set (RUNBOOK).' });

  const db = createClient(url, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const prices = new Prices(db, apiKey);
  try {
    const result = mode === 'backfill' ? await backfill(db, prices) : await nightly(db, prices);
    return reply(result.mode === 'backfill' && !result.ok ? 502 : 200, result);
  } catch (e) {
    return reply(500, { mode, error: (e as Error).message.slice(0, 500) });
  }
});
