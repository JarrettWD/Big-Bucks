// The nightly function's plain logic, with no Deno or network in it, so Vitest can
// check it (lib.test.ts). Prices stay strings from the provider to the database:
// they're never turned into floating-point numbers.

export interface Close {
  date: string;
  close: string;
}

export interface Split {
  date: string;
  from: number;
  to: number;
}

export type Fetched<T> =
  | { ok: true; value: T }
  | { ok: false; kind: 'bad_symbol' | 'limit' | 'unexpected' | 'network'; message: string };

/** The provider's symbol: TSX funds carry the Toronto suffix (XIC → XIC.TRT). */
export function providerSymbol(symbol: string, market: string): string {
  return market === 'tsx' ? `${symbol}.TRT` : symbol;
}

const DAY = /^\d{4}-\d{2}-\d{2}$/;
const PRICE = /^\d{1,12}(\.\d{1,8})?$/;

/** A price as the database wants it: digits only, above zero, at most 8 decimals. */
export function cleanPrice(raw: unknown): string | null {
  if (typeof raw !== 'string') return null;
  const s = raw.trim();
  if (!PRICE.test(s) || !/[1-9]/.test(s)) return null;
  return s;
}

function problem(json: unknown): Fetched<never> | null {
  if (!json || typeof json !== 'object')
    return { ok: false, kind: 'unexpected', message: 'The reply was not JSON.' };
  const j = json as Record<string, unknown>;
  if (typeof j['Error Message'] === 'string')
    return { ok: false, kind: 'bad_symbol', message: String(j['Error Message']).slice(0, 300) };
  for (const k of ['Note', 'Information'])
    if (typeof j[k] === 'string')
      return { ok: false, kind: 'limit', message: String(j[k]).slice(0, 300) };
  return null;
}

function series(json: unknown, key: string): Fetched<Close[]> {
  const p = problem(json);
  if (p) return p;
  const s = (json as Record<string, unknown>)[key];
  if (!s || typeof s !== 'object')
    return { ok: false, kind: 'unexpected', message: `The reply had no "${key}".` };
  const out: Close[] = [];
  for (const [date, bar] of Object.entries(s as Record<string, unknown>)) {
    if (!DAY.test(date) || !bar || typeof bar !== 'object') continue;
    const close = cleanPrice((bar as Record<string, unknown>)['4. close']);
    if (close) out.push({ date, close });
  }
  out.sort((a, b) => (a.date < b.date ? -1 : a.date > b.date ? 1 : 0));
  if (out.length === 0)
    return { ok: false, kind: 'unexpected', message: 'The reply had no closes.' };
  return { ok: true, value: out };
}

/** TIME_SERIES_DAILY: the last 100 trading days' closes, oldest first. */
export const parseDaily = (json: unknown) => series(json, 'Time Series (Daily)');

/** TIME_SERIES_WEEKLY: each week's last close, oldest first. */
export const parseWeekly = (json: unknown) => series(json, 'Weekly Time Series');

/** A split factor ("2.0000", "0.5", "1.5") as whole numbers: 2-for-1 is from 1, to 2. */
export function splitRatio(factor: string): { from: number; to: number } | null {
  const m = /^(\d+)(?:\.(\d+))?$/.exec(factor.trim());
  if (!m) return null;
  const frac = (m[2] ?? '').replace(/0+$/, '');
  let num = BigInt(m[1] + frac);
  let den = 10n ** BigInt(frac.length);
  const gcd = (a: bigint, b: bigint): bigint => (b === 0n ? a : gcd(b, a % b));
  const g = gcd(num, den);
  if (g === 0n) return null;
  num /= g;
  den /= g;
  if (num === 0n || num === den || num > 1000n || den > 1000n) return null;
  return { from: Number(den), to: Number(num) };
}

/** SPLITS: every split the provider knows of. */
export function parseSplits(json: unknown): Fetched<Split[]> {
  const p = problem(json);
  if (p) return p;
  const data = (json as Record<string, unknown>).data;
  if (data === undefined) return { ok: true, value: [] };
  if (!Array.isArray(data))
    return { ok: false, kind: 'unexpected', message: 'The split list was not a list.' };
  const out: Split[] = [];
  for (const row of data) {
    const date = String((row as Record<string, unknown>)?.effective_date ?? '');
    const ratio = splitRatio(String((row as Record<string, unknown>)?.split_factor ?? ''));
    if (DAY.test(date) && ratio) out.push({ date, ...ratio });
  }
  return { ok: true, value: out };
}

/**
 * The weekly closes the backfill keeps: older than the first daily close it has (the
 * daily series is better where it exists) and no older than `from`.
 */
export function weeklyForBackfill(weekly: Close[], daily: Close[], from: string): Close[] {
  const firstDaily = daily.length ? daily[0].date : null;
  return weekly.filter((w) => w.date >= from && (firstDaily === null || w.date < firstDaily));
}

// The made-up price source (your own computer only) ------------------------------------

function moveBp(symbol: string, date: string): number {
  let s = 2166136261;
  for (const ch of `${symbol}:${date}`) {
    s ^= ch.charCodeAt(0);
    s = Math.imul(s, 16777619) >>> 0;
  }
  return (s % 241) - 118; // about −1.2% to +1.2% a day, drifting up a little
}

const toMicros = (close: string): bigint => {
  const [w, f = ''] = close.split('.');
  return BigInt(w) * 1_000_000n + BigInt((f + '000000').slice(0, 6));
};
const fromMicros = (v: bigint): string =>
  `${v / 1_000_000n}.${(v % 1_000_000n).toString().padStart(6, '0')}`;

/**
 * Made-up closes for the given trading days, each following on from the last stored
 * close by a small move that is the same every time for the same fund and day.
 * Whole-number arithmetic, like everything that touches money.
 */
export function fakeCloses(
  symbol: string,
  last: { date: string; close: string } | null,
  dates: string[],
): Close[] {
  let price = toMicros(last?.close ?? '100');
  return [...dates].sort().map((date) => {
    price = (price * BigInt(10000 + moveBp(symbol, date))) / 10000n;
    return { date, close: fromMicros(price) };
  });
}

// Keys ----------------------------------------------------------------------------------

/** Compares two keys in time that doesn't depend on where they differ. */
export function sameKey(given: string, expected: string): boolean {
  const a = new TextEncoder().encode(given);
  const b = new TextEncoder().encode(expected);
  let diff = a.length ^ b.length;
  for (let i = 0; i < b.length; i++) diff |= (a[i] ?? 0) ^ b[i];
  return diff === 0 && b.length > 0;
}

/** Hosted Supabase, as opposed to the local copy on Dad's computer. */
export function isHosted(supabaseUrl: string): boolean {
  try {
    return new URL(supabaseUrl).hostname.endsWith('.supabase.co');
  } catch {
    return true; // unknown: treat as production, the careful side
  }
}

/**
 * Why a function key can't be used, or null when it can: long enough, and never the
 * local test key (it starts "local-") on hosted Supabase.
 */
export function keyProblem(key: string, hosted: boolean): string | null {
  if (key.length < 32) return 'The function key is missing or shorter than 32 characters.';
  if (hosted && key.startsWith('local-'))
    return 'The function key is the local test key. Set a real one (RUNBOOK).';
  return null;
}
