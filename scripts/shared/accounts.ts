// Creating logins, shared by the local setup script (scripts/local) and the
// production one (scripts/prod). Every rule is in the database; these only call it
// with the service role, and never store a PIN or a password anywhere.

import { randomBytes, randomUUID } from 'node:crypto';
import type { SupabaseClient } from '@supabase/supabase-js';

/**
 * A kid's hidden email: random, never worked out from her username, so knowing
 * her username doesn't give away her Auth login (pre-launch audit, 2026-10-08).
 */
export const newKidEmail = (): string => `kid-${randomBytes(12).toString('hex')}@kids.local`;

export interface NewKid {
  username: string;
  displayName: string;
  pin: string;
  isTest: boolean;
}

/**
 * A kid: an Auth login (a random hidden email, and a password the server works
 * out from her PIN: never the PIN itself), her account and profile.
 */
export async function createKid(
  admin: SupabaseClient,
  kid: NewKid,
): Promise<{ userId: string; accountId: string; email: string }> {
  if (!/^\d{6}$/.test(kid.pin)) throw new Error('A PIN is exactly 6 digits.');
  if (!/^[a-z0-9_]{3,30}$/.test(kid.username))
    throw new Error('A username is 3 to 30 lowercase letters, numbers or _.');
  const id = randomUUID();
  const pw = await admin.rpc('kid_auth_password', { p_user_id: id, p_pin: kid.pin });
  if (pw.error || typeof pw.data !== 'string')
    throw new Error(`Couldn't work out her password: ${pw.error?.message}`);
  const { data, error } = await admin.auth.admin.createUser({
    id,
    email: newKidEmail(),
    password: pw.data,
    email_confirm: true,
  });
  if (error || !data.user) throw new Error(`Couldn't create the login: ${error?.message}`);
  const r = await admin.rpc('create_kid_account', {
    p_user_id: data.user.id,
    p_username: kid.username,
    p_display_name: kid.displayName,
    p_is_test: kid.isTest,
  });
  if (r.error) {
    await admin.auth.admin.deleteUser(data.user.id);
    throw new Error(r.error.message);
  }
  return { userId: data.user.id, accountId: r.data as string, email: data.user.email! };
}

export interface NewParent {
  email: string;
  password: string;
  username: string;
  displayName: string;
}

/** A parent: an Auth login (email + password) and a profile. MFA is set up at first sign-in. */
export async function createParent(
  admin: SupabaseClient,
  p: NewParent,
): Promise<{ userId: string }> {
  if (p.password.length < 12) throw new Error('A parent password needs at least 12 characters.');
  const { data, error } = await admin.auth.admin.createUser({
    email: p.email,
    password: p.password,
    email_confirm: true,
  });
  if (error || !data.user) throw new Error(`Couldn't create the login: ${error?.message}`);
  const r = await admin.rpc('create_parent_profile', {
    p_user_id: data.user.id,
    p_username: p.username,
    p_display_name: p.displayName,
  });
  if (r.error) {
    await admin.auth.admin.deleteUser(data.user.id);
    throw new Error(r.error.message);
  }
  return { userId: data.user.id };
}
