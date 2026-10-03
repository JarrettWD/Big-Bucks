import { describe, expect, it } from 'vitest';
import { assertLocalApi } from './local.ts';
import { moveBp, nextClose } from './closes.ts';

describe('local-only guard', () => {
  it('allows the local Supabase', () => {
    expect(() => assertLocalApi('http://127.0.0.1:54321')).not.toThrow();
    expect(() => assertLocalApi('http://localhost:54321')).not.toThrow();
  });

  it.each([
    'https://abcdefghijklmnop.supabase.co',
    'http://127.0.0.1:54322', // the database port, not the API
    'https://127.0.0.1:54321',
    'http://192.168.1.20:54321',
    'http://127.0.0.1:54321.supabase.co',
    'not a url',
  ])('refuses %s', (url) => {
    expect(() => assertLocalApi(url)).toThrow(/Refusing to run/);
  });
});

describe('synthetic closes for jobs:local', () => {
  it('are the same every time for a fund and day', () => {
    expect(moveBp('dow', '2026-10-05')).toBe(moveBp('dow', '2026-10-05'));
  });

  it("stay within each fund's daily wobble", () => {
    for (let i = 1; i <= 28; i++) {
      const d = `2026-11-${String(i).padStart(2, '0')}`;
      expect(Math.abs(moveBp('dow', d) - 3)).toBeLessThanOrEqual(90);
      expect(Math.abs(moveBp('nasdaq100', d) - 5)).toBeLessThanOrEqual(160);
      expect(Math.abs(moveBp('tsx', d) - 3)).toBeLessThanOrEqual(80);
    }
  });

  it('move the price in whole thousandths of a dollar', () => {
    expect(nextClose(420_000n, 100)).toBe(424_200n); // $420.000 up 1% = $424.200
    expect(nextClose(38_123n, -37)).toBe(37_981n); // rounds toward zero
  });
});
