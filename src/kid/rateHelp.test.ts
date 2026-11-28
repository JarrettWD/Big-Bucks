// Dad, 2026-10-26: the ?s beside a live rate use that rate and her own figures (from the
// database), and a special says its last day.
import { describe, expect, it } from 'vitest';
import { inflationLines, interestLines, shortAmount, type RateHelp } from './rateHelp';
import { specialTag } from './trade/tradeText';

const help: RateHelp = {
  today: '2026-10-27',
  savings_rate: '1.000',
  now_rate: '1.000',
  special_until: null,
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
  it('during a savings special, says the special and its last day, and works the year at the regular rate', () => {
    // Dad, 2026-10-27: the figures are kid_rate_help's known answers (rate_help_test.sql).
    expect(
      interestLines({
        ...help,
        today: '2026-11-03',
        savings_rate: '2.125',
        now_rate: '5.000',
        special_until: '2026-11-08',
        per_100_cents: 213,
        per_100_exact: false,
        year_cents: '210',
      }),
    ).toEqual([
      "Right now you're earning the special 5.0% until Nov 8, then 2.125%.",
      'At 2.125% a year, every $100 earns about $2.13 in a year.',
      'Your $95.00 would earn about $2.10 in a year.',
    ]);
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
  // Dad's Nov 8 example, the database's figures (inflation_total_test.sql).
  const dads = {
    ...help,
    balance_cents: '7511',
    need_cents: '7662',
    year_total_cents: '7595',
    gap_cents: '67',
  };
  it('ends with where her savings get to and how far behind prices (Dad, 2026-11-08)', () => {
    expect(inflationLines(dads)).toEqual([
      'At 2.0% a year, something that costs $100 now costs $102 next year.',
      'Your $75.11 in savings would need to grow to $76.62 to buy the same things.',
      'At 1.0%, your savings grow to about $75.95, about 67¢ behind prices.',
    ]);
  });
  it('says ahead or keeping up when her rate beats prices or matches them', () => {
    expect(
      inflationLines({
        ...dads,
        savings_rate: '3.000',
        year_total_cents: '7746',
        gap_cents: '-84',
      })[2],
    ).toBe('At 3.0%, your savings grow to about $77.46, about 84¢ ahead of prices.');
    expect(
      inflationLines({
        ...dads,
        savings_rate: '2.000',
        year_total_cents: '7662',
        gap_cents: '0',
      })[2],
    ).toBe('At 2.0%, your savings grow to about $76.62, keeping up with prices.');
    expect(
      inflationLines({ ...dads, savings_rate: '0', year_total_cents: '7511', gap_cents: '151' })[2],
    ).toBe('At 0.0%, your savings stay at $75.11, about $1.51 behind prices.');
  });
  it('has no gap line when she has nothing saved', () => {
    expect(
      inflationLines({ ...dads, need_cents: null, year_total_cents: null, gap_cents: null }),
    ).toHaveLength(1);
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
