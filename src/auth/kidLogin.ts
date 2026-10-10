// Calls the kid-login Edge Function and turns its answer into a session or a
// friendly result for the login screen.

import { anonKeyForFunctions, functionsUrl, supabase } from '../lib/supabase';

export type KidLoginResult =
  | { kind: 'ok' }
  | { kind: 'wrong'; triesLeft: number }
  | { kind: 'locked'; until: Date }
  /** Dad reset her PIN and she typed his code: she chooses a new PIN. */
  | { kind: 'new_pin_needed' }
  /** Her new PIN can't be Dad's code. */
  | { kind: 'bad_new_pin' }
  /** Her new PIN is saved, but signing in didn't work this time: she signs in with it next. */
  | { kind: 'pin_set' }
  | { kind: 'offline' }
  | { kind: 'error' };

export async function kidLogin(
  username: string,
  pin: string,
  newPin?: string,
): Promise<KidLoginResult> {
  let res: Response;
  try {
    res = await fetch(`${functionsUrl}/kid-login`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        apikey: anonKeyForFunctions,
        Authorization: `Bearer ${anonKeyForFunctions}`,
      },
      body: JSON.stringify(newPin ? { username, pin, new_pin: newPin } : { username, pin }),
    });
  } catch {
    return { kind: 'offline' };
  }
  let body: Record<string, unknown> = {};
  try {
    body = await res.json();
  } catch {
    /* keep empty */
  }
  if (res.status === 200 && body.session) {
    const s = body.session as { access_token: string; refresh_token: string };
    const { error } = await supabase.auth.setSession(s);
    return error ? { kind: 'error' } : { kind: 'ok' };
  }
  if (res.status === 423 && typeof body.locked_until === 'string')
    return { kind: 'locked', until: new Date(body.locked_until) };
  if (res.status === 401) return { kind: 'wrong', triesLeft: Number(body.tries_left ?? 0) };
  if (res.status === 409 && body.error === 'new_pin_needed') return { kind: 'new_pin_needed' };
  if (res.status === 400 && body.error === 'bad_new_pin') return { kind: 'bad_new_pin' };
  if (res.status === 503 && body.error === 'pin_set_try_again') return { kind: 'pin_set' };
  return { kind: 'error' };
}

/** How long until a lock ends, in words: minutes up to 90, then hours. */
export function waitWords(until: Date, now = new Date()): string {
  const m = minutesLeft(until, now);
  if (m <= 90) return `${m} minute${m === 1 ? '' : 's'}`;
  const h = Math.ceil(m / 60);
  return `${h} hours`;
}

/** Minutes until a lock ends, at least 1. */
export function minutesLeft(until: Date, now = new Date()): number {
  return Math.max(1, Math.ceil((until.getTime() - now.getTime()) / 60000));
}
