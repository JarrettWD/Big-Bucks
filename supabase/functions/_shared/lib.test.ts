// The nightly and health functions' plain logic (Stage 4).
import { describe, expect, it } from 'vitest';
import {
  cleanPrice,
  fakeCloses,
  isHosted,
  keyProblem,
  parseDaily,
  parseSplits,
  parseWeekly,
  providerSymbol,
  sameKey,
  splitRatio,
  weeklyForBackfill,
} from './lib.ts';

describe('provider symbols', () => {
  it('adds the Toronto suffix for TSX funds only', () => {
    expect(providerSymbol('XIC', 'tsx')).toBe('XIC.TRT');
    expect(providerSymbol('DIA', 'nyse')).toBe('DIA');
  });
});

describe('prices stay exact strings', () => {
  it('keeps digits as they came', () => {
    expect(cleanPrice('423.1500')).toBe('423.1500');
    expect(cleanPrice(' 41.25 ')).toBe('41.25');
  });
  it('refuses anything that is not a positive price with at most 8 decimals', () => {
    for (const bad of ['0', '0.0000', '-1', '1e3', 'abc', '', '1.123456789', '12,5'])
      expect(cleanPrice(bad)).toBeNull();
    expect(cleanPrice(423.15)).toBeNull();
  });
});

describe('the daily series', () => {
  const reply = {
    'Meta Data': { '2. Symbol': 'DIA' },
    'Time Series (Daily)': {
      '2026-10-08': { '1. open': '420.0000', '4. close': '423.1500' },
      '2026-10-07': { '4. close': '421.0100' },
      'not-a-day': { '4. close': '1' },
      '2026-10-06': { '4. close': 'n/a' },
    },
  };
  it('gives each day its close, oldest first, skipping anything malformed', () => {
    expect(parseDaily(reply)).toEqual({
      ok: true,
      value: [
        { date: '2026-10-07', close: '421.0100' },
        { date: '2026-10-08', close: '423.1500' },
      ],
    });
  });
  it('tells a wrong symbol from a used-up limit', () => {
    expect(parseDaily({ 'Error Message': 'Invalid API call.' })).toMatchObject({
      ok: false,
      kind: 'bad_symbol',
    });
    expect(parseDaily({ Note: 'Thank you for using Alpha Vantage!' })).toMatchObject({
      ok: false,
      kind: 'limit',
    });
    expect(
      parseDaily({ Information: 'Our standard API rate limit is 25 requests per day.' }),
    ).toMatchObject({
      ok: false,
      kind: 'limit',
    });
  });
  it('never treats an empty or odd reply as closes', () => {
    expect(parseDaily({})).toMatchObject({ ok: false, kind: 'unexpected' });
    expect(parseDaily(null)).toMatchObject({ ok: false, kind: 'unexpected' });
    expect(parseDaily({ 'Time Series (Daily)': {} })).toMatchObject({ ok: false });
  });
  it('reads the weekly series the same way', () => {
    expect(
      parseWeekly({ 'Weekly Time Series': { '2025-01-10': { '4. close': '425.5000' } } }),
    ).toEqual({
      ok: true,
      value: [{ date: '2025-01-10', close: '425.5000' }],
    });
  });
});

describe('splits', () => {
  it('turns a split factor into whole numbers', () => {
    expect(splitRatio('2.0000')).toEqual({ from: 1, to: 2 });
    expect(splitRatio('3')).toEqual({ from: 1, to: 3 });
    expect(splitRatio('1.5')).toEqual({ from: 2, to: 3 });
    expect(splitRatio('0.5000')).toEqual({ from: 2, to: 1 });
    expect(splitRatio('0.1')).toEqual({ from: 10, to: 1 });
  });
  it('refuses a factor that changes nothing or makes no sense', () => {
    for (const bad of ['1.0000', '0', '', 'two', '-2', '1.0001'])
      expect(splitRatio(bad)).toBeNull();
  });
  it('reads the split list', () => {
    expect(
      parseSplits({
        symbol: 'QQQ',
        data: [
          { effective_date: '2000-03-20', split_factor: '2.0000' },
          { effective_date: 'bad', split_factor: '2' },
        ],
      }),
    ).toEqual({ ok: true, value: [{ date: '2000-03-20', from: 1, to: 2 }] });
    expect(parseSplits({ symbol: 'DIA', data: [] })).toEqual({ ok: true, value: [] });
    expect(parseSplits({})).toEqual({ ok: true, value: [] });
  });
});

describe('the backfill', () => {
  it('keeps weekly closes only before the daily series and no older than two years', () => {
    const weekly = [
      { date: '2024-10-04', close: '1' },
      { date: '2024-10-11', close: '2' },
      { date: '2026-05-15', close: '3' },
      { date: '2026-05-22', close: '4' },
    ];
    const daily = [{ date: '2026-05-20', close: '5' }];
    expect(weeklyForBackfill(weekly, daily, '2024-10-09').map((w) => w.date)).toEqual([
      '2024-10-11',
      '2026-05-15',
    ]);
  });
});

describe('the made-up price source (your own computer only)', () => {
  it('follows on from the last close, the same every time', () => {
    const a = fakeCloses('DIA', { date: '2026-10-08', close: '423.150000' }, [
      '2026-10-09',
      '2026-10-12',
    ]);
    const b = fakeCloses('DIA', { date: '2026-10-08', close: '423.150000' }, [
      '2026-10-12',
      '2026-10-09',
    ]);
    expect(a).toEqual(b);
    expect(a.map((c) => c.date)).toEqual(['2026-10-09', '2026-10-12']);
    for (const c of a) expect(cleanPrice(c.close)).toBe(c.close);
    const first = Number(a[0].close);
    expect(Math.abs(first / 423.15 - 1)).toBeLessThan(0.013);
  });
  it('starts from 100 when nothing is stored yet', () => {
    const [c] = fakeCloses('XIC', null, ['2026-10-09']);
    expect(Math.abs(Number(c.close) - 100)).toBeLessThan(1.3);
  });
});

describe('keys', () => {
  it('match only exactly', () => {
    expect(sameKey('abc', 'abc')).toBe(true);
    expect(sameKey('abd', 'abc')).toBe(false);
    expect(sameKey('ab', 'abc')).toBe(false);
    expect(sameKey('abcd', 'abc')).toBe(false);
    expect(sameKey('', '')).toBe(false);
  });
  it('tell hosted Supabase from your own computer', () => {
    expect(isHosted('https://abcdefghij.supabase.co')).toBe(true);
    expect(isHosted('http://kong:8000')).toBe(false);
    expect(isHosted('not a url')).toBe(true);
  });
  it('refuse a short key, and the local test key on hosted Supabase', () => {
    expect(keyProblem('short', false)).not.toBeNull();
    expect(keyProblem('local-nightly-key-for-this-computer-only', false)).toBeNull();
    expect(keyProblem('local-nightly-key-for-this-computer-only', true)).not.toBeNull();
    expect(keyProblem('x'.repeat(40), true)).toBeNull();
  });
});
