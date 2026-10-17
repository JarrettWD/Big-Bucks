// The badge checks the app makes AFTER a money call has succeeded (stage 10, Dad's
// decision): the money functions never call badges, so these are separate calls.
// Each only gives badges already earned, once each, and never touches money; if one
// fails (no signal, say), the nightly check after reconcile gives the badge anyway,
// so a failure here is ignored.

import { supabase } from './supabase';

/** After her own GIC purchase or renewal. Does nothing in Dad's "View as". */
export async function checkMyBadges(): Promise<void> {
  try {
    await supabase.rpc('kid_check_my_badges');
  } catch {
    // the nightly check catches it
  }
}

/** After Dad approves a deposit (one kid) or changes the Badges switch (every kid). */
export async function parentCheckBadges(
  accountId: string | null,
  after: 'deposit' | 'switch',
): Promise<void> {
  try {
    await supabase.rpc('parent_check_badges', { p_account: accountId, p_after: after });
  } catch {
    // the nightly check catches it
  }
}
