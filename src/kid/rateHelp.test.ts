// Dad, 2026-10-26: the ?s beside a live rate use that rate and her own figures (from the
// database), and a special says its last day.
import { describe, expect, it } from 'vitest';
import { inflationLines, interestLines, shortAmount, type RateHelp } from './rateHelp';
import { specialTag } from './trade/tradeText';

const help: RateHelp = {
  savings_rate: '1.000',
  per_100_cents: 100,
  per_100_exact: true,
  balance_cents: '9500',
  year_cents: '96',
  inflation_rate: '2.0',
  infl_100_cents: 10200,
  infl_exact: true,
  need_cents: '9690',
};

describe('the Interest rate ?', () => {
  it('says what her rate means for $100, then her own figure', () => {
    expect(interestLines(help)).toEqual([
      'At 1.0% a year, every $100 earns $1 in a year.',
      'Your $95.00 would earn about 96¢ in a year.',
    ]);
  });
  it('says "about" when $100 doesn\'t earn whole cents', () => {
    expect(
      interestLines({
        ...help,
        savings_rate: '2.125',
        per_100_cents: 213,
        per_100_exact: false,
      })[0],
    ).toBe('At 2.125% a year, every $100 earns about $2.13 in a year.');
  });
  it('leaves out her line when she has nothing saved, and says nothing before it loads', () => {
    expect(interestLines({ ...help, year_cents: null })).toHaveLength(1);
    expect(interestLines(null)).toEqual([]);
  });
});

describe('the Inflation ?', () => {
  it('says what the inflation rate means for $100, then what her savings would need', () => {
    expect(inflationLines(help)).toEqual([
      'At 2.0% a year, something that costs $100 now costs $102 next year.',
      'Your $95.00 in savings would need to grow to $96.90 to buy the same things.',
    ]);
  });
  it('leaves out her line when she has nothing saved', () => {
    expect(inflationLines({ ...help, need_cents: null })).toHaveLength(1);
  });
});

describe('amounts and the special tag', () => {
  it('writes cents, whole dollars and the rest the way a kid reads them', () => {
    expect(shortAmount(96)).toBe('96¢');
    expect(shortAmount('100')).toBe('$1');
    expect(shortAmount(213)).toBe('$2.13');
    expect(shortAmount(123456)).toBe('$1,234.56');
  });
  it("says a special's last day", () => {
    expect(specialTag('2026-11-01', 2026)).toBe('Special! Last day: Nov 1');
    expect(specialTag(null, 2026)).toBe('Special!');
  });
});
