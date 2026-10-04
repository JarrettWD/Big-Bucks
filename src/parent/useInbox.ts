// The Approvals screen's data: parent_inbox() in one call. The database works out
// every amount, date and time; the screen only counts the seconds down.

import { useCallback, useEffect, useRef, useState } from 'react';
import { supabase } from '../lib/supabase';
import type { ActivityRow } from '../kid/home/activityText';

type Cents = number | string;

export interface WaitingRequest {
  id: number;
  account_id: string;
  kid: string;
  is_test: boolean;
  type: 'deposit' | 'withdraw';
  amount_cents: Cents;
  asked: string;
  approve_from: string | null;
  wait_seconds: number;
  expires: string;
  expires_seconds: number;
  savings_cents: Cents;
  held_cents: Cents;
  available_cents: Cents;
  savings_after_cents: Cents;
  cap_cents: Cents;
  net_deposits_cents: Cents;
  pending_deposits_cents: Cents;
  cap_room_cents: Cents;
}

export interface OpenQuestion {
  id: number;
  account_id: string;
  kid: string;
  is_test: boolean;
  message: string;
  asked: string;
  transaction_id: number | null;
  line: ActivityRow | null;
}

export interface RecentAction {
  id: number;
  action: string;
  summary: string;
  who: string;
  when: string;
  kid: string | null;
  is_test: boolean;
}

export interface Inbox {
  now: string;
  requests: WaitingRequest[];
  questions: OpenQuestion[];
  recent: RecentAction[];
}

export interface InboxState {
  inbox: Inbox | null;
  error: string | null;
  /** performance.now() when the inbox arrived: the countdowns run from here. */
  loadedAt: number;
  reload: () => Promise<Inbox | null>;
}

export function useInbox(): InboxState {
  const [inbox, setInbox] = useState<Inbox | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loadedAt, setLoadedAt] = useState(0);
  const alive = useRef(true);

  const apply = useCallback((r: { data: Inbox | null; error: string | null }) => {
    if (!alive.current) return null;
    if (r.error) {
      setError(r.error);
      return null;
    }
    setError(null);
    setInbox(r.data);
    setLoadedAt(performance.now());
    return r.data;
  }, []);

  const reload = useCallback(async () => apply(await fetchInbox()), [apply]);

  useEffect(() => {
    alive.current = true;
    fetchInbox().then(apply);
    // Fresh when Dad comes back to the app, and every minute while it's open.
    const onShow = () => {
      if (document.visibilityState === 'visible') void reload();
    };
    document.addEventListener('visibilitychange', onShow);
    const timer = window.setInterval(() => void reload(), 60_000);
    return () => {
      alive.current = false;
      document.removeEventListener('visibilitychange', onShow);
      window.clearInterval(timer);
    };
  }, [apply, reload]);

  return { inbox, error, loadedAt, reload };
}

async function fetchInbox(): Promise<{ data: Inbox | null; error: string | null }> {
  const { data, error } = await supabase.rpc('parent_inbox');
  return error ? { data: null, error: error.message } : { data: data as Inbox, error: null };
}
