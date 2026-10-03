import { describe, expect, it } from 'vitest';
import {
  AMOUNT_MESSAGES as M,
  dropdownPlaces,
  isGicPlace,
  fromPlaces,
  keepOrFirst,
  moveFor,
  parseAmount,
  toPlaces,
  type Holdings,
} from './moves';

const h: Holdings = {
  fundIds: ['dow', 'nasdaq100', 'tsx'],
  sellableFundIds: ['dow'],
  gicIds: [7, 9],
};

describe('From and To choices: every move goes through savings', () => {
  it('Buy: from cash or savings', () => {
    expect(fromPlaces('buy', h)).toEqual(['cash', 'savings']);
    expect(toPlaces('buy', 'cash', h)).toEqual(['savings']);
    expect(toPlaces('buy', 'savings', h)).toEqual([
      'gic',
      'fund:dow',
      'fund:nasdaq100',
      'fund:tsx',
    ]);
  });

  it('Sell: from her GICs, the funds she can sell, or savings', () => {
    expect(fromPlaces('sell', h)).toEqual(['gic:7', 'gic:9', 'fund:dow', 'savings']);
    expect(toPlaces('sell', 'gic:7', h)).toEqual(['savings']);
    expect(toPlaces('sell', 'fund:dow', h)).toEqual(['savings']);
    expect(toPlaces('sell', 'savings', h)).toEqual(['cash']);
  });

  it('Sell with nothing held offers only savings → cash', () => {
    const empty = { fundIds: h.fundIds, sellableFundIds: [], gicIds: [] };
    expect(fromPlaces('sell', empty)).toEqual(['savings']);
  });

  it('each allowed pair means one action', () => {
    expect(moveFor('buy', 'cash', 'savings')).toEqual({
      kind: 'deposit',
      fundId: null,
      gicId: null,
    });
    expect(moveFor('buy', 'savings', 'gic')).toEqual({
      kind: 'buy_gic',
      fundId: null,
      gicId: null,
    });
    expect(moveFor('buy', 'savings', 'fund:tsx')).toEqual({
      kind: 'buy_fund',
      fundId: 'tsx',
      gicId: null,
    });
    expect(moveFor('sell', 'gic:9', 'savings')).toEqual({
      kind: 'break_gic',
      fundId: null,
      gicId: 9,
    });
    expect(moveFor('sell', 'fund:dow', 'savings')).toEqual({
      kind: 'sell_fund',
      fundId: 'dow',
      gicId: null,
    });
    expect(moveFor('sell', 'savings', 'cash')).toEqual({
      kind: 'withdraw',
      fundId: null,
      gicId: null,
    });
  });

  it('pairs that skip savings are refused', () => {
    expect(moveFor('buy', 'cash', 'gic')).toBeNull();
    expect(moveFor('buy', 'cash', 'fund:dow')).toBeNull();
    expect(moveFor('sell', 'fund:dow', 'cash')).toBeNull();
    expect(moveFor('sell', 'gic:7', 'fund:dow')).toBeNull();
    expect(moveFor('buy', 'savings', 'savings')).toBeNull();
    expect(moveFor('sell', 'gic:abc' as never, 'savings')).toBeNull();
  });

  it('the From dropdown shows her GICs as one choice, standing for the one she picked', () => {
    const list = fromPlaces('sell', h); // gic:7, gic:9, fund:dow, savings
    expect(dropdownPlaces(list, null)).toEqual(['gic:7', 'fund:dow', 'savings']);
    expect(dropdownPlaces(list, 'gic:9')).toEqual(['gic:9', 'fund:dow', 'savings']);
    expect(dropdownPlaces(list, 'fund:dow')).toEqual(['gic:7', 'fund:dow', 'savings']);
    expect(dropdownPlaces(list, 'gic:99')).toEqual(['gic:7', 'fund:dow', 'savings']);
    expect(dropdownPlaces(['cash', 'savings'], null)).toEqual(['cash', 'savings']);
    expect(isGicPlace('gic:7')).toBe(true);
    expect(isGicPlace('gic')).toBe(false);
  });

  it('keeps a choice that is still allowed, otherwise picks the first', () => {
    expect(keepOrFirst('fund:tsx', ['gic', 'fund:tsx'])).toBe('fund:tsx');
    expect(keepOrFirst('cash', ['gic', 'fund:tsx'])).toBe('gic');
    expect(keepOrFirst(null, [])).toBeNull();
  });
});

describe('typing an amount', () => {
  const ok = (text: string) => {
    const r = parseAmount(text);
    if (r.state !== 'ok') throw new Error(`${text} → ${JSON.stringify(r)}`);
    return r.cents;
  };
  const bad = (text: string) => {
    const r = parseAmount(text);
    return r.state === 'bad' ? r.message : `not bad: ${JSON.stringify(r)}`;
  };

  it('reads dollars and cents exactly, without floating point', () => {
    expect(ok('25')).toBe(2500n);
    expect(ok('12.5')).toBe(1250n);
    expect(ok('12.50')).toBe(1250n);
    expect(ok('0.10')).toBe(10n);
    expect(ok('.5')).toBe(50n);
    expect(ok('7.')).toBe(700n);
    expect(ok('  $25 ')).toBe(2500n);
    expect(ok('$ 4.99')).toBe(499n);
    expect(ok('1,000')).toBe(100000n);
    expect(ok('12,345.67')).toBe(1234567n);
    expect(ok('0025')).toBe(2500n);
    // 0.1 + 0.2 trouble can't happen: these are whole cents from the text.
    expect(ok('0.29')).toBe(29n);
    expect(ok('1.13')).toBe(113n);
    expect(ok('9999999.99')).toBe(999999999n);
  });

  it('empty is not an error, just nothing yet', () => {
    expect(parseAmount('')).toEqual({ state: 'empty' });
    expect(parseAmount('   ')).toEqual({ state: 'empty' });
  });

  it('refuses negatives', () => {
    expect(bad('-5')).toBe(M.negative);
    expect(bad('−5')).toBe(M.negative);
    expect(bad('$-5')).toBe(M.negative);
  });

  it('refuses letters and other characters', () => {
    expect(bad('abc')).toBe(M.notNumber);
    expect(bad('5 dollars')).toBe(M.notNumber);
    expect(bad('1e3')).toBe(M.notNumber);
    expect(bad('5.5.5')).toBe(M.notNumber);
    expect(bad('.')).toBe(M.notNumber);
    expect(bad('$')).toBe(M.notNumber);
    expect(bad('+5')).toBe(M.notNumber);
    expect(bad('1,00')).toBe(M.commaCents);
    expect(bad('12,5')).toBe(M.commaCents);
    expect(bad('1,0000')).toBe(M.notNumber);
  });

  it('refuses more than 2 decimals', () => {
    expect(bad('12.345')).toBe(M.tooManyDecimals);
    expect(bad('0.001')).toBe(M.tooManyDecimals);
  });

  it('refuses zero and huge numbers', () => {
    expect(bad('0')).toBe(M.zero);
    expect(bad('0.00')).toBe(M.zero);
    expect(bad('10000000')).toBe(M.tooBig);
  });
});
