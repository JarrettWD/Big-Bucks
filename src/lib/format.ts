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
export function formatPct(pct: string | number): string {
  const s = String(pct).trim().replace(/^-/, '');
  if (!/^\d+(\.\d+)?$/.test(s)) throw new Error(`Not a percent: "${pct}"`);
  return `${s}%`;
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

// Alberta's time rule, the same one the database pins in edmonton_local(): from
// 2026-03-08 09:00 UTC on, Alberta is UTC−6 all year (Official Time Act, 2026).
// Plain arithmetic, so a phone with old time-zone data still gets the right day.
// Prefer dates the database worked out; this is for the few lists that read a
// timestamp straight from a table.
const ALBERTA_FIXED_FROM_MS = Date.UTC(2026, 2, 8, 9, 0, 0);
const SIX_HOURS_MS = 6 * 3_600_000;

/** A moment from the database ("2026-11-02T05:30:00+00:00") → its Alberta date, "2026-11-01". */
export function albertaDate(moment: string): string {
  const ms = Date.parse(moment);
  if (Number.isNaN(ms)) throw new Error(`Not a moment: "${moment}"`);
  if (ms < ALBERTA_FIXED_FROM_MS) throw new Error(`Before Alberta's fixed time rule: "${moment}"`);
  return new Date(ms - SIX_HOURS_MS).toISOString().slice(0, 10);
}
