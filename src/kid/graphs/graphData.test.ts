import { describe, expect, it } from 'vitest';
import { daysBetween } from '../../lib/format';
import {
  axisDollars,
  formatPrice,
  fundFrom,
  fundRanges,
  fundRows,
  growthRows,
  ladderWidth,
  lastPoints,
  optionList,
  signedPct,
  worthFrom,
  worthRows,
  type FundChart,
  type Ranges,
} from './graphData';
import { earnedNote, earnedSentence, flowWords, fundChange, fundFigures } from './graphText';

const RANGES: Ranges = {
  today: '2026-11-06',
  first_day: '2026-10-01',
  worth: { '1M': '2026-10-06', '3M': '2026-10-01', '1Y': '2026-10-01', All: '2026-10-01' },
  fund: { '1M': '2026-10-06', '3M': '2026-08-06', '6M': '2026-05-06' },
  first_purchase: { dow: '2026-10-05' },
  ladder_until: '2028-11-06',
};
const FUNDS = [
  { id: 'tsx', name: 'TSX', colour: '#074945', sort_order: 3 },
  { id: 'dow', name: 'Dow Jones', colour: '#146DE4', sort_order: 1 },
  { id: 'nasdaq100', name: 'Nasdaq-100', colour: '#F06008', sort_order: 2 },
];
const OPTIONS = optionList(FUNDS);

describe('options and ranges', () => {
  it('lists savings, GICs, then the funds in their usual order, each with a pattern', () => {
    expect(OPTIONS.map((o) => o.key)).toEqual(['savings', 'gic', 'dow', 'nasdaq100', 'tsx']);
    expect(OPTIONS.find((o) => o.key === 'gic')!.dash).not.toBe('');
  });
  it('takes each range start from the database', () => {
    expect(worthFrom(RANGES, '1M')).toBe('2026-10-06');
    expect(worthFrom(RANGES, 'All')).toBe('2026-10-01');
    expect(fundFrom(RANGES, 'dow', '6M')).toBe('2026-05-06');
    expect(fundFrom(RANGES, 'dow', 'first')).toBe('2026-10-05');
  });
  it('offers "since your first buy" only for a fund she has bought', () => {
    expect(fundRanges(RANGES, 'dow')).toEqual(['1M', '3M', '6M', 'first']);
    expect(fundRanges(RANGES, 'tsx')).toEqual(['1M', '3M', '6M']);
    expect(fundFrom(RANGES, 'tsx', 'first')).toBeNull();
  });
});

describe('total worth rows', () => {
  it('stacks each option and shows only options with money in the range', () => {
    const { rows, shown } = worthRows(
      [
        {
          balance_date: '2026-10-01',
          savings_cents: '100000',
          gic_cents: 0,
          stock_cents: 0,
          total_cents: '100000',
          net_flow_cents: '100000',
          fund_values: null,
        },
        {
          balance_date: '2026-10-05',
          savings_cents: 65000,
          gic_cents: 10000,
          stock_cents: 25000,
          total_cents: 100000,
          net_flow_cents: 0,
          fund_values: { dow: 25000 },
        },
      ],
      OPTIONS,
    );
    expect(shown.map((o) => o.key)).toEqual(['savings', 'gic', 'dow']);
    expect(rows[1].plot).toEqual({
      total: 100000,
      savings: 65000,
      gic: 10000,
      dow: 25000,
      nasdaq100: 0,
      tsx: 0,
    });
    expect(rows[0].flow).toBe('100000');
  });
});

describe('growth rows', () => {
  const points = [
    { day: '2026-10-05', option: 'dow', growth_pct: '0.00', earned_cents: 0, flow_cents: 0 },
    { day: '2026-10-01', option: 'savings', growth_pct: 0, earned_cents: 0, flow_cents: 0 },
    {
      day: '2026-10-05',
      option: 'savings',
      growth_pct: '0.00',
      earned_cents: 0,
      flow_cents: '-25000',
    },
    { day: '2026-10-06', option: 'dow', growth_pct: '10.00', earned_cents: '2500', flow_cents: 0 },
  ];
  it('makes one row a day, in date order, with a line only where it has started', () => {
    const { rows, shown } = growthRows(points, OPTIONS);
    expect(rows.map((r) => r.day)).toEqual(['2026-10-01', '2026-10-05', '2026-10-06']);
    expect(rows[0].pct).toEqual({ savings: 0 });
    expect(rows[2].pct).toEqual({ dow: 10 });
    expect(rows[2].cents).toEqual({ dow: 2500 });
    expect(shown.map((o) => o.key)).toEqual(['savings', 'dow']);
  });
  it("finds each option's last point", () => {
    const last = lastPoints(points);
    expect(last.dow.day).toBe('2026-10-06');
    expect(last.savings.day).toBe('2026-10-05');
  });
});

describe('the GIC ladder', () => {
  it('sizes a bar from today to its ready date, out of 2 years', () => {
    expect(ladderWidth('2027-11-06', '2026-11-06', '2028-11-06', daysBetween)).toBeCloseTo(
      49.93,
      1,
    );
    expect(ladderWidth('2028-11-06', '2026-11-06', '2028-11-06', daysBetween)).toBe(100);
  });
  it('never draws a bar too thin to see, even when it is ready now', () => {
    expect(ladderWidth('2026-11-06', '2026-11-06', '2028-11-06', daysBetween)).toBe(3);
    expect(ladderWidth('2026-11-01', '2026-11-06', '2028-11-06', daysBetween)).toBe(3);
  });
});

describe('fund rows', () => {
  const chart: FundChart = {
    fund_id: 'dow',
    from: '2026-10-05',
    today: '2026-10-06',
    closes: [
      { d: '2026-10-05', c: 400, pct: 0 },
      { d: '2026-10-06', c: '440', pct: '10.00' },
    ],
    change_pct: 10,
    trades: [{ d: '2026-10-05', side: 'buy', price: 400, units: 0.625, amount_cents: 25000 }],
    notes: [{ d: '2026-10-06', body: 'Big jump today.' }],
    range_growth_pct: 10,
    range_earned_cents: 2500,
    holding: null,
  };
  it('puts her trades and the notes on their days', () => {
    const rows = fundRows(chart);
    expect(rows[0].buy?.amount_cents).toBe(25000);
    expect(rows[0].sell).toBeUndefined();
    expect(rows[1].note).toBe('Big jump today.');
    expect(rows[1].close).toBe(440);
  });
});

describe('formats', () => {
  it("writes a unit price from the database's exact close", () => {
    expect(formatPrice('396')).toBe('$396.00');
    expect(formatPrice(40.123)).toBe('$40.123');
    expect(formatPrice('1234.5')).toBe('$1,234.50');
    expect(() => formatPrice('-1')).toThrow();
  });
  it('writes a percent with its sign and two decimals', () => {
    expect(signedPct('1.11')).toBe('+1.11%');
    expect(signedPct(19.9)).toBe('+19.90%');
    expect(signedPct('-10')).toBe('−10.00%');
    expect(signedPct(0)).toBe('0.00%');
    expect(signedPct('-0.00')).toBe('0.00%');
    expect(() => signedPct('1.234')).toThrow();
  });
  it('labels a dollar axis in whole dollars', () => {
    expect(axisDollars(125000)).toBe('$1,250');
    expect(axisDollars(0)).toBe('$0');
    expect(axisDollars(-5000)).toBe('−$50');
  });
});

describe('graph wording', () => {
  it('says what her money earned, kindly either way', () => {
    expect(earnedSentence(1876)).toBe('So far, your money has earned $18.76. 🎉');
    expect(earnedSentence('-1395')).toBe(
      'Right now your total worth is $13.95 less than you put in. Funds go up and down, so that can change.',
    );
    expect(earnedNote(1876)).toBe('That’s what your money has made for you. 🎉');
    expect(earnedNote(-1)).toBe(
      'Right now your total worth is less than you put in. Funds go up and down, so that can change.',
    );
    expect(earnedSentence(0)).toBe('Your total worth is the same as the money you put in.');
  });
  it('names money in and out', () => {
    expect(flowWords(5000)).toBe('You put in $50.00');
    expect(flowWords('-5000')).toBe('You took out $50.00');
  });
  it("labels the fund's change and her money's change apart, and says why when they differ", () => {
    const c = {
      range_growth_pct: '1.11',
      range_earned_cents: -1505,
      holding: { value_cents: 10020, cost_cents: 10000, gain_cents: 20, return_pct: 0.2 },
    };
    expect(fundFigures('Nasdaq-100', 'first', c)).toEqual({
      lines: [
        { label: 'Worth now', value: '$100.20' },
        { label: 'You paid', value: '$100.00' },
        { label: 'Your money’s change', value: '+$0.20 (+0.20%)' },
      ],
    });
    expect(fundFigures('Dow Jones', '1M', c)).toEqual({
      lines: [
        { label: 'The fund’s change while you had it', value: '+1.11%' },
        { label: 'Your money’s change', value: '−$15.05' },
      ],
      why: 'These point different ways because of timing: you had more money in the Dow Jones on its down days than on its up days. When you buy matters, not just what you buy.',
    });
    expect(
      fundFigures('TSX', '3M', { ...c, range_growth_pct: '-2.00', range_earned_cents: '150' }).why,
    ).toBe(
      'These point different ways because of timing: you had more money in the TSX on its up days than on its down days. When you buy matters, not just what you buy.',
    );
    expect(
      fundFigures('TSX', '3M', { ...c, range_growth_pct: '2.00', range_earned_cents: 150 }).why,
    ).toBeUndefined();
    expect(
      fundFigures('TSX', '3M', { ...c, range_growth_pct: '0.00', range_earned_cents: -5 }).why,
    ).toBeUndefined();
    const none = { range_growth_pct: null, range_earned_cents: null, holding: null };
    expect(fundFigures('TSX', '1M', none).none).toBe('You didn’t own any TSX in this time.');
    expect(fundFigures('TSX', 'first', none).none).toBe('You don’t own any TSX right now.');
  });
  it('says how the whole fund moved over the range', () => {
    expect(fundChange('Dow Jones', '0.26')).toBe(
      'Over the whole time shown, the Dow Jones fund went up 0.26%.',
    );
    expect(fundChange('TSX', -1.4)).toBe(
      'Over the whole time shown, the TSX fund went down 1.40%.',
    );
    expect(fundChange('TSX', 0)).toBe('Over the whole time shown, the TSX fund didn’t change.');
  });
});
