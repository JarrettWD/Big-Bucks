// Dad, 2026-10-19: the kid screens name each fund by the real fund it follows.
import { describe, expect, it } from 'vitest';
import { fundLabel, optionName, unitPriceLine } from './fundNames';
import { optionList } from './graphs/graphData';
import {
  withFundLabels,
  placeLabel,
  summaryFor,
  type Preview,
  type TradeOptions,
} from './trade/tradeText';

describe('fund labels', () => {
  it('names every fund with the fund it follows', () => {
    expect(fundLabel('dow', 'Dow Jones')).toBe('Dow Jones fund (DIA)');
    expect(fundLabel('nasdaq100', 'Nasdaq-100')).toBe('Nasdaq-100 fund (QQQ)');
    expect(fundLabel('tsx', 'TSX')).toBe('TSX fund (XIC)');
    expect(unitPriceLine('tsx')).toBe('Price of one unit of XIC');
  });
  it('leaves savings and GICs alone', () => {
    expect(optionName('savings', 'Savings')).toBe('Savings');
    expect(optionName('gic', 'GICs')).toBe('GICs');
    expect(optionName('dow', 'Dow Jones')).toBe('Dow Jones fund (DIA)');
  });
  it('is what the graphs show', () => {
    const o = optionList([{ id: 'tsx', name: 'TSX', colour: '#074945', sort_order: 3 }]);
    expect(o.map((x) => x.name)).toEqual(['Savings', 'GICs', 'TSX fund (XIC)']);
  });
});

describe('fund labels on Buy / Sell', () => {
  const opts = withFundLabels({
    funds: [{ fund_id: 'tsx', name: 'TSX' }],
    gics: [],
  } as unknown as TradeOptions);
  const fund = opts.funds[0];
  const preview = { settles: 'the Oct 20 market close', warnings: [] } as unknown as Preview;
  it('names the fund in the picker and the question', () => {
    expect(placeLabel('fund:tsx', opts, 'to')).toBe('📈 TSX fund (XIC)');
    expect(
      summaryFor({ kind: 'buy_fund', amount: '$25.00', sellAll: false, fund, preview, year: 2026 })
        .question,
    ).toBe('Buy $25.00 of TSX fund (XIC)?');
    expect(
      summaryFor({ kind: 'sell_fund', amount: null, sellAll: true, fund, preview, year: 2026 })
        .question,
    ).toBe('Sell all of your TSX fund (XIC)?');
  });
});
