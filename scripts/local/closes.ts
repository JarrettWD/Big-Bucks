// Synthetic closes for the LOCAL database after the demo: each trading day's
// close follows on from the last stored one by a small repeatable move (seeded
// by fund and date), in whole-number arithmetic. Local only: real closes come
// from the price provider in stage 4.

import type { LocalDb } from '../timemachine/db.ts';
import { addDays, daysFrom, toNum, type Day } from '../timemachine/model/calendar.ts';

// Daily drift and wobble in basis points, as in the time machine's prices.
const MOVE: Record<string, { drift: number; wobble: number }> = {
  dow: { drift: 3, wobble: 90 },
  nasdaq100: { drift: 5, wobble: 160 },
  tsx: { drift: 3, wobble: 80 },
};

/** A move in basis points for a fund on a day: the same answer every time. */
export function moveBp(fund: string, day: Day): number {
  const m = MOVE[fund] ?? { drift: 0, wobble: 50 };
  let s = (toNum(day) * 2654435761 + fund.length * 40503 + fund.charCodeAt(0)) >>> 0 || 1;
  for (let i = 0; i < 3; i++) {
    s ^= s << 13;
    s >>>= 0;
    s ^= s >>> 17;
    s ^= s << 5;
    s >>>= 0;
  }
  return m.drift + ((s % (2 * m.wobble + 1)) - m.wobble);
}

/** Next close in thousandths of a dollar. */
export function nextClose(lastMills: bigint, bp: number): bigint {
  return (lastMills * BigInt(10000 + bp)) / 10000n;
}

const toMills = (close: string): bigint => {
  const [w, f = ''] = close.split('.');
  return BigInt(w) * 1000n + BigInt((f + '000').slice(0, 3));
};
const fromMills = (v: bigint): string => `${v / 1000n}.${(v % 1000n).toString().padStart(3, '0')}`;

/**
 * Adds a close for every trading day after each fund's last stored close, up to
 * and including `through`. Returns how many were added.
 */
export async function addSyntheticCloses(db: LocalDb, through: Day): Promise<number> {
  const funds = await db.q<{
    id: string;
    market: string;
    last_day: string | null;
    last_close: string | null;
  }>(
    `select f.id, f.market::text,
            (select max(p.price_date)::text from public.fund_prices p where p.fund_id = f.id) as last_day,
            (select p.close::text from public.fund_prices p where p.fund_id = f.id
              order by p.price_date desc limit 1) as last_close
       from public.funds f order by f.id`,
  );
  let added = 0;
  for (const f of funds) {
    if (!f.last_day || !f.last_close)
      throw new Error(`No closes yet for ${f.id}. Run "npm run demo" first.`);
    let price = toMills(f.last_close);
    const from = addDays(f.last_day, 1);
    if (from > through) continue;
    for (const d of daysFrom(from, through)) {
      const [{ open }] = await db.q<{ open: boolean }>(
        `select public.is_trading_day($1::public.market, $2) as open`,
        [f.market, d],
      );
      if (!open) continue;
      price = nextClose(price, moveBp(f.id, d));
      await db.q(
        `insert into public.fund_prices (fund_id, price_date, close) values ($1, $2, $3)`,
        [f.id, d, fromMills(price)],
      );
      added++;
    }
  }
  return added;
}
