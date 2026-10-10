import { describe, expect, it } from 'vitest';
import {
  argsProblem,
  confirmProblem,
  productionUrl,
  refProblem,
  serviceKeyProblem,
} from './guards.ts';

const REF = 'abcdefghijklmnopqrst';
const jwt = (payload: Record<string, unknown>) =>
  `eyJhbGciOiJIUzI1NiJ9.${Buffer.from(JSON.stringify(payload)).toString('base64url')}.signature`;

describe('the production setup script refuses unless every guard passes', () => {
  it('needs --production', () => {
    expect(argsProblem([])).toMatch(/Refusing to run/);
    expect(argsProblem(['--prod'])).toMatch(/Refusing to run/);
    expect(argsProblem(['--production'])).toBeNull();
  });

  it('needs a real project ref, typed twice', () => {
    expect(refProblem(REF)).toBeNull();
    for (const bad of [
      '',
      'abc',
      'ABCDEFGHIJKLMNOPQRST',
      'abcdefghijklmnopqrs1',
      `${REF}a`,
      '127.0.0.1',
    ])
      expect(refProblem(bad)).not.toBeNull();
    expect(confirmProblem(REF, REF)).toBeNull();
    expect(confirmProblem(REF, 'abcdefghijklmnopqrss')).not.toBeNull();
    expect(productionUrl(REF)).toBe('https://abcdefghijklmnopqrst.supabase.co');
  });

  it('needs this project’s service role key, never the anon key', () => {
    expect(serviceKeyProblem(jwt({ role: 'service_role', ref: REF }), REF)).toBeNull();
    expect(serviceKeyProblem('sb_secret_abcdefghijklmnopqrstuvwxyz', REF)).toBeNull();
    expect(serviceKeyProblem(jwt({ role: 'anon', ref: REF }), REF)).toMatch(/role is "anon"/);
    expect(
      serviceKeyProblem(jwt({ role: 'service_role', ref: 'zzzzzzzzzzzzzzzzzzzz' }), REF),
    ).toMatch(/another project/);
    expect(serviceKeyProblem('sb_publishable_abcdefghijklmnop', REF)).toMatch(/publishable/);
    expect(serviceKeyProblem('sb_secret_x', REF)).toMatch(/cut short/);
    expect(serviceKeyProblem('hello', REF)).toMatch(/isn't a Supabase key/);
  });
});
