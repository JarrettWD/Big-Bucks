// The wording for the learning features (stage 11, MESSAGES §14). Every amount comes from
// the database; these only put words around them.

import { formatDate } from '../../lib/format';
import { formatCents } from '../../lib/money';
import { fundLabel } from '../fundNames';

export const TEXT = {
  // Modes
  simpler: '👀 Simpler view',
  moreDetail: '🔎 More detail',
  simplerNote: 'Big numbers and fewer graphs. You can switch back any time.',
  // Inflation
  whatBuy: '💡 What will it buy?',
  // What-if
  whatIfTitle: 'What if? 🤔',
  whatIfIntro:
    "Here's what would have happened if all the money you put in had gone into just one place.",
  whatIfYours: 'What you have',
  whatIfSavings: 'All in savings',
  whatIfGics: 'All in 1-year GICs',
  whatIfNasdaq: 'All in the Nasdaq-100 fund (QQQ)',
  whatIfClose: 'Different choices do better at different times. Nobody can know ahead of time.',
  whatIfNone: "Once you've put money in, you'll see what would have happened with it here.",
  whatIfHow: 'How was this calculated?',
  whatIfHowLines: [
    'Each case uses your real deposits and withdrawals, on the days they happened.',
    'Savings: the savings rate on each day, with interest paid on the 1st, like your real savings.',
    "1-year GICs: each deposit buys a 1-year GIC that day, at that day's rate. When one matures, all of it goes into a new one. (The $10 smallest GIC is left out.)",
    'The Nasdaq-100 fund (QQQ): each deposit buys at the next market close. Dividends are paid like your real ones.',
    'A withdrawal comes out the way it really would: from savings, by selling units, or by breaking a GIC early (which pays no interest).',
    'Interest counts when it would really be paid, just like your real money.',
  ],
  // Markets
  marketsTitle: 'Compare the markets 🌎',
  marketsIntro: 'Same time, different markets. Each fund follows a different group of companies.',
  marketsRanges: {
    '1M': '1M',
    '3M': '3M',
    '1Y': '1Y',
    '2Y': '2Y',
    start: 'Since you started',
  } as Record<string, string>,
  // Reflection
  reflectTitle: 'Why did you sell? ✏️',
  reflectNote: 'Mom and Dad can see this.',
  reflectSkipNote: 'You can skip this.',
  reflectSave: 'Save',
  reflectSkip: 'Skip',
  reflectSaved: 'Saved. You can find it in your history.',
  whyISold: 'Why I sold:',
  // Statements
  statementsLink: '📄 Your statements',
  statementsTitle: 'Your statements 📄',
  statementsIntro:
    'Each month: where your money started, what came in and went out, what it earned, and where it ended.',
  start: 'Starting balance',
  moneyIn: 'Money in',
  moneyOut: 'Money out',
  interest: 'Interest',
  dividends: 'Dividends',
  fundGains: 'Fund gains or losses',
  fixes: 'Fixes from Dad',
  earned: 'Earned',
  end: 'Ending balance',
  print: '🖨️ Print or save as PDF',
  checking: "This statement is being checked. It'll be here soon.",
  none: 'Your first statement comes at the end of your first month.',
} as const;

export function monthName(month: string): string {
  const [y, m] = month.split('-').map(Number);
  return `${['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'][m - 1]} ${y}`;
}

export const readyOn = (month: string, readyDay: string, year: number) =>
  `Your ${monthName(month).split(' ')[0]} statement will be ready on ${formatDate(readyDay, year)}.`;

/** Under a statement: this month's savings interest is paid on the 1st, so it's on next month's. */
export function interestNote(month: string): string {
  const [y, m] = month.split('-').map(Number);
  const next = `${m === 12 ? y + 1 : y}-${String((m % 12) + 1).padStart(2, '0')}-01`;
  const nextName = monthName(next).split(' ')[0];
  return `Your ${monthName(month).split(' ')[0]} interest is paid on ${nextName.slice(0, 3)} 1, so it shows on your ${nextName} statement.`;
}

export const startLine = (from: string, opened: boolean, year: number) =>
  opened ? `${TEXT.start} (${formatDate(from, year)}, when your account opened)` : TEXT.start;

export const gicsGrowing = (n: number) =>
  n > 0
    ? `GIC interest is paid when each GIC matures. ${n === 1 ? '1 is' : `${n} are`} still growing.`
    : null;

/** "In a year, at today's 2% savings rate, your $183.67 would grow to about $187.38. ..." */
export function savingsInflation(
  s: {
    now_cents: number | string;
    savings_rate: string | number;
    in_a_year_cents: number | string;
    buys_like_cents: number | string;
  },
  inflation: string,
): string {
  return `In a year, at today's ${Number(s.savings_rate)}% savings rate, your ${formatCents(s.now_cents)} would grow to about ${formatCents(s.in_a_year_cents)}. Prices usually go up too, about ${Number(inflation)}% a year right now, so it would buy about what ${formatCents(s.buys_like_cents)} buys today.`;
}

export function gicInflation(
  g: {
    at_maturity_cents: number | string;
    buys_like_cents: number | string;
    maturity_date: string;
  },
  year: number,
): string {
  return `When it matures on ${formatDate(g.maturity_date, year)}, it pays ${formatCents(g.at_maturity_cents)}. With prices going up meanwhile, that buys about what ${formatCents(g.buys_like_cents)} buys today.`;
}

/** A percent to one decimal: "2.0%". */
const pct1 = (n: number) => `${Math.abs(n).toFixed(1)}%`;

/** "the TSX fund (XIC)", "the Dow Jones fund (DIA) and the TSX fund (XIC)". */
const theFunds = (names: string[]) =>
  names
    .map((n) => `the ${n}`)
    .reduce(
      (a, n, i, all) => (i === 0 ? n : i === all.length - 1 ? `${a} and ${n}` : `${a}, ${n}`),
      '',
    );

const cap = (s: string) => s.charAt(0).toUpperCase() + s.slice(1);

/**
 * Under her total (Dad, 2026-11-03): the whole thought in one place, never a sentence that
 * follows one on another card.
 */
export function totalInflationNote(inflation: string): string {
  return `Prices usually go up a little each year (about ${pct1(Number(inflation))} right now), so the same money buys a bit less later. That's normal. It's one reason people use GICs and funds too.`;
}

export interface FundYear {
  fund?: string;
  name: string;
  year_change_pct: string | number | null;
}

/**
 * One card for all her funds (Dad, 2026-11-03): an intro, a line per fund with its change over
 * the past year to one decimal, and a closing line that says only what's true. Each fund is
 * compared with prices at the same one-decimal figures she sees.
 */
export function fundsInflation(
  funds: FundYear[],
  inflation: string,
): { intro: string; lines: string[]; closing: string | null } {
  const infl = Number(Number(inflation).toFixed(1));
  const shown = funds.map((f) => ({
    name: fundLabel(f.fund, f.name),
    pct: f.year_change_pct === null ? null : Number(Number(f.year_change_pct).toFixed(1)),
  }));
  const lines = shown.map((f) =>
    f.pct === null
      ? `${f.name}: not a full year of prices yet`
      : `${f.name}: ${f.pct > 0 ? `up ${pct1(f.pct)}` : f.pct < 0 ? `down ${pct1(f.pct)}` : 'no change'}`,
  );
  const known = shown.filter((f) => f.pct !== null) as { name: string; pct: number }[];
  const prices = `prices did (about ${pct1(infl)})`;
  let closing: string | null = null;
  if (known.length > 0) {
    const more = known.filter((f) => f.pct > infl).map((f) => f.name);
    const same = known.filter((f) => f.pct >= 0 && f.pct === infl).map((f) => f.name);
    const less = known.filter((f) => f.pct >= 0 && f.pct < infl).map((f) => f.name);
    const down = known.filter((f) => f.pct < 0).map((f) => f.name);
    if (more.length === known.length)
      closing =
        known.length === 1
          ? `It grew more than ${prices}.`
          : `${known.length === 2 ? 'Both' : `All ${known.length}`} grew more than ${prices}.`;
    else {
      const parts: string[] = [];
      if (more.length) parts.push(`${cap(theFunds(more))} grew more than ${prices}.`);
      if (same.length) parts.push(`${cap(theFunds(same))} grew about as much as ${prices}.`);
      if (less.length)
        parts.push(
          `${cap(theFunds(less))} grew less than ${prices}, so ${less.length === 1 ? 'it buys' : 'they buy'} a little less than a year ago.`,
        );
      if (down.length)
        parts.push(
          `${cap(theFunds(down))} went down, so ${down.length === 1 ? 'it buys' : 'they buy'} less than a year ago.`,
        );
      closing = parts.join(' ');
    }
  }
  return {
    intro: "Funds don't have a set rate. They go up and down. Over the past year:",
    lines,
    closing,
  };
}
