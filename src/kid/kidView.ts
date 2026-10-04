// Whose screens these are, and how they read. In her own app: her account, read
// through her own functions and views. In Dad's "View as <kid>": her account, read
// ONLY through parent_view (parent-only, authenticator code required), with every
// action switched off. The database refuses kid actions from a parent anyway.

import { createContext, useContext } from 'react';
import { supabase } from '../lib/supabase';

export interface KidView {
  accountId: string;
  /** Her name, as on "Hi, …!". */
  name: string;
  /** True when Dad is looking at her screens (read-only). */
  viewing: boolean;
  /** Where her screens live: "/kid", or "/parent/view/<account>". */
  base: string;
}

export const KidViewContext = createContext<KidView | null>(null);

export function useKidView(): KidView {
  const v = useContext(KidViewContext);
  if (!v) throw new Error('useKidView outside a kid shell');
  return v;
}

type Result<T> = { data: T | null; error: { message: string } | null };

/** One of her read functions. Viewing: the same read through parent_view. */
export async function kidRpc<T>(
  view: KidView,
  fn: string,
  args: Record<string, unknown> = {},
): Promise<Result<T>> {
  if (!view.viewing) {
    const { data, error } = await supabase.rpc(fn, args);
    return { data: data as T | null, error };
  }
  const rest = Object.fromEntries(Object.entries(args).filter(([k]) => k !== 'p_account_id'));
  const { data, error } = await supabase.rpc('parent_view', {
    p_account: view.accountId,
    p_read: fn,
    p_args: rest,
  });
  return { data: data as T | null, error };
}

/** Her balances (one row of account_balances). */
export async function kidBalances<T>(view: KidView): Promise<Result<T>> {
  if (view.viewing) return kidRpc<T>(view, 'balances');
  const { data, error } = await supabase
    .from('account_balances')
    .select('*')
    .eq('account_id', view.accountId)
    .maybeSingle();
  return { data: data as T | null, error };
}

/** Her active GICs, and any matured one waiting for her choice. */
export async function kidHomeGics<T>(view: KidView): Promise<Result<T[]>> {
  if (view.viewing) return kidRpc<T[]>(view, 'home_gics');
  const { data, error } = await supabase
    .from('gic_positions')
    .select('*')
    .eq('account_id', view.accountId)
    .or('status.eq.active,and(status.eq.matured,maturity_choice.is.null)')
    .order('maturity_date')
    .order('gic_id');
  return { data: data as T[] | null, error };
}

/** Her unread notices, newest first. */
export async function kidUnreadNotices<T>(view: KidView): Promise<Result<T[]>> {
  if (view.viewing) return kidRpc<T[]>(view, 'unread_notices');
  const { data, error } = await supabase
    .from('notifications')
    .select('id, type, title, body, related_gic_id')
    .is('read_at', null)
    .order('created_at', { ascending: false })
    .order('id', { ascending: false });
  return { data: data as T[] | null, error };
}

/** How many notices she hasn't opened. */
export async function kidUnreadCount(view: KidView): Promise<Result<number>> {
  if (view.viewing) return kidRpc<number>(view, 'unread_count');
  const { count, error } = await supabase
    .from('notifications')
    .select('id', { count: 'exact', head: true })
    .is('read_at', null);
  return { data: count ?? 0, error };
}

/** Marks notices read: only in her own app. Dad viewing never marks anything. */
export async function kidMarkRead(view: KidView, ids: number[]): Promise<void> {
  if (view.viewing || ids.length === 0) return;
  await supabase.rpc('mark_notices_read', { p_ids: ids });
}
