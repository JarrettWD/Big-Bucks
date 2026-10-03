// Buy / Sell rules the screen needs before asking the database: which From and
// To choices go together (every move goes through savings), which action a pair
// means, and turning what she typed into whole cents. No money maths: the
// database decides every amount and every rule (move_preview, then the action).
// Wording is listed in docs/MESSAGES.md §8.

export type Side = 'buy' | 'sell';
export type Kind = 'deposit' | 'withdraw' | 'buy_gic' | 'break_gic' | 'buy_fund' | 'sell_fund';

/** A place money can be: cash (Dad's real money), savings, a new GIC, one of her GICs, a fund. */
export type Place = 'cash' | 'savings' | 'gic' | `gic:${number}` | `fund:${string}`;

export interface Move {
  kind: Kind;
  fundId: string | null;
  gicId: number | null;
}

/** What she holds, as far as choosing a pair goes. */
export interface Holdings {
  fundIds: string[]; // every fund, in order
  sellableFundIds: string[]; // funds with units free to sell
  gicIds: number[]; // her active GICs
}

/** Buy puts money into something; Sell takes it out. */
export function fromPlaces(side: Side, h: Holdings): Place[] {
  if (side === 'buy') return ['cash', 'savings'];
  return [
    ...h.gicIds.map((id) => `gic:${id}` as Place),
    ...h.sellableFundIds.map((id) => `fund:${id}` as Place),
    'savings',
  ];
}

export function toPlaces(side: Side, from: Place, h: Holdings): Place[] {
  if (side === 'buy') {
    if (from === 'cash') return ['savings'];
    if (from === 'savings') return ['gic', ...h.fundIds.map((id) => `fund:${id}` as Place)];
    return [];
  }
  if (from === 'savings') return ['cash'];
  if (from.startsWith('gic:') || from.startsWith('fund:')) return ['savings'];
  return [];
}

/** The action a From/To pair means, or null if the pair isn't allowed. */
export function moveFor(side: Side, from: Place, to: Place): Move | null {
  const none = { fundId: null, gicId: null };
  if (side === 'buy') {
    if (from === 'cash' && to === 'savings') return { kind: 'deposit', ...none };
    if (from === 'savings' && to === 'gic') return { kind: 'buy_gic', ...none };
    if (from === 'savings' && to.startsWith('fund:'))
      return { kind: 'buy_fund', fundId: to.slice(5), gicId: null };
    return null;
  }
  if (from === 'savings' && to === 'cash') return { kind: 'withdraw', ...none };
  if (to !== 'savings') return null;
  if (from.startsWith('gic:')) {
    const id = Number(from.slice(4));
    return Number.isSafeInteger(id) && id > 0
      ? { kind: 'break_gic', fundId: null, gicId: id }
      : null;
  }
  if (from.startsWith('fund:')) return { kind: 'sell_fund', fundId: from.slice(5), gicId: null };
  return null;
}

export const isGicPlace = (p: Place): p is `gic:${number}` => p.startsWith('gic:');

/**
 * The From dropdown lists her GICs as one choice; she picks which GIC on cards
 * below it (a dropdown can't show enough to tell two GICs apart). That one choice
 * stands for the GIC she has picked, or the first.
 */
export function dropdownPlaces(list: Place[], current: Place | null): Place[] {
  const gics = list.filter(isGicPlace);
  if (gics.length === 0) return list;
  const stand = current !== null && gics.includes(current as `gic:${number}`) ? current : gics[0];
  const firstGic = list.findIndex(isGicPlace);
  return list
    .filter((p, i) => !isGicPlace(p) || i === firstGic)
    .map((p) => (isGicPlace(p) ? stand : p));
}

/** Keep a choice if it's still allowed, otherwise take the first allowed one. */
export function keepOrFirst(current: Place | null, allowed: Place[]): Place | null {
  return current !== null && allowed.includes(current) ? current : (allowed[0] ?? null);
}

// Typing an amount ------------------------------------------------------------------------------

export const AMOUNT_MESSAGES = {
  negative: "Amounts can't be less than zero. Type how much, like 25.",
  notNumber: 'Use numbers only, like 25 or 12.50.',
  commaCents: 'Use a dot for cents, like 12.50.',
  tooManyDecimals:
    'Money only goes down to cents, so use at most 2 numbers after the dot, like 12.50.',
  zero: 'Type an amount bigger than $0.',
  tooBig: "That's a really big number! Check it and try again.",
} as const;

export type AmountResult =
  { state: 'empty' } | { state: 'ok'; cents: bigint } | { state: 'bad'; message: string };

/**
 * "25", "$25", "12.5", "1,000.50" → whole cents, with string arithmetic only
 * (never floating point). Anything else gets a friendly message.
 */
export function parseAmount(text: string): AmountResult {
  let s = text.trim();
  if (s === '') return { state: 'empty' };
  if (/[-−–]/.test(s)) return { state: 'bad', message: AMOUNT_MESSAGES.negative };
  s = s.replace(/^\$\s*/, '');
  if (s.includes(',')) {
    // Only proper thousands groups ("1,000" or "12,345.67"); "12,50" means cents.
    if (/^\d{1,3}(,\d{3})+(\.\d*)?$/.test(s)) s = s.replace(/,/g, '');
    else if (/^\d+,\d{1,2}$/.test(s)) return { state: 'bad', message: AMOUNT_MESSAGES.commaCents };
    else return { state: 'bad', message: AMOUNT_MESSAGES.notNumber };
  }
  const m = s.match(/^(\d*)(?:\.(\d*))?$/);
  if (!m || (m[1] === '' && (m[2] ?? '') === ''))
    return { state: 'bad', message: AMOUNT_MESSAGES.notNumber };
  const whole = m[1].replace(/^0+(?=\d)/, '');
  const frac = m[2] ?? '';
  if (frac.length > 2) return { state: 'bad', message: AMOUNT_MESSAGES.tooManyDecimals };
  if (whole.length > 7) return { state: 'bad', message: AMOUNT_MESSAGES.tooBig };
  const cents = BigInt(whole || '0') * 100n + BigInt(frac.padEnd(2, '0'));
  if (cents === 0n) return { state: 'bad', message: AMOUNT_MESSAGES.zero };
  return { state: 'ok', cents };
}
