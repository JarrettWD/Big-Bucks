// `npm run jobs:local`: tonight's nightly run, by hand, on the LOCAL database.
//
// Until stage 4 nothing runs the nightly job on this computer, so after the demo
// the figures stand still. This does what the real job will do at 4:30 pm:
//   1. adds synthetic closes for each fund's trading days up to the run date
//      (local only; real closes come from the price provider in stage 4);
//   2. runs run_daily through that date (catching up any missed days);
//   3. reconciles every day since the last check.
// Before 4:30 pm Alberta time it runs through yesterday, because today's markets
// haven't closed yet and no trade may settle on a close that doesn't exist.

import { connectLocal } from './local.ts';
import { addSyntheticCloses } from './closes.ts';
import { nightly } from './nightly.ts';
import { NIGHTLY_RUN, addDays } from '../timemachine/model/calendar.ts';

async function main(): Promise<void> {
  const { db } = await connectLocal();
  try {
    const [now] = await db.q<{ today: string; hhmm: string; override: string | null }>(
      `select public.app_today()::text as today,
              to_char(public.edmonton_local(public.app_now()), 'HH24:MI') as hhmm,
              (select nullif(value, '') from public.settings where key = 'clock_override'
                order by id desc limit 1) as override`,
    );
    if (now.override) console.log(`Note: the app clock is set to ${now.override} (time machine).`);
    const target = now.hhmm >= NIGHTLY_RUN ? now.today : addDays(now.today, -1);
    console.log(
      now.hhmm >= NIGHTLY_RUN
        ? `It's ${now.hhmm} in Edmonton: running tonight's jobs for today, ${target}.`
        : `It's ${now.hhmm} in Edmonton, before the 4:30 pm run, so running through yesterday, ${target}.`,
    );

    const added = await addSyntheticCloses(db, target);
    console.log(`Added ${added} synthetic closes.`);
    const r = await nightly(db, target);
    console.log(
      `run_daily: ${r.status}${r.completedThrough ? `, all jobs done through ${r.completedThrough}` : ''}.`,
    );
    console.log(
      r.reconciled.length
        ? `Reconciled ${r.reconciled[0]}${r.reconciled.length > 1 ? ` to ${r.reconciled.at(-1)}` : ''}: ${r.problems.length ? 'PROBLEMS FOUND' : 'all clean'}.`
        : 'Nothing new to reconcile.',
    );
    for (const p of r.problems) console.log(`  ${p}`);
    if (r.status !== 'ok' || r.problems.length) process.exitCode = 1;
  } finally {
    await db.close();
  }
}

main().catch((e) => {
  console.error((e as Error).message);
  process.exitCode = 1;
});
