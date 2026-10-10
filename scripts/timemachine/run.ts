// `npm run timemachine`: a simulated year against the LOCAL database, checked to
// the cent against the independent reference model. See docs/BUILD-PLAN.md, stage 3.
//
// 1. Resets the local database (made-up data only; production is never touched).
// 2. Creates a parent and two made-up kids (A regular, B a test account).
// 3. Walks the clock a day at a time from Jul 1, 2027 to Jul 1, 2028: the scripted
//    actions, then at 4:30 pm (NIGHTLY_RUN) the day's closes, run_daily and reconcile.
// 4. Compares what the screens would show (nearest cent) every day, then every
//    posted amount (rounded up), every accrual and the graph history.
// 5. Injects deliberate faults in transactions that are rolled back, and checks
//    reconcile catches each one.
// 6. Prints a plain-English summary and saves it to docs/TIMEMACHINE-REPORT.md.
// 7. Resets the local database again (add `-- --keep` to keep the simulated year).

import { execSync } from 'node:child_process';
import { writeFileSync } from 'node:fs';
import { LocalDb, type Who } from './db.ts';
import { Q } from './model/rational.ts';
import { NIGHTLY_RUN, addDays, at, dayOf, daysFrom, type Day } from './model/calendar.ts';
import {
  FUNDS,
  Model,
  type Action,
  type FundId,
  type Holiday,
  type Posting,
} from './model/model.ts';
import { generateCloses, LATE_CLOSE, LATE_CLOSE_2, LATE_CLOSE_3, SPLIT } from './prices.ts';
import { END_DAY, MISSED, START, STEPS, type Check, type Step } from './scenario.ts';

const KIDS = ['A', 'B'] as const;
const PARENT_ID = '00000000-0000-0000-0000-0000000000aa';
const KID_USER: Record<string, string> = {
  A: '00000000-0000-0000-0000-0000000000a1',
  B: '00000000-0000-0000-0000-0000000000b1',
};
const SERVER: Who = { role: 'service_role' };
const PARENT: Who = { role: 'authenticated', sub: PARENT_ID, aal: 'aal2' };
const kidWho = (k: string): Who => ({ role: 'authenticated', sub: KID_USER[k], aal: 'aal1' });

// ------------------------------------------------------------------ results

interface CheckResult {
  name: string;
  passed: boolean;
  detail: string;
}
const results: CheckResult[] = [];
const mismatches = new Map<string, string[]>(); // check name -> first few differences
const mismatchCount = new Map<string, number>();

function differ(check: string, msg: string): void {
  mismatchCount.set(check, (mismatchCount.get(check) ?? 0) + 1);
  const list = mismatches.get(check) ?? [];
  if (list.length < 8) list.push(msg);
  mismatches.set(check, list);
}

function record(name: string, passed: boolean, detail: string): void {
  results.push({ name, passed, detail });
}

const cents = (c: bigint | number | string): string => {
  const v = BigInt(c);
  const neg = v < 0n;
  const a = neg ? -v : v;
  const whole = (a / 100n).toString().replace(/\B(?=(\d{3})+(?!\d))/g, ',');
  return `${neg ? '−' : ''}$${whole}.${(a % 100n).toString().padStart(2, '0')}`;
};

// ------------------------------------------------------------------ main

async function main(): Promise<void> {
  // Guard first (refuses anything but the local database), then reset it.
  (await LocalDb.connect()).close();
  console.log('Resetting the local database…');
  execSync('npx supabase db reset', { stdio: 'ignore' });
  const db = await LocalDb.connect();
  const started = Date.now();

  try {
    const holidays: Holiday[] = (
      await db.q<{
        market: 'nyse' | 'tsx';
        d: string;
        kind: 'closed' | 'early_close';
        closes_at: string | null;
      }>(
        `select market::text, holiday_date::text as d, kind::text, to_char(closes_at, 'HH24:MI') as closes_at from public.market_holidays`,
      )
    ).map((h) => ({ market: h.market, date: h.d, kind: h.kind, closesAt: h.closes_at }));

    // People ----------------------------------------------------------------
    await db.setClock(START);
    const accounts: Record<string, string> = {};
    await db.q(`insert into auth.users (id, email) values ($1, 'parent@timemachine.invalid')`, [
      PARENT_ID,
    ]);
    await db.q(
      `insert into public.profiles (user_id, role, username, display_name) values ($1, 'parent', 'tm_parent', 'Parent')`,
      [PARENT_ID],
    );
    for (const k of KIDS) {
      await db.q(`insert into auth.users (id, email) values ($1, $2)`, [
        KID_USER[k],
        `kid_${k.toLowerCase()}@timemachine.invalid`,
      ]);
      const [{ id }] = await db.q<{ id: string }>(
        `insert into public.accounts (name, is_test) values ($1, $2) returning id`,
        [`Kid ${k}`, k === 'B'],
      );
      accounts[k] = id;
      await db.q(
        `insert into public.profiles (user_id, role, account_id, username, display_name) values ($1, 'investor', $2, $3, $4)`,
        [KID_USER[k], id, `tm_kid_${k.toLowerCase()}`, `Kid ${k}`],
      );
    }
    const kidOfAccount = new Map(Object.entries(accounts).map(([k, id]) => [id, k]));

    // Prices ----------------------------------------------------------------
    const closes = generateCloses(holidays, '2027-06-01', END_DAY);
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
    await publishUpTo(START);
    await db.q(
      `insert into public.fund_splits (fund_id, split_date, ratio_from, ratio_to, source) values ($1, $2, $3, $4, 'time machine')`,
      [SPLIT.fund, SPLIT.day, Number(SPLIT.from), Number(SPLIT.to)],
    );

    // The model -------------------------------------------------------------
    const model = new Model(START, holidays);
    for (const k of KIDS) model.openAccount(k);
    for (const c of closes) model.addClose(c.fund, c.day, c.close, c.publishedAt);
    model.addSplit(SPLIT.fund, SPLIT.day, SPLIT.from, SPLIT.to);
    model.skipNights(daysFrom(MISSED.from, MISSED.to));

    const reqId = new Map<string, number>(); // label -> request id
    const gicId = new Map<string, number>(); // label -> gic id
    const gicLabel = new Map<number, string>();
    const setGic = (label: string, id: number) => {
      gicId.set(label, id);
      gicLabel.set(id, label);
    };

    let actionsAgreed = 0;
    let expectationsMet = 0;
    let expectations = 0;
    let snapshotDays = 0;
    const runsWaiting: string[] = [];
    // The nightly runs each late close holds up (in date order).
    const expectedWaiting = [LATE_CLOSE, LATE_CLOSE_3, LATE_CLOSE_2].flatMap((l) =>
      l.waits.map((d) => `${d}: waiting`),
    );
    let reconcileRuns = 0;
    let reconcileProblems = 0;
    const reconcileProblemList: string[] = [];
    let lastReconciled: Day | null = null;

    // One scripted step, on both sides.
    const doStep = async (s: Step) => {
      await db.setClock(s.at);
      if (
        typeof s.do !== 'function' &&
        (s.do.kind === 'request_status' || s.do.kind === 'health')
      ) {
        model.advanceTo(s.at);
        await runCheck(s, s.do);
        return;
      }
      const action: Action = typeof s.do === 'function' ? s.do(model) : (s.do as Action);
      const m = model.act(s.at, action);
      const d = await dbAction(action);
      if (m.ok === d.ok) actionsAgreed++;
      else
        differ(
          'Actions accepted or refused the same way',
          `${s.at} ${action.kind} (${s.why}): model ${m.ok ? 'accepted' : `refused (${m.reason})`}, database ${d.ok ? 'accepted' : `refused (${d.error})`}`,
        );
      if (s.expect) {
        expectations++;
        const want = s.expect === 'ok';
        if (m.ok === want && d.ok === want) expectationsMet++;
        else
          differ(
            'Scripted refusals and approvals happened as planned',
            `${s.at} ${action.kind} (${s.why}): expected ${s.expect}, model ${m.ok ? 'ok' : 'refused'}, database ${d.ok ? 'ok' : 'refused'}`,
          );
      }
    };

    const runCheck = async (s: Step, c: Check) => {
      expectations++;
      if (c.kind === 'request_status') {
        const [row] = await db.q<{ status: string }>(
          `select status::text from public.requests where id = $1`,
          [reqId.get(c.label)],
        );
        const ms = model.requestStatus(c.label);
        if (row?.status === c.status && ms === c.status) expectationsMet++;
        else
          differ(
            'Scripted refusals and approvals happened as planned',
            `${s.at} ${c.label}: expected ${c.status}, database ${row?.status}, model ${ms}`,
          );
      } else {
        const r = await db.call(SERVER, 'select public.health_check()');
        const ok = r.ok && (r.value as { ok: boolean }).ok;
        if (ok === c.ok) expectationsMet++;
        else
          differ(
            'Scripted refusals and approvals happened as planned',
            `${s.at} health_check ok=${ok}, expected ${c.ok}: ${JSON.stringify(r.ok ? r.value : r.error)}`,
          );
      }
    };

    // Scheduled rate and setting changes the scenario may cancel, by label.
    const changeId = new Map<string, { kind: 'rate' | 'setting'; id: number }>();

    const dbAction = async (a: Action): Promise<{ ok: true } | { ok: false; error: string }> => {
      const res = await (async () => {
        switch (a.kind) {
          case 'sign_agreement': {
            // She signs, then Dad countersigns: no money moves before both have
            // (pre-launch audit, 2026-10-08).
            const signed = await db.call(kidWho(a.kid), 'select public.sign_agreement(1)');
            if (!signed.ok) return signed;
            return db.call(PARENT, 'select public.countersign_agreement($1, 1)', [accounts[a.kid]]);
          }
          case 'deposit':
            return db.call(kidWho(a.kid), 'select public.request_deposit($1)', [
              a.cents.toString(),
            ]);
          case 'withdraw':
            return db.call(kidWho(a.kid), 'select public.request_withdrawal($1)', [
              a.cents.toString(),
            ]);
          case 'approve':
            return db.call(PARENT, 'select public.approve_request($1)', [reqId.get(a.label) ?? -1]);
          case 'decline':
            return db.call(PARENT, 'select public.decline_request($1, $2)', [
              reqId.get(a.label) ?? -1,
              a.reason,
            ]);
          case 'buy_gic':
            return db.call(kidWho(a.kid), 'select public.buy_gic($1, $2)', [
              a.cents.toString(),
              a.term,
            ]);
          case 'break_gic':
            return db.call(kidWho(kidOfGic(a.gic)), 'select public.break_gic($1)', [
              gicId.get(a.gic),
            ]);
          case 'choose':
            return db.call(
              kidWho(kidOfGic(a.gic)),
              'select public.choose_maturity($1, $2::public.maturity_choice, $3)',
              [gicId.get(a.gic), a.choice, a.term ?? null],
            );
          case 'buy':
            return db.call(kidWho(a.kid), `select public.request_trade($1, 'buy', $2, false)`, [
              a.fund,
              a.cents.toString(),
            ]);
          case 'sell':
            return db.call(kidWho(a.kid), `select public.request_trade($1, 'sell', $2, false)`, [
              a.fund,
              a.cents.toString(),
            ]);
          case 'sell_all':
            return db.call(kidWho(a.kid), `select public.request_trade($1, 'sell', null, true)`, [
              a.fund,
            ]);
          case 'add_rate':
            return db.call(
              PARENT,
              'select public.add_rate($1::public.vehicle, $2, $3, $4, $5, $6)',
              [
                a.rate.vehicle,
                a.rate.term,
                a.rate.rate,
                a.rate.effective,
                'Time machine rate change',
                a.rate.end ?? null,
              ],
            );
          case 'set_cap':
            return db.call(
              PARENT,
              `select public.set_setting('deposit_cap_cents', $1, $2, 'Time machine cap change')`,
              [a.cents.toString(), a.effective],
            );
          case 'set_expiry':
            return db.call(
              PARENT,
              `select public.set_setting('request_expiry_days', $1, $2, 'Time machine expiry change')`,
              [String(a.days), a.effective],
            );
          case 'set_yield':
            return db.call(
              PARENT,
              `select public.set_setting($1, $2, $3, 'Time machine yield change')`,
              [`dividend_yield:${a.fund}`, a.yield, a.effective],
            );
          case 'correct': {
            // Linked to her latest line of that kind, as Dad would pick it from her history.
            const line = await db.call(
              PARENT,
              `select item_key from public.my_activity($1, 200) where kind = $2 order by at desc limit 1`,
              [accounts[a.kid], a.line],
            );
            if (!line.ok || !line.value) throw new Error(`no ${a.line} line for kid ${a.kid}`);
            const args = [
              accounts[a.kid],
              line.value,
              null,
              a.direction,
              a.amount,
              'Time machine fix',
            ];
            // The extra check, as the screen gives it: the same amount again (a tap for a
            // reduction, the amount typed a second time for an addition over $100).
            return db.call(
              PARENT,
              'select public.correct_savings($1, $2, $3, $4, $5, $6, $7, $8, $9)',
              [...args, null, a.checked ? a.amount : null, crypto.randomUUID()],
            );
          }
          case 'cancel': {
            const target = changeId.get(a.label);
            if (!target) throw new Error(`nothing labelled ${a.label}`);
            return db.call(PARENT, 'select public.cancel_change($1, $2, $3)', [
              target.kind,
              target.id,
              'Time machine cancellation',
            ]);
          }
        }
      })();
      if (res.ok) {
        const v = res.value;
        if (['deposit', 'withdraw', 'buy', 'sell', 'sell_all'].includes(a.kind))
          reqId.set((a as { label: string }).label, Number(v));
        if (a.kind === 'buy_gic') setGic(a.label, Number(v));
        if (a.kind === 'add_rate' && a.rate.label)
          changeId.set(a.rate.label, { kind: 'rate', id: Number(v) });
        if ((a.kind === 'set_cap' || a.kind === 'set_yield') && a.label)
          changeId.set(a.label, { kind: 'setting', id: Number(v) });
        if (a.kind === 'choose' && a.newLabel) setGic(a.newLabel, Number(v));
        return { ok: true };
      }
      return { ok: false, error: res.error };
    };

    const gicKid = new Map<string, string>();
    const kidOfGic = (label: string): string => {
      const found = gicKid.get(label);
      if (found) return found;
      const step = STEPS.find(
        (s) => typeof s.do !== 'function' && s.do.kind === 'buy_gic' && s.do.label === label,
      );
      if (step && typeof step.do !== 'function' && step.do.kind === 'buy_gic') return step.do.kid;
      const parent = STEPS.find(
        (s) => typeof s.do !== 'function' && s.do.kind === 'choose' && s.do.newLabel === label,
      );
      if (parent && typeof parent.do !== 'function' && parent.do.kind === 'choose')
        return kidOfGic(parent.do.gic);
      throw new Error(`whose GIC is ${label}?`);
    };

    // What the screens show, compared with the model, to the nearest cent.
    const compareSnapshot = async (day: Day) => {
      snapshotDays++;
      for (const k of KIDS) {
        const acct = accounts[k];
        const m = model.snapshot(k);
        const [b] = await db.q<Record<string, string>>(
          `select * from public.account_balances where account_id = $1`,
          [acct],
        );
        const pairs: [string, bigint, bigint][] = [
          ['savings', BigInt(b.savings_cents), m.savings],
          ['held', BigInt(b.held_cents), m.held],
          ['available', BigInt(b.available_cents), m.available],
          ['GICs', BigInt(b.gic_cents), m.gicTotal],
          [
            'funds value',
            BigInt(b.stock_value_cents),
            [...m.fundValue.values()].reduce((s, v) => s + v, 0n),
          ],
          ['total worth', BigInt(b.total_worth_cents), m.total],
          ['net deposits', BigInt(b.net_deposits_cents), m.netDeposits],
          ['cap room', BigInt(b.cap_room_cents), m.capRoom],
        ];
        for (const [f, dbv, mv] of pairs)
          if (dbv !== mv)
            differ(
              'Shown figures match every day (nearest cent)',
              `${day} kid ${k} ${f}: database ${cents(dbv)}, model ${cents(mv)}`,
            );

        const funds = await db.q<{ fund_id: FundId; units: string; value_cents: string }>(
          `select fund_id, units::text, value_cents::text from public.fund_positions where account_id = $1`,
          [acct],
        );
        for (const f of FUNDS) {
          const row = funds.find((x) => x.fund_id === f);
          const du = row ? Q.dec(row.units) : Q.ZERO;
          const dv = row ? BigInt(row.value_cents) : 0n;
          const mu = m.units.get(f)!;
          if (!du.eq(mu))
            differ(
              'Fund units match every day',
              `${day} kid ${k} ${f}: database ${du.toFixed(8)}, model ${mu.toFixed(8)}`,
            );
          if (dv !== m.fundValue.get(f))
            differ(
              'Shown figures match every day (nearest cent)',
              `${day} kid ${k} ${f} value: database ${cents(dv)}, model ${cents(m.fundValue.get(f)!)}`,
            );
        }
        const gics = await db.q<{ gic_id: string; balance_cents: string }>(
          `select gic_id::text, balance_cents::text from public.gic_positions where account_id = $1 and balance_cents <> 0`,
          [acct],
        );
        const dbG = new Map(
          gics.map((g) => [
            gicLabel.get(Number(g.gic_id)) ?? `#${g.gic_id}`,
            BigInt(g.balance_cents),
          ]),
        );
        for (const label of new Set([...dbG.keys(), ...m.gics.keys()]))
          if (dbG.get(label) !== m.gics.get(label))
            differ(
              'Shown figures match every day (nearest cent)',
              `${day} kid ${k} GIC ${label}: database ${dbG.has(label) ? cents(dbG.get(label)!) : 'none'}, model ${m.gics.has(label) ? cents(m.gics.get(label)!) : 'none'}`,
            );
      }
    };

    const missed = (d: Day) => d >= MISSED.from && d <= MISSED.to;

    // The walk ----------------------------------------------------------------
    console.log('Walking the year…');
    for (const day of daysFrom(dayOf(START), END_DAY)) {
      const steps = STEPS.filter((s) => dayOf(s.at) === day).sort((a, b) => (a.at < b.at ? -1 : 1));
      for (const s of steps.filter((x) => x.at < at(day, NIGHTLY_RUN))) await doStep(s);

      const runAt = at(day, NIGHTLY_RUN);
      await db.setClock(runAt);
      await publishUpTo(runAt);
      model.advanceTo(runAt);
      if (!missed(day)) {
        const r = await db.call(SERVER, 'select public.run_daily($1)', [day]);
        if (!r.ok) throw new Error(`run_daily(${day}) failed: ${r.error}`);
        const res = r.value as { status: string; completed_through: string | null };
        const complete = res.status === 'ok' && res.completed_through === day;
        if (!complete) runsWaiting.push(`${day}: ${res.status}`);
        // Reconcile every day not yet checked (after the missed week, each missed day too).
        const from = lastReconciled ? addDays(lastReconciled, 1) : day;
        for (const d of daysFrom(from, day)) {
          const rc = await db.call(SERVER, 'select public.reconcile($1)', [d]);
          if (!rc.ok) throw new Error(`reconcile(${d}) failed: ${rc.error}`);
          reconcileRuns++;
          const v = rc.value as { status: string; problems: unknown[] };
          if (v.status !== 'ok') {
            reconcileProblems++;
            if (reconcileProblemList.length < 8)
              reconcileProblemList.push(`${d}: ${JSON.stringify(v.problems).slice(0, 600)}`);
          }
        }
        lastReconciled = day;
        if (complete) await compareSnapshot(day);
      }

      for (const s of steps.filter((x) => x.at >= runAt)) await doStep(s);
    }
    model.advanceTo(at(END_DAY, '23:00'));

    // Final comparisons ---------------------------------------------------------
    console.log('Comparing the ledger, accruals and graphs…');
    await comparePostings(db, model, accounts, kidOfAccount, gicLabel);
    await compareAccruals(db, model, accounts);
    await compareGraphs(db, model, accounts);

    record(
      'Actions accepted or refused the same way',
      !mismatchCount.has('Actions accepted or refused the same way'),
      `${actionsAgreed} of ${STEPS.filter((s) => typeof s.do === 'function' || !['request_status', 'health'].includes(s.do.kind)).length} actions agreed`,
    );
    record(
      'Scripted refusals and approvals happened as planned',
      expectationsMet === expectations,
      `${expectationsMet} of ${expectations} planned outcomes (refusals, expiries, health checks)`,
    );
    record(
      'Shown figures match every day (nearest cent)',
      !mismatchCount.has('Shown figures match every day (nearest cent)'),
      `${snapshotDays} days × 2 kids: savings, held, available, GICs, each fund, total worth, net deposits, cap room`,
    );
    record(
      'Fund units match every day',
      !mismatchCount.has('Fund units match every day'),
      `${snapshotDays} days, to 8 decimal places`,
    );
    record(
      'Nightly reconcile finds nothing wrong',
      reconcileProblems === 0,
      `${reconcileRuns} nightly checks, ${reconcileProblems} with problems`,
    );
    for (const p of reconcileProblemList) differ('Nightly reconcile finds nothing wrong', p);
    const openAlerts = await db.q<{ n: string }>(
      `select count(*)::text as n from public.alerts where resolved_at is null`,
    );
    record('No alerts were raised', openAlerts[0].n === '0', `${openAlerts[0].n} open alerts`);
    record(
      'Missed week and late close caught up',
      runsWaiting.join('; ') === expectedWaiting.join('; '),
      `runs that had to wait: ${runsWaiting.join('; ') || 'none'} (expected: ${expectedWaiting.join('; ')})`,
    );

    // Deliberate faults -----------------------------------------------------------
    console.log('Injecting deliberate faults…');
    await faultChecks(db, accounts);

    // Report ----------------------------------------------------------------------
    const report = await buildReport(db, model, accounts, Date.now() - started);
    console.log('\n' + report);
    writeFileSync('docs/TIMEMACHINE-REPORT.md', report);
    if (results.some((r) => !r.passed)) process.exitCode = 1;
  } finally {
    await db.close();
  }

  // Put the local database back to a clean reset, so the other tests start from
  // empty. `npm run timemachine -- --keep` leaves the simulated year to look at.
  if (process.argv.includes('--keep')) {
    console.log(
      'Kept the simulated year in the local database (run `npm run db:reset` to clear it).',
    );
  } else {
    console.log('Resetting the local database to clean…');
    execSync('npx supabase db reset', { stdio: 'ignore' });
  }
}

// ------------------------------------------------------------------ ledger comparison

function postingKey(p: {
  kid: string;
  day: Day;
  kind: string;
  cents: bigint;
  units?: Q;
  fund?: string;
  gic?: string;
}): string {
  return [
    p.kid,
    p.day,
    p.kind,
    p.cents.toString(),
    p.units ? p.units.toFixed(8) : '',
    p.fund ?? '',
    p.gic ?? '',
  ].join(' | ');
}

async function comparePostings(
  db: LocalDb,
  model: Model,
  accounts: Record<string, string>,
  kidOfAccount: Map<string, string>,
  gicLabel: Map<number, string>,
): Promise<void> {
  const rows = await db.q<{
    account_id: string;
    vehicle: string;
    type: string;
    amount_cents: string;
    units: string | null;
    fund_id: string | null;
    gic_id: string | null;
    posting_key: string | null;
    day: string;
  }>(
    `select account_id, vehicle::text, type::text, amount_cents::text, units::text, fund_id, gic_id::text, posting_key,
            public.edmonton_local(effective_at)::date::text as day
       from public.transactions where account_id = any ($1) order by id`,
    [Object.values(accounts)],
  );

  const dbPostings: Posting[] = [];
  const trades = new Map<
    string,
    { savings?: bigint; units?: Q; cost?: bigint; fund?: FundId; day?: Day; kid?: string }
  >();
  for (const r of rows) {
    const kid = kidOfAccount.get(r.account_id)!;
    const amt = BigInt(r.amount_cents);
    const gl = r.gic_id ? gicLabel.get(Number(r.gic_id)) : undefined;
    const [stem, ref, part] = (r.posting_key ?? '').split(':');
    const base = { kid, day: r.day };
    if (r.type === 'deposit') dbPostings.push({ ...base, kind: 'deposit', cents: amt });
    else if (r.type === 'withdraw') dbPostings.push({ ...base, kind: 'withdraw', cents: -amt });
    else if (r.type === 'interest' && r.vehicle === 'savings' && stem === 'late_interest')
      dbPostings.push({ ...base, kind: 'late_interest', cents: amt });
    else if (r.type === 'interest' && r.vehicle === 'savings')
      dbPostings.push({ ...base, kind: 'savings_interest', cents: amt });
    else if (r.type === 'interest' && r.vehicle === 'gic')
      dbPostings.push({ ...base, kind: 'gic_interest', cents: amt, gic: gl });
    else if (r.type === 'dividend')
      dbPostings.push({ ...base, kind: 'dividend', cents: amt, fund: r.fund_id as FundId });
    else if (r.type === 'correction')
      dbPostings.push(
        amt > 0n
          ? { ...base, kind: 'correction_add', cents: amt }
          : { ...base, kind: 'correction_take', cents: -amt },
      );
    else if (r.type === 'split_adjust')
      dbPostings.push({
        ...base,
        kind: 'split',
        cents: 0n,
        units: Q.dec(r.units!),
        fund: r.fund_id as FundId,
      });
    else if (stem === 'gic_buy' && part === 'gic')
      dbPostings.push({ ...base, kind: 'gic_buy', cents: amt, gic: gl });
    else if (stem === 'gic_break' && part === 'savings')
      dbPostings.push({ ...base, kind: 'gic_break', cents: amt, gic: gicLabel.get(Number(ref)) });
    else if (stem === 'gic_release' && part === 'savings')
      dbPostings.push({
        ...base,
        kind: 'gic_to_savings',
        cents: amt,
        gic: gicLabel.get(Number(ref)),
      });
    else if (stem === 'gic_renew' && part === 'in')
      dbPostings.push({ ...base, kind: 'gic_renew', cents: amt, gic: gl });
    else if (stem === 'trade') {
      const t = trades.get(ref) ?? {};
      t.kid = kid;
      t.day = r.day;
      t.fund = r.fund_id as FundId;
      if (r.vehicle === 'savings') t.savings = amt;
      else {
        t.units = Q.dec(r.units!);
        t.cost = amt;
      }
      trades.set(ref, t);
    } else if (!['gic_buy', 'gic_break', 'gic_release', 'gic_renew'].includes(stem))
      differ(
        'Every posted amount matches (rounded up)',
        `unrecognised ledger line ${r.posting_key ?? '(no key)'} ${r.type} ${r.amount_cents}`,
      );
  }
  for (const t of trades.values()) {
    if (t.units!.sign() > 0)
      dbPostings.push({
        kid: t.kid!,
        day: t.day!,
        kind: 'buy',
        cents: t.cost!,
        units: t.units,
        fund: t.fund,
      });
    else
      dbPostings.push({
        kid: t.kid!,
        day: t.day!,
        kind: 'sell',
        cents: t.savings!,
        units: Q.ZERO.sub(t.units!),
        fund: t.fund,
      });
  }

  const count = (ps: Posting[]) => {
    const m = new Map<string, number>();
    for (const p of ps) m.set(postingKey(p), (m.get(postingKey(p)) ?? 0) + 1);
    return m;
  };
  const inModel = count(model.postings.filter((p) => p.day <= END_DAY));
  const inDb = count(dbPostings);
  for (const key of new Set([...inModel.keys(), ...inDb.keys()])) {
    const a = inDb.get(key) ?? 0;
    const b = inModel.get(key) ?? 0;
    if (a !== b)
      differ('Every posted amount matches (rounded up)', `${key}: database ${a}×, model ${b}×`);
  }
  const byKind = new Map<string, number>();
  for (const p of dbPostings) byKind.set(p.kind, (byKind.get(p.kind) ?? 0) + 1);
  record(
    'Every posted amount matches (rounded up)',
    !mismatchCount.has('Every posted amount matches (rounded up)'),
    `${dbPostings.length} ledger events: ${[...byKind].map(([k, n]) => `${n} ${k.replace(/_/g, ' ')}`).join(', ')}`,
  );
}

async function compareAccruals(
  db: LocalDb,
  model: Model,
  accounts: Record<string, string>,
): Promise<void> {
  const rows = await db.q<{
    account_id: string;
    d: string;
    base: string;
    rate: string;
    diy: number;
    accrued: string;
  }>(
    `select account_id, accrual_date::text as d, (balance_cents + gic_waiting_cents)::text as base, rate::text,
            days_in_year as diy, accrued::text from public.interest_accruals where account_id = any ($1)`,
    [Object.values(accounts)],
  );
  const kidOf = new Map(Object.entries(accounts).map(([k, v]) => [v, k]));
  const dbMap = new Map(rows.map((r) => [`${kidOf.get(r.account_id)}|${r.d}`, r]));
  const tolerance = Q.of(1, 10_000_000_000n); // one ten-billionth of a cent
  let n = 0;
  const seen = new Set<string>();
  for (const a of model.accrualLog) {
    if (a.day >= END_DAY) continue;
    const key = `${a.kid}|${a.day}`;
    seen.add(key);
    n++;
    const r = dbMap.get(key);
    if (!r) {
      differ(
        'Every daily interest accrual matches',
        `${key}: missing in the database (model ${a.accrued.toFixed(6)}¢ on ${cents(a.base)})`,
      );
      continue;
    }
    if (
      BigInt(r.base) !== a.base ||
      !Q.dec(r.rate).eq(a.rate) ||
      r.diy !== a.days ||
      Q.dec(r.accrued).sub(a.accrued).abs().cmp(tolerance) > 0
    )
      differ(
        'Every daily interest accrual matches',
        `${key}: database ${cents(r.base)} × ${r.rate}% ÷ ${r.diy} = ${r.accrued}¢, model ${cents(a.base)} × ${a.rate.toFixed(3)}% ÷ ${a.days} = ${a.accrued.toFixed(12)}¢`,
      );
  }
  for (const key of dbMap.keys())
    if (!seen.has(key) && key.split('|')[1] < END_DAY)
      differ('Every daily interest accrual matches', `${key}: in the database but not the model`);
  const leap = model.accrualLog
    .filter((a) => a.day.startsWith('2028'))
    .every((a) => a.days === 366);
  record(
    'Every daily interest accrual matches',
    !mismatchCount.has('Every daily interest accrual matches') && leap,
    `${n} kid-days, each within one ten-billionth of a cent; every 2028 day ÷366${leap ? '' : ' (NOT)'}`,
  );
}

async function compareGraphs(
  db: LocalDb,
  model: Model,
  accounts: Record<string, string>,
): Promise<void> {
  let n = 0;
  for (const k of KIDS) {
    const rows = await db.q<{
      d: string;
      savings_cents: string;
      gic_cents: string;
      total_cents: string;
      fund_values: Record<string, number> | null;
    }>(
      `select balance_date::text as d, savings_cents::text, gic_cents::text, total_cents::text, fund_values
         from public.daily_balances($1, $2, $3)`,
      [accounts[k], dayOf(START), addDays(END_DAY, -1)],
    );
    for (const r of rows) {
      const m = model.dayFigures.get(`${k}|${r.d}`);
      if (!m) continue;
      n++;
      const pairs: [string, bigint, bigint][] = [
        ['savings', BigInt(r.savings_cents), m.savings],
        ['GICs', BigInt(r.gic_cents), m.gic],
        ['total', BigInt(r.total_cents), m.total],
        ...FUNDS.map((f): [string, bigint, bigint] => [
          f,
          BigInt(r.fund_values?.[f] ?? 0),
          m.funds.get(f)!,
        ]),
      ];
      for (const [f, a, b] of pairs)
        if (a !== b)
          differ(
            'Graph history matches every day (nearest cent)',
            `${r.d} kid ${k} ${f}: database ${cents(a)}, model ${cents(b)}`,
          );
    }
  }
  record(
    'Graph history matches every day (nearest cent)',
    !mismatchCount.has('Graph history matches every day (nearest cent)'),
    `${n} kid-days of end-of-day savings, GICs, each fund and total`,
  );
}

// ------------------------------------------------------------------ deliberate faults

async function faultChecks(db: LocalDb, accounts: Record<string, string>): Promise<void> {
  const A = accounts.A;
  const B = accounts.B;
  const today = END_DAY;

  // Each fault runs inside a transaction that is rolled back: a throwaway copy.
  const trial = async (
    name: string,
    kid: 'A' | 'B',
    code: string,
    inject: () => Promise<void>,
    extra?: () => Promise<string | null>,
  ) => {
    const acct = accounts[kid];
    await db.q('begin');
    try {
      await inject();
      await db.q('set local role service_role');
      const [{ r }] = await db.q<{ r: { problems: { account_id: string; code: string }[] } }>(
        'select public.reconcile($1) as r',
        [today],
      );
      await db.q('reset role');
      const caught = r.problems.some((p) => p.account_id === acct && p.code === code);
      const [{ updating }] = await db.q<{ updating: boolean }>(
        'select public.figures_updating($1) as updating',
        [acct],
      );
      const alerts = await db.q<{ is_quiet: boolean }>(
        `select is_quiet from public.alerts where account_id = $1 and resolved_at is null and details ->> 'code' = $2`,
        [acct, code],
      );
      const quietRight = alerts.length === 1 && alerts[0].is_quiet === (kid === 'B');
      const [{ h }] = await db.q<{ h: { ok: boolean } }>('select public.health_check() as h');
      const healthRight = h.ok === (kid === 'B'); // a test account's problem is logged quietly
      const more = extra ? await extra() : null;
      const passed = caught && updating && quietRight && healthRight && more === null;
      record(
        `Fault caught: ${name}`,
        passed,
        `reconcile ${caught ? 'caught it' : 'MISSED it'} (${code}); "Updating…" ${updating ? 'on' : 'OFF'}; alert ${
          alerts.length === 1 ? (alerts[0].is_quiet ? 'logged quietly' : 'raised') : 'MISSING'
        }; health check ${h.ok ? 'clear' : 'failing'}${more ? `; ${more}` : ''}`,
      );
    } finally {
      await db.q('rollback');
    }
  };

  // 1. A wrong posting: an extra $1.37 of interest for kid A.
  let faultTx = 0;
  await trial(
    'an extra interest posting (kid A)',
    'A',
    'posting',
    async () => {
      const [{ id }] = await db.q<{ id: number }>(
        `insert into public.transactions (account_id, vehicle, type, amount_cents, posting_key, effective_at, note)
       values ($1::uuid, 'savings', 'interest', 137, 'interest:2028-05:' || $1::text || ':extra', public.edmonton_start('2028-06-01'), 'fault')
       returning id`,
        [A],
      );
      faultTx = id;
    },
    async () => {
      // Fixed openly with a correction: "Updating…" clears by itself, the alert waits for Dad.
      await db.q(
        `insert into public.transactions (account_id, vehicle, type, amount_cents, reverses_id, note)
                values ($1, 'savings', 'correction', -137, $2, 'Reverses an interest line posted by mistake.')`,
        [A, faultTx],
      );
      await db.q('set local role service_role');
      await db.q('select public.reconcile($1)', [today]);
      await db.q('reset role');
      const [{ updating }] = await db.q<{ updating: boolean }>(
        'select public.figures_updating($1) as updating',
        [A],
      );
      const [{ open }] = await db.q<{ open: number }>(
        `select count(*)::int as open from public.alerts where account_id = $1 and resolved_at is null`,
        [A],
      );
      await db.q(`select set_config('request.jwt.claims', $1, true)`, [
        JSON.stringify({ sub: PARENT_ID, role: 'authenticated', aal: 'aal2' }),
      ]);
      await db.q('set local role authenticated');
      const ids = await db.q<{ id: number }>(
        `select id from public.alerts where account_id = $1 and resolved_at is null`,
        [A],
      );
      for (const { id } of ids) await db.q('select public.acknowledge_alert($1)', [id]);
      await db.q('reset role');
      const [{ h }] = await db.q<{ h: { ok: boolean } }>('select public.health_check() as h');
      if (updating || open < 1 || !h.ok)
        return `after the correction: "Updating…" ${updating ? 'still on' : 'off'}, ${open} alert(s) still open before Dad acknowledged, health ${h.ok ? 'clear' : 'failing'} after`;
      return null;
    },
  );

  // 2. A fund buy for kid B with the wrong number of units.
  await trial('a trade with the wrong units (kid B)', 'B', 'posting', async () => {
    const [{ id, close_at, close }] = await db.q<{ id: number; close_at: string; close: string }>(
      `with r as (
         insert into public.requests (account_id, type, from_vehicle, to_vehicle, fund_id, amount_cents, status, created_at, settled_at)
         values ($1, 'move', 'savings', 'stock', 'dow', 1000, 'settled', public.edmonton_start('2028-06-26') + interval '9 hours', null)
         returning id, created_at)
       select r.id, public.next_close('nyse', r.created_at)::text as close_at,
              (select fp.close::text from public.fund_prices fp
                where fp.fund_id = 'dow' and fp.price_date = (public.next_close('nyse', r.created_at) at time zone 'America/Toronto')::date) as close
         from r`,
      [B],
    );
    await db.q(
      `insert into public.transactions (account_id, vehicle, fund_id, type, amount_cents, request_id, posting_key, effective_at)
                values ($1, 'savings', 'dow', 'transfer_out', -1000, $2::bigint, 'trade:' || $2::text || ':savings', $3)`,
      [B, id, close_at],
    );
    await db.q(
      `insert into public.transactions (account_id, vehicle, fund_id, type, amount_cents, units, unit_price, request_id, posting_key, effective_at)
                values ($1, 'stock', 'dow', 'transfer_in', 1000, 1, $4, $2::bigint, 'trade:' || $2::text || ':fund', $3)`,
      [B, id, close_at, close],
    );
  });

  // 3. A GIC with no purchase line behind it (kid A).
  await trial('a GIC with no purchase entry (kid A)', 'A', 'gic', async () => {
    await db.q(
      `insert into public.gic_holdings (account_id, principal_cents, rate, term_months, start_date, maturity_date)
                values ($1, 5000, 3.0, 3, date '2028-06-01', date '2028-09-01')`,
      [A],
    );
  });

  // After the rollbacks, everything is clean again.
  const [{ ua }] = await db.q<{ ua: boolean }>('select public.figures_updating($1) as ua', [A]);
  const [{ ub }] = await db.q<{ ub: boolean }>('select public.figures_updating($1) as ub', [B]);
  record(
    'Throwaway copies left no trace',
    !ua && !ub,
    `"Updating…" is off for both kids after the faults were rolled back`,
  );
}

// ------------------------------------------------------------------ the report

async function buildReport(
  db: LocalDb,
  model: Model,
  accounts: Record<string, string>,
  ms: number,
): Promise<string> {
  const lines: string[] = [];
  const passed = results.filter((r) => r.passed).length;
  lines.push('# Time machine report');
  lines.push('');
  lines.push(
    `A simulated year, Jul 1, 2027 to Jul 1, 2028, on the local database, checked against the independent reference model. Generated by \`npm run timemachine\` (took ${Math.round(ms / 1000)} s). All accounts and people are made up.`,
  );
  lines.push('');
  lines.push(
    `**Result: ${passed === results.length ? 'PASS' : 'FAIL'}: ${passed} of ${results.length} checks passed.**`,
  );
  lines.push('');
  lines.push('## Each kid at the end (Jul 1, 2028)');
  lines.push('');
  for (const k of KIDS) {
    const acct = accounts[k];
    const [b] = await db.q<Record<string, string>>(
      `select * from public.account_balances where account_id = $1`,
      [acct],
    );
    const funds = await db.q<{ fund_id: string; units: string; value_cents: string }>(
      `select fund_id, units::text, value_cents::text from public.fund_positions where account_id = $1 and units <> 0`,
      [acct],
    );
    const gics = await db.q<{
      term_months: number;
      balance_cents: string;
      rate: string;
      maturity_date: string;
    }>(
      `select term_months, balance_cents::text, rate::text, maturity_date::text from public.gic_positions
        where account_id = $1 and balance_cents <> 0 order by maturity_date`,
      [acct],
    );
    const [t] = await db.q<{ savings_interest: string; gic_interest: string; dividends: string }>(
      `select coalesce(sum(amount_cents) filter (where type = 'interest' and vehicle = 'savings'), 0)::text as savings_interest,
              coalesce(sum(amount_cents) filter (where type = 'interest' and vehicle = 'gic'), 0)::text as gic_interest,
              coalesce(sum(amount_cents) filter (where type = 'dividend'), 0)::text as dividends
         from public.transactions where account_id = $1`,
      [acct],
    );
    const total = BigInt(b.total_worth_cents);
    const net = BigInt(b.net_deposits_cents);
    const interest = BigInt(t.savings_interest) + BigInt(t.gic_interest);
    const gains = total - net - interest - BigInt(t.dividends);
    lines.push(`### Kid ${k}${k === 'B' ? ' (test account)' : ''}`);
    lines.push('');
    lines.push(
      `- **Total worth: ${cents(total)}**, from ${cents(net)} put in (deposits minus withdrawals).`,
    );
    lines.push(`- Savings: ${cents(b.savings_cents)}`);
    lines.push(
      `- GICs: ${cents(b.gic_cents)}${gics.length ? ` (${gics.map((g) => `${g.term_months}-month at ${Number(g.rate)}%: ${cents(g.balance_cents)}, matures ${g.maturity_date}`).join('; ')})` : ''}`,
    );
    lines.push(
      `- Funds: ${cents(b.stock_value_cents)}${funds.length ? ` (${funds.map((f) => `${f.fund_id}: ${cents(f.value_cents)}`).join('; ')})` : ''}`,
    );
    lines.push(
      `- Earned over the year: savings interest ${cents(t.savings_interest)}, GIC interest ${cents(t.gic_interest)}, dividends ${cents(t.dividends)}, fund gains ${cents(gains)}.`,
    );
    lines.push('');
  }
  lines.push('## Checks');
  lines.push('');
  lines.push('| Check | Result | What was compared |');
  lines.push('|---|---|---|');
  for (const r of results)
    lines.push(`| ${r.name} | ${r.passed ? 'PASS' : '**FAIL**'} | ${r.detail} |`);
  lines.push('');
  if (mismatches.size) {
    lines.push('## Differences found');
    lines.push('');
    for (const [check, list] of mismatches) {
      lines.push(`### ${check} (${mismatchCount.get(check)} in all; first ${list.length})`);
      lines.push('');
      for (const l of list) lines.push(`- ${l}`);
      lines.push('');
    }
  }
  lines.push('## What the year covered');
  lines.push('');
  for (const s of STEPS) lines.push(`- ${s.at}: ${s.why}`);
  lines.push(`- ${SPLIT.day}: Nasdaq-100 2-for-1 split`);
  lines.push(`- ${LATE_CLOSE.day}: Nasdaq-100 close arrives a day late`);
  lines.push(
    `- ${LATE_CLOSE_3.day}: Nasdaq-100 close arrives on ${LATE_CLOSE_3.publishedAt.slice(0, 10)}; only its Oct 1 dividend waits (the Dow and TSX pay on time)`,
  );
  lines.push(
    `- ${LATE_CLOSE_2.day}: Dow close arrives on ${LATE_CLOSE_2.publishedAt.slice(0, 10)}; the sale and the Jan 3 dividends post late, with the interest they missed`,
  );
  lines.push(
    '- Feb 14 – Mar 6, 2028: Nasdaq-100 falls about 25% (Dow and TSX less), then recovers',
  );
  lines.push(
    `- ${MISSED.from} to ${MISSED.to}: the nightly jobs don't run, then catch up on Apr 8`,
  );
  lines.push(
    "- Quarterly dividends Oct 1, 2027, Jan 3–4, 2028 (each fund's own market) and Apr 3, 2028; monthly interest on every 1st",
  );
  void model;
  return lines.join('\n') + '\n';
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
