// Everything Home shows, read in one go. Every figure comes from the database
// (views and read functions); the screen only arranges it.

import { useCallback, useEffect, useState } from 'react';
import { kidBalances, kidHomeGics, kidRpc, kidUnreadNotices, type KidView } from '../kidView';
import type { ActivityRow } from './activityText';

export type Cents = number | string;

export interface Balances {
  savings_cents: Cents;
  held_cents: Cents;
  available_cents: Cents;
  gic_cents: Cents;
  stock_value_cents: Cents;
  total_worth_cents: Cents;
}

export interface Gic {
  gic_id: number;
  principal_cents: Cents;
  balance_cents: Cents;
  rate: string;
  term_months: number;
  start_date: string;
  maturity_date: string;
  status: 'active' | 'matured' | 'broken';
  maturity_choice: string | null;
  interest_at_maturity_cents: Cents;
  choose_by: string | null;
}

export interface Fund {
  fund_id: string;
  name: string;
  colour: string;
  owned: boolean;
  value_cents: Cents;
  latest_close_date: string | null;
  day_change_pct: string | number | null;
  mix_pct: number | null;
  spark: { d: string; c: number }[];
}

export interface Rate {
  vehicle: 'savings' | 'gic';
  gic_term: number | null;
  rate: string;
  is_special: boolean;
  special_ends: string | null;
  next_rate: string | null;
  next_effective: string | null;
}

export interface Notice {
  id: number;
  type: string;
  title: string;
  body: string;
  related_gic_id: number | null;
}

export interface HomeData {
  today: string;
  balances: Balances;
  gics: Gic[];
  funds: Fund[];
  activity: ActivityRow[];
  rates: Rate[];
  notices: Notice[];
  updating: boolean;
}

export const isWaiting = (g: Gic) => g.status === 'matured' && g.maturity_choice === null;

export async function loadHome(view: KidView): Promise<HomeData> {
  const accountId = view.accountId;
  const [today, bal, gics, funds, activity, rates, notices, updating] = await Promise.all([
    kidRpc<string>(view, 'app_today'),
    kidBalances<Balances>(view),
    kidHomeGics<Gic>(view),
    kidRpc<Fund[]>(view, 'fund_overview', { p_account_id: accountId }),
    kidRpc<ActivityRow[]>(view, 'my_activity', { p_account_id: accountId, p_limit: 5 }),
    kidRpc<Rate[]>(view, 'current_rates'),
    kidUnreadNotices<Notice>(view),
    kidRpc<boolean>(view, 'figures_updating', { p_account_id: accountId }),
  ]);
  const failed = [today, bal, gics, funds, activity, rates, notices, updating].find((r) => r.error);
  if (failed?.error) throw new Error(failed.error.message);
  return {
    today: today.data as string,
    balances: bal.data as Balances,
    gics: (gics.data ?? []) as Gic[],
    funds: (funds.data ?? []) as Fund[],
    activity: (activity.data ?? []) as ActivityRow[],
    rates: (rates.data ?? []) as Rate[],
    notices: (notices.data ?? []) as Notice[],
    updating: updating.data === true,
  };
}

export function useHome(view: KidView | null) {
  const [data, setData] = useState<HomeData | null>(null);
  const [error, setError] = useState(false);
  const [tick, setTick] = useState(0);
  const reload = useCallback(() => setTick((t) => t + 1), []);

  useEffect(() => {
    if (!view) return;
    let alive = true;
    loadHome(view)
      .then((d) => {
        if (!alive) return;
        setData(d);
        setError(false);
      })
      .catch(() => alive && setError(true));
    return () => {
      alive = false;
    };
  }, [view, tick]);

  return { data, error, reload };
}
