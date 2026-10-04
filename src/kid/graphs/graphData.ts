// The Graphs tab's data: what the database sends, and the small reshaping each
// chart needs. Every figure, percent and date comes from the database; nothing
// here adds up money or works out a date. Cents become plain numbers only to
// place a point on a chart (they're whole numbers, well inside the safe range);
// every amount written on screen is formatted from the database's own cents.

import { OPTION } from '../../lib/colours';
import { toCents, type Cents } from '../../lib/money';

export type GraphTab = 'worth' | 'growth' | 'money' | 'mix' | 'gics' | 'funds';
export const GRAPH_TABS: GraphTab[] = ['worth', 'growth', 'money', 'mix', 'gics', 'funds'];

export type WorthRange = '1M' | '3M' | '1Y' | 'All';
export type FundRange = '1M' | '3M' | '6M' | 'first';
export const WORTH_RANGES: WorthRange[] = ['1M', '3M', '1Y', 'All'];
export const FUND_RANGES: FundRange[] = ['1M', '3M', '6M', 'first'];

/** graph_ranges(account) */
export interface Ranges {
  today: string;
  first_day: string;
  worth: Record<WorthRange, string>;
  fund: Record<'1M' | '3M' | '6M', string>;
  first_purchase: Record<string, string>;
  ladder_until: string;
}

/** A fund's name and colour (from the funds table). */
export interface FundInfo {
  id: string;
  name: string;
  colour: string;
  sort_order: number;
}

/** One option on the graphs: savings, GICs or a fund. */
export interface OptionInfo {
  key: string;
  name: string;
  colour: string;
  /** A line pattern, so lines differ by more than colour ('' is solid). */
  dash: string;
}

const DASHES: Record<string, string> = {
  savings: '',
  gic: '9 5',
  dow: '',
  nasdaq100: '',
  tsx: '12 5',
};

/** Savings and GICs first, then the funds in their usual order. */
export function optionList(funds: FundInfo[]): OptionInfo[] {
  return [
    { key: 'savings', name: 'Savings', colour: OPTION.savings, dash: DASHES.savings },
    { key: 'gic', name: 'GICs', colour: OPTION.gic, dash: DASHES.gic },
    ...[...funds]
      .sort((a, b) => a.sort_order - b.sort_order)
      .map((f) => ({ key: f.id, name: f.name, colour: f.colour, dash: DASHES[f.id] ?? '' })),
  ];
}

/** Which day a range starts on. Fund ranges: "since first purchase" only if she bought it. */
export function worthFrom(r: Ranges, range: WorthRange): string {
  return r.worth[range];
}
export function fundFrom(r: Ranges, fund: string, range: FundRange): string | null {
  if (range === 'first') return r.first_purchase[fund] ?? null;
  return r.fund[range];
}
/** The fund ranges she can pick: "since first purchase" only for a fund she has bought. */
export function fundRanges(r: Ranges, fund: string): FundRange[] {
  return FUND_RANGES.filter((x) => x !== 'first' || r.first_purchase[fund] !== undefined);
}

/** A whole number of cents as a number for a chart's scale. */
export function plot(c: Cents): number {
  return Number(toCents(c));
}

// ---- Total worth over time (daily_balances) -----------------------------------------------

export interface DailyBalance {
  balance_date: string;
  savings_cents: Cents;
  gic_cents: Cents;
  stock_cents: Cents;
  total_cents: Cents;
  net_flow_cents: Cents;
  fund_values: Record<string, Cents> | null;
}

export interface WorthRow {
  day: string;
  /** Each option's value, keyed by option. */
  values: Record<string, Cents>;
  total: Cents;
  flow: Cents;
  /** Plot positions: option key → number, plus "total". */
  plot: Record<string, number>;
}

/** Each day's stacked values, and which options ever have money in the range. */
export function worthRows(
  rows: DailyBalance[],
  options: OptionInfo[],
): { rows: WorthRow[]; shown: OptionInfo[] } {
  const out = rows.map((r) => {
    const values: Record<string, Cents> = { savings: r.savings_cents, gic: r.gic_cents };
    for (const [k, v] of Object.entries(r.fund_values ?? {})) values[k] = v;
    const p: Record<string, number> = { total: plot(r.total_cents) };
    for (const o of options) p[o.key] = values[o.key] === undefined ? 0 : plot(values[o.key]);
    return { day: r.balance_date, values, total: r.total_cents, flow: r.net_flow_cents, plot: p };
  });
  const shown = options.filter((o) =>
    out.some((r) => r.values[o.key] !== undefined && toCents(r.values[o.key]) !== 0n),
  );
  return { rows: out, shown };
}

// ---- Growth by option (growth_by_option) ---------------------------------------------------

export interface GrowthPoint {
  day: string;
  option: string;
  growth_pct: string | number;
  earned_cents: Cents;
  flow_cents: Cents;
}

export interface GrowthRow {
  day: string;
  /** option → its point that day (missing before its line starts). */
  points: Record<string, GrowthPoint>;
  /** Plot positions per option, in % or cents, by unit. */
  pct: Record<string, number>;
  cents: Record<string, number>;
}

/** One row per day, with a point for every option that has a line that day. */
export function growthRows(points: GrowthPoint[], options: OptionInfo[]) {
  const byDay = new Map<string, GrowthRow>();
  for (const p of points) {
    let row = byDay.get(p.day);
    if (!row) {
      row = { day: p.day, points: {}, pct: {}, cents: {} };
      byDay.set(p.day, row);
    }
    row.points[p.option] = p;
    row.pct[p.option] = Number(p.growth_pct);
    row.cents[p.option] = plot(p.earned_cents);
  }
  const rows = [...byDay.values()].sort((a, b) => (a.day < b.day ? -1 : a.day > b.day ? 1 : 0));
  const shown = options.filter((o) => points.some((p) => p.option === o.key));
  return { rows, shown };
}

/** Each option's last point (for the key under the chart). */
export function lastPoints(points: GrowthPoint[]): Record<string, GrowthPoint> {
  const last: Record<string, GrowthPoint> = {};
  for (const p of points) if (!last[p.option] || last[p.option].day < p.day) last[p.option] = p;
  return last;
}

// ---- Money in vs money earned --------------------------------------------------------------

export interface MoneyInRow {
  day: string;
  net_deposits_cents: Cents;
  total_cents: Cents;
  earned_cents: Cents;
}

// ---- My mix today -------------------------------------------------------------------------------

export interface MixRow {
  option: string;
  name: string;
  value_cents: Cents;
  mix_pct: number;
}

// ---- GIC ladder -------------------------------------------------------------------------------

export interface LadderRow {
  gic_id: number;
  principal_cents: Cents;
  rate: string;
  term_months: number;
  start_date: string;
  maturity_date: string;
  interest_cents: Cents;
  at_maturity_cents: Cents;
  ready: boolean;
}

/**
 * How wide a GIC's bar is on the ladder: from today to its ready date, as % of
 * the width from today to the ladder's end. Day counts come from the dates the
 * database sent (no clock). Never narrower than 3%, so one that's ready soon shows.
 */
export function ladderWidth(
  maturity: string,
  today: string,
  until: string,
  daysBetween: (a: string, b: string) => number,
): number {
  const span = Math.max(daysBetween(today, until), 1);
  const end = Math.min(Math.max(daysBetween(today, maturity), 0), span);
  return Math.min(Math.max((end / span) * 100, 3), 100);
}

// ---- Stock fund detail (fund_chart) -------------------------------------------------------

export interface FundChart {
  fund_id: string;
  from: string;
  today: string;
  closes: { d: string; c: number | string; pct: number | string }[];
  change_pct: number | string | null;
  trades: {
    d: string;
    side: 'buy' | 'sell';
    price: number | string;
    units: number | string;
    amount_cents: Cents;
  }[];
  notes: { d: string; body: string }[];
  range_growth_pct: number | string | null;
  range_earned_cents: Cents | null;
  holding: {
    units: number | string;
    value_cents: Cents;
    cost_cents: Cents;
    gain_cents: Cents;
    return_pct: number | string | null;
  } | null;
}

export interface FundRow {
  day: string;
  close: number;
  pct: number;
  closeText: string;
  pctText: string;
  buy?: FundChart['trades'][number];
  sell?: FundChart['trades'][number];
  note?: string;
}

/** Each close, with her trade and any market-move note on that day. */
export function fundRows(c: FundChart): FundRow[] {
  return c.closes.map((x) => ({
    day: x.d,
    close: Number(x.c),
    pct: Number(x.pct),
    closeText: String(x.c),
    pctText: String(x.pct),
    buy: c.trades.find((t) => t.d === x.d && t.side === 'buy'),
    sell: c.trades.find((t) => t.d === x.d && t.side === 'sell'),
    note: c.notes.find((n) => n.d === x.d)?.body,
  }));
}

/**
 * A unit price for display: the database's exact close as dollars and cents,
 * written from its text (no float rounding): "396" → "$396.00", "40.123" → "$40.123".
 */
export function formatPrice(close: number | string): string {
  const s = String(close).trim();
  const m = s.match(/^(\d+)(?:\.(\d+))?$/);
  if (!m) throw new Error(`Not a price: "${close}"`);
  const whole = m[1].replace(/\B(?=(\d{3})+(?!\d))/g, ',');
  const frac = (m[2] ?? '').padEnd(2, '0');
  return `$${whole}.${frac}`;
}

/**
 * A percent with its sign and two decimals, from the database's figure (already
 * rounded to 2 places there; JSON can drop trailing zeros, so they're put back as
 * text): "1.11" → "+1.11%", 19.9 → "+19.90%", "-10" → "−10.00%", 0 → "0.00%".
 */
export function signedPct(pct: number | string): string {
  const s = String(pct).trim();
  const m = s.match(/^(-?)(\d+)(?:\.(\d{1,2}))?$/);
  if (!m) throw new Error(`Not a percent: "${pct}"`);
  const text = `${m[2]}.${(m[3] ?? '').padEnd(2, '0')}`;
  if (/^0+\.00$/.test(text)) return `${text}%`;
  return `${m[1] ? '−' : '+'}${text}%`;
}

/** Tick labels on a dollar axis: whole dollars only ("$1,200"), from a plotted cents number. */
export function axisDollars(cents: number): string {
  const neg = cents < 0;
  const whole = Math.round(Math.abs(cents) / 100)
    .toString()
    .replace(/\B(?=(\d{3})+(?!\d))/g, ',');
  return `${neg ? '−' : ''}$${whole}`;
}
