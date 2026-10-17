// The nightly run, as the time machine does it: run_daily through a date, then
// reconcile every date since the last check, then (stage 10) the badge check in its
// own call, as the nightly function does. Shared by the demo and jobs:local.

import type { LocalDb, Who } from '../timemachine/db.ts';
import { addDays, daysFrom, type Day } from '../timemachine/model/calendar.ts';

const SERVER: Who = { role: 'service_role' };

export interface NightlyResult {
  /** run_daily's status: ok, waiting or failed. */
  status: string;
  completedThrough: Day | null;
  reconciled: Day[];
  /** Plain descriptions of anything reconcile found. Empty means clean. */
  problems: string[];
  /** The badge check's status (stage 10): ok or failed. Never affects the rest. */
  badges: string;
}

export async function nightly(db: LocalDb, day: Day): Promise<NightlyResult> {
  const r = await db.call(SERVER, 'select public.run_daily($1)', [day]);
  if (!r.ok) throw new Error(`run_daily(${day}) failed: ${r.error}`);
  const res = r.value as { status: string; completed_through: string | null };

  const [last] = await db.q<{ d: string | null }>(
    `select max(run_for_date)::text as d from public.job_runs where job = 'reconcile'`,
  );
  const from = last.d ? addDays(last.d, 1) : day;
  const reconciled: Day[] = [];
  const problems: string[] = [];
  for (const d of from <= day ? daysFrom(from, day) : []) {
    const rc = await db.call(SERVER, 'select public.reconcile($1)', [d]);
    if (!rc.ok) throw new Error(`reconcile(${d}) failed: ${rc.error}`);
    reconciled.push(d);
    const v = rc.value as { status: string; problems: unknown[] };
    if (v.status !== 'ok') problems.push(`${d}: ${JSON.stringify(v.problems).slice(0, 600)}`);
  }
  const b = await db.call(SERVER, 'select public.check_badges_through($1)', [day]);
  const badges = b.ok ? (b.value as { status: string }).status : 'failed';
  return {
    status: res.status,
    completedThrough: res.completed_through,
    reconciled,
    problems,
    badges,
  };
}
