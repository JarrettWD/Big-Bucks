// Every word on the Graphs tab, in one place. Listed in docs/MESSAGES.md §10.

import { formatCents, toCents, type Cents } from '../../lib/money';
import { formatDate } from '../../lib/format';
import type { FundRange, GraphTab, WorthRange } from './graphData';
import { formatPrice, signedPct } from './graphData';

export const TITLE = 'Graphs';

export const TAB_LABEL: Record<GraphTab, string> = {
  worth: 'Total worth',
  growth: 'Growth',
  money: 'Money in',
  mix: 'Mix',
  gics: 'GICs',
  funds: 'Funds',
};

export const HEADING: Record<GraphTab, string> = {
  worth: 'Total worth over time',
  growth: 'Growth by option',
  money: 'Money in vs money earned',
  mix: 'My mix today',
  gics: 'GIC ladder',
  funds: 'Stock fund detail',
};

/** One sentence on what each graph shows. */
export const WHAT: Record<GraphTab, string> = {
  worth: 'How your savings, GICs and funds add up to your total worth.',
  growth:
    'How much each option grew by itself. Money you put in or take out doesn’t count, only what it earned.',
  money:
    'Money in is everything you’ve put in, minus what you’ve taken out. The gap up to your total worth is what your money earned.',
  mix: 'Where your money is today.',
  gics: 'When each of your GICs is ready, so you can see when your money unlocks.',
  funds: 'The price of one unit of a fund, with your buys and sells marked.',
};

/** The **?** words on each graph, each shown beside its **?**. */
export const WORDS = 'Words to know';
export const TERMS: Record<GraphTab, string[]> = {
  worth: ['Total worth'],
  growth: ['Growth', 'Risk'],
  money: ['Net deposits', 'Money earned'],
  mix: ['Diversification'],
  gics: ['GIC ladder', 'Maturity'],
  funds: ['Unit price', 'Volatility', 'Rate of return'],
};

/** A short lesson under each graph. */
export const LESSON: Partial<Record<GraphTab, string>> = {
  growth:
    'Savings grows slow and steady, GICs grow in a step when they’re ready, and funds bounce up and down.',
  mix: 'Spreading your money out is called diversification: one bad day doesn’t hurt as much.',
  funds: 'Buying low and selling high is hard to time. Nobody knows tomorrow’s price.',
};

export const RANGE_LABEL: Record<WorthRange | FundRange, { short: string; long: string }> = {
  '1M': { short: '1M', long: '1 month' },
  '3M': { short: '3M', long: '3 months' },
  '6M': { short: '6M', long: '6 months' },
  '1Y': { short: '1Y', long: '1 year' },
  All: { short: 'All', long: 'All of it' },
  first: { short: 'Since I bought', long: 'Since your first buy' },
};

export const RANGE_GROUP = 'Time range';
export const UNIT_GROUP = 'Show in';
export const UNIT_DOLLARS = { short: '$', long: 'Dollars' };
export const UNIT_PERCENT = { short: '%', long: 'Percent' };
export const FUND_GROUP = 'Which fund?';

export const SHOW_TABLE = 'Show as a table';
export const HIDE_TABLE = 'Hide the table';
export const LOADING = 'Loading the graph…';
export const LOAD_FAILED =
  'Big Bucks couldn’t load this graph just now. Please try again in a minute.';
export const TRY_AGAIN = 'Try again';
export const NOTHING_YET =
  'Nothing to show yet. Once you have money in Big Bucks, it’ll show up here.';

// ---- Total worth ----

export const DOT_KEY =
  'A dot marks a day you put money in or took it out, so new money isn’t mistaken for growth.';
export const DOT_IN = 'Money in';
export const DOT_OUT = 'Money out';
export function flowWords(flow: Cents): string {
  const c = toCents(flow);
  if (c > 0n) return `You put in ${formatCents(c)}`;
  if (c < 0n) return `You took out ${formatCents(-c)}`;
  return '';
}
export const COL_DAY = 'Day';
export const COL_TOTAL = 'Total';
export const COL_IN_OUT = 'Money in or out';

// ---- Growth ----

export function growthKey(pct: number | string, earned: Cents, unit: 'pct' | 'cents'): string {
  return unit === 'pct' ? signedPct(pct) : formatCents(earned, { sign: true });
}
export const COL_GROWTH = (name: string) => `${name}`;

// ---- Money in vs earned ----

export const LINE_MONEY_IN = 'Money in';
export const LINE_TOTAL = 'Total worth';
export const COL_EARNED = 'Earned';
export function earnedSentence(earned: Cents): string {
  const c = toCents(earned);
  if (c > 0n) return `So far, your money has earned ${formatCents(c)}. 🎉`;
  if (c < 0n)
    return `Right now your total worth is ${formatCents(-c)} less than you put in. Funds go up and down, so that can change.`;
  return 'Your total worth is the same as the money you put in.';
}
/** Under the big "Money earned so far" amount, so the number isn't said twice. */
export function earnedNote(earned: Cents): string {
  const c = toCents(earned);
  if (c > 0n) return 'That’s what your money has made for you. 🎉';
  if (c < 0n)
    return 'Right now your total worth is less than you put in. Funds go up and down, so that can change.';
  return 'Your total worth is the same as the money you put in.';
}

// ---- My mix ----

export const COL_OPTION = 'Option';
export const COL_VALUE = 'Worth';
export const COL_SHARE = 'Share';
export function allIn(name: string): string {
  return `All your money is in ${name} right now.`;
}

// ---- GIC ladder ----

export const NO_GICS = 'You don’t have any GICs right now. You can buy one on Buy / Sell.';
export const LADDER_TODAY = 'Today';
export const LADDER_1Y = '1 year';
export const LADDER_2Y = '2 years';
export function ladderLine(
  g: { principal_cents: Cents; term_months: number; rate: string },
  termLabel: string,
  rate: string,
): string {
  return `${formatCents(g.principal_cents)} · ${termLabel} at ${rate}`;
}
export function ladderReady(maturity: string, ready: boolean, at: Cents, year: number): string {
  return ready
    ? `Ready now: ${formatCents(at)}`
    : `Ready ${formatDate(maturity, year)}: ${formatCents(at)}`;
}
export const COL_GIC = 'GIC';
export const COL_START = 'Started';
export const COL_READY = 'Ready';
export const COL_AT_READY = 'You’ll get';
export const READY_NOW = 'Now';

// ---- Stock fund detail ----

export const BUY = 'You bought';
export const SELL = 'You sold';
export const NOTES_HEADING = 'Big market days';
export const COL_PRICE = 'Unit price';
export const COL_CHANGE = 'Change';
export const COL_YOU = 'You';
export function tradeWords(t: {
  side: 'buy' | 'sell';
  amount_cents: Cents;
  price: number | string;
}): string {
  return `${t.side === 'buy' ? BUY : SELL} ${formatCents(t.amount_cents)} at ${formatPrice(t.price)}`;
}
export const FUND_PCT_LABEL = 'The fund’s change while you had it';
export const MONEY_LABEL = 'Your money’s change';
export const WORTH_LABEL = 'Worth now';
export const PAID_LABEL = 'You paid';

export interface FundFigures {
  /** Labelled figures: the fund's change and her money's change. */
  lines: { label: string; value: string }[];
  /** When there's nothing of hers to show. */
  none?: string;
  /** When the fund's change and her money's change point opposite ways. */
  why?: string;
}

const sign = (v: number | string | bigint) => {
  const s = String(v).trim();
  if (/^-?0*(\.0*)?$/.test(s)) return 0;
  return s.startsWith('-') ? -1 : 1;
};

/**
 * Her fund, for the chosen range. For 1M, 3M and 6M: how the fund did while she
 * had it (time-weighted, %) and how her money did ($), labelled apart, with one
 * plain sentence when they point opposite ways. Since her first buy: what it's
 * worth, what she paid, and her money's change (gain ÷ what she paid).
 */
export function fundFigures(
  name: string,
  range: FundRange,
  c: {
    range_growth_pct: number | string | null;
    range_earned_cents: Cents | null;
    holding: {
      value_cents: Cents;
      cost_cents: Cents;
      gain_cents: Cents;
      return_pct: number | string | null;
    } | null;
  },
): FundFigures {
  if (range === 'first') {
    if (!c.holding) return { lines: [], none: `You don’t own any ${name} right now.` };
    const pct = c.holding.return_pct === null ? '' : ` (${signedPct(c.holding.return_pct)})`;
    return {
      lines: [
        { label: WORTH_LABEL, value: formatCents(c.holding.value_cents) },
        { label: PAID_LABEL, value: formatCents(c.holding.cost_cents) },
        { label: MONEY_LABEL, value: `${formatCents(c.holding.gain_cents, { sign: true })}${pct}` },
      ],
    };
  }
  if (c.range_growth_pct === null || c.range_earned_cents === null)
    return { lines: [], none: `You didn’t own any ${name} in this time.` };
  const fundWay = sign(c.range_growth_pct);
  const moneyWay = sign(toCents(c.range_earned_cents));
  let why: string | undefined;
  if (fundWay > 0 && moneyWay < 0)
    why = `These point different ways because of timing: you had more money in the ${name} on its down days than on its up days. When you buy matters, not just what you buy.`;
  if (fundWay < 0 && moneyWay > 0)
    why = `These point different ways because of timing: you had more money in the ${name} on its up days than on its down days. When you buy matters, not just what you buy.`;
  return {
    lines: [
      { label: FUND_PCT_LABEL, value: signedPct(c.range_growth_pct) },
      { label: MONEY_LABEL, value: formatCents(c.range_earned_cents, { sign: true }) },
    ],
    why,
  };
}

/** The whole fund over the range shown, whether she owned it or not. */
export function fundChange(name: string, pct: number | string | null): string {
  if (pct === null) return '';
  const way = sign(pct);
  const amount = signedPct(pct).replace(/^[+−]/, '');
  if (way === 0) return `Over the whole time shown, the ${name} fund didn’t change.`;
  return `Over the whole time shown, the ${name} fund went ${way > 0 ? 'up' : 'down'} ${amount}.`;
}

export const EARNED_LABEL = 'Money earned so far';
export const SAVINGS_STEPS =
  'Savings interest arrives on the 1st of each month, so the savings line steps up a little then.';
