// Synthetic daily closes for the simulated year: repeatable (seeded), whole-number
// arithmetic only, on each market's real trading days. Includes a Nasdaq-100
// crash of about 25% over three weeks in Feb–Mar 2028 and a recovery, smaller
// drops for the Dow and TSX, a 2-for-1 Nasdaq-100 split, one close that arrives a
// day late, and one that arrives five days late (late money: second audit,
// 2026-10-08).

import { at, daysFrom, weekday, type Day, type Moment } from './model/calendar.ts';
import { MARKET_OF, type FundId, type Holiday } from './model/model.ts';

export interface GeneratedClose {
  fund: FundId;
  day: Day;
  close: string; // dollars, exact decimal
  publishedAt: Moment;
}

export const SPLIT = { fund: 'nasdaq100' as FundId, day: '2027-11-15', from: 1n, to: 2n };
export const LATE_CLOSE = {
  fund: 'nasdaq100' as FundId,
  day: '2027-09-14',
  publishedAt: '2027-09-15 15:30',
  /** The nightly runs that wait for it. */
  waits: ['2027-09-14'],
};
/**
 * The Dow's Dec 31 close arrives five days late: a sale settling at it and every
 * dividend paid on Jan 3 wait for it, and their money reaches savings after that day's
 * interest was worked out, so it gets the interest it missed (Dad, 2026-10-08).
 */
export const LATE_CLOSE_2 = {
  fund: 'dow' as FundId,
  day: '2027-12-31',
  publishedAt: '2028-01-05 15:30',
  waits: ['2027-12-31', '2028-01-01', '2028-01-02', '2028-01-03', '2028-01-04'],
};
/**
 * The Nasdaq-100's Sep 30, 2027 close (the quarter's last) arrives Oct 4. No trade needs
 * it, so only that fund's Oct 1 dividend waits: the Dow and TSX dividends are paid on
 * time, and the Nasdaq-100's reaches savings late with the interest it missed (third
 * audit: each fund on its own).
 */
export const LATE_CLOSE_3 = {
  fund: 'nasdaq100' as FundId,
  day: '2027-09-30',
  publishedAt: '2027-10-04 15:30',
  waits: ['2027-10-01', '2027-10-02', '2027-10-03'],
};
/** A day the Nasdaq-100 falls hard: the dollar sale requested the evening before sells everything. */
export const BIG_DROP_DAY = '2028-02-24';

const CRASH = { from: '2028-02-14', to: '2028-03-06' };
const RECOVERY = { from: '2028-03-07', to: '2028-06-30' };

// Start prices in thousandths of a dollar, daily drift and wobble in basis points.
const PARAMS: Record<
  FundId,
  { start: bigint; drift: number; wobble: number; crashBp: number; recoverBp: number }
> = {
  dow: { start: 420_000n, drift: 3, wobble: 90, crashBp: -70, recoverBp: 12 },
  nasdaq100: { start: 480_000n, drift: 5, wobble: 160, crashBp: -190, recoverBp: 30 },
  tsx: { start: 38_000n, drift: 3, wobble: 80, crashBp: -85, recoverBp: 14 },
};

function rng(seed: number): () => number {
  // xorshift32 on unsigned 32-bit integers: no floating point.
  let s = seed >>> 0 || 1;
  return () => {
    s ^= s << 13;
    s >>>= 0;
    s ^= s >>> 17;
    s ^= s << 5;
    s >>>= 0;
    return s;
  };
}

function isTrading(market: 'nyse' | 'tsx', d: Day, holidays: Map<string, Holiday>): boolean {
  const wd = weekday(d);
  return wd !== 0 && wd !== 6 && holidays.get(`${market}|${d}`)?.kind !== 'closed';
}

function mills(v: bigint): string {
  const whole = v / 1000n;
  const frac = (v % 1000n).toString().padStart(3, '0');
  return `${whole}.${frac}`;
}

export function generateCloses(holidayList: Holiday[], from: Day, through: Day): GeneratedClose[] {
  const holidays = new Map(holidayList.map((h) => [`${h.market}|${h.date}`, h]));
  const out: GeneratedClose[] = [];
  const seeds: Record<FundId, number> = { dow: 20270701, nasdaq100: 20270702, tsx: 20270703 };
  for (const fund of Object.keys(PARAMS) as FundId[]) {
    const p = PARAMS[fund];
    const next = rng(seeds[fund]);
    let price = p.start;
    for (const d of daysFrom(from, through)) {
      if (!isTrading(MARKET_OF[fund], d, holidays)) continue;
      let bp: number;
      if (d >= CRASH.from && d <= CRASH.to)
        bp = fund === 'nasdaq100' && d === BIG_DROP_DAY ? -400 : p.crashBp;
      else if (d >= RECOVERY.from && d <= RECOVERY.to) bp = p.recoverBp + ((next() % 81) - 40);
      else bp = p.drift + ((next() % (2 * p.wobble + 1)) - p.wobble);
      price = (price * BigInt(10000 + bp)) / 10000n;
      if (fund === SPLIT.fund && d === SPLIT.day) price = price / 2n; // 2-for-1: each unit is worth half
      const late = [LATE_CLOSE, LATE_CLOSE_2, LATE_CLOSE_3].find(
        (l) => l.fund === fund && l.day === d,
      );
      const publishedAt = late ? late.publishedAt : at(d, '15:30');
      out.push({ fund, day: d, close: mills(price), publishedAt });
    }
  }
  return out;
}
