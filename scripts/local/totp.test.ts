import { describe, expect, it } from 'vitest';
import { base32Decode, totp, totpFromKey } from './totp.ts';

// RFC 6238 Appendix B, SHA-1, with the key "12345678901234567890".
const KEY = Buffer.from('12345678901234567890', 'ascii');

describe('authenticator codes (RFC 6238)', () => {
  it.each([
    [59, '94287082'],
    [1111111109, '07081804'],
    [1111111111, '14050471'],
    [1234567890, '89005924'],
    [2000000000, '69279037'],
    [20000000000, '65353130'],
  ])('at %i seconds the 8-digit code is %s', (t, code) => {
    expect(totpFromKey(KEY, t, 8)).toBe(code);
  });

  it('6-digit codes are the last 6 digits', () => {
    expect(totpFromKey(KEY, 59)).toBe('287082');
  });

  it('decodes base32 (the form authenticator apps use)', () => {
    // "12345678901234567890" in base32
    const secret = 'GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ';
    expect(base32Decode(secret).toString('ascii')).toBe('12345678901234567890');
    expect(totp(secret, 59)).toBe('287082');
    expect(totp(secret.toLowerCase().replace(/(.{4})/g, '$1 '), 59)).toBe('287082');
  });

  it('refuses characters that are not base32', () => {
    expect(() => base32Decode('ABC1')).toThrow();
  });
});
