// What the kid shell needs about her account: total worth, whether her figures
// are "Updating…", whether the Wish List is on for her, and unread notices.
// All read through the database's own rules; she can only ever see her own.

import { useCallback, useEffect, useState } from 'react';
import { supabase } from '../lib/supabase';

export interface KidSummary {
  loading: boolean;
  totalWorthCents: string | null;
  updating: boolean;
  wishlist: boolean;
  unread: number;
  error: boolean;
}

export function useKidSummary(accountId: string | null): KidSummary & { reload: () => void } {
  const [s, setS] = useState<KidSummary>({
    loading: true,
    totalWorthCents: null,
    updating: false,
    wishlist: false,
    unread: 0,
    error: false,
  });
  const [tick, setTick] = useState(0);
  const reload = useCallback(() => setTick((t) => t + 1), []);

  useEffect(() => {
    if (!accountId) return;
    let alive = true;
    Promise.all([
      supabase
        .from('account_balances')
        .select('total_worth_cents')
        .eq('account_id', accountId)
        .maybeSingle(),
      supabase.rpc('figures_updating', { p_account_id: accountId }),
      supabase.rpc('feature_enabled', { p_feature: 'wishlist', p_account_id: accountId }),
      supabase
        .from('notifications')
        .select('id', { count: 'exact', head: true })
        .is('read_at', null),
    ]).then(([bal, upd, wish, unread]) => {
      if (!alive) return;
      setS({
        loading: false,
        totalWorthCents: bal.data ? String(bal.data.total_worth_cents) : null,
        updating: upd.data === true,
        wishlist: wish.data === true,
        unread: unread.count ?? 0,
        error: Boolean(bal.error || upd.error || wish.error || unread.error),
      });
    });
    return () => {
      alive = false;
    };
  }, [accountId, tick]);

  return { ...s, reload };
}
