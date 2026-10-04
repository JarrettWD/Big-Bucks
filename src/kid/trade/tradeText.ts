// The words on the Buy / Sell screen. The database sends facts (amounts, dates,
// "today's 2:00 pm close"); this only chooses the words. Every message here is
// listed in docs/MESSAGES.md §8.

import { formatDate, formatRate, termLabel, termWords } from '../../lib/format';
import { formatCents, type Cents } from '../../lib/money';
import type { Kind, Place } from './moves';

// What the database sends ---------------------------------------------------------------------

export interface TradeFund {
  fund_id: string;
  name: string;
  colour: string;
  units: number | string;
  available_units: number | string;
  value_cents: Cents;
  cost_cents: Cents;
  gain_cents: Cents;
  sellable_cents: Cents;
  traded_today: boolean;
  settles: string;
}

export interface TradeGic {
  gic_id: number;
  term_months: number;
  rate: number | string;
  principal_cents: Cents;
  balance_cents: Cents;
  start_date: string;
  maturity_date: string;
  interest_so_far_cents: Cents;
  interest_at_maturity_cents: Cents;
  can_break: boolean;
}

export interface GicRate {
  term_months: number;
  rate: number | string;
  is_special: boolean;
  special_ends: string | null;
}

export interface Waiting {
  request_id: number;
  type: 'deposit' | 'withdraw' | 'move';
  from_vehicle: string | null;
  to_vehicle: string | null;
  fund_id: string | null;
  amount_cents: Cents | null;
  sell_all: boolean;
  on_day: string;
  approve_from: string | null;
  settles: string | null;
}

export interface TradeOptions {
  today: string;
  updating: boolean;
  savings_cents: Cents;
  held_cents: Cents;
  available_cents: Cents;
  cap_cents: Cents;
  cap_room_cents: Cents;
  funds: TradeFund[];
  gics: TradeGic[];
  gic_rates: GicRate[];
  waiting: Waiting[];
}

export type Warning =
  | { code: 'deposit_wait' }
  | { code: 'withdraw_wait'; approve_from: string }
  | {
      code: 'early_break';
      lost_cents: Cents;
      at_maturity_cents: Cents;
      back_cents: Cents;
      maturity_date: string;
    }
  | { code: 'fund_below_cost'; value_cents: Cents; cost_cents: Cents; loss_cents: Cents }
  | { code: 'market_price'; settles: string }
  | { code: 'sells_all' };

export interface GicQuote {
  term_months: number;
  rate: number | string;
  is_special: boolean;
  interest_cents: Cents;
  maturity_date: string;
}

export interface Preview {
  kind: Kind;
  problem: string | null;
  warnings: Warning[];
  settles: string | null;
  gic_quotes: GicQuote[];
}

// Choices in the From and To lists ---------------------------------------------------------------

export function placeLabel(p: Place, o: TradeOptions, side: 'from' | 'to'): string {
  if (p === 'cash') return side === 'from' ? '💵 Cash from Dad' : '💵 Cash to you';
  if (p === 'savings') return '🐷 Savings';
  if (p === 'gic') return '🔒 A new GIC';
  // Her GICs are one choice here; she picks which one on the cards below the list.
  if (p.startsWith('gic:')) return o.gics.length > 1 ? '🔒 One of your GICs' : '🔒 Your GIC';
  const f = o.funds.find((x) => `fund:${x.fund_id}` === p);
  return `📈 ${f?.name ?? 'A fund'}`;
}

/** Why a choice can't be picked today, if it can't. */
export function placeBlocked(p: Place, o: TradeOptions): string | null {
  if (p.startsWith('fund:')) {
    const f = o.funds.find((x) => `fund:${x.fund_id}` === p);
    if (f?.traded_today) return 'traded today, again tomorrow';
  }
  if (p.startsWith('gic:')) {
    const g = o.gics.find((x) => `gic:${x.gic_id}` === p);
    if (g && !g.can_break) return 'ready today';
  }
  return null;
}

// The line under the amount box ---------------------------------------------------------------------

export function amountHelp(kind: Kind, o: TradeOptions, fund?: TradeFund): string {
  switch (kind) {
    case 'deposit':
      return `You can put in up to ${formatCents(o.cap_room_cents)} more.`;
    case 'sell_fund':
      return `Your ${fund?.name ?? 'fund'} is worth about ${formatCents(fund?.sellable_cents ?? 0)}.`;
    default:
      return `${formatCents(o.available_cents)} free to use.`;
  }
}

// Warnings -------------------------------------------------------------------------------------------

export function warningText(
  w: Warning,
  ctx: { kind: Kind; year: number; sellAll: boolean; amount: string | null; fundName: string },
): string {
  switch (w.code) {
    case 'deposit_wait':
      return 'Dad needs to say yes first. Give him the cash, and it lands in your savings when he approves.';
    case 'withdraw_wait':
      return `Withdrawals wait at least 24 hours, so you can sleep on it. Dad can say yes from ${w.approve_from}. Until then, this money is on hold.`;
    case 'early_break':
      return BigInt(String(w.lost_cents)) > 0n
        ? `Moving money out of this GIC before it's ready means you lose all ${formatCents(w.lost_cents)} of interest earned so far. If you wait until ${formatDate(w.maturity_date, ctx.year)}, it earns ${formatCents(w.at_maturity_cents)}.`
        : `This GIC hasn't earned any interest yet. If you wait until ${formatDate(w.maturity_date, ctx.year)}, it earns ${formatCents(w.at_maturity_cents)}.`;
    case 'fund_below_cost':
      return `Your ${ctx.fundName} is worth ${formatCents(w.value_cents)} right now, but you paid ${formatCents(w.cost_cents)}. Selling now makes a loss of ${formatCents(w.loss_cents)} final. Markets go up and down, and nobody knows what comes next.`;
    case 'market_price':
      if (ctx.kind === 'buy_fund')
        return `Your buy happens at ${w.settles}, at that day's price. It could be higher or lower than today's, so you'll see how many units you got after the close.`;
      if (ctx.sellAll)
        return `Your sale happens at ${w.settles}. You'll get whatever your units are worth at that day's price.`;
      return `Your sale happens at ${w.settles}. You'll get ${ctx.amount ?? 'that amount'}, as long as your units are still worth that much at the close. If they're worth less, you'll sell all of them.`;
    case 'sells_all':
      return `That's what all of your ${ctx.fundName} is worth, so this sells all of it.`;
  }
}

/** True when the amount she typed sells everything (the database decided: sells_all). */
export const sellsAll = (p: Preview | null) =>
  p?.warnings.some((w) => w.code === 'sells_all') ?? false;

/** Warnings that are cautions (shown with ⚠️), as opposed to "good to know" notes. */
export const isCaution = (w: Warning) => w.code === 'early_break' || w.code === 'fund_below_cost';

// The summary before "Yes, do it" -------------------------------------------------------------------

export interface Summary {
  question: string;
  points: string[];
}

export function summaryFor(a: {
  kind: Kind;
  amount: string | null;
  sellAll: boolean;
  fund?: TradeFund;
  gic?: TradeGic;
  quote?: GicQuote;
  preview: Preview;
  year: number;
}): Summary {
  const settles = a.preview.settles ?? 'the next market close';
  switch (a.kind) {
    case 'deposit':
      return {
        question: `Ask Dad to put in ${a.amount}?`,
        points: ['It goes into your savings once Dad says yes.'],
      };
    case 'withdraw': {
      const w = a.preview.warnings.find((x) => x.code === 'withdraw_wait');
      return {
        question: `Ask to take ${a.amount} out of your savings?`,
        points: [
          w ? `Dad can say yes from ${w.approve_from}.` : 'Dad needs to say yes first.',
          'Until then, this money is on hold.',
        ],
      };
    }
    case 'buy_gic':
      return {
        question: `Put ${a.amount} into a ${termLabel(a.quote!.term_months)} GIC at ${formatRate(a.quote!.rate)}?`,
        points: [
          `It earns ${formatCents(a.quote!.interest_cents)} of interest by ${formatDate(a.quote!.maturity_date, a.year)}.`,
          `It's locked for ${termWords(a.quote!.term_months)}. Taking it out early means losing the interest.`,
        ],
      };
    case 'break_gic': {
      const w = a.preview.warnings.find((x) => x.code === 'early_break');
      const g = a.gic!;
      return {
        question: `Take your ${termLabel(g.term_months)} GIC out early?`,
        points: [
          `Your ${formatCents(g.balance_cents)} goes back into savings.`,
          w && BigInt(String(w.lost_cents)) > 0n
            ? `You give up the ${formatCents(w.lost_cents)} of interest it has earned so far.`
            : `You give up the ${formatCents(g.interest_at_maturity_cents)} it would earn by ${formatDate(g.maturity_date, a.year)}.`,
        ],
      };
    }
    case 'buy_fund':
      return {
        question: `Buy ${a.amount} of ${a.fund?.name}?`,
        points: [`It happens at ${settles}.`, 'Until then, the money is on hold in your savings.'],
      };
    case 'sell_fund': {
      const loss = a.preview.warnings.find((x) => x.code === 'fund_below_cost');
      return {
        question: a.sellAll
          ? `Sell all of your ${a.fund?.name}?`
          : `Sell ${a.amount} of your ${a.fund?.name}?`,
        points: [
          `It happens at ${settles}.`,
          'The money goes into your savings.',
          ...(loss ? [`It's worth ${formatCents(loss.loss_cents)} less than you paid.`] : []),
        ],
      };
    }
  }
}

// After "Yes, do it" ---------------------------------------------------------------------------------

export function doneText(a: {
  kind: Kind;
  amount: string | null;
  fund?: TradeFund;
  gic?: TradeGic;
  quote?: GicQuote;
  preview: Preview;
  year: number;
}): { title: string; text: string } {
  const settles = a.preview.settles ?? 'the next market close';
  switch (a.kind) {
    case 'deposit':
      return {
        title: 'Asked!',
        text: `Dad will see your request. Your ${a.amount} lands in savings when he says yes.`,
      };
    case 'withdraw': {
      const w = a.preview.warnings.find((x) => x.code === 'withdraw_wait');
      return {
        title: 'Asked!',
        text: w
          ? `Dad can say yes from ${w.approve_from}. Until then, the money stays on hold.`
          : 'Dad will see your request.',
      };
    }
    case 'buy_gic':
      return {
        title: '🎉 Done!',
        text: `Your ${a.amount} is growing in a ${termLabel(a.quote!.term_months)} GIC. It's ready on ${formatDate(a.quote!.maturity_date, a.year)}.`,
      };
    case 'break_gic':
      return { title: 'Done', text: `Your ${formatCents(a.gic!.balance_cents)} is in savings.` };
    case 'buy_fund':
      return { title: 'Done!', text: `Your ${a.fund?.name} buy happens at ${settles}.` };
    case 'sell_fund':
      return {
        title: 'Done!',
        text: `Your ${a.fund?.name} sale happens at ${settles}. The money goes into your savings.`,
      };
  }
}

// Her waiting requests ----------------------------------------------------------------------------

export function waitingLine(w: Waiting, funds: TradeFund[]): { title: string; detail: string } {
  const fund = funds.find((f) => f.fund_id === w.fund_id)?.name ?? 'a fund';
  const amount = w.amount_cents === null ? 'all of it' : formatCents(w.amount_cents);
  if (w.type === 'deposit')
    return { title: `Asked to put in ${amount}`, detail: 'Waiting for Dad' };
  if (w.type === 'withdraw')
    return {
      title: `Asked to take out ${amount}`,
      detail: w.approve_from ? `Dad can say yes from ${w.approve_from}` : 'Waiting for Dad',
    };
  const happens = w.settles ? `Happens at ${w.settles}` : 'Waiting for the market close';
  return w.to_vehicle === 'stock'
    ? { title: `Buying ${fund}: ${amount}`, detail: happens }
    : { title: `Selling ${fund}: ${w.sell_all ? 'all of it' : amount}`, detail: happens };
}
