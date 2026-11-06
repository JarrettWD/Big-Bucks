// Stage 11: the learning features' wording and which graphs each view shows.
import { describe, expect, it } from 'vitest';
import { visibleTabs } from '../graphs/graphData';
import {
  fundsInflation,
  gicInflation,
  gicsGrowing,
  interestNote,
  monthName,
  readyOn,
  savingsInflation,
  startLine,
  TEXT,
  totalInflationNote,
} from './learnText';

describe('what-if wording teaches, never scolds', () => {
  const all = [
    TEXT.whatIfIntro,
    TEXT.whatIfClose,
    TEXT.whatIfYours,
    TEXT.whatIfSavings,
    TEXT.whatIfGics,
    TEXT.whatIfNasdaq,
    ...TEXT.whatIfHowLines,
  ].join(' ');
  it.each(['lost', 'lose', 'could have', 'should have', 'wrong', 'mistake', 'better choice'])(
    'never says "%s"',
    (w) => {
      expect(all.toLowerCase()).not.toMatch(new RegExp(`\\b${w}\\b`));
      // (and the check itself works: it would catch the word in a sentence)
      expect(`you ${w} here`).toMatch(new RegExp(`\\b${w}\\b`));
    },
  );
  it('starts with what would have happened, and ends with nobody knowing ahead', () => {
    expect(TEXT.whatIfIntro).toBe(
      "Here's what would have happened if all the money you put in had gone into just one place.",
    );
    expect(TEXT.whatIfClose).toContain('Nobody can know ahead of time.');
  });
  it('says GICs still growing, so early GICs never look worse (Dad addition 3)', () => {
    expect(gicsGrowing(1)).toBe('GIC interest is paid when each GIC matures. 1 is still growing.');
    expect(gicsGrowing(3)).toBe('GIC interest is paid when each GIC matures. 3 are still growing.');
    expect(gicsGrowing(0)).toBeNull();
  });
});

describe('the reflection box', () => {
  it('tells her Mom and Dad can see it, and that it can be skipped (Dad addition 4)', () => {
    expect(TEXT.reflectTitle).toBe('Why did you sell? ✏️');
    expect(TEXT.reflectNote).toBe('Mom and Dad can see this.');
    expect(TEXT.reflectSkipNote).toBe('You can skip this.');
  });
});

describe('statements', () => {
  it('names months in full', () => {
    expect(monthName('2026-10-01')).toBe('October 2026');
  });
  it('says when a month will be ready', () => {
    expect(readyOn('2026-10-01', '2026-11-01', 2026)).toBe(
      'Your October statement will be ready on Nov 1.',
    );
  });
  it("says where this month's interest shows (it is paid on the 1st of the next month)", () => {
    expect(interestNote('2026-10-01')).toBe(
      'Your October interest is paid on Nov 1, so it shows on your November statement.',
    );
    expect(interestNote('2026-12-01')).toBe(
      'Your December interest is paid on Jan 1, so it shows on your January statement.',
    );
  });
  it('marks a first, partial month', () => {
    expect(startLine('2026-10-10', true, 2026)).toBe(
      'Starting balance (Oct 10, when your account opened)',
    );
    expect(startLine('2026-11-01', false, 2026)).toBe('Starting balance');
  });
});

describe('the inflation view', () => {
  it('words savings gently, from the database figures', () => {
    expect(
      savingsInflation(
        { now_cents: 18367, savings_rate: '2.000', in_a_year_cents: 18738, buys_like_cents: 18370 },
        '2.0',
      ),
    ).toBe(
      "In a year, at today's 2% savings rate, your $183.67 would grow to about $187.38. Prices usually go up too, about 2% a year right now, so it would buy about what $183.70 buys today.",
    );
  });
  it('words a GIC to when it matures', () => {
    expect(
      gicInflation(
        { at_maturity_cents: 10075, buys_like_cents: 10030, maturity_date: '2027-01-10' },
        2026,
      ),
    ).toBe(
      'When it matures on Jan 10, 2027, it pays $100.75. With prices going up meanwhile, that buys about what $100.30 buys today.',
    );
  });
  // Dad, 2026-11-03: one card for her funds, with a closing line that's only ever true.
  const dow = { fund: 'dow', name: 'Dow Jones' };
  const qqq = { fund: 'nasdaq100', name: 'Nasdaq-100' };
  const xic = { fund: 'tsx', name: 'TSX' };
  it('one card: the intro, a line per fund to one decimal, all three ahead of prices', () => {
    // Nov 3, 2026's real figures: closes Nov 3 against Oct 31, 2025.
    expect(
      fundsInflation(
        [
          { ...dow, year_change_pct: '8.69' },
          { ...qqq, year_change_pct: '8.94' },
          { ...xic, year_change_pct: '17.40' },
        ],
        '2.0',
      ),
    ).toEqual({
      intro: "Funds don't have a set rate. They go up and down. Over the past year:",
      lines: [
        'Dow Jones fund (DIA): up 8.7%',
        'Nasdaq-100 fund (QQQ): up 8.9%',
        'TSX fund (XIC): up 17.4%',
      ],
      closing: 'All 3 grew more than prices did (about 2.0%).',
    });
  });
  it('never claims they all beat prices when one grew less or went down', () => {
    const t = fundsInflation(
      [
        { ...dow, year_change_pct: '1.20' },
        { ...qqq, year_change_pct: '-4.06' },
        { ...xic, year_change_pct: '9.00' },
      ],
      '2.0',
    );
    expect(t.lines).toEqual([
      'Dow Jones fund (DIA): up 1.2%',
      'Nasdaq-100 fund (QQQ): down 4.1%',
      'TSX fund (XIC): up 9.0%',
    ]);
    expect(t.closing).toBe(
      'The TSX fund (XIC) grew more than prices did (about 2.0%). The Dow Jones fund (DIA) grew less than prices did (about 2.0%), so it buys a little less than a year ago. The Nasdaq-100 fund (QQQ) went down, so it buys less than a year ago.',
    );
    expect(t.closing).not.toMatch(/\ball\b|both/i);
  });
  it('compares at the one decimal she sees, says "both" for two, and "it" for one', () => {
    // 2.04% shows as 2.0%, the same as prices: "about as much", not "more".
    expect(fundsInflation([{ ...dow, year_change_pct: '2.04' }], '2.0').closing).toBe(
      'The Dow Jones fund (DIA) grew about as much as prices did (about 2.0%).',
    );
    expect(
      fundsInflation(
        [
          { ...dow, year_change_pct: '5' },
          { ...xic, year_change_pct: '6' },
        ],
        '2.0',
      ).closing,
    ).toBe('Both grew more than prices did (about 2.0%).');
    expect(fundsInflation([{ ...xic, year_change_pct: '6' }], '2.0').closing).toBe(
      'It grew more than prices did (about 2.0%).',
    );
    // Two funds below prices: "they buy".
    expect(
      fundsInflation(
        [
          { ...dow, year_change_pct: '-1' },
          { ...xic, year_change_pct: '-2' },
        ],
        '2.0',
      ).closing,
    ).toBe(
      'The Dow Jones fund (DIA) and the TSX fund (XIC) went down, so they buy less than a year ago.',
    );
  });
  it('a fund without a year of prices is listed, and left out of the comparison', () => {
    const t = fundsInflation(
      [
        { ...dow, year_change_pct: null },
        { ...xic, year_change_pct: '9' },
      ],
      '2.0',
    );
    expect(t.lines[0]).toBe('Dow Jones fund (DIA): not a full year of prices yet');
    expect(t.closing).toBe('It grew more than prices did (about 2.0%).');
    expect(fundsInflation([{ ...dow, year_change_pct: null }], '2.0').closing).toBeNull();
  });
  it('the Total card has the whole thought, never half of one', () => {
    expect(totalInflationNote('2.0')).toBe(
      "Prices usually go up a little each year (about 2.0% right now), so the same money buys a bit less later. That's normal. It's one reason people use GICs and funds too.",
    );
    expect(totalInflationNote('2.5')).toContain('about 2.5% right now');
  });
  it('is never scary', () => {
    const words = [
      totalInflationNote('2.0'),
      fundsInflation([{ ...dow, year_change_pct: '-3' }], '2.0').closing,
      savingsInflation(
        { now_cents: 1, savings_rate: 1, in_a_year_cents: 1, buys_like_cents: 1 },
        '2',
      ),
    ]
      .join(' ')
      .toLowerCase();
    for (const w of ['losing', 'lose', 'shrink', 'danger', 'bad']) expect(words).not.toContain(w);
  });
});

describe('graphs in each view', () => {
  const on = { whatif: true, markets: true };
  it('detailed: every graph, plus What if? and Markets when they are on', () => {
    expect(visibleTabs('detailed', on)).toEqual([
      'worth',
      'growth',
      'money',
      'mix',
      'gics',
      'funds',
      'whatif',
      'markets',
    ]);
    expect(visibleTabs('detailed', {})).toEqual([
      'worth',
      'growth',
      'money',
      'mix',
      'gics',
      'funds',
    ]);
  });
  it('basic: three graphs, the what-if, and never Compare the markets', () => {
    expect(visibleTabs('basic', on)).toEqual(['worth', 'mix', 'money', 'whatif']);
    expect(visibleTabs('basic', {})).toEqual(['worth', 'mix', 'money']);
  });
});
