// The kid-login function itself, called directly against the LOCAL Supabase (third
// audit, 2026-10-09): every failure takes the same time, which header gives the device
// address, and Dad's PIN-reset code (wrong codes count as wrong PINs; the right one
// leads to a new PIN). A throwaway test kid (e2e_api); each test uses its own made-up
// device address so their counts don't mix.
import { readFileSync } from 'node:fs';
import { expect, test } from '@playwright/test';
import { LocalDb } from '../scripts/timemachine/db.ts';
import { logins } from './helpers';

test.describe.configure({ mode: 'serial' });

const URL = 'http://127.0.0.1:54321/functions/v1/kid-login';
const anon = () =>
  readFileSync('.env.local', 'utf8')
    .match(/^VITE_SUPABASE_ANON_KEY=(.*)$/m)![1]
    .trim();

async function call(body: Record<string, unknown>, headers: Record<string, string> = {}) {
  const started = Date.now();
  const r = await fetch(URL, {
    method: 'POST',
    headers: {
      apikey: anon(),
      Authorization: `Bearer ${anon()}`,
      'Content-Type': 'application/json',
      ...headers,
    },
    body: JSON.stringify(body),
  });
  const json = (await r.json()) as Record<string, unknown>;
  return { status: r.status, body: json, ms: Date.now() - started };
}

async function rows<T>(sql: string, params: unknown[] = []): Promise<T[]> {
  const db = await LocalDb.connect();
  try {
    return (await db.q(sql, params)) as T[];
  } finally {
    await db.close();
  }
}

const other = (pin: string) => (pin === '000000' ? '111111' : '000000');

test('every failure takes at least 1.5 seconds, a known username or not', async () => {
  const { apiKid } = logins();
  const ip = { 'cf-connecting-ip': '203.0.113.21' };
  const wrong = await call({ username: apiKid.username, pin: other(apiKid.pin) }, ip);
  expect(wrong.status).toBe(401);
  expect(wrong.ms).toBeGreaterThanOrEqual(1450);
  const unknown = await call({ username: 'nobody_e2e', pin: '123456' }, ip);
  expect(unknown.status).toBe(401);
  expect(unknown.ms).toBeGreaterThanOrEqual(1450);
  const notAPin = await call({ username: apiKid.username, pin: 'abc' }, ip);
  expect(notAPin.status).toBe(401);
  expect(notAPin.ms).toBeGreaterThanOrEqual(1450);
});

test('the device address comes from the platform header first, and is stored only as a hash', async () => {
  const { apiKid } = logins();
  await call(
    { username: apiKid.username, pin: other(apiKid.pin) },
    { 'cf-connecting-ip': '203.0.113.22', 'X-Forwarded-For': '198.51.100.1, 198.51.100.2' },
  );
  const [r] = await rows<{ client: string; expected: string }>(
    `select la.client, public.login_client('203.0.113.22') as expected
       from public.login_attempts la where la.username = $1 order by la.id desc limit 1`,
    [apiKid.username],
  );
  expect(r.client).toBe(r.expected);
  expect(r.client).not.toContain('203.0.113');
});

test("Dad's reset code: wrong codes count as wrong PINs; the right one leads to a new PIN", async () => {
  const { apiKid } = logins();
  const code = '246810';
  // A reset waiting for her, as Dad's Settings → Logins makes one (its code known here).
  await rows(
    `insert into private.kid_pin_resets (account_id, code_hash, expires_at)
     select p.account_id, public.pin_reset_code_hash(p.user_id, $2), public.app_now() + interval '1 day'
       from public.profiles p where p.username = $1
     on conflict (account_id) do update set code_hash = excluded.code_hash, expires_at = excluded.expires_at`,
    [apiKid.username, code],
  );
  const ip = { 'cf-connecting-ip': '203.0.113.23' };
  const wrong = await call({ username: apiKid.username, pin: '135790' }, ip);
  expect(wrong.status).toBe(401);
  expect(wrong.body.tries_left).toBe(4);
  // Her old PIN isn't the code either: also a wrong try.
  const old = await call({ username: apiKid.username, pin: apiKid.pin }, ip);
  expect(old.status).toBe(401);
  expect(old.body.tries_left).toBe(3);

  const right = await call({ username: apiKid.username, pin: code }, ip);
  expect(right.status).toBe(409);
  expect(right.body.error).toBe('new_pin_needed');
  const same = await call({ username: apiKid.username, pin: code, new_pin: code }, ip);
  expect(same.body.error).toBe('bad_new_pin');

  const fresh = '975310';
  const set = await call({ username: apiKid.username, pin: code, new_pin: fresh }, ip);
  expect(set.status).toBe(200);
  expect(set.body.session).toBeTruthy();
  const again = await call({ username: apiKid.username, pin: fresh }, ip);
  expect(again.status).toBe(200);
  const used = await call({ username: apiKid.username, pin: code }, ip);
  expect(used.status).toBe(401); // the code works only once
});
