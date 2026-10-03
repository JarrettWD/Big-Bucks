// The app's one Supabase client. Only the project URL and the anon key are in
// the app; everything else is decided by the database's own rules.

import { createClient, type SupabaseClient } from '@supabase/supabase-js';

const url = import.meta.env.VITE_SUPABASE_URL as string | undefined;
const anonKey = import.meta.env.VITE_SUPABASE_ANON_KEY as string | undefined;

export const supabaseConfigured = Boolean(url && anonKey);

export const supabase: SupabaseClient = createClient(
  url ?? 'http://127.0.0.1:54321',
  anonKey ?? 'not-configured',
  { auth: { persistSession: true, autoRefreshToken: true, storageKey: 'bb.auth' } },
);

export const functionsUrl = `${url ?? 'http://127.0.0.1:54321'}/functions/v1`;
export const anonKeyForFunctions = anonKey ?? '';
