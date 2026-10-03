// Money on screen. Amounts arrive from the database as whole cents (bigint in
// Postgres, so a JSON number or a string). They're formatted with whole-number
// arithmetic only: never floating point, never rounded here. The database
// already decided every cent.

export type Cents = bigint | number | string;

/** Whole cents as a bigint. Refuses fractions, non-numbers and unsafe numbers. */
export function toCents(value: Cents): bigint {
  if (typeof value === 'bigint') return value;
  if (typeof value === 'number') {
    if (!Number.isSafeInteger(value)) throw new Error(`Not a whole number of cents: ${value}`);
    return BigInt(value);
  }
  const s = value.trim();
  if (!/^-?\d+$/.test(s)) throw new Error(`Not a whole number of cents: "${value}"`);
  return BigInt(s);
}

/**
 * Cents as Canadian dollars: 123456 → "$1,234.56", -500 → "−$5.00".
 * `sign: true` adds "+" to amounts above zero (for history lines).
 */
export function formatCents(value: Cents, opts: { sign?: boolean } = {}): string {
  const c = toCents(value);
  const neg = c < 0n;
  const a = neg ? -c : c;
  const whole = (a / 100n).toString().replace(/\B(?=(\d{3})+(?!\d))/g, ',');
  const frac = (a % 100n).toString().padStart(2, '0');
  const prefix = neg ? '−' : opts.sign && a > 0n ? '+' : '';
  return `${prefix}$${whole}.${frac}`;
}
