// Calendar maths for the reference model. Dates are 'YYYY-MM-DD' strings and
// moments are Edmonton wall-clock 'YYYY-MM-DD HH:MM' strings, which sort
// correctly as plain text. No clock is read here: time comes from the script.

export type Day = string; // 'YYYY-MM-DD'
export type Moment = string; // 'YYYY-MM-DD HH:MM', Edmonton time

function pad(n: number, w = 2): string {
  return String(n).padStart(w, '0');
}

export function isLeap(y: number): boolean {
  return (y % 4 === 0 && y % 100 !== 0) || y % 400 === 0;
}

export function daysInYear(y: number): number {
  return isLeap(y) ? 366 : 365;
}

export function daysInMonth(y: number, m: number): number {
  return [31, isLeap(y) ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][m - 1];
}

export function parts(d: Day): [number, number, number] {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(d);
  if (!m) throw new Error(`bad date ${d}`);
  return [Number(m[1]), Number(m[2]), Number(m[3])];
}

export function mk(y: number, m: number, d: number): Day {
  return `${pad(y, 4)}-${pad(m)}-${pad(d)}`;
}

// Days since 1970-01-01 (proleptic Gregorian), Howard Hinnant's algorithm.
export function toNum(d: Day): number {
  let [y, m] = parts(d);
  const day = parts(d)[2];
  y -= m <= 2 ? 1 : 0;
  const era = Math.floor(y / 400);
  const yoe = y - era * 400;
  m = m > 2 ? m - 3 : m + 9;
  const doy = Math.floor((153 * m + 2) / 5) + day - 1;
  const doe = yoe * 365 + Math.floor(yoe / 4) - Math.floor(yoe / 100) + doy;
  return era * 146097 + doe - 719468;
}

export function fromNum(z: number): Day {
  z += 719468;
  const era = Math.floor(z / 146097);
  const doe = z - era * 146097;
  const yoe = Math.floor(
    (doe - Math.floor(doe / 1460) + Math.floor(doe / 36524) - Math.floor(doe / 146096)) / 365,
  );
  const doy = doe - (365 * yoe + Math.floor(yoe / 4) - Math.floor(yoe / 100));
  const mp = Math.floor((5 * doy + 2) / 153);
  const d = doy - Math.floor((153 * mp + 2) / 5) + 1;
  const m = mp < 10 ? mp + 3 : mp - 9;
  const y = yoe + era * 400 + (m <= 2 ? 1 : 0);
  return mk(y, m, d);
}

export function addDays(d: Day, n: number): Day {
  return fromNum(toNum(d) + n);
}

export function diffDays(a: Day, b: Day): number {
  return toNum(a) - toNum(b);
}

/** 0 = Sunday … 6 = Saturday. */
export function weekday(d: Day): number {
  return (((toNum(d) + 4) % 7) + 7) % 7; // 1970-01-01 was a Thursday
}

/** Same day of the month, `n` months later, moved back to the month's last day when needed. */
export function addMonths(d: Day, n: number): Day {
  const [y, m, day] = parts(d);
  const idx = y * 12 + (m - 1) + n;
  const ny = Math.floor(idx / 12);
  const nm = (idx % 12) + 1;
  return mk(ny, nm, Math.min(day, daysInMonth(ny, nm)));
}

export function dayOf(t: Moment): Day {
  return t.slice(0, 10);
}

export function at(d: Day, hhmm: string): Moment {
  return `${d} ${hhmm}`;
}

export function* daysFrom(from: Day, through: Day): Generator<Day> {
  for (let n = toNum(from); n <= toNum(through); n++) yield fromNum(n);
}

// Clock rules, written independently of the database's pinned rule.
//
// Toronto (and New York) daylight saving, since 2007: from 2:00 am on the second
// Sunday of March to 2:00 am on the first Sunday of November. UTC−4 in summer,
// UTC−5 otherwise.
//
// Alberta: the same daylight saving until March 8, 2026, when the clocks went
// forward for the last time. From 3:00 am that day Alberta is UTC−6 all year
// (Official Time Act, 2026). Before then: UTC−6 in summer, UTC−7 otherwise.
function nthSunday(y: number, m: number, nth: number): Day {
  const first = mk(y, m, 1);
  const offset = (7 - weekday(first)) % 7;
  return addDays(first, offset + 7 * (nth - 1));
}

function isSummerTime(t: Moment): boolean {
  const [y] = parts(dayOf(t));
  const start = at(nthSunday(y, 3, 2), '02:00');
  const end = at(nthSunday(y, 11, 1), '02:00');
  return t >= start && t < end;
}

/** Alberta's last clock change: from this Alberta time on it is UTC−6 all year. */
export const ALBERTA_FIXED_FROM: Moment = '2026-03-08 03:00';

function edmontonOffsetH(t: Moment): number {
  if (t >= ALBERTA_FIXED_FROM) return 6;
  return isSummerTime(t) ? 6 : 7;
}

function torontoOffsetH(t: Moment): number {
  return isSummerTime(t) ? 4 : 5;
}

function minutesOfDay(t: Moment): number {
  const [hh, mm] = t.slice(11).split(':').map(Number);
  return hh * 60 + mm;
}

function wallToUtc(t: Moment, offsetH: number): number {
  return toNum(dayOf(t)) * 1440 + minutesOfDay(t) + offsetH * 60;
}

function wallFromUtc(u: number, offsetH: number): Moment {
  const local = u - offsetH * 60;
  const d = fromNum(Math.floor(local / 1440));
  const mins = local - Math.floor(local / 1440) * 1440;
  return `${d} ${pad(Math.floor(mins / 60))}:${pad(mins % 60)}`;
}

/** Minutes since 1970-01-01 00:00 UTC for an Edmonton wall-clock moment. */
export function utcMinutes(t: Moment): number {
  return wallToUtc(t, edmontonOffsetH(t));
}

function fromUtcMinutes(u: number): Moment {
  // Try each offset Alberta has used; pick the one that round-trips.
  for (const offsetH of [6, 7]) {
    const t = wallFromUtc(u, offsetH);
    if (utcMinutes(t) === u) return t;
  }
  throw new Error(`no Edmonton time for ${u}`);
}

/** Add real elapsed hours to an Edmonton moment (clock changes included). */
export function addHours(t: Moment, h: number): Moment {
  return fromUtcMinutes(utcMinutes(t) + h * 60);
}

/** The Edmonton wall-clock moment of a Toronto wall-clock time on day d. */
export function torontoToEdmonton(d: Day, hhmm: string): Moment {
  const t = at(d, hhmm);
  return fromUtcMinutes(wallToUtc(t, torontoOffsetH(t)));
}

/** The nightly run, in Alberta time, all year: after the latest close (3:00 pm in winter). */
export const NIGHTLY_RUN = '16:30';
