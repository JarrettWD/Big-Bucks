// Display formats that match the database's own (fmt_rate, fmt_date, term_label),
// so a rate or date reads the same in a notice and on a screen. Text only, never
// arithmetic on money. Dates always come from the database (Edmonton dates it
// worked out); the browser never converts times to dates itself, so a phone with
// different time-zone rules can't show a different day.

const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/** A rate as the database sends it ("2.500", 1.75) → "2.5%", "1.75%", "5.0%". */
export function formatRate(rate: string | number): string {
  const s = String(rate).trim();
  const m = s.match(/^(-?\d+)(?:\.(\d+))?$/);
  if (!m) throw new Error(`Not a rate: "${rate}"`);
  const frac = (m[2] ?? '').replace(/0+$/, '');
  return `${m[1]}.${frac.length === 0 ? '0' : frac}%`;
}

/** A percent for display, with its sign handled by the caller: "-0.67" → "0.67%". */
export function formatPct(pct: string | number, places?: number): string {
  const s = String(pct).trim().replace(/^-/, '');
  if (!/^\d+(\.\d+)?$/.test(s)) throw new Error(`Not a percent: "${pct}"`);
  if (places === undefined) return `${s}%`;
  // The database rounds to `places`; JSON drops trailing zeros (0.90 arrives as 0.9),
  // so pad them back as text. Never rounds.
  const [whole, frac = ''] = s.split('.');
  if (frac.length > places) throw new Error(`More than ${places} decimals: "${pct}"`);
  return `${whole}.${frac.padEnd(places, '0')}%`;
}

/** 1 → "1-month", 12 → "1-year", 24 → "2-year". */
export function termLabel(months: number): string {
  if (months === 12) return '1-year';
  if (months === 24) return '2-year';
  return `${months}-month`;
}

/** Long form for buttons and sentences: 1 → "1 month", 12 → "1 year". */
export function termWords(months: number): string {
  if (months === 12) return '1 year';
  if (months === 24) return '2 years';
  return months === 1 ? '1 month' : `${months} months`;
}

/** "2026-10-07" → "Oct 7" (or "Jan 4, 2027" when it isn't this year). */
export function formatDate(day: string, thisYear?: number): string {
  const m = day.match(/^(\d{4})-(\d{2})-(\d{2})/);
  if (!m) throw new Error(`Not a date: "${day}"`);
  const text = `${MONTHS[Number(m[2]) - 1]} ${Number(m[3])}`;
  return thisYear !== undefined && Number(m[1]) !== thisYear ? `${text}, ${m[1]}` : text;
}

/** Whole days from one date to another (both YYYY-MM-DD). */
export function daysBetween(from: string, to: string): number {
  const ms =
    Date.UTC(+to.slice(0, 4), +to.slice(5, 7) - 1, +to.slice(8, 10)) -
    Date.UTC(+from.slice(0, 4), +from.slice(5, 7) - 1, +from.slice(8, 10));
  return Math.round(ms / 86_400_000);
}
