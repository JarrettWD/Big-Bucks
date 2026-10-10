// The LOCAL Supabase, for the setup script, the demo and jobs:local.
//
// Everything here refuses to work with anything but the local Supabase on this
// computer: the API must be http://127.0.0.1:54321 and the database must say
// is_local_dev = true (the time machine's guard). Production comes after stage 4.

import { execSync } from 'node:child_process';
import { writeFileSync } from 'node:fs';
import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import { LocalDb } from '../timemachine/db.ts';

export const LOCAL_API_URL = 'http://127.0.0.1:54321';

export interface LocalKeys {
  apiUrl: string;
  anonKey: string;
  serviceKey: string;
}

/** Refuse anything that isn't the local API. */
export function assertLocalApi(url: string): void {
  let u: URL;
  try {
    u = new URL(url);
  } catch {
    throw new Error(`Refusing to run: "${url}" isn't a web address.`);
  }
  if (
    u.protocol !== 'http:' ||
    !['127.0.0.1', 'localhost'].includes(u.hostname) ||
    u.port !== '54321' ||
    /supabase\.(co|com|net)/i.test(url)
  ) {
    throw new Error(
      `Refusing to run: this only works with the local Supabase (${LOCAL_API_URL}), not ${url}. ` +
        'Real accounts in production come after stage 4.',
    );
  }
}

/** The local URL and keys, read from `supabase status` (the local stack must be running). */
export function localKeys(): LocalKeys {
  let out: string;
  try {
    out = execSync('npx supabase status -o env', {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore'],
    });
  } catch {
    throw new Error(
      'The local Supabase isn\'t running. Start Docker Desktop, then run "npm run db:start".',
    );
  }
  const env = Object.fromEntries(
    out
      .split(/\r?\n/)
      .map((l) => l.match(/^([A-Z_0-9]+)="?(.*?)"?$/))
      .filter((m): m is RegExpMatchArray => m !== null)
      .map((m) => [m[1], m[2]]),
  );
  const keys = { apiUrl: env.API_URL, anonKey: env.ANON_KEY, serviceKey: env.SERVICE_ROLE_KEY };
  if (!keys.apiUrl || !keys.anonKey || !keys.serviceKey)
    throw new Error(
      'The local Supabase isn\'t fully running (no API address or keys). Run "npm run db:start".',
    );
  assertLocalApi(keys.apiUrl);
  return keys;
}

/** Both guards: the local API, and a database that says is_local_dev = true. */
export async function connectLocal(): Promise<{
  keys: LocalKeys;
  db: LocalDb;
  admin: SupabaseClient;
}> {
  const keys = localKeys();
  const db = await LocalDb.connect();
  const admin = createClient(keys.apiUrl, keys.serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  return { keys, db, admin };
}

/** A fresh signed-out client with the anon key, as the app would have. */
export function anonClient(keys: LocalKeys): SupabaseClient {
  return createClient(keys.apiUrl, keys.anonKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

/**
 * Points the app at the local Supabase: writes `.env.local` (gitignored) with
 * the local URL and anon key. Only these two ever go in the app.
 */
export function writeAppEnv(keys: LocalKeys): void {
  writeFileSync(
    '.env.local',
    [
      '# Written by the demo / setup script: the app talks to the LOCAL Supabase.',
      `VITE_SUPABASE_URL=${keys.apiUrl}`,
      `VITE_SUPABASE_ANON_KEY=${keys.anonKey}`,
      '',
    ].join('\n'),
  );
}

// Creating logins lives in scripts/shared/accounts.ts (the production setup script uses it too).
export {
  createKid,
  createParent,
  newKidEmail,
  type NewKid,
  type NewParent,
} from '../shared/accounts.ts';
