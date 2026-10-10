// The production setup script's guards (scripts/prod/setup-account.ts), as small
// tested functions (guards.test.ts). Each answers why something can't go ahead, or
// null when it can.

/** A Supabase project ref: 20 lowercase letters (Dashboard → Project Settings → General). */
const REF = /^[a-z]{20}$/;

export function argsProblem(argv: string[]): string | null {
  return argv.includes('--production')
    ? null
    : 'Refusing to run: this changes PRODUCTION. Run it as  npm run setup-account:prod -- --production';
}

export function refProblem(ref: string): string | null {
  return REF.test(ref)
    ? null
    : 'A project ref is 20 lowercase letters (Dashboard → Project Settings → General → Project ID).';
}

export function confirmProblem(ref: string, again: string): string | null {
  return ref === again ? null : "The two didn't match, so nothing was changed.";
}

export const productionUrl = (ref: string): string => `https://${ref}.supabase.co`;

/** What a JWT says about itself (never checked for a signature: that's the server's job). */
function claims(jwt: string): Record<string, unknown> | null {
  const part = jwt.split('.')[1];
  if (!part) return null;
  try {
    return JSON.parse(Buffer.from(part, 'base64url').toString('utf8')) as Record<string, unknown>;
  } catch {
    return null;
  }
}

/**
 * The key must be this project's service role key (the legacy JWT) or a secret key
 * (sb_secret_…). Never the anon or publishable key, and never another project's.
 */
export function serviceKeyProblem(key: string, ref: string): string | null {
  const k = key.trim();
  if (k.startsWith('sb_secret_')) return k.length > 20 ? null : 'That secret key looks cut short.';
  if (k.startsWith('sb_publishable_'))
    return "That's the publishable key. This needs the secret (service role) key.";
  const c = claims(k);
  if (!c)
    return "That isn't a Supabase key. Copy the service_role key from Project Settings → API Keys.";
  if (c.role !== 'service_role')
    return `That key's role is "${String(c.role)}". This needs the service_role key.`;
  if (c.ref !== undefined && c.ref !== ref)
    return `That key belongs to another project (${String(c.ref)}), not ${ref}.`;
  return null;
}
