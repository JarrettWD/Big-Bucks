// How each line of her history reads. The database groups the ledger into lines
// (my_activity) and decides every amount; this only chooses the words and icon.
// All wording is listed in docs/MESSAGES.md §7.

import { formatCents } from '../../lib/money';
import { formatRate, termLabel } from '../../lib/format';

export interface ActivityRow {
  item_key: string;
  at: string;
  on_day: string;
  kind: string;
  request_type: string | null;
  amount_cents: number | string | null;
  fund_id: string | null;
  gic_id: number | null;
  gic_term: number | null;
  rate: string | number | null;
  units: string | number | null;
  unit_price: string | number | null;
  note: string | null;
  transaction_ids: number[] | null;
  request_id: number | null;
}

/** in: adds to her total · out: takes from it · move: between her options · waiting / declined: not in yet. */
export type Tone = 'in' | 'out' | 'move' | 'waiting' | 'declined';

export interface ActivityLine {
  key: string;
  icon: string;
  title: string;
  detail: string | null;
  amount: string;
  tone: Tone;
  day: string;
}

export const FUND_NAMES: Record<string, string> = {
  dow: 'Dow Jones',
  nasdaq100: 'Nasdaq-100',
  tsx: 'TSX',
};

const fund = (id: string | null) => (id ? (FUND_NAMES[id] ?? id) : 'a fund');
const gic = (r: ActivityRow) => (r.gic_term ? `${termLabel(r.gic_term)} GIC` : 'GIC');
const at = (r: ActivityRow) => (r.rate !== null ? ` at ${formatRate(r.rate)}` : '');

export function describeActivity(r: ActivityRow): ActivityLine {
  const money = (c = r.amount_cents) => (c === null ? '' : formatCents(c));
  const base = { key: r.item_key, day: r.on_day, detail: null as string | null };
  switch (r.kind) {
    case 'deposit':
      return { ...base, icon: '💵', title: 'Money in', amount: `+${money()}`, tone: 'in' };
    case 'withdraw':
      return { ...base, icon: '👛', title: 'Money out', amount: `−${money()}`, tone: 'out' };
    case 'interest':
      return { ...base, icon: '🐷', title: 'Savings interest', amount: `+${money()}`, tone: 'in' };
    case 'gic_interest':
      return {
        ...base,
        icon: '🔒',
        title: `Interest from your ${gic(r)}`,
        amount: `+${money()}`,
        tone: 'in',
      };
    case 'dividend':
      return {
        ...base,
        icon: '🎁',
        title: `Dividend from ${fund(r.fund_id)}`,
        amount: `+${money()}`,
        tone: 'in',
      };
    case 'gic_buy':
      return {
        ...base,
        icon: '🔒',
        title: `Bought a ${gic(r)}${at(r)}`,
        amount: money(),
        tone: 'move',
      };
    case 'gic_break':
      return { ...base, icon: '🔓', title: 'Broke a GIC early', amount: money(), tone: 'move' };
    case 'gic_to_savings':
      return {
        ...base,
        icon: '🐷',
        title: r.note?.includes('automatically')
          ? 'GIC moved to savings automatically'
          : 'GIC moved to savings',
        amount: money(),
        tone: 'move',
      };
    case 'gic_renew':
      return {
        ...base,
        icon: '🔁',
        title: `Renewed: a new ${gic(r)}${at(r)}`,
        amount: money(),
        tone: 'move',
      };
    case 'fund_buy':
      return {
        ...base,
        icon: '📈',
        title: `Bought ${fund(r.fund_id)}`,
        amount: money(),
        tone: 'move',
      };
    case 'fund_sell':
      return {
        ...base,
        icon: '💰',
        title: `Sold ${fund(r.fund_id)}`,
        amount: money(),
        tone: 'move',
      };
    case 'split':
      return {
        ...base,
        icon: '✂️',
        title: `${fund(r.fund_id)} split its units`,
        detail: 'Same value, more units.',
        amount: '',
        tone: 'move',
      };
    case 'correction': {
      const c = Number(r.amount_cents ?? 0);
      return {
        ...base,
        icon: '🛠️',
        title: 'A correction',
        detail: r.note,
        amount: formatCents(r.amount_cents ?? 0, { sign: true }),
        tone: c >= 0 ? 'in' : 'out',
      };
    }
    case 'penalty':
      return {
        ...base,
        icon: '⚠️',
        title: 'A penalty',
        detail: null, // its working opens under "How was this calculated?"
        amount: `−${money()}`,
        tone: 'out',
      };
    case 'request_pending':
      return { ...base, ...pending(r, money()) };
    case 'request_declined':
      return {
        ...base,
        icon: '💬',
        title:
          r.request_type === 'withdraw'
            ? 'Dad said not this time (money out)'
            : 'Dad said not this time (money in)',
        detail: r.note ? `Dad says: “${r.note}”` : null,
        amount: money(),
        tone: 'declined',
      };
    case 'request_expired':
      return {
        ...base,
        icon: '⌛',
        title: 'A request ran out of time',
        detail: 'Nobody answered within 7 days, so it was cancelled. You can ask again any time.',
        amount: money(),
        tone: 'declined',
      };
    default:
      return {
        ...base,
        icon: '•',
        title: 'A change to your account',
        amount: money(),
        tone: 'move',
      };
  }
}

function pending(r: ActivityRow, amount: string): Omit<ActivityLine, 'key' | 'day'> {
  switch (r.request_type) {
    case 'deposit':
      return {
        icon: '⏳',
        title: 'Asked to put money in',
        detail: 'Waiting for Dad',
        amount,
        tone: 'waiting',
      };
    case 'withdraw':
      return {
        icon: '⏳',
        title: 'Asked to take money out',
        detail: 'Waiting for Dad',
        amount,
        tone: 'waiting',
      };
    case 'buy':
      return {
        icon: '⏳',
        title: `Buying ${fund(r.fund_id)}`,
        detail: 'Waiting for the market close',
        amount,
        tone: 'waiting',
      };
    case 'sell':
      return {
        icon: '⏳',
        title: `Selling ${fund(r.fund_id)}`,
        detail: 'Waiting for the market close',
        amount: amount || 'All of it',
        tone: 'waiting',
      };
    default:
      return { icon: '⏳', title: 'Waiting', detail: null, amount, tone: 'waiting' };
  }
}
