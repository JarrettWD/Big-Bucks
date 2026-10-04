// `npm run demo`: made-up data for the screens, on the LOCAL database only.
//
// 1. Refuses anything but the local Supabase, then resets the local database.
// 2. Creates a parent and two made-up kids with real logins: Robin (a regular
//    account) and Sky (a test account). PINs and the parent password are new
//    random values on every run.
// 3. Walks about 3 months, ending yesterday evening, with the time machine's
//    engine: its price generator and clock, every action through the real kid
//    and parent functions, then each day at 4:30 pm the closes, run_daily and
//    reconcile. It stops if reconcile ever finds a problem.
// 4. Hands the clock back to real time, sets up the parent's authenticator,
//    points the app at the local Supabase (.env.local), and prints the logins.
//    They're also saved to .demo-logins.local (gitignored) for `npm run demo:code`
//    and the end-to-end tests.

import { execSync } from 'node:child_process';
import { randomBytes, randomInt } from 'node:crypto';
import { writeFileSync } from 'node:fs';
import type { LocalDb, Who } from '../timemachine/db.ts';
import {
  NIGHTLY_RUN,
  addDays,
  addMonths,
  at,
  dayOf,
  daysFrom,
  type Day,
} from '../timemachine/model/calendar.ts';
import type { Holiday } from '../timemachine/model/model.ts';
import { generateCloses } from '../timemachine/prices.ts';
import {
  anonClient,
  connectLocal,
  createKid,
  createParent,
  writeAppEnv,
  type LocalKeys,
} from './local.ts';
import { nightly } from './nightly.ts';
import { totp } from './totp.ts';

export const DEMO_LOGINS_FILE = '.demo-logins.local';

export interface DemoLogins {
  created: string;
  parent: { email: string; password: string; totpSecret: string; displayName: string };
  kids: { username: string; pin: string; displayName: string; isTest: boolean }[];
}

const DAYS = 92;
const $ = (dollars: number) => String(Math.round(dollars * 100)); // whole cents, as text

interface Step {
  at: string; // Edmonton wall-clock time, 'YYYY-MM-DD HH:MM'
  why: string;
  run: () => Promise<void>;
}

const pin = () => String(randomInt(0, 1_000_000)).padStart(6, '0');

async function waitForAuth(keys: LocalKeys): Promise<void> {
  for (let i = 0; i < 60; i++) {
    try {
      const r = await fetch(`${keys.apiUrl}/auth/v1/health`, { headers: { apikey: keys.anonKey } });
      if (r.ok) return;
    } catch {
      /* not up yet */
    }
    await new Promise((res) => setTimeout(res, 1000));
  }
  throw new Error(
    'The local Auth service didn\'t come back after the reset. Try "npm run db:start".',
  );
}

async function main(): Promise<void> {
  // Guards first (local API, is_local_dev), then reset.
  const first = await connectLocal();
  await first.db.close();
  console.log('Resetting the local database (this wipes local data, never production)…');
  execSync('npx supabase db reset', { stdio: 'ignore' });
  const { keys, db, admin } = await connectLocal();
  await waitForAuth(keys);

  try {
    const [{ today }] = await db.q<{ today: string }>(`select public.app_today()::text as today`);
    const T: Day = today;
    const S: Day = addDays(T, -DAYS);
    const yesterday = addDays(T, -1);
    const on = (offset: number, hhmm: string) => at(addDays(S, offset), hhmm);
    console.log(`Simulating ${S} to ${yesterday} (today is ${T})…`);

    // People ------------------------------------------------------------------
    await db.setClock(at(S, '08:00'));
    const logins: DemoLogins = {
      created: new Date().toISOString(),
      parent: {
        email: 'parent@demo.example',
        password: randomBytes(18).toString('base64url'),
        totpSecret: '',
        displayName: 'Dad',
      },
      kids: [
        { username: 'demo_robin', pin: pin(), displayName: 'Robin', isTest: false },
        { username: 'demo_sky', pin: pin(), displayName: 'Sky', isTest: true },
      ],
    };
    const parent = await createParent(admin, {
      email: logins.parent.email,
      password: logins.parent.password,
      username: 'demo_parent',
      displayName: logins.parent.displayName,
    });
    const kidUser: string[] = [];
    for (const k of logins.kids) kidUser.push((await createKid(admin, k)).userId);
    const P: Who = { role: 'authenticated', sub: parent.userId, aal: 'aal2' };
    const A: Who = { role: 'authenticated', sub: kidUser[0], aal: 'aal1' };
    const B: Who = { role: 'authenticated', sub: kidUser[1], aal: 'aal1' };

    // Prices: 45 days of history before the start, so 30-day sparklines are full.
    const holidays: Holiday[] = (
      await db.q<{
        market: 'nyse' | 'tsx';
        d: string;
        kind: 'closed' | 'early_close';
        closes_at: string | null;
      }>(
        `select market::text, holiday_date::text as d, kind::text, to_char(closes_at, 'HH24:MI') as closes_at
           from public.market_holidays`,
      )
    ).map((h) => ({ market: h.market, date: h.d, kind: h.kind, closesAt: h.closes_at }));
    const closes = generateCloses(holidays, addDays(S, -45), yesterday);

    // Sky buys the TSX 3 market days before the end, and the TSX then eases down
    // (1.5% a day, under the 2% market-move note), so her TSX is worth less than she
    // paid and Buy / Sell shows its "worth less than you paid" warning. Made-up
    // prices; closes are exact decimals with 3 places ("40.123").
    const tsxCloses = closes.filter((c) => c.fund === 'tsx');
    const skyTsxBuy = tsxCloses[tsxCloses.length - 4];
    const buyMills = BigInt(skyTsxBuy.close.replace('.', ''));
    [985n, 970n, 955n].forEach((perMille, i) => {
      const m = (buyMills * perMille) / 1000n;
      tsxCloses[tsxCloses.length - 3 + i].close =
        `${m / 1000n}.${(m % 1000n).toString().padStart(3, '0')}`;
    });
    // One big day for the Graphs tab's market-move notes: about 15 market days
    // before the end, the Nasdaq-100 jumps 3% and stays up (every later close is
    // 3% higher too, so the next day isn't a big drop). Made-up prices.
    const nasdaqCloses = closes.filter((c) => c.fund === 'nasdaq100');
    nasdaqCloses.slice(nasdaqCloses.length - 15).forEach((c) => {
      const m = (BigInt(c.close.replace('.', '')) * 1030n) / 1000n;
      c.close = `${m / 1000n}.${(m % 1000n).toString().padStart(3, '0')}`;
    });
    const published = new Set<string>();
    const publishUpTo = async (moment: string) => {
      for (const c of closes) {
        const key = `${c.fund}|${c.day}`;
        if (published.has(key) || c.publishedAt > moment) continue;
        await db.q(
          `insert into public.fund_prices (fund_id, price_date, close) values ($1, $2, $3)`,
          [c.fund, c.day, c.close],
        );
        published.add(key);
      }
    };
    await publishUpTo(at(S, '08:00'));

    // The script --------------------------------------------------------------
    const ids = new Map<string, number>();
    const steps: Step[] = [];
    const act = (
      moment: string,
      why: string,
      who: Who,
      sql: string,
      params: unknown[],
      label?: string,
    ) =>
      steps.push({
        at: moment,
        why,
        run: async () => {
          const r = await db.call(who, sql, params);
          if (!r.ok) throw new Error(`Demo step "${why}" at ${moment} was refused: ${r.error}`);
          if (label) ids.set(label, Number(r.value));
        },
      });
    const id = (label: string) => {
      const v = ids.get(label);
      if (v === undefined) throw new Error(`demo: no id for ${label}`);
      return v;
    };
    const later = (moment: string, why: string, run: () => Promise<void>) =>
      steps.push({ at: moment, why, run });
    const maturityOf = async (gic: number): Promise<Day> =>
      (
        await db.q<{ d: string }>(
          `select maturity_date::text as d from public.gic_holdings where id = $1`,
          [gic],
        )
      )[0].d;

    // Day 0: first deposits, and the Wish List switched on for test accounts only.
    act(
      on(0, '08:30'),
      'Wish List on for test accounts',
      P,
      `select public.set_setting('feature:wishlist', 'test')`,
      [],
    );
    act(
      on(0, '09:00'),
      'Robin asks to deposit $600',
      A,
      'select public.request_deposit($1)',
      [$(600)],
      'dA1',
    );
    act(
      on(0, '09:05'),
      'Sky asks to deposit $400',
      B,
      'select public.request_deposit($1)',
      [$(400)],
      'dB1',
    );
    later(on(0, '10:00'), 'Dad approves both', async () => {
      for (const l of ['dA1', 'dB1']) {
        const r = await db.call(P, 'select public.approve_request($1)', [id(l)]);
        if (!r.ok) throw new Error(r.error);
      }
    });

    // Day 1–3: a GIC ladder start and the first fund buys.
    act(on(1, '09:00'), 'Robin: 1-month GIC', A, 'select public.buy_gic($1, 1)', [$(100)], 'gA1');
    act(on(1, '09:05'), 'Robin: 6-month GIC', A, 'select public.buy_gic($1, 6)', [$(150)], 'gA6');
    act(
      on(1, '09:10'),
      'Robin buys the Dow',
      A,
      `select public.request_trade('dow', 'buy', $1, false)`,
      [$(100)],
    );
    act(
      on(1, '09:15'),
      'Sky buys the TSX',
      B,
      `select public.request_trade('tsx', 'buy', $1, false)`,
      [$(60)],
    );
    act(
      on(2, '09:00'),
      'Robin buys the Nasdaq-100',
      A,
      `select public.request_trade('nasdaq100', 'buy', $1, false)`,
      [$(80)],
    );
    act(on(3, '09:00'), 'Sky: 6-month GIC', B, 'select public.buy_gic($1, 6)', [$(50)], 'gB6');
    act(
      on(10, '18:00'),
      'Sky buys the Dow (settles next close)',
      B,
      `select public.request_trade('dow', 'buy', $1, false)`,
      [$(50)],
    );

    // Robin's 1-month GIC matures; she renews it, and next time moves it to savings.
    later(on(1, '09:30'), 'schedule the renewal', async () => {
      const m1 = await maturityOf(id('gA1'));
      act(
        at(addDays(m1, 1), '09:00'),
        'Robin renews her matured GIC',
        A,
        `select public.choose_maturity($1, 'renew')`,
        [id('gA1')],
        'gA1r',
      );
      later(at(addDays(m1, 1), '09:30'), 'schedule the move to savings', async () => {
        const m2 = await maturityOf(id('gA1r'));
        act(
          at(addDays(m2, 1), '09:00'),
          'Robin moves her renewed GIC to savings',
          A,
          `select public.choose_maturity($1, 'to_savings')`,
          [id('gA1r')],
        );
      });
    });

    // A partial sale, a withdrawal (approved after the 24 hours), more deposits and a decline.
    act(
      on(20, '09:00'),
      'Robin sells $30 of the Dow',
      A,
      `select public.request_trade('dow', 'sell', $1, false)`,
      [$(30)],
    );
    act(
      on(25, '09:00'),
      'Sky asks to withdraw $20',
      B,
      'select public.request_withdrawal($1)',
      [$(20)],
      'wB1',
    );
    later(on(26, '10:00'), 'Dad approves the withdrawal (25 hours later)', async () => {
      const r = await db.call(P, 'select public.approve_request($1)', [id('wB1')]);
      if (!r.ok) throw new Error(r.error);
    });
    act(
      on(40, '09:00'),
      'Robin asks to deposit $200',
      A,
      'select public.request_deposit($1)',
      [$(200)],
      'dA2',
    );
    later(on(40, '18:00'), 'Dad approves', async () => {
      const r = await db.call(P, 'select public.approve_request($1)', [id('dA2')]);
      if (!r.ok) throw new Error(r.error);
    });
    act(
      on(41, '09:00'),
      'Sky asks to deposit $500',
      B,
      'select public.request_deposit($1)',
      [$(500)],
      'dB2',
    );
    later(on(42, '09:00'), 'Dad declines, with a reason', async () => {
      const r = await db.call(P, 'select public.decline_request($1, $2)', [
        id('dB2'),
        "Let's talk about this one at dinner first.",
      ]);
      if (!r.ok) throw new Error(r.error);
    });

    // A rate cut with a week's notice, and a question about it.
    act(
      on(45, '10:00'),
      'Dad lowers the savings rate (in 7 days)',
      P,
      `select public.add_rate('savings', null, 1.75, $1, $2)`,
      [addDays(S, 52), 'The Bank of Canada lowered its rate, so savings pays a little less.'],
    );
    act(
      on(55, '19:00'),
      'Robin asks a question',
      A,
      'select public.ask_question($1)',
      ['Why did my savings interest go down?'],
      'q1',
    );
    later(on(56, '08:00'), 'Dad answers', async () => {
      const r = await db.call(P, 'select public.answer_question($1, $2)', [
        id('q1'),
        "The savings rate went down a little. Your GICs keep the rate they started with, so they're not affected.",
      ]);
      if (!r.ok) throw new Error(r.error);
    });

    act(
      on(57, '09:00'),
      'Robin buys the TSX',
      A,
      `select public.request_trade('tsx', 'buy', $1, false)`,
      [$(50)],
    );
    act(
      on(58, '09:00'),
      'Sky buys the Nasdaq-100',
      B,
      `select public.request_trade('nasdaq100', 'buy', $1, false)`,
      [$(40)],
    );
    act(
      on(70, '09:00'),
      'Sky sells all her TSX',
      B,
      `select public.request_trade('tsx', 'sell', null, true)`,
      [],
    );

    act(
      at(skyTsxBuy.day, '09:00'),
      'Sky buys the TSX again, just before it eases down',
      B,
      `select public.request_trade('tsx', 'buy', $1, false)`,
      [$(60)],
    );

    // A 1-month GIC that matured a couple of days ago and is waiting for Robin's choice.
    const waitBuy = addMonths(addDays(T, -2), -1);
    const waitMature = addMonths(waitBuy, 1);
    if (waitMature > yesterday || waitMature < addDays(T, -6))
      throw new Error(`demo: the waiting GIC would mature on ${waitMature}`);
    act(
      at(waitBuy, '09:30'),
      'Robin: a 1-month GIC (matures 2 days ago)',
      A,
      'select public.buy_gic($1, 1)',
      [$(50)],
    );

    // Last days: another rate cut announced for next week, and two requests waiting for Dad.
    act(
      at(addDays(T, -2), '10:00'),
      'Dad announces another cut, next week',
      P,
      `select public.add_rate('savings', null, 1.5, $1, $2)`,
      [addDays(T, 5), 'The Bank of Canada lowered its rate again.'],
    );
    // Two requests asked 6 days ago: they run out of time tomorrow, so the dashboard
    // warns about them (Sky's, a test account, folded away).
    act(
      at(addDays(T, -6), '18:00'),
      'Robin asks to deposit $25 (runs out of time tomorrow)',
      A,
      'select public.request_deposit($1)',
      [$(25)],
    );
    act(
      at(addDays(T, -6), '18:30'),
      'Sky asks to deposit $8 (runs out of time tomorrow)',
      B,
      'select public.request_deposit($1)',
      [$(8)],
    );
    act(
      at(addDays(T, -2), '16:00'),
      'Robin asks to withdraw $10 (past its 24 hours, ready for Dad)',
      A,
      'select public.request_withdrawal($1)',
      [$(10)],
    );
    act(
      at(yesterday, '18:30'),
      'Robin asks about her latest savings interest (waiting for Dad)',
      A,
      `select public.ask_question($1, (select max(t.id) from public.transactions t
                                        where t.type = 'interest' and t.vehicle = 'savings'))`,
      ['Why was my interest smaller this month?'],
    );
    act(
      at(yesterday, '19:00'),
      'Robin asks to deposit $50 (waiting for Dad)',
      A,
      'select public.request_deposit($1)',
      [$(50)],
    );
    act(
      at(yesterday, '19:30'),
      'Sky asks to withdraw $15 (24-hour wait)',
      B,
      'select public.request_withdrawal($1)',
      [$(15)],
    );

    // The walk ----------------------------------------------------------------
    const done = new Set<Step>();
    const runSteps = async (day: Day, before: string | null, from: string | null) => {
      for (;;) {
        const next = steps
          .filter((s) => !done.has(s) && dayOf(s.at) === day)
          .filter((s) => (before ? s.at < before : true) && (from ? s.at >= from : true))
          .sort((a, b) => (a.at < b.at ? -1 : 1))[0];
        if (!next) return;
        done.add(next);
        await db.setClock(next.at);
        await next.run();
      }
    };
    let reconciled = 0;
    for (const day of daysFrom(S, yesterday)) {
      const runAt = at(day, NIGHTLY_RUN);
      await runSteps(day, runAt, null);
      await db.setClock(runAt);
      await publishUpTo(runAt);
      const r = await nightly(db, day);
      if (r.status !== 'ok' || r.completedThrough !== day)
        throw new Error(`run_daily(${day}) didn't finish: ${r.status}`);
      if (r.problems.length)
        throw new Error(`reconcile found a problem:\n${r.problems.join('\n')}`);
      reconciled += r.reconciled.length;
      await runSteps(day, null, runAt);
    }
    const missed = steps.filter((s) => !done.has(s));
    if (missed.length)
      throw new Error(`demo: steps never ran: ${missed.map((s) => `${s.at} ${s.why}`).join('; ')}`);

    // Like real kids, they've read the notices from more than 3 days ago.
    for (const kid of [A, B]) {
      const r = await db.call(
        kid,
        'select public.mark_notices_read(array(select id from public.notifications where created_at < $1))',
        [at(addDays(T, -3), '00:00')],
      );
      if (!r.ok) throw new Error(`demo: marking notices read: ${r.error}`);
    }

    // Back to real time.
    await db.setClock('');
    // One withdrawal asked for right now, so the Approvals screen shows a live 24-hour countdown.
    const w = await db.call(A, 'select public.request_withdrawal($1)', [$(5)]);
    if (!w.ok) throw new Error(`demo: the countdown withdrawal: ${w.error}`);
    const [alerts] = await db.q<{ n: string }>(`select count(*)::text as n from public.alerts`);
    if (alerts.n !== '0') throw new Error(`demo: ${alerts.n} alerts were raised`);

    // The parent's authenticator, so the demo parent can sign in with a code.
    logins.parent.totpSecret = await enrolParent(keys, logins.parent.email, logins.parent.password);

    writeAppEnv(keys);
    writeFileSync(DEMO_LOGINS_FILE, JSON.stringify(logins, null, 2) + '\n');
    await printSummary(db, logins, reconciled);
  } finally {
    await db.close();
  }
}

async function enrolParent(keys: LocalKeys, email: string, password: string): Promise<string> {
  const c = anonClient(keys);
  const s = await c.auth.signInWithPassword({ email, password });
  if (s.error) throw new Error(`demo parent sign-in: ${s.error.message}`);
  const e = await c.auth.mfa.enroll({ factorType: 'totp', friendlyName: 'Big Bucks demo' });
  if (e.error) throw new Error(`demo parent authenticator: ${e.error.message}`);
  const v = await c.auth.mfa.challengeAndVerify({
    factorId: e.data.id,
    code: totp(e.data.totp.secret),
  });
  if (v.error) throw new Error(`demo parent authenticator check: ${v.error.message}`);
  await c.auth.signOut();
  return e.data.totp.secret;
}

const fmt = (c: string) => {
  const v = BigInt(c);
  const whole = (v / 100n).toString().replace(/\B(?=(\d{3})+(?!\d))/g, ',');
  return `$${whole}.${(v % 100n).toString().padStart(2, '0')}`;
};

async function printSummary(db: LocalDb, logins: DemoLogins, reconciled: number): Promise<void> {
  const rows = await db.q<{
    display_name: string;
    total_worth_cents: string;
    savings_cents: string;
  }>(
    `select p.display_name, b.total_worth_cents::text, b.savings_cents::text
       from public.account_balances b join public.profiles p on p.account_id = b.account_id order by p.display_name`,
  );
  const [counts] = await db.q<Record<string, string>>(
    `select (select count(*) from public.transactions)::text as lines,
            (select count(*) from public.notifications)::text as notices,
            (select count(*) from public.requests where status = 'pending')::text as pending`,
  );
  console.log(
    `\nDemo ready: ${counts.lines} ledger lines, ${counts.notices} notices, ${counts.pending} requests waiting for Dad.`,
  );
  console.log(`Reconciled ${reconciled} days with no problems.`);
  for (const r of rows)
    console.log(
      `  ${r.display_name}: total worth ${fmt(r.total_worth_cents)}, savings ${fmt(r.savings_cents)}`,
    );
  console.log('\nDemo logins (local only; new every run):');
  for (const k of logins.kids)
    console.log(
      `  ${k.displayName.padEnd(6)} username ${k.username.padEnd(11)} PIN ${k.pin}${k.isTest ? '   (test account)' : ''}`,
    );
  console.log(`  Parent  email ${logins.parent.email}   password ${logins.parent.password}`);
  console.log(
    '          authenticator code: run "npm run demo:code" (or add this key to an authenticator app:',
  );
  console.log(`          ${logins.parent.totpSecret})`);
  console.log(`\nSaved to ${DEMO_LOGINS_FILE} (not committed). Start the app with "npm run dev",`);
  console.log('then open http://127.0.0.1:5173/Big-Bucks/ in Chrome.');
}

main().catch((e) => {
  console.error((e as Error).message);
  process.exitCode = 1;
});
