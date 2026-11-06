// The live lines in the "Interest rate" and "Inflation" ?s beside her savings (Dad, 2026-10-26).
// Every figure comes from the database (kid_rate_help); these only put words around them.

import { useEffect, useState } from 'react';
import { formatDate, formatRate } from '../lib/format';
import { formatCents, toCents, type Cents } from '../lib/money';
import { kidRpc, type KidView } from './kidView';

export interface RateHelp {
  today: string;
  /** The regular rate: what both year figures use, never a special (Dad, 2026-10-27). */
  savings_rate: string | number;
  /** Today's rate, a special included: what Home shows. */
  now_rate: string | number;
  /** A savings special's last day, while one is running. */
  special_until: string | null;
  per_100_cents: Cents;
  per_100_exact: boolean;
  balance_cents: Cents;
  year_cents: Cents | null;
  inflation_rate: string | number;
  infl_100_cents: Cents;
  infl_exact: boolean;
  need_cents: Cents | null;
}

/** "96¢" under a dollar, "$1" for whole dollars, "$2.13" otherwise. */
export function shortAmount(value: Cents): string {
  const c = toCents(value);
  if (c >= 0n && c < 100n) return `${c}¢`;
  const s = formatCents(c);
  return s.endsWith('.00') ? s.slice(0, -3) : s;
}

/** The Interest rate ?: a running savings special in words, then the plain meaning of her
 * regular rate, then her own figure (at the regular rate: a special lasts days, not a year). */
export function interestLines(h: RateHelp | null): string[] {
  if (!h) return [];
  const lines: string[] = [];
  if (h.special_until)
    lines.push(
      `Right now you're earning the special ${formatRate(h.now_rate)} until ${formatDate(h.special_until, Number(h.today.slice(0, 4)))}, then ${formatRate(h.savings_rate)}.`,
    );
  lines.push(
    `At ${formatRate(h.savings_rate)} a year, every $100 earns ${h.per_100_exact ? '' : 'about '}${shortAmount(h.per_100_cents)} in a year.`,
  );
  if (h.year_cents !== null)
    lines.push(
      `Your ${formatCents(h.balance_cents)} would earn about ${shortAmount(h.year_cents)} in a year.`,
    );
  return lines;
}

/** The Inflation ?: the plain meaning of the inflation rate, then what her savings would need. */
export function inflationLines(h: RateHelp | null): string[] {
  if (!h) return [];
  const lines = [
    `At ${formatRate(h.inflation_rate)} a year, something that costs $100 now costs ${h.infl_exact ? '' : 'about '}${shortAmount(h.infl_100_cents)} next year.`,
  ];
  if (h.need_cents !== null)
    lines.push(
      `Your ${formatCents(h.balance_cents)} in savings would need to grow to ${formatCents(h.need_cents)} to buy the same things.`,
    );
  return lines;
}

/** Her figures for the ?s; null until loaded (the ? then shows the glossary words alone).
 * They load again when `refresh` changes (Home passes her savings balance). */
export function useRateHelp(view: KidView, refresh?: unknown): RateHelp | null {
  const [help, setHelp] = useState<RateHelp | null>(null);
  useEffect(() => {
    let alive = true;
    void kidRpc<RateHelp>(view, 'kid_rate_help', { p_account_id: view.accountId }).then(
      ({ data }) => {
        if (alive && data) setHelp(data);
      },
    );
    return () => {
      alive = false;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps -- the account and mode are what matter
  }, [view.accountId, view.viewing, refresh]);
  return help;
}
