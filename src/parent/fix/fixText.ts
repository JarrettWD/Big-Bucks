// Fix a mistake: Dad's wording. Every amount and rule comes from the database
// (correction_preview runs the real correction and rolls it back); this only
// chooses words. What she sees is the database's own notice.

import { formatCents } from '../../lib/money';

export type Direction = 'add' | 'take';
export type CountsAs = 'money' | 'earned';

export interface FixPreview {
  problem: string | null;
  /** Not a block: e.g. an addition larger than the line it fixes. */
  warning: string | null;
  kid: string | null;
  line: { key: string; words: string; on: string; amount_cents: number | null } | null;
  question: { id: number; message: string; asked_on: string } | null;
  savings_cents: number | null;
  held_cents: number | null;
  free_cents: number | null;
  check_over_cents: number | null;
  /** No single correction may be larger (the deposit cap). */
  limit_cents: number | null;
  /** What a reduction may still take from the line. */
  line_left_cents: number | null;
  counts_as: CountsAs | null;
  cents: number | null;
  typed: string | null;
  rounded: boolean;
  needs_check: boolean;
  needs_retype: boolean;
  savings_after_cents: number | null;
  free_after_cents: number | null;
  summary: string | null;
  notices: { title: string; body: string }[];
}

export interface PastCorrection {
  id: number;
  cents: number;
  note: string;
  fixes: string | null;
  summary: string | null;
  who: string | null;
  when: string | null;
}

/**
 * A light check of the amount box, so the database is only asked about something
 * that looks like dollars. The database checks again and decides the rounding.
 */
export function amountLooksOk(text: string): boolean {
  const t = text.replace(/[$,\s]/g, '');
  return /^\d+(\.\d+)?$/.test(t) && /[1-9]/.test(t);
}

/** "$1.24 (you typed $1.2340: rounded up in Robin's favour)" */
export function roundedLine(p: FixPreview, kid: string): string | null {
  if (!p.rounded || p.cents === null || p.typed === null) return null;
  const dir = p.cents > 0 ? 'up' : 'down';
  return `You typed ${p.typed}. It's rounded ${dir} to ${formatCents(Math.abs(p.cents))}, in ${kid}'s favour.`;
}

export function beforeAfter(p: FixPreview): string | null {
  if (p.savings_cents === null || p.savings_after_cents === null || p.free_after_cents === null)
    return null;
  return `Savings ${formatCents(p.savings_cents)} → ${formatCents(p.savings_after_cents)} (free to use ${formatCents(p.free_after_cents)}).`;
}

/** The first button's words. */
export function yesLabel(direction: Direction, cents: number | null, kid: string, check: boolean) {
  const amount = cents === null ? '' : ` ${formatCents(Math.abs(cents))}`;
  if (check) return 'Next: check the amount';
  return direction === 'add' ? `Yes, add${amount} to ${kid}'s savings` : `Yes, take${amount}`;
}

/** The extra check's heading and button (every reduction; additions over the line). */
export function checkHeading(direction: Direction, kid: string): string {
  return direction === 'add'
    ? `Check the amount: you're adding to ${kid}'s savings`
    : `Check the amount: you're taking this from ${kid}'s savings`;
}
export function checkWhy(direction: Direction, overCents: number | null): string {
  return direction === 'take'
    ? 'Taking money away always gets a second look.'
    : `It's more than ${formatCents(overCents ?? 0)}, so type the amount again in case of a typo.`;
}
export function checkYes(direction: Direction, cents: number): string {
  return direction === 'add'
    ? `Yes, add ${formatCents(Math.abs(cents))}`
    : `Yes, take ${formatCents(Math.abs(cents))}`;
}

export const pastLine = (c: PastCorrection) =>
  `${formatCents(c.cents, { sign: true })} · ${c.fixes ?? 'not linked'}`;

export const TEXT = {
  title: (kid: string) => `Fix a mistake in ${kid}'s savings`,
  intro:
    'A fix is a new line in her history, with your note. Nothing she already has is changed or deleted.',
  fixing: 'Fixing:',
  question: 'Her question:',
  questionOnly: 'This question is about a request, so the fix links to the question.',
  figures: (savings: number, held: number, free: number) =>
    `Savings ${formatCents(savings)} · on hold ${formatCents(held)} · free to use ${formatCents(free)}`,
  theFix: 'The fix',
  direction: 'What should the fix do?',
  add: 'Add to her savings',
  take: 'Take from her savings',
  amount: 'Amount in dollars',
  amountHelp: 'Up to 4 decimal places. Anything past the cent rounds in her favour.',
  amountBad: 'Type the amount in dollars, like 12.50.',
  note: 'Note she will read (required)',
  countsAs: 'How should her graphs count it?',
  countsChoice: {
    earned: 'Earned (like interest)',
    money: 'Money in or out (like a deposit)',
  } as Record<CountsAs, string>,
  countsLine: (c: CountsAs) =>
    c === 'money'
      ? 'Her graphs count it as money in or out, not money earned.'
      : 'Her graphs count it as money earned.',
  again: 'Type the amount again to confirm',
  noteHelp: 'What went wrong and what this fixes, in words she understands.',
  willRecord: 'This will be recorded:',
  sheSees: (kid: string) => `${kid} will see this right away:`,
  checking: 'Checking…',
  waiting: 'Choose add or take, and type an amount and a note, to see the preview.',
  back: 'Back',
  saving: 'Saving…',
  done: (summary: string, who: string, when: string) =>
    `Done. ${summary} Recorded: ${who}, ${when}.`,
  another: 'Fix something else',
  toHistory: (kid: string) => `Back to ${kid}'s history`,
  toApprovals: 'Back to Approvals to answer her question',
  pastTitle: 'Corrections so far',
  pastNone: 'No corrections yet.',
  pastWho: (c: PastCorrection) => (c.who && c.when ? `${c.who}, ${c.when}` : 'Not logged'),
  loadError: (e: string) => `Couldn't load this: ${e}`,
  retry: 'Try again',
  linkFromView: 'Fix a mistake',
  linkFromViewHelp: 'Opens your own parent screen for this line. Nothing changes here.',
};
