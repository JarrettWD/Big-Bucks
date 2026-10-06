import { describe, expect, it } from 'vitest';
import { daysBetween, formatDate, formatPct, formatRate, termLabel, termWords } from './format';

describe('formatRate (same as the database fmt_rate)', () => {
  it.each([
    ['2.000', '2.0%'],
    ['2.500', '2.5%'],
    ['1.750', '1.75%'],
    ['4.125', '4.125%'],
    [5, '5.0%'],
    ['0.000', '0.0%'],
  ])('%s → %s', (r, t) => expect(formatRate(r)).toBe(t));
  it('refuses junk', () => expect(() => formatRate('abc')).toThrow());
});

describe('formatPct', () => {
  it('pads the daily change to 2 decimals when JSON dropped a zero, never rounding', () => {
    expect(formatPct(0.9, 2)).toBe('0.90%');
    expect(formatPct('1', 2)).toBe('1.00%');
    expect(formatPct('-0.67', 2)).toBe('0.67%');
    expect(() => formatPct('0.675', 2)).toThrow();
  });
  it('drops the sign (the words say up or down)', () => {
    expect(formatPct('-0.67')).toBe('0.67%');
    expect(formatPct('2.50')).toBe('2.50%');
    expect(formatPct(0)).toBe('0%');
  });
});

describe('terms', () => {
  it.each([
    [1, '1-month', '1 month'],
    [3, '3-month', '3 months'],
    [12, '1-year', '1 year'],
    [24, '2-year', '2 years'],
  ])('%i months', (m, label, words) => {
    expect(termLabel(m)).toBe(label);
    expect(termWords(m)).toBe(words);
  });
});

describe('dates', () => {
  it('formats like the database ("Oct 7")', () => {
    expect(formatDate('2026-10-07')).toBe('Oct 7');
    expect(formatDate('2026-10-07', 2026)).toBe('Oct 7');
    expect(formatDate('2027-01-04', 2026)).toBe('Jan 4, 2027');
  });
  it('counts whole days, across month ends and leap days', () => {
    expect(daysBetween('2026-10-01', '2026-10-07')).toBe(6);
    expect(daysBetween('2028-02-28', '2028-03-01')).toBe(2);
    expect(daysBetween('2026-10-07', '2026-10-01')).toBe(-6);
  });
});
