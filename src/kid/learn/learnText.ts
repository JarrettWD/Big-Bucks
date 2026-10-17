// The wording for the learning features (stage 11, MESSAGES §14). Every amount comes from
// the database; these only put words around them.

import { formatDate } from '../../lib/format';
import { formatCents } from '../../lib/money';

export const TEXT = {
  // Modes
  simpler: '👀 Simpler view',
  moreDetail: '🔎 More detail',
  simplerNote: 'Big numbers and fewer graphs. You can switch back any time.',
  // Inflation
  whatBuy: '💡 What will it buy?',
  inflationNote: "That's normal. It's one reason people use GICs and funds too.",
  // What-if
  whatIfTitle: 'What if? 🤔',
  whatIfIntro:
    "Here's what would have happened if all the money you put in had gone into just one place.",
  whatIfYours: 'What you have',
  whatIfSavings: 'All in savings',
  whatIfGics: 'All in 1-year GICs',
  whatIfNasdaq: 'All in the Nasdaq-100 fund',
  whatIfClose: 'Different choices do better at different times. Nobody can know ahead of time.',
  whatIfNone: "Once you've put money in, you'll see what would have happened with it here.",
  whatIfHow: 'How was this calculated?',
  whatIfHowLines: [
    'Each case uses your real deposits and withdrawals, on the days they happened.',
    'Savings: the savings rate on each day, with interest paid on the 1st, like your real savings.',
    "1-year GICs: each deposit buys a 1-year GIC that day, at that day's rate. When one finishes, all of it goes into a new one. (The $10 smallest GIC is left out.)",
    'The Nasdaq-100 fund: each deposit buys at the next market close. Dividends are paid like your real ones.',
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
    ? `GIC interest is paid when each GIC finishes. ${n === 1 ? '1 is' : `${n} are`} still growing.`
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
  return `When it finishes on ${formatDate(g.maturity_date, year)}, it pays ${formatCents(g.at_maturity_cents)}. With prices going up meanwhile, that buys about what ${formatCents(g.buys_like_cents)} buys today.`;
}

export function fundInflation(
  f: { name: string; year_change_pct: string | number | null },
  inflation: string,
): string {
  if (f.year_change_pct === null)
    return `Funds don't have a set rate. Prices go up about ${Number(inflation)}% a year right now.`;
  const pct = Number(f.year_change_pct);
  const word = pct >= 0 ? 'went up' : 'went down';
  return `Funds don't have a set rate. Over the past year, the ${f.name} fund ${word} ${Math.abs(pct).toFixed(2).replace(/\.00$/, '')}%, while prices went up about ${Number(inflation)}%.`;
}
