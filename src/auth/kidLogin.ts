// Calls the kid-login Edge Function and turns its answer into a session or a
// friendly result for the login screen.

import { anonKeyForFunctions, functionsUrl, supabase } from '../lib/supabase';

export type KidLoginResult =
  | { kind: 'ok' }
  | { kind: 'wrong'; triesLeft: number }
  | { kind: 'locked'; until: Date }
  | { kind: 'offline' }
  | { kind: 'error' };

export async function kidLogin(username: string, pin: string): Promise<KidLoginResult> {
  let res: Response;
  try {
    res = await fetch(`${functionsUrl}/kid-login`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        apikey: anonKeyForFunctions,
        Authorization: `Bearer ${anonKeyForFunctions}`,
      },
      body: JSON.stringify({ username, pin }),
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
  return { kind: 'error' };
}

/** Minutes until a lock ends, at least 1. */
export function minutesLeft(until: Date, now = new Date()): number {
  return Math.max(1, Math.ceil((until.getTime() - now.getTime()) / 60000));
}
