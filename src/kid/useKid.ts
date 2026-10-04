// What the kid shell needs about her account: total worth, whether her figures
// are "Updating…", whether the Wish List is on for her, and unread notices.
// All read through the database's own rules; she can only ever see her own.

import { useCallback, useEffect, useState } from 'react';
import { kidBalances, kidRpc, kidUnreadCount, type KidView } from './kidView';

export interface KidSummary {
  loading: boolean;
  totalWorthCents: string | null;
  updating: boolean;
  wishlist: boolean;
  unread: number;
  error: boolean;
}

export function useKidSummary(view: KidView | null): KidSummary & { reload: () => void } {
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
    if (!view) return;
    let alive = true;
    const accountId = view.accountId;
    Promise.all([
      kidBalances<{ total_worth_cents: number | string }>(view),
      kidRpc<boolean>(view, 'figures_updating', { p_account_id: accountId }),
      kidRpc<boolean>(view, 'feature_enabled', { p_feature: 'wishlist', p_account_id: accountId }),
      kidUnreadCount(view),
    ]).then(([bal, upd, wish, unread]) => {
      if (!alive) return;
      setS({
        loading: false,
        totalWorthCents: bal.data ? String(bal.data.total_worth_cents) : null,
        updating: upd.data === true,
        wishlist: wish.data === true,
        unread: unread.data ?? 0,
        error: Boolean(bal.error || upd.error || wish.error || unread.error),
      });
    });
    return () => {
      alive = false;
    };
  }, [view, tick]);

  return { ...s, reload };
}
