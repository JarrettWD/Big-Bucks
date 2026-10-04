import { describe, expect, it } from 'vitest';
import {
  TEXT,
  gicText,
  moveText,
  noticeReadText,
  type DashGic,
  type DashMove,
} from './dashboardText';

const move = (m: Partial<DashMove>): DashMove => ({
  request_id: 1,
  kid: 'Robin',
  is_test: false,
  when: 'Oct 1 at 10:00 am',
  from_vehicle: 'savings',
  to_vehicle: 'gic',
  fund_id: null,
  gic_term: 12,
  amount_cents: '10000',
  sell_all: false,
  status: 'settled',
  ...m,
});

describe('automatic moves', () => {
  it('says what moved, and whether a trade is still waiting for its close', () => {
    expect(moveText(move({}))).toBe('Bought a 1-year GIC with $100.00');
    expect(moveText(move({ from_vehicle: 'gic', to_vehicle: 'savings', gic_term: null }))).toBe(
      'Moved $100.00 from a GIC to savings',
    );
    expect(
      moveText(
        move({ to_vehicle: 'stock', fund_id: 'nasdaq100', gic_term: null, status: 'pending' }),
      ),
    ).toBe('Buy $100.00 of the Nasdaq-100 fund (settles at the next close)');
    expect(moveText(move({ to_vehicle: 'stock', fund_id: 'dow', gic_term: null }))).toBe(
      'Buy $100.00 of the Dow Jones fund',
    );
    expect(
      moveText(
        move({
          from_vehicle: 'stock',
          to_vehicle: 'savings',
          fund_id: 'tsx',
          sell_all: true,
          amount_cents: null,
          gic_term: null,
        }),
      ),
    ).toBe('Sell all of the TSX fund');
  });
});

describe('GICs coming due', () => {
  const gic: DashGic = {
    gic_id: 1,
    kid: 'Robin',
    is_test: false,
    amount_cents: '10000',
    interest_cents: '21',
    term_months: 1,
    rate: '2.5',
    matures: 'Nov 1',
    days_left: 22,
    waiting: false,
    choose_by: null,
  };
  it('says when, and what it earns, from the database figures', () => {
    expect(gicText(gic)).toBe(
      '$100.00 1-month GIC at 2.5% matures Nov 1 (in 22 days), earning $0.21.',
    );
    expect(gicText({ ...gic, days_left: 1 })).toContain('(tomorrow)');
    expect(gicText({ ...gic, days_left: 0 })).toContain('(today)');
    expect(gicText({ ...gic, waiting: true, matures: 'Oct 5', choose_by: 'Oct 11' })).toBe(
      '$100.00 1-month GIC at 2.5% matured Oct 5. Waiting for her choice (by Oct 11).',
    );
  });
});

describe('the rest of the wording', () => {
  it('counts and read status', () => {
    expect(TEXT.waiting(0)).toBe('Nothing waiting for you.');
    expect(TEXT.waiting(1)).toBe('1 thing waiting for you');
    expect(TEXT.waiting(5)).toBe('5 things waiting for you');
    expect(TEXT.waitingDetail(1, 0)).toBe('1 deposit or withdrawal, 0 questions');
    expect(TEXT.waitingDetail(4, 1)).toBe('4 deposits and withdrawals, 1 question');
    expect(noticeReadText({ read: 'Oct 7 at 8:00 am' })).toBe('Read Oct 7 at 8:00 am');
    expect(noticeReadText({ read: null })).toBe('Not read yet');
  });
});
