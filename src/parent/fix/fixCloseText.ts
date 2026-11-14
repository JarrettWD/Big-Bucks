// Fix a close: Dad's wording (the price fix, 2026-11). Every figure and rule comes from the
// database (close_fix_preview reads the stored close and what the fix would change; correct_fund_price
// does it); this only chooses words.

export interface CloseAdjustment {
  kind: 'buy' | 'sale' | 'sale_all' | 'dividend' | 'no_change';
  side: 'buy' | 'sell' | 'dividend';
  kid_name: string | null;
  request_id?: number;
  words: string;
}

export interface ClosePreview {
  fund_id: string;
  fund_name: string;
  date: string;
  day_words: string;
  old_close_words: string;
  fetched_words: string;
  final: boolean;
  new_close_words: string | null;
  adjustments: CloseAdjustment[];
}

export const FUNDS: { id: string; name: string }[] = [
  { id: 'dow', name: 'Dow Jones (DIA)' },
  { id: 'nasdaq100', name: 'Nasdaq-100 (QQQ)' },
  { id: 'tsx', name: 'TSX (XIC)' },
];

export const TEXT = {
  title: 'Fix a close',
  intro:
    'Use this when a stored close doesn’t match the official one (for example Yahoo Finance’s daily history for the fund). Anything that used the wrong close is fixed in her favour, never against her: a buy gets its missing units, a sale its missing money with the interest it would have earned. Each girl gets a notice.',
  fund: 'Fund',
  day: 'Day of the close',
  stored: (p: ClosePreview) =>
    `Stored close for ${p.day_words}: ${p.old_close_words} (fetched ${p.fetched_words}${p.final ? '' : ', not final yet'}).`,
  official: 'The official close',
  officialHelp: 'Type it exactly as published, for example 647.05.',
  officialBad: 'That doesn’t look like a price. Type numbers only, for example 647.05.',
  source: 'Where it comes from',
  sourceHelp: 'For example "Yahoo Finance daily history, checked Nov 21". It goes in the log.',
  checking: 'Checking…',
  waiting: 'Choose the fund and day to see the stored close.',
  typeClose: 'Type the official close and where it comes from to see what changes.',
  nothingUsed: 'No trade or dividend used this close, so only the stored close changes.',
  changes: 'What changes',
  same: 'That’s the close already stored.',
  yes: 'Yes, fix the close',
  saving: 'Fixing…',
  done: (fund: string, day: string, close: string) =>
    `Done. The ${fund} close for ${day} is now ${close}, and everything that used it is fixed. It’s in your log.`,
  back: 'Back to the dashboard',
};

/** A light check of the price box, so the database is only asked about something that looks like a price. */
export function closeLooksOk(text: string): boolean {
  const t = text.replace(/[$,\s]/g, '');
  return /^\d+(\.\d{1,8})?$/.test(t) && /[1-9]/.test(t);
}

/** The price as the database takes it: digits and a point. */
export const cleanClose = (text: string) => text.replace(/[$,\s]/g, '');

/** One line per trade or dividend: "Robin's buy: Adds 0.00003646 units, worth about 2¢." */
export function adjustmentLine(a: CloseAdjustment): string {
  const who = a.kid_name ?? 'A test account';
  const what = a.side === 'buy' ? 'buy' : a.side === 'sell' ? 'sale' : 'dividend';
  return `${who}’s ${what}: ${a.words}`;
}
