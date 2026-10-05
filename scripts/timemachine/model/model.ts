// The independent reference model: what every balance SHOULD be, worked out
// from docs/SPEC.md and the decisions recorded in docs/PROGRESS.md. It shares
// input data with the database (closes, holidays, the scripted actions) but
// none of its logic, so it's a genuine second opinion.
//
// Units of measure: money in whole cents (bigint) once posted; exact fractions
// (Q) for accruals, units and prices. Rates are percent per year ("2.5" = 2.5%).

import { Q, sumQ } from './rational.ts';
import {
  NIGHTLY_RUN,
  type Day,
  type Moment,
  addDays,
  addHours,
  addMonths,
  at,
  dayOf,
  daysInYear,
  parts,
  torontoToEdmonton,
  weekday,
  mk,
} from './calendar.ts';

export type FundId = 'dow' | 'nasdaq100' | 'tsx';
export const FUNDS: FundId[] = ['dow', 'nasdaq100', 'tsx'];
export const MARKET_OF: Record<FundId, 'nyse' | 'tsx'> = {
  dow: 'nyse',
  nasdaq100: 'nyse',
  tsx: 'tsx',
};
export const GIC_TERMS = [1, 3, 6, 9, 12, 24];

export interface Holiday {
  market: 'nyse' | 'tsx';
  date: Day;
  kind: 'closed' | 'early_close';
  /** Eastern time, for early closes. */
  closesAt: string | null;
}

export interface RateInput {
  vehicle: 'savings' | 'gic';
  term: number | null;
  rate: string;
  effective: Day;
  end?: Day;
  special?: boolean;
  /** A name the scenario can cancel it by. */
  label?: string;
}

export type Action =
  | { kind: 'deposit'; kid: string; cents: bigint; label: string }
  | { kind: 'withdraw'; kid: string; cents: bigint; label: string }
  | { kind: 'approve'; label: string }
  | { kind: 'decline'; label: string; reason: string }
  | { kind: 'buy_gic'; kid: string; cents: bigint; term: number; label: string }
  | { kind: 'break_gic'; gic: string }
  | {
      kind: 'choose';
      gic: string;
      choice: 'renew' | 'to_savings' | 'new_term';
      term?: number;
      newLabel?: string;
    }
  | { kind: 'buy'; kid: string; fund: FundId; cents: bigint; label: string }
  | { kind: 'sell'; kid: string; fund: FundId; cents: bigint; label: string }
  | { kind: 'sell_all'; kid: string; fund: FundId; label: string }
  | { kind: 'add_rate'; rate: RateInput }
  | { kind: 'set_cap'; cents: bigint; effective: Day; label?: string }
  | { kind: 'set_yield'; fund: FundId; yield: string; effective: Day; label?: string }
  | { kind: 'cancel'; label: string }
  | { kind: 'set_expiry'; days: number; effective: Day }
  /**
   * Fix a mistake (stage 8): add to or take from savings. amount is dollars as Dad types them
   * (up to 4 decimals); line is the kind of history line it's linked to (her latest one).
   * checked: Dad gave the extra check (a tap for a reduction, the amount typed again for an
   * addition over $100).
   */
  | {
      kind: 'correct';
      kid: string;
      direction: 'add' | 'take';
      amount: string;
      line: string;
      checked: boolean;
    };

/** The history lines a correction can be linked to in the scenario, as postings. */
const LINE_POSTING: Record<string, PostingKind> = {
  interest: 'savings_interest',
  deposit: 'deposit',
  withdraw: 'withdraw',
  dividend: 'dividend',
};

export type Outcome = { ok: true } | { ok: false; reason: string };

export type PostingKind =
  | 'deposit'
  | 'withdraw'
  | 'savings_interest'
  | 'gic_interest'
  | 'dividend'
  | 'buy'
  | 'sell'
  | 'gic_buy'
  | 'gic_break'
  | 'gic_to_savings'
  | 'gic_renew'
  | 'split'
  | 'correction_add'
  | 'correction_take';

/** One money event as it should appear in the ledger. */
export interface Posting {
  kid: string;
  day: Day; // the day the money counts from
  kind: PostingKind;
  cents: bigint; // money moved (always ≥ 0; the kind gives the direction)
  units?: Q; // units bought, sold or added by a split
  fund?: FundId;
  gic?: string; // GIC label
}

interface Gic {
  label: string;
  kid: string;
  principal: bigint;
  rate: Q;
  term: number;
  start: Day;
  maturity: Day;
  status: 'active' | 'matured' | 'broken' | 'closed';
  balance: bigint;
}

interface Req {
  label: string;
  kid: string;
  kind: 'deposit' | 'withdraw' | 'buy' | 'sell' | 'sell_all';
  fund?: FundId;
  cents: bigint;
  createdAt: Moment;
  /** Deposits and withdrawals: fixed when she asks, from the expiry rule in force that day. */
  expiresAt?: Moment;
  status: 'pending' | 'approved' | 'declined' | 'expired' | 'settled';
  settleAt?: Moment;
  settleDay?: Day;
}

interface Kid {
  id: string;
  opened: Day;
  savings: bigint;
  netDeposits: bigint;
  unitChanges: { at: Moment; fund: FundId; units: Q }[];
  accruals: Map<Day, Q>;
  tradeDays: Set<string>;
}

/** What the screens should show, to the nearest cent. */
export interface Snapshot {
  savings: bigint;
  held: bigint;
  available: bigint;
  gics: Map<string, bigint>; // GIC label -> balance, for GICs with money in them
  gicTotal: bigint;
  units: Map<FundId, Q>;
  fundValue: Map<FundId, bigint>;
  total: bigint;
  netDeposits: bigint;
  capRoom: bigint;
}

/** End-of-day figures, as the graphs show them. */
export interface DayFigures {
  savings: bigint;
  gic: bigint;
  funds: Map<FundId, bigint>;
  total: bigint;
}

const DEFAULT_YIELDS: Record<FundId, string> = { dow: '1.8', nasdaq100: '0.6', tsx: '2.8' };
const MIN_SAVINGS = 500n;
const MIN_GIC_OR_FUND = 1000n;

export class Model {
  private now: Moment;
  private kids = new Map<string, Kid>();
  private gics = new Map<string, Gic>();
  private reqs = new Map<string, Req>();
  private rates: (RateInput & { seq: number; q: Q; cancelled?: boolean })[] = [];
  private caps: {
    cents: bigint;
    effective: Day;
    seq: number;
    label?: string;
    cancelled?: boolean;
  }[] = [];
  private yields: {
    fund: FundId;
    q: Q;
    effective: Day;
    seq: number;
    label?: string;
    cancelled?: boolean;
  }[] = [];
  private expiryRules: { days: number; effective: Day; seq: number }[] = [];
  private closes = new Map<string, { close: Q; publishedAt: Moment }>(); // `${fund}|${day}`
  private splits: { fund: FundId; day: Day; from: bigint; to: bigint }[] = [];
  private holidays = new Map<string, Holiday>(); // `${market}|${day}`
  private seq = 0;
  /** Fix a mistake: cents already taken from each line by earlier fixes. */
  private takenFromLine = new Map<string, bigint>();
  readonly postings: Posting[] = [];
  readonly dayFigures = new Map<string, DayFigures>(); // `${kid}|${day}`
  readonly accrualLog: {
    kid: string;
    day: Day;
    base: bigint;
    rate: Q;
    days: number;
    accrued: Q;
  }[] = [];

  constructor(start: Moment, holidays: Holiday[]) {
    this.now = start;
    for (const h of holidays) this.holidays.set(`${h.market}|${h.date}`, h);
    // Starting rates and cap from the spec.
    const r = (vehicle: 'savings' | 'gic', term: number | null, rate: string) =>
      this.addRate({ vehicle, term, rate, effective: '2026-01-01' });
    r('savings', null, '2.0');
    for (const [t, v] of [
      [1, '2.5'],
      [3, '3.0'],
      [6, '4.0'],
      [9, '4.5'],
      [12, '5.0'],
      [24, '6.0'],
    ] as const)
      r('gic', t, v);
    this.caps.push({ cents: 100000n, effective: '2026-01-01', seq: this.seq++ });
    for (const f of FUNDS)
      this.yields.push({
        fund: f,
        q: Q.dec(DEFAULT_YIELDS[f]),
        effective: '2026-01-01',
        seq: this.seq++,
      });
    // Dad has 7 days to answer a deposit or withdrawal, to start (stage 8: a setting).
    this.expiryRules.push({ days: 7, effective: '2026-01-01', seq: this.seq++ });
  }

  /** The model's current moment. */
  get clock(): Moment {
    return this.now;
  }

  // ---------------------------------------------------------------- inputs

  addClose(fund: FundId, day: Day, close: string, publishedAt: Moment): void {
    this.closes.set(`${fund}|${day}`, { close: Q.dec(close), publishedAt });
  }

  addSplit(fund: FundId, day: Day, from: bigint, to: bigint): void {
    this.splits.push({ fund, day, from, to });
  }

  openAccount(id: string): void {
    this.kids.set(id, {
      id,
      opened: dayOf(this.now),
      savings: 0n,
      netDeposits: 0n,
      unitChanges: [],
      accruals: new Map(),
      tradeDays: new Set(),
    });
  }

  private addRate(r: RateInput): void {
    this.rates.push({ ...r, seq: this.seq++, q: Q.dec(r.rate) });
  }

  // ---------------------------------------------------------------- lookups

  rateOn(vehicle: 'savings' | 'gic', term: number | null, d: Day): Q {
    const same = this.rates.filter((r) => r.vehicle === vehicle && r.term === term && !r.cancelled);
    const special = same
      .filter((r) => r.special && r.effective <= d && r.end !== undefined && d <= r.end)
      .sort((a, b) => b.seq - a.seq)[0];
    if (special) return special.q;
    const regular = same
      .filter((r) => !r.special && r.effective <= d)
      .sort((a, b) =>
        a.effective === b.effective ? b.seq - a.seq : a.effective < b.effective ? 1 : -1,
      )[0];
    if (!regular) throw new Error(`no ${vehicle} rate for ${term} on ${d}`);
    return regular.q;
  }

  /** A fund's yearly dividend yield (percent) in force on day d. */
  yieldOn(f: FundId, d: Day): Q {
    return this.yields
      .filter((y) => y.fund === f && y.effective <= d && !y.cancelled)
      .sort((a, b) =>
        a.effective === b.effective ? b.seq - a.seq : a.effective < b.effective ? 1 : -1,
      )[0].q;
  }

  /**
   * Seven days' notice for a cut (stage 8 B2): the first of the 7 days from `today`
   * on which `after` gives less than `before`, or null.
   */
  private firstLowerDay(today: Day, before: Q[], after: Q[]): Day | null {
    for (let i = 0; i < 7; i++) if (after[i].cmp(before[i]) < 0) return addDays(today, i);
    return null;
  }
  private week(today: Day, f: (d: Day) => Q): Q[] {
    return Array.from({ length: 7 }, (_, i) => f(addDays(today, i)));
  }

  capOn(d: Day): bigint {
    const c = this.caps
      .filter((x) => x.effective <= d && !x.cancelled)
      .sort((a, b) =>
        a.effective === b.effective ? b.seq - a.seq : a.effective < b.effective ? 1 : -1,
      )[0];
    return c.cents;
  }

  isTradingDay(market: 'nyse' | 'tsx', d: Day): boolean {
    const wd = weekday(d);
    if (wd === 0 || wd === 6) return false;
    return this.holidays.get(`${market}|${d}`)?.kind !== 'closed';
  }

  /**
   * The close moment in Edmonton time. Closes are set in Toronto time: 4:00 pm, or
   * the early-close time. In Alberta that's 2:00 pm (early: 11:00 am) while Toronto
   * is on summer time, and 3:00 pm (early: 12:00 pm) the rest of the year.
   */
  closeMoment(market: 'nyse' | 'tsx', d: Day): Moment {
    const h = this.holidays.get(`${market}|${d}`);
    const toronto = h?.kind === 'early_close' && h.closesAt ? h.closesAt.slice(0, 5) : '16:00';
    return torontoToEdmonton(d, toronto);
  }

  /** The first close of this fund's market strictly after moment t. */
  nextClose(fund: FundId, t: Moment): { day: Day; at: Moment } {
    const m = MARKET_OF[fund];
    for (let d = dayOf(t); ; d = addDays(d, 1)) {
      if (!this.isTradingDay(m, d)) continue;
      const c = this.closeMoment(m, d);
      if (c > t) return { day: d, at: c };
    }
  }

  private closeOf(fund: FundId, d: Day): Q {
    const c = this.closes.get(`${fund}|${d}`);
    if (!c) throw new Error(`reference model has no close for ${fund} on ${d}`);
    return c.close;
  }

  /** Latest close on or before day d (published by moment `seen`, when given). */
  latestClose(fund: FundId, d: Day, seen?: Moment): Q | null {
    for (let x = d, i = 0; i < 30; x = addDays(x, -1), i++) {
      const c = this.closes.get(`${fund}|${x}`);
      if (c && (!seen || c.publishedAt <= seen)) return c.close;
    }
    return null;
  }

  /**
   * The latest close the database knows at moment t: a day's close arrives with the
   * nightly run (NIGHTLY_RUN), or later when it's published late. This is the price
   * a request is checked against (a sale by amount), not the one it settles at.
   */
  knownClose(fund: FundId, t: Moment): Q | null {
    for (let x = dayOf(t), i = 0; i < 30; x = addDays(x, -1), i++) {
      const c = this.closes.get(`${fund}|${x}`);
      if (!c) continue;
      const arrives = c.publishedAt > at(x, NIGHTLY_RUN) ? c.publishedAt : at(x, NIGHTLY_RUN);
      if (arrives <= t) return c.close;
    }
    return null;
  }

  unitsAt(kid: string, fund: FundId, t: Moment): Q {
    return sumQ(
      this.kid(kid)
        .unitChanges.filter((u) => u.fund === fund && u.at <= t)
        .map((u) => u.units),
    );
  }

  private kid(id: string): Kid {
    const k = this.kids.get(id);
    if (!k) throw new Error(`unknown kid ${id}`);
    return k;
  }

  gicLabels(): string[] {
    return [...this.gics.keys()];
  }

  // ---------------------------------------------------------------- holds

  private heldCents(kid: string): bigint {
    let h = 0n;
    for (const r of this.reqs.values())
      if (r.kid === kid && r.status === 'pending' && (r.kind === 'withdraw' || r.kind === 'buy'))
        h += r.cents;
    return h;
  }

  private pendingDeposits(kid: string): bigint {
    let p = 0n;
    for (const r of this.reqs.values())
      if (r.kid === kid && r.status === 'pending' && r.kind === 'deposit') p += r.cents;
    return p;
  }

  private available(kid: string): bigint {
    return this.kid(kid).savings - this.heldCents(kid);
  }

  // ---------------------------------------------------------------- the clock

  /** Move time forward to t, applying everything that happens on the way. */
  advanceTo(t: Moment): void {
    if (t < this.now) throw new Error(`model clock can't go back from ${this.now} to ${t}`);
    for (;;) {
      const nextDayStart = at(addDays(dayOf(this.now), 1), '00:00');
      const due = this.nextTimedEvent();
      if (due && due.at <= t && due.at < nextDayStart) {
        this.now = due.at;
        due.run();
        continue;
      }
      if (nextDayStart <= t) {
        this.endOfDay(dayOf(this.now));
        this.now = nextDayStart;
        this.startOfDay(dayOf(this.now));
        continue;
      }
      this.now = t;
      return;
    }
  }

  private nextTimedEvent(): { at: Moment; run: () => void } | null {
    let best: { at: Moment; run: () => void } | null = null;
    const consider = (when: Moment, run: () => void) => {
      if (when >= this.now && (!best || when < best.at)) best = { at: when, run };
    };
    // Earliest first; at the same moment, expiries before settlements (neither happens in the script).
    for (const r of this.reqs.values()) {
      if (r.status !== 'pending') continue;
      if (r.kind === 'deposit' || r.kind === 'withdraw') {
        consider(r.expiresAt!, () => {
          r.status = 'expired';
        });
      } else if (r.settleAt) {
        consider(r.settleAt, () => this.settle(r));
      }
    }
    return best;
  }

  // ---------------------------------------------------------------- daily rules

  private startOfDay(d: Day): void {
    const [y, m, dd] = parts(d);

    // Splits count from the start of their day.
    for (const s of this.splits.filter((x) => x.day === d)) {
      for (const k of this.kids.values()) {
        const before = this.unitsAt(k.id, s.fund, at(d, '00:00'));
        if (before.sign() <= 0) continue;
        const added = before.mul(Q.of(s.to, s.from)).sub(before);
        k.unitChanges.push({ at: at(d, '00:00'), fund: s.fund, units: added });
        this.postings.push({
          kid: k.id,
          day: d,
          kind: 'split',
          cents: 0n,
          units: added,
          fund: s.fund,
        });
      }
    }

    // GICs mature on their maturity date, with simple interest for the term, rounded up.
    for (const g of this.gics.values()) {
      if (g.status !== 'active' || g.maturity !== d) continue;
      const interest = Q.of(g.principal).mul(g.rate).mul(Q.of(g.term)).div(Q.of(1200)).ceil();
      g.balance += interest;
      g.status = 'matured';
      if (interest > 0n)
        this.postings.push({
          kid: g.kid,
          day: d,
          kind: 'gic_interest',
          cents: interest,
          gic: g.label,
        });
    }

    // Not chosen within 7 days: moves to savings at the start of day 7.
    for (const g of this.gics.values()) {
      if (g.status !== 'matured' || addDays(g.maturity, 7) !== d) continue;
      this.gicToSavings(g, d);
    }

    // Quarterly dividends on the first trading day of Jan, Apr, Jul and Oct (each fund's own market).
    if ([1, 4, 7, 10].includes(m)) {
      const qStart = mk(y, m, 1);
      for (const f of FUNDS) {
        const market = MARKET_OF[f];
        let first = qStart;
        while (!this.isTradingDay(market, first)) first = addDays(first, 1);
        if (first !== d) continue;
        let last = addDays(qStart, -1);
        while (!this.isTradingDay(market, last)) last = addDays(last, -1);
        const closeAt = this.closeMoment(market, last);
        const yld = this.yieldOn(f, d);
        for (const k of this.kids.values()) {
          const units = this.unitsAt(k.id, f, closeAt);
          if (units.sign() <= 0) continue;
          const close = this.closeOf(f, last);
          // units × close (dollars) × 100 (cents) × yield% ÷ 100 ÷ 4
          const cents = units.mul(close).mul(yld).div(Q.of(4)).ceil();
          if (cents <= 0n) continue;
          k.savings += cents;
          this.postings.push({ kid: k.id, day: d, kind: 'dividend', cents, fund: f });
        }
      }
    }

    // On the 1st, last month's accruals are posted as one line, rounded up.
    if (dd === 1) {
      const prevMonth = addDays(d, -1).slice(0, 7);
      for (const k of this.kids.values()) {
        const total = sumQ(
          [...k.accruals].filter(([day]) => day.startsWith(prevMonth)).map(([, a]) => a),
        );
        if (total.sign() <= 0) continue;
        const cents = total.ceil();
        k.savings += cents;
        this.postings.push({ kid: k.id, day: d, kind: 'savings_interest', cents });
      }
    }
  }

  private endOfDay(d: Day): void {
    const endMoment = at(d, '23:59');
    for (const k of this.kids.values()) {
      if (d < k.opened) continue;
      // Savings (held money included) plus matured GIC money waiting for her choice.
      const waiting = [...this.gics.values()]
        .filter((g) => g.kid === k.id && g.status === 'matured')
        .reduce((s, g) => s + g.balance, 0n);
      const base = k.savings + waiting;
      if (base > 0n) {
        const rate = this.rateOn('savings', null, d);
        const days = daysInYear(parts(d)[0]);
        const accrued = Q.of(base)
          .mul(rate)
          .div(Q.of(100 * days));
        k.accruals.set(d, accrued);
        this.accrualLog.push({ kid: k.id, day: d, base, rate, days, accrued });
      }

      // End-of-day figures for the graphs.
      const funds = new Map<FundId, bigint>();
      for (const f of FUNDS) {
        const u = this.unitsAt(k.id, f, endMoment);
        const c = this.latestClose(f, d);
        funds.set(f, u.sign() === 0 || !c ? 0n : u.mul(c).mul(Q.of(100)).round());
      }
      const gic = [...this.gics.values()]
        .filter((g) => g.kid === k.id)
        .reduce((s, g) => s + g.balance, 0n);
      const total = k.savings + gic + [...funds.values()].reduce((s, v) => s + v, 0n);
      this.dayFigures.set(`${k.id}|${d}`, { savings: k.savings, gic, funds, total });
    }
  }

  private gicToSavings(g: Gic, d: Day): void {
    const amount = g.balance;
    this.kid(g.kid).savings += amount;
    g.balance = 0n;
    g.status = 'closed';
    this.postings.push({ kid: g.kid, day: d, kind: 'gic_to_savings', cents: amount, gic: g.label });
  }

  private settle(r: Req): void {
    const k = this.kid(r.kid);
    const fund = r.fund!;
    const close = this.closeOf(fund, r.settleDay!);
    const t = r.settleAt!;
    if (r.kind === 'buy') {
      // units = amount ÷ close, rounded up at 8 decimal places
      const units = Q.of(r.cents, 100).div(close).ceilTo(8);
      k.savings -= r.cents;
      k.unitChanges.push({ at: t, fund, units });
      this.postings.push({ kid: k.id, day: dayOf(t), kind: 'buy', cents: r.cents, units, fund });
    } else {
      const have = this.unitsAt(k.id, fund, t);
      let units = have;
      if (r.kind === 'sell') {
        // Units for the dollar amount, rounded DOWN at 8 places so she gets what she asked for and
        // keeps the sliver (Dad's decision, stage 3: the spec didn't say). If the price fell and
        // she hasn't enough, sell all (Dad's decision, stage 2).
        const exact = Q.of(r.cents, 100).div(close);
        const need = exact.floorTo(8);
        if (need.cmp(have) < 0) units = need;
      }
      const proceeds = units.mul(close).mul(Q.of(100)).ceil();
      k.savings += proceeds;
      k.unitChanges.push({ at: t, fund, units: Q.ZERO.sub(units) });
      this.postings.push({ kid: k.id, day: dayOf(t), kind: 'sell', cents: proceeds, units, fund });
    }
    r.status = 'settled';
  }

  // ---------------------------------------------------------------- actions

  /** Apply a kid or parent action at moment t. Refused actions change nothing. */
  /** Days Dad has to answer a deposit or withdrawal asked for on day d. */
  expiryDaysOn(d: Day): number {
    const e = this.expiryRules
      .filter((x) => x.effective <= d)
      .sort((a, b) =>
        a.effective === b.effective ? b.seq - a.seq : a.effective < b.effective ? 1 : -1,
      )[0];
    return e.days;
  }

  act(t: Moment, a: Action): Outcome {
    this.advanceTo(t);
    const today = dayOf(t);
    const no = (reason: string): Outcome => ({ ok: false, reason });

    switch (a.kind) {
      case 'deposit': {
        if (a.cents < MIN_SAVINGS) return no('under the $5 minimum');
        const k = this.kid(a.kid);
        if (k.netDeposits + this.pendingDeposits(a.kid) + a.cents > this.capOn(today))
          return no('over the deposit cap');
        this.reqs.set(a.label, {
          label: a.label,
          kid: a.kid,
          kind: 'deposit',
          cents: a.cents,
          createdAt: t,
          expiresAt: addHours(t, this.expiryDaysOn(today) * 24),
          status: 'pending',
        });
        return { ok: true };
      }
      case 'withdraw': {
        const avail = this.available(a.kid);
        if (a.cents <= 0n || a.cents > avail) return no('more than available');
        if (a.cents < MIN_SAVINGS && a.cents !== avail)
          return no('under $5 without emptying savings');
        this.reqs.set(a.label, {
          label: a.label,
          kid: a.kid,
          kind: 'withdraw',
          cents: a.cents,
          createdAt: t,
          expiresAt: addHours(t, this.expiryDaysOn(today) * 24),
          status: 'pending',
        });
        return { ok: true };
      }
      case 'approve': {
        const r = this.reqs.get(a.label);
        if (!r || r.status !== 'pending') return no('not pending');
        if (r.kind === 'withdraw' && t < addHours(r.createdAt, 24))
          return no('withdrawal under 24 hours old');
        const k = this.kid(r.kid);
        if (r.kind === 'deposit') {
          k.savings += r.cents;
          k.netDeposits += r.cents;
          this.postings.push({ kid: k.id, day: today, kind: 'deposit', cents: r.cents });
        } else if (r.kind === 'withdraw') {
          k.savings -= r.cents;
          k.netDeposits -= r.cents;
          this.postings.push({ kid: k.id, day: today, kind: 'withdraw', cents: r.cents });
        } else return no('only deposits and withdrawals need approval');
        r.status = 'approved';
        return { ok: true };
      }
      case 'decline': {
        const r = this.reqs.get(a.label);
        if (!r || r.status !== 'pending' || !(r.kind === 'deposit' || r.kind === 'withdraw'))
          return no('not pending');
        r.status = 'declined';
        return { ok: true };
      }
      case 'buy_gic': {
        if (!GIC_TERMS.includes(a.term)) return no('bad term');
        if (a.cents < MIN_GIC_OR_FUND) return no('under the $10 minimum');
        if (a.cents > this.available(a.kid)) return no('more than available');
        this.kid(a.kid).savings -= a.cents;
        this.newGic(a.label, a.kid, a.cents, a.term, today);
        this.postings.push({
          kid: a.kid,
          day: today,
          kind: 'gic_buy',
          cents: a.cents,
          gic: a.label,
        });
        return { ok: true };
      }
      case 'break_gic': {
        const g = this.gics.get(a.gic);
        if (!g || g.status !== 'active') return no('not an active GIC');
        // Principal back, interest forfeited.
        this.kid(g.kid).savings += g.principal;
        this.postings.push({
          kid: g.kid,
          day: today,
          kind: 'gic_break',
          cents: g.principal,
          gic: g.label,
        });
        g.balance = 0n;
        g.status = 'broken';
        return { ok: true };
      }
      case 'choose': {
        const g = this.gics.get(a.gic);
        if (!g || g.status !== 'matured') return no('not waiting for a choice');
        if (a.choice === 'to_savings') {
          this.gicToSavings(g, today);
          return { ok: true };
        }
        const term = a.choice === 'renew' ? g.term : a.term!;
        if (!GIC_TERMS.includes(term)) return no('bad term');
        const amount = g.balance;
        g.balance = 0n;
        g.status = 'closed';
        this.newGic(a.newLabel!, g.kid, amount, term, today);
        this.postings.push({
          kid: g.kid,
          day: today,
          kind: 'gic_renew',
          cents: amount,
          gic: a.newLabel!,
        });
        return { ok: true };
      }
      case 'buy':
      case 'sell':
      case 'sell_all': {
        const k = this.kid(a.kid);
        const key = `${a.fund}|${today}`;
        if (k.tradeDays.has(key)) return no('already traded this fund today');
        if (a.kind === 'buy') {
          if (a.cents < MIN_GIC_OR_FUND) return no('under the $10 minimum');
          if (a.cents > this.available(a.kid)) return no('more than available');
        }
        let kind = a.kind;
        if (a.kind !== 'buy') {
          const units = this.unitsAt(a.kid, a.fund, t);
          if (units.sign() <= 0) return no('no units to sell');
          if (a.kind === 'sell') {
            if (a.cents < MIN_GIC_OR_FUND) return no('under the $10 minimum');
            // Dad's decision (stage 7, 2b review): typing the value she's shown (to the
            // nearest cent) sells all, and so does anything up to the exact value when
            // that is a fraction of a cent higher. More than that is refused.
            const close = this.knownClose(a.fund, t);
            if (close) {
              const exact = units.mul(close).mul(Q.of(100));
              const shown = exact.round();
              const amount = Q.of(a.cents);
              const top = exact.cmp(Q.of(shown)) > 0 ? exact : Q.of(shown);
              if (a.cents >= shown && amount.cmp(top) <= 0) kind = 'sell_all';
              else if (amount.cmp(exact) > 0) return no('more than her units are worth');
            }
          }
        }
        const nc = this.nextClose(a.fund, t);
        k.tradeDays.add(key);
        this.reqs.set(a.label, {
          label: a.label,
          kid: a.kid,
          kind,
          fund: a.fund,
          cents: kind === 'sell_all' || a.kind === 'sell_all' ? 0n : a.cents,
          createdAt: t,
          status: 'pending',
          settleAt: nc.at,
          settleDay: nc.day,
        });
        return { ok: true };
      }
      case 'add_rate': {
        const { vehicle, term } = a.rate;
        const week = () => this.week(today, (d) => this.rateOn(vehicle, term, d));
        const before = week();
        this.addRate(a.rate);
        if (this.firstLowerDay(today, before, week())) {
          this.rates.pop();
          return no("a cut needs 7 days' notice");
        }
        return { ok: true };
      }
      case 'set_cap': {
        const week = () => this.week(today, (d) => Q.of(this.capOn(d)));
        const before = week();
        this.caps.push({ cents: a.cents, effective: a.effective, seq: this.seq++, label: a.label });
        if (this.firstLowerDay(today, before, week())) {
          this.caps.pop();
          return no("a cut needs 7 days' notice");
        }
        return { ok: true };
      }
      case 'set_yield': {
        const week = () => this.week(today, (d) => this.yieldOn(a.fund, d));
        const before = week();
        this.yields.push({
          fund: a.fund,
          q: Q.dec(a.yield),
          effective: a.effective,
          seq: this.seq++,
          label: a.label,
        });
        if (this.firstLowerDay(today, before, week())) {
          this.yields.pop();
          return no("a cut needs 7 days' notice");
        }
        return { ok: true };
      }
      case 'cancel': {
        const rate = this.rates.find((r) => r.label === a.label);
        const cap = this.caps.find((c) => c.label === a.label);
        const yld = this.yields.find((y) => y.label === a.label);
        const target = rate ?? cap ?? yld;
        if (!target) throw new Error(`nothing labelled ${a.label}`);
        if (target.cancelled) return no('already cancelled');
        if (target.effective <= today) return no('already started');
        const week = (): Q[] =>
          rate
            ? this.week(today, (d) => this.rateOn(rate.vehicle, rate.term, d))
            : yld
              ? this.week(today, (d) => this.yieldOn(yld.fund, d))
              : this.week(today, (d) => Q.of(this.capOn(d)));
        const before = week();
        target.cancelled = true;
        if (this.firstLowerDay(today, before, week())) {
          target.cancelled = false;
          return no('cancelling a promised raise needs 7 days');
        }
        return { ok: true };
      }
      case 'correct': {
        // Rounds in her favour: an addition up to the cent, a reduction down.
        const exact = Q.dec(a.amount).mul(Q.of(100));
        if (exact.sign() <= 0) return no('nothing to correct');
        const cents = a.direction === 'add' ? exact.ceil() : exact.floor();
        if (cents === 0n) return no('rounds down to nothing');
        // No single correction larger than the deposit cap.
        if (cents > this.capOn(today)) return no('larger than the deposit cap');
        if (a.direction === 'take' && cents > this.available(a.kid))
          return no('more than her free savings');
        // The line it's linked to: her latest posting of that kind. A reduction can't
        // take more than it, less what earlier fixes took from it.
        const kind = LINE_POSTING[a.line];
        if (!kind) throw new Error(`the model doesn't know "${a.line}" lines`);
        const line = this.postings.filter((p) => p.kid === a.kid && p.kind === kind).at(-1);
        if (!line) return no(`no ${a.line} line`);
        const lineKey = `${a.kid}|${kind}|${line.day}|${line.cents}`;
        const taken = this.takenFromLine.get(lineKey) ?? 0n;
        if (a.direction === 'take' && cents > line.cents - taken)
          return no('more than the line it fixes');
        // The extra check: a confirming tap for every reduction; the amount typed
        // again for an addition over $100.
        if ((a.direction === 'take' || cents > 10_000n) && !a.checked)
          return no('needs the extra check');
        if (a.direction === 'take') this.takenFromLine.set(lineKey, taken + cents);
        const k = this.kid(a.kid);
        k.savings += a.direction === 'add' ? cents : -cents;
        this.postings.push({
          kid: k.id,
          day: today,
          kind: a.direction === 'add' ? 'correction_add' : 'correction_take',
          cents,
        });
        return { ok: true };
      }
      case 'set_expiry':
        if (!Number.isInteger(a.days) || a.days < 3 || a.days > 30)
          return no('expiry is 3 to 30 whole days');
        this.expiryRules.push({ days: a.days, effective: a.effective, seq: this.seq++ });
        return { ok: true };
    }
  }

  private newGic(label: string, kid: string, cents: bigint, term: number, start: Day): void {
    if (this.gics.has(label)) throw new Error(`duplicate GIC label ${label}`);
    this.gics.set(label, {
      label,
      kid,
      principal: cents,
      rate: this.rateOn('gic', term, start),
      term,
      start,
      maturity: addMonths(start, term),
      status: 'active',
      balance: cents,
    });
  }

  // ---------------------------------------------------------------- what the screens should show

  snapshot(kid: string): Snapshot {
    const k = this.kid(kid);
    const today = dayOf(this.now);
    const gics = new Map<string, bigint>();
    for (const g of this.gics.values())
      if (g.kid === kid && g.balance !== 0n) gics.set(g.label, g.balance);
    const gicTotal = [...gics.values()].reduce((s, v) => s + v, 0n);
    const units = new Map<FundId, Q>();
    const fundValue = new Map<FundId, bigint>();
    for (const f of FUNDS) {
      const u = this.unitsAt(kid, f, this.now);
      units.set(f, u);
      const c = this.latestClose(f, today, this.now);
      // A value shown, not money posted: nearest cent.
      fundValue.set(f, u.sign() === 0 || !c ? 0n : u.mul(c).mul(Q.of(100)).round());
    }
    const held = this.heldCents(kid);
    const total = k.savings + gicTotal + [...fundValue.values()].reduce((s, v) => s + v, 0n);
    const room = this.capOn(today) - k.netDeposits - this.pendingDeposits(kid);
    return {
      savings: k.savings,
      held,
      available: k.savings - held,
      gics,
      gicTotal,
      units,
      fundValue,
      total,
      netDeposits: k.netDeposits,
      capRoom: room > 0n ? room : 0n,
    };
  }

  gicInfo(label: string): {
    start: Day;
    maturity: Day;
    rate: Q;
    principal: bigint;
    status: string;
  } {
    const g = this.gics.get(label);
    if (!g) throw new Error(`unknown GIC ${label}`);
    return {
      start: g.start,
      maturity: g.maturity,
      rate: g.rate,
      principal: g.principal,
      status: g.status,
    };
  }

  requestStatus(label: string): string | undefined {
    return this.reqs.get(label)?.status;
  }

  settlementOf(label: string): { day: Day; at: Moment } | undefined {
    const r = this.reqs.get(label);
    return r?.settleAt ? { day: r.settleDay!, at: r.settleAt } : undefined;
  }
}
