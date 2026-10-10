// health: the daily health check (Stage 4, plan approved by Dad 2026-10-09).
//
// The GitHub workflow .github/workflows/health-check.yml calls this once a day with
// the x-health-key header (HEALTH_CHECK_KEY). It checks the database size (an alert
// past about 400 MB), then answers with health_check(): 200 when all is well, 503
// when anything is open, so the workflow fails and GitHub emails Dad. The call is
// also the Free plan's keep-alive.
//
// mode "test_alert": raises a test alert on Dad's Dashboard (raise_test_alert), so
// the check fails and GitHub emails him. He acknowledges it on the Dashboard.
//
// The workflow never holds the service role key: only this function does. The repo
// may be public, and so may the workflow's log, so the answer holds only kinds of
// problems and job names: no alert wording, names or account ids.
//
// Runs with verify_jwt = false (supabase/config.toml).

import { createClient } from 'npm:@supabase/supabase-js@2';
import { isHosted, keyProblem, sameKey } from '../_shared/lib.ts';

function reply(status: number, body: Record<string, unknown>): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}

interface Problem {
  kind?: string;
  alert_kind?: string;
  job?: string;
  done_through?: string | null;
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return reply(405, { error: 'method' });

  const url = Deno.env.get('SUPABASE_URL') ?? '';
  const expected = Deno.env.get('HEALTH_CHECK_KEY') ?? '';
  const bad = keyProblem(expected, isHosted(url));
  if (bad) return reply(500, { error: bad });
  if (!sameKey(req.headers.get('x-health-key') ?? '', expected))
    return reply(401, { error: 'key' });

  let mode = 'check';
  try {
    const body = await req.json();
    if (body?.mode === 'test_alert') mode = 'test_alert';
  } catch {
    // An empty body means the normal check.
  }

  const db = createClient(url, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  try {
    const size = await db.rpc('check_database_size');
    if (size.error) throw new Error(`check_database_size: ${size.error.message}`);
    if (mode === 'test_alert') {
      const t = await db.rpc('raise_test_alert');
      if (t.error) throw new Error(`raise_test_alert: ${t.error.message}`);
    }
    const health = await db.rpc('health_check');
    if (health.error) throw new Error(`health_check: ${health.error.message}`);

    const h = health.data as {
      ok: boolean;
      checked_at: string;
      summary: string;
      problems: Problem[];
    };
    const problems = h.problems.map((p) => ({
      kind: p.kind,
      ...(p.alert_kind ? { alert_kind: p.alert_kind } : {}),
      ...(p.job ? { job: p.job, done_through: p.done_through ?? null } : {}),
    }));
    const body = {
      ok: h.ok,
      checked_at: h.checked_at,
      // Plain words with job names, dates and counts only, never anyone's name.
      summary: h.summary,
      database_mb: (size.data as { megabytes: number }).megabytes,
      problems,
      ...(mode === 'test_alert'
        ? {
            test: 'Test alert from Big Bucks: it is on the Dashboard too. Acknowledge it there to clear it.',
          }
        : {}),
    };
    return reply(h.ok && mode !== 'test_alert' ? 200 : 503, body);
  } catch (e) {
    return reply(500, { ok: false, error: (e as Error).message.slice(0, 300) });
  }
});
