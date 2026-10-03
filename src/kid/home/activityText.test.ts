import { describe, expect, it } from 'vitest';
import { describeActivity, type ActivityRow } from './activityText';

const row = (r: Partial<ActivityRow>): ActivityRow => ({
  item_key: 'k',
  at: '2026-10-01T06:00:00Z',
  on_day: '2026-10-01',
  kind: 'deposit',
  request_type: null,
  amount_cents: 1000,
  fund_id: null,
  gic_id: null,
  gic_term: null,
  rate: null,
  units: null,
  unit_price: null,
  note: null,
  transaction_ids: [1],
  request_id: null,
  ...r,
});

describe('history lines', () => {
  it.each([
    [{ kind: 'deposit', amount_cents: 60000 }, 'Money in', '+$600.00', 'in'],
    [{ kind: 'withdraw', amount_cents: 2000 }, 'Money out', '−$20.00', 'out'],
    [{ kind: 'interest', amount_cents: 56 }, 'Savings interest', '+$0.56', 'in'],
    [
      { kind: 'gic_interest', amount_cents: 11, gic_term: 1 },
      'Interest from your 1-month GIC',
      '+$0.11',
      'in',
    ],
    [{ kind: 'dividend', amount_cents: 36, fund_id: 'tsx' }, 'Dividend from TSX', '+$0.36', 'in'],
    [
      { kind: 'gic_buy', amount_cents: 15000, gic_term: 6, rate: '4.000' },
      'Bought a 6-month GIC at 4.0%',
      '$150.00',
      'move',
    ],
    [
      { kind: 'gic_renew', amount_cents: 10021, gic_term: 1, rate: '2.500' },
      'Renewed: a new 1-month GIC at 2.5%',
      '$100.21',
      'move',
    ],
    [
      { kind: 'gic_to_savings', amount_cents: 10042, note: 'Moved your matured GIC to savings.' },
      'GIC moved to savings',
      '$100.42',
      'move',
    ],
    [
      {
        kind: 'gic_to_savings',
        amount_cents: 500,
        note: 'Moved to savings automatically: no choice was made within 7 days.',
      },
      'GIC moved to savings automatically',
      '$5.00',
      'move',
    ],
    [{ kind: 'gic_break', amount_cents: 5000 }, 'Broke a GIC early', '$50.00', 'move'],
    [
      { kind: 'fund_buy', amount_cents: 10000, fund_id: 'dow' },
      'Bought Dow Jones',
      '$100.00',
      'move',
    ],
    [{ kind: 'fund_sell', amount_cents: 3000, fund_id: 'dow' }, 'Sold Dow Jones', '$30.00', 'move'],
    [
      { kind: 'request_pending', request_type: 'deposit', amount_cents: 5000 },
      'Asked to put money in',
      '$50.00',
      'waiting',
    ],
    [
      { kind: 'request_pending', request_type: 'sell', amount_cents: null, fund_id: 'tsx' },
      'Selling TSX',
      'All of it',
      'waiting',
    ],
    [
      {
        kind: 'request_declined',
        request_type: 'deposit',
        amount_cents: 50000,
        note: "Let's talk.",
      },
      'Dad said not this time (money in)',
      '$500.00',
      'declined',
    ],
    [
      { kind: 'correction', amount_cents: -25, note: 'Fixed a double posting.' },
      'A correction',
      '−$0.25',
      'out',
    ],
  ] as [Partial<ActivityRow>, string, string, string][])('%o', (r, title, amount, tone) => {
    const line = describeActivity(row(r));
    expect(line.title).toBe(title);
    expect(line.amount).toBe(amount);
    expect(line.tone).toBe(tone);
  });

  it('shows Dad’s reason on a declined request', () => {
    expect(
      describeActivity(
        row({ kind: 'request_declined', request_type: 'deposit', note: 'Not this week.' }),
      ).detail,
    ).toBe('Dad says: “Not this week.”');
  });

  it('pending trades wait for the market close', () => {
    expect(
      describeActivity(row({ kind: 'request_pending', request_type: 'buy', fund_id: 'dow' }))
        .detail,
    ).toBe('Waiting for the market close');
  });

  it('every line keeps the date the database gave it', () => {
    expect(describeActivity(row({ on_day: '2026-09-05' })).day).toBe('2026-09-05');
  });
});
