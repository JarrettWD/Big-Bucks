// Authenticator-app codes (TOTP, RFC 6238: HMAC-SHA1, 30-second steps, 6 digits),
// for the demo parent and the end-to-end tests. Node's built-in crypto only.

import { createHmac } from 'node:crypto';

const ALPHABET = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';

export function base32Decode(text: string): Buffer {
  const clean = text.replace(/[\s=-]/g, '').toUpperCase();
  let bits = 0;
  let value = 0;
  const out: number[] = [];
  for (const ch of clean) {
    const v = ALPHABET.indexOf(ch);
    if (v < 0) throw new Error(`"${ch}" isn't a base32 character.`);
    value = (value << 5) | v;
    bits += 5;
    if (bits >= 8) {
      out.push((value >>> (bits - 8)) & 0xff);
      bits -= 8;
    }
  }
  return Buffer.from(out);
}

/** The code for a raw key at a moment (Unix seconds). */
export function totpFromKey(key: Buffer, unixSeconds: number, digits = 6, step = 30): string {
  const counter = Buffer.alloc(8);
  counter.writeBigUInt64BE(BigInt(Math.floor(unixSeconds / step)));
  const h = createHmac('sha1', key).update(counter).digest();
  const offset = h[h.length - 1] & 0x0f;
  const bin = (h.readUInt32BE(offset) & 0x7fffffff) % 10 ** digits;
  return bin.toString().padStart(digits, '0');
}

/** The code an authenticator app shows now for a base32 secret. */
export function totp(secretBase32: string, unixSeconds = Date.now() / 1000): string {
  return totpFromKey(base32Decode(secretBase32), unixSeconds);
}
