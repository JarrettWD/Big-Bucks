// kid-login: a kid signs in with her username and 6-digit PIN.
//
// 1. Look up the username (server-only database function): is it a kid, her
//    login id and hidden email, and is it locked for this device?
// 2. If it's a kid and not locked, turn the PIN into her Supabase Auth password
//    (kid_auth_password, a keyed hash only the server can work out) and sign in.
// 3. Record the attempt. 5 wrong PINs in a row lock this device out of the
//    username; 20 in a day from any devices lock it for everyone. Locks last 15
//    minutes, then an hour, then 24 hours if they repeat. Dad is alerted (all
//    decided in the database).
// 3b. If Dad reset her PIN, what she types is his one-time code: with the right
//    code she chooses a new PIN (new_pin) and is signed in with it.
// 4. On success, hand back a normal Supabase session.
//
// Her Auth password is never her PIN, so guessing PINs straight against
// Supabase Auth (skipping this door and its lockout) can't work (pre-launch
// audit, 2026-10-08).
//
// Unknown usernames and the parent's username get the same answer as a wrong
// PIN, and every failure takes the same time, so this door never reveals which
// usernames exist. Nothing here is personal: usernames and emails live only in
// the database, and the device's IP address is only ever stored as a keyed hash.
//
// Runs with verify_jwt = false (see supabase/config.toml): it's the way in, so
// callers aren't signed in yet. It only ever uses the service role inside.

import { createClient } from 'npm:@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

/** Every failure answers no sooner than this after the request arrived. */
const FAILURE_MS = 1500;

function reply(status: number, body: Record<string, unknown>): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
}

/**
 * The caller's IP address, from the headers the platform sets itself. A caller can
 * write its own X-Forwarded-For, but proxies only ever add to its end, so its last
 * entry is the one our side saw; cf-connecting-ip and x-real-ip are set by the
 * platform when present (second audit, 2026-10-08; checked on production: RUNBOOK).
 */
function clientAddress(req: Request): string {
  const set = req.headers.get('cf-connecting-ip') ?? req.headers.get('x-real-ip');
  if (set) return set.trim().slice(0, 100);
  const forwarded = (req.headers.get('x-forwarded-for') ?? '').split(',');
  return (forwarded[forwarded.length - 1] ?? '').trim().slice(0, 100);
}

Deno.serve(async (req) => {
  const started = Date.now();
  const fail = async (status: number, body: Record<string, unknown>) => {
    const wait = FAILURE_MS - (Date.now() - started);
    if (wait > 0) await new Promise((r) => setTimeout(r, wait));
    return reply(status, body);
  };

  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  if (req.method !== 'POST') return reply(405, { error: 'method' });

  let username = '';
  let pin = '';
  let newPin: string | null = null;
  try {
    const body = await req.json();
    username = String(body?.username ?? '').slice(0, 100);
    pin = String(body?.pin ?? '');
    newPin = body?.new_pin == null ? null : String(body.new_pin);
  } catch {
    return fail(400, { error: 'bad_request' });
  }
  if (username.trim() === '') return fail(400, { error: 'bad_request' });

  const url = Deno.env.get('SUPABASE_URL')!;
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
  const anonKey = Deno.env.get('SUPABASE_ANON_KEY')!;
  const server = createClient(url, serviceKey, { auth: { persistSession: false } });
  const client = clientAddress(req);

  const pre = await server.rpc('login_precheck', { p_username: username, p_client: client });
  if (pre.error) return fail(500, { error: 'server' });
  const check = pre.data as {
    is_kid: boolean;
    user_id: string | null;
    email: string | null;
    reset_pending: boolean;
    locked_until: string | null;
  };
  if (check.locked_until) return fail(423, { error: 'locked', locked_until: check.locked_until });

  // Try the PIN only for a kid, and only if it looks like a PIN.
  let session: { access_token: string; refresh_token: string } | null = null;
  if (check.is_kid && check.email && check.user_id && /^\d{6}$/.test(pin)) {
    let signInPin: string | null = pin;
    let pinJustSet = false;
    if (check.reset_pending) {
      // Dad reset her PIN: what she typed must be his one-time code. A wrong code
      // counts as a wrong PIN. With the right code she chooses a new PIN.
      const ok = await server.rpc('check_pin_reset_code', {
        p_user_id: check.user_id,
        p_code: pin,
      });
      if (ok.error) return fail(500, { error: 'server' });
      signInPin = null;
      if (ok.data === true) {
        // These two answers come back quickly and aren't recorded as attempts: they only
        // happen with Dad's right code, so they reveal nothing a guesser could use.
        if (newPin === null) return reply(409, { error: 'new_pin_needed' });
        if (!/^\d{6}$/.test(newPin) || newPin === pin) return reply(400, { error: 'bad_new_pin' });
        const done = await server.rpc('finish_pin_reset', {
          p_user_id: check.user_id,
          p_code: pin,
          p_new_pin: newPin,
        });
        if (done.error) return fail(500, { error: 'server' });
        signInPin = newPin;
        pinJustSet = true;
      }
    }
    if (signInPin !== null) {
      const pw = await server.rpc('kid_auth_password', {
        p_user_id: check.user_id,
        p_pin: signInPin,
      });
      if (pw.error || typeof pw.data !== 'string') return fail(500, { error: 'server' });
      const signer = createClient(url, anonKey, { auth: { persistSession: false } });
      const { data, error } = await signer.auth.signInWithPassword({
        email: check.email,
        password: pw.data,
      });
      if (!error && data.session) {
        session = {
          access_token: data.session.access_token,
          refresh_token: data.session.refresh_token,
        };
      } else if (error && error.status !== 400) {
        // Not a wrong PIN (Auth is down, rate limited…): don't count it against her. If her
        // new PIN was just saved, say so: next time she signs in with it.
        return fail(503, { error: pinJustSet ? 'pin_set_try_again' : 'try_later' });
      }
    }
  }

  const rec = await server.rpc('record_login_attempt', {
    p_username: username,
    p_succeeded: session !== null,
    p_client: client,
  });
  if (rec.error) return fail(500, { error: 'server' });
  const result = rec.data as { locked_until: string | null; tries_left: number };

  if (result.locked_until) return fail(423, { error: 'locked', locked_until: result.locked_until });
  if (!session) return fail(401, { error: 'wrong', tries_left: result.tries_left });
  return reply(200, { session });
});
