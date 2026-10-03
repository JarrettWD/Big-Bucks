import { describe, expect, it } from 'vitest';
import {
  albertaDate,
  daysBetween,
  formatDate,
  formatPct,
  formatRate,
  termLabel,
  termWords,
} from './format';

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

describe('albertaDate (same rule as the database edmonton_local)', () => {
  it.each([
    ['2026-10-31T18:00:00Z', '2026-10-31'],
    ['2026-11-01T05:59:00Z', '2026-10-31'], // 11:59 pm Oct 31 in Alberta
    ['2026-11-01T06:00:00Z', '2026-11-01'], // midnight Nov 1: no clock change
    ['2026-11-02T06:30:00+00:00', '2026-11-02'], // 12:30 am, not 11:30 pm the day before
    ['2027-01-01T05:30:00Z', '2026-12-31'], // 11:30 pm Dec 31 in Alberta, already Jan 1 in UTC
    ['2027-07-01T06:00:00Z', '2027-07-01'],
    ['2027-11-08T05:59:59Z', '2027-11-07'],
  ])('%s → %s', (m, d) => expect(albertaDate(m)).toBe(d));
  it('refuses junk and moments before the fixed rule', () => {
    expect(() => albertaDate('soon')).toThrow();
    expect(() => albertaDate('2026-01-15T12:00:00Z')).toThrow();
  });
});
