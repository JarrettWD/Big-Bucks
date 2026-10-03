import { describe, expect, it } from 'vitest';
import { formatCents, toCents } from './money';

describe('formatCents', () => {
  it.each([
    [0, '$0.00'],
    [5, '$0.05'],
    [42, '$0.42'],
    [100, '$1.00'],
    [10500, '$105.00'],
    [123456, '$1,234.56'],
    [100000, '$1,000.00'],
    [123456789, '$1,234,567.89'],
    [-500, '−$5.00'],
    [-123456, '−$1,234.56'],
  ])('%s cents → %s', (cents, text) => {
    expect(formatCents(cents)).toBe(text);
  });

  it('takes strings and bigints, as the database sends them', () => {
    expect(formatCents('82136')).toBe('$821.36');
    expect(formatCents(' 82136 ')).toBe('$821.36');
    expect(formatCents(82136n)).toBe('$821.36');
    expect(formatCents('-7')).toBe('−$0.07');
  });

  it('handles amounts beyond what a JavaScript number holds exactly', () => {
    expect(formatCents('900719925474099312')).toBe('$9,007,199,254,740,993.12');
  });

  it('adds a + only when asked, and only above zero', () => {
    expect(formatCents(250, { sign: true })).toBe('+$2.50');
    expect(formatCents(0, { sign: true })).toBe('$0.00');
    expect(formatCents(-250, { sign: true })).toBe('−$2.50');
  });
});

describe('toCents refuses anything that is not whole cents', () => {
  it.each([[1.5], [NaN], [Infinity], [2 ** 53]])('number %s', (v) => {
    expect(() => toCents(v)).toThrow();
  });
  it.each([['1.50'], [''], ['$5'], ['1e3'], ['12abc']])('string "%s"', (v) => {
    expect(() => toCents(v)).toThrow();
  });
});
