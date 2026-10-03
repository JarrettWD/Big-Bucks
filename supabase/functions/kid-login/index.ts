// kid-login: a kid signs in with her username and 6-digit PIN.
//
// 1. Look up the username (server-only database function): is it a kid, what's
//    her hidden email, and is it locked?
// 2. If it's a kid and not locked, try the PIN as her Supabase Auth password.
// 3. Record the attempt. Five wrong PINs in a row lock the username for 15
//    minutes and alert Dad (all decided in the database).
// 4. On success, hand back a normal Supabase session.
//
// Unknown usernames and the parent's username get the same answer as a wrong
// PIN, so this door never reveals which usernames exist. Nothing here is
// personal: usernames and emails live only in the database.
//
// Runs with verify_jwt = false (see supabase/config.toml): it's the way in, so
// callers aren't signed in yet. It only ever uses the service role inside.

import { createClient } from 'npm:@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

function reply(status: number, body: Record<string, unknown>): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  if (req.method !== 'POST') return reply(405, { error: 'method' });

  let username = '';
  let pin = '';
  try {
    const body = await req.json();
    username = String(body?.username ?? '').slice(0, 100);
    pin = String(body?.pin ?? '');
  } catch {
    return reply(400, { error: 'bad_request' });
  }
  if (username.trim() === '') return reply(400, { error: 'bad_request' });

  const url = Deno.env.get('SUPABASE_URL')!;
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
  const anonKey = Deno.env.get('SUPABASE_ANON_KEY')!;
  const server = createClient(url, serviceKey, { auth: { persistSession: false } });

  const pre = await server.rpc('login_precheck', { p_username: username });
  if (pre.error) return reply(500, { error: 'server' });
  const check = pre.data as { is_kid: boolean; email: string | null; locked_until: string | null };
  if (check.locked_until) return reply(423, { error: 'locked', locked_until: check.locked_until });

  // Try the PIN only for a kid, and only if it looks like a PIN.
  let session: { access_token: string; refresh_token: string } | null = null;
  if (check.is_kid && check.email && /^\d{6}$/.test(pin)) {
    const signer = createClient(url, anonKey, { auth: { persistSession: false } });
    const { data, error } = await signer.auth.signInWithPassword({
      email: check.email,
      password: pin,
    });
    if (!error && data.session) {
      session = {
        access_token: data.session.access_token,
        refresh_token: data.session.refresh_token,
      };
    } else if (error && error.status !== 400) {
      // Not a wrong PIN (Auth is down, rate limited…): don't count it against her.
      return reply(503, { error: 'try_later' });
    }
  }

  const rec = await server.rpc('record_login_attempt', {
    p_username: username,
    p_succeeded: session !== null,
  });
  if (rec.error) return reply(500, { error: 'server' });
  const result = rec.data as { locked_until: string | null; tries_left: number };

  if (result.locked_until)
    return reply(423, { error: 'locked', locked_until: result.locked_until });
  if (!session) return reply(401, { error: 'wrong', tries_left: result.tries_left });
  return reply(200, { session });
});
