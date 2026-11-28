// Block 1, item 4: a passed deadline, worded for her (Dad, 2026-11-24 and 2026-11-27).
import { describe, expect, it } from 'vitest';
import { GIC_TIME_UP, gicGoesToSavings, requestRanOut } from './deadlineText';
import { waitingLine, type Waiting } from './trade/tradeText';

describe('a GIC whose days to choose are over', () => {
  it("says time's up and where the money goes tonight", () => {
    expect(`${GIC_TIME_UP} ${gicGoesToSavings(3007)}`).toBe(
      "Time's up for this GIC. Your $30.07 goes into your savings tonight.",
    );
  });
});

describe('a request past its days', () => {
  it('a withdrawal says its money stays on hold until it is cancelled', () => {
    expect(requestRanOut('withdraw', true)).toBe(
      'This request ran out of time. It will be cancelled tonight, and its money is no longer on hold after that.',
    );
  });
  it('a deposit holds nothing', () => {
    expect(requestRanOut('deposit', true)).toBe(
      'This request ran out of time. It will be cancelled tonight.',
    );
  });
  it("says tomorrow evening when tonight's run is already done", () => {
    expect(requestRanOut('deposit', false)).toBe(
      'This request ran out of time. It will be cancelled tomorrow evening.',
    );
    expect(requestRanOut('withdraw', false)).toContain('cancelled tomorrow evening, and its money');
  });

  const w: Waiting = {
    request_id: 1,
    type: 'withdraw',
    from_vehicle: 'savings',
    to_vehicle: null,
    fund_id: null,
    amount_cents: 2000,
    sell_all: false,
    on_day: '2027-01-05',
    approve_from: null,
    settles: null,
  };
  it('her waiting list words it from the database flags', () => {
    expect(waitingLine({ ...w, expired: true, cancels_tonight: true }, [])).toEqual({
      title: 'Asked to take out $20.00',
      detail:
        'This request ran out of time. It will be cancelled tonight, and its money is no longer on hold after that.',
      over: true,
    });
    expect(
      waitingLine({ ...w, type: 'deposit', expired: true, cancels_tonight: false }, []),
    ).toEqual({
      title: 'Asked to put in $20.00',
      detail: 'This request ran out of time. It will be cancelled tomorrow evening.',
      over: true,
    });
    // Not expired: as before.
    expect(waitingLine({ ...w, expired: false }, []).over).toBeUndefined();
  });
  it('a buy or sell never runs out of time, whatever the flag says', () => {
    const buy: Waiting = { ...w, type: 'move', to_vehicle: 'stock', fund_id: 'dow', expired: true };
    expect(waitingLine(buy, []).over).toBeUndefined();
  });
  it('never shames or nags', () => {
    const words = [
      GIC_TIME_UP,
      gicGoesToSavings(100),
      requestRanOut('withdraw', true),
      requestRanOut('deposit', false),
    ]
      .join(' ')
      .toLowerCase();
    for (const bad of ['should have', 'missed', 'forgot', 'too late', 'late'])
      expect(words).not.toContain(bad);
  });
});
