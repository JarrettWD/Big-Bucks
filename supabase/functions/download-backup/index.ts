// download-backup: the parent's Download backup button (Stage 5).
//
// The app calls this with Dad's own sign-in token. The function signs in as him (never
// with the service role key) and calls parent_backup_export(), which refuses anyone
// but a parent with the authenticator code, reads every table as CSV and JSON text,
// and logs the download in parent_actions. This function only puts that text into a
// zip and hands it back.
//
// Runs with verify_jwt = false (supabase/config.toml): the database checks the token
// itself, the same as for every other parent action.

import { createClient } from 'npm:@supabase/supabase-js@2';
import { backupFileName, buildBackupZip, type Export } from '../_shared/backup_zip.ts';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Access-Control-Expose-Headers': 'content-disposition',
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

  const auth = req.headers.get('Authorization') ?? '';
  if (!/^Bearer \S+$/.test(auth)) return reply(401, { error: 'Sign in first.' });

  const url = Deno.env.get('SUPABASE_URL') ?? '';
  const anon = Deno.env.get('SUPABASE_ANON_KEY') ?? req.headers.get('apikey') ?? '';
  const db = createClient(url, anon, {
    global: { headers: { Authorization: auth } },
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const r = await db.rpc('parent_backup_export');
  if (r.error) {
    const refused = r.error.code === '42501' || /JWT|token/i.test(r.error.message);
    return reply(refused ? 403 : 500, { error: r.error.message.slice(0, 300) });
  }

  try {
    const data = r.data as Export;
    const zip = buildBackupZip(data);
    return new Response(zip, {
      status: 200,
      headers: {
        ...corsHeaders,
        'Content-Type': 'application/zip',
        'Content-Disposition': `attachment; filename="${backupFileName(data.day)}"`,
        'Cache-Control': 'no-store',
      },
    });
  } catch (e) {
    return reply(500, { error: (e as Error).message.slice(0, 300) });
  }
});
