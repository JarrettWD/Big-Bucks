// Exact fractions built on BigInt, for the reference model. No floating point
// anywhere: every money figure is a whole number of cents or an exact fraction.

function gcd(a: bigint, b: bigint): bigint {
  a = a < 0n ? -a : a;
  b = b < 0n ? -b : b;
  while (b !== 0n) [a, b] = [b, a % b];
  return a;
}

export class Q {
  readonly n: bigint;
  readonly d: bigint;

  private constructor(n: bigint, d: bigint) {
    if (d === 0n) throw new Error('division by zero');
    if (d < 0n) [n, d] = [-n, -d];
    const g = gcd(n, d) || 1n;
    this.n = n / g;
    this.d = d / g;
  }

  static of(n: bigint | number, d: bigint | number = 1n): Q {
    if (typeof n === 'number' && !Number.isInteger(n)) throw new Error(`not an integer: ${n}`);
    if (typeof d === 'number' && !Number.isInteger(d)) throw new Error(`not an integer: ${d}`);
    return new Q(BigInt(n), BigInt(d));
  }

  /** Parse an exact decimal string such as "2.5", "-0.125" or "420.37". */
  static dec(s: string): Q {
    const m = /^(-?)(\d+)(?:\.(\d+))?$/.exec(s.trim());
    if (!m) throw new Error(`not a decimal: ${s}`);
    const frac = m[3] ?? '';
    const n = BigInt(m[2] + frac) * (m[1] ? -1n : 1n);
    return new Q(n, 10n ** BigInt(frac.length));
  }

  static readonly ZERO = new Q(0n, 1n);

  add(o: Q): Q {
    return new Q(this.n * o.d + o.n * this.d, this.d * o.d);
  }
  sub(o: Q): Q {
    return new Q(this.n * o.d - o.n * this.d, this.d * o.d);
  }
  mul(o: Q): Q {
    return new Q(this.n * o.n, this.d * o.d);
  }
  div(o: Q): Q {
    return new Q(this.n * o.d, this.d * o.n);
  }
  cmp(o: Q): number {
    const l = this.n * o.d;
    const r = o.n * this.d;
    return l < r ? -1 : l > r ? 1 : 0;
  }
  eq(o: Q): boolean {
    return this.cmp(o) === 0;
  }
  isZero(): boolean {
    return this.n === 0n;
  }
  sign(): number {
    return this.n < 0n ? -1 : this.n > 0n ? 1 : 0;
  }
  abs(): Q {
    return this.n < 0n ? new Q(-this.n, this.d) : this;
  }

  /** Smallest integer >= this. */
  ceil(): bigint {
    const q = this.n / this.d; // truncates toward zero
    return this.n > 0n && q * this.d !== this.n ? q + 1n : q;
  }
  /** Largest integer <= this. */
  floor(): bigint {
    const q = this.n / this.d;
    return this.n < 0n && q * this.d !== this.n ? q - 1n : q;
  }
  /** Nearest integer; an exact half goes away from zero. */
  round(): bigint {
    const twice = this.mul(Q.of(2));
    return this.sign() >= 0 ? twice.add(Q.of(1)).div(Q.of(2)).floor() : -this.abs().round();
  }
  /** Round up to `places` decimal places. */
  ceilTo(places: number): Q {
    const s = 10n ** BigInt(places);
    return Q.of(this.mul(Q.of(s)).ceil(), s);
  }

  /** Round down to `places` decimal places. */
  floorTo(places: number): Q {
    const s = 10n ** BigInt(places);
    return Q.of(this.mul(Q.of(s)).floor(), s);
  }

  /** Decimal string with exactly `places` places, truncated (for display and comparison). */
  toFixed(places: number): string {
    const s = 10n ** BigInt(places);
    const neg = this.n < 0n;
    const v = this.abs().mul(Q.of(s)).floor();
    const whole = (v / s).toString();
    const frac = (v % s).toString().padStart(places, '0');
    return (neg ? '-' : '') + whole + (places > 0 ? '.' + frac : '');
  }
}

export function sumQ(xs: Iterable<Q>): Q {
  let t = Q.ZERO;
  for (const x of xs) t = t.add(x);
  return t;
}
