import { describe, expect, it } from 'vitest';
import type { WaitingRequest } from '../useInbox';
import {
  approveCashLine,
  approveHeading,
  declineHeading,
  declineLine,
  expiryLine,
  formatWait,
  requestFacts,
  requestTitle,
  secondsLeft,
  waitLine,
} from './approvalsText';

const base: WaitingRequest = {
  id: 1,
  account_id: 'a',
  kid: 'Robin',
  is_test: false,
  type: 'deposit',
  amount_cents: '2500',
  asked: 'Oct 2 at 7:00 pm',
  approve_from: null,
  wait_seconds: 0,
  expires: 'Oct 9 at 7:00 pm',
  expires_seconds: 500000,
  savings_cents: '40270',
  held_cents: '1000',
  available_cents: '39270',
  savings_after_cents: '42770',
  cap_cents: '100000',
  net_deposits_cents: '80000',
  pending_deposits_cents: '2500',
  cap_room_cents: '17500',
};
const withdrawal: WaitingRequest = {
  ...base,
  type: 'withdraw',
  amount_cents: '1000',
  approve_from: 'Oct 3 at 4:00 pm',
  wait_seconds: 66600,
  savings_after_cents: '39270',
};

describe('the countdown', () => {
  it('counts down from the database seconds, in whole seconds, never below 0', () => {
    expect(secondsLeft(66600, 0)).toBe(66600);
    expect(secondsLeft(66600, 999)).toBe(66600);
    expect(secondsLeft(66600, 1000)).toBe(66599);
    expect(secondsLeft(10, 60_000)).toBe(0);
    expect(secondsLeft(10, -5000)).toBe(10);
  });
  it('says hours and minutes, rounding minutes up so a wait never ends early', () => {
    expect(formatWait(66600)).toBe('18 h 30 min');
    expect(formatWait(66601)).toBe('18 h 31 min');
    expect(formatWait(3600)).toBe('1 h');
    expect(formatWait(3599)).toBe('1 h');
    expect(formatWait(3540)).toBe('59 min');
    expect(formatWait(61)).toBe('2 min');
    expect(formatWait(59)).toBe('under a minute');
    expect(formatWait(0)).toBe('now');
  });
});

describe('request cards', () => {
  it('names the request and the money behind it', () => {
    expect(requestTitle(base)).toBe('Deposit $25.00');
    expect(requestTitle(withdrawal)).toBe('Withdrawal $10.00');
    expect(requestFacts(base)).toEqual([
      ['Deposit cap', '$1,000.00'],
      ['Put in so far', '$800.00'],
      ['Waiting (this included)', '$25.00'],
      ['Room left after all waiting', '$175.00'],
    ]);
    expect(requestFacts(withdrawal)).toEqual([
      ['Savings', '$402.70'],
      ['On hold (this included)', '$10.00'],
      ['Free to use', '$392.70'],
    ]);
  });
  it('says when a withdrawal unlocks, and when a request expires', () => {
    expect(waitLine(withdrawal, 66600)).toBe(
      '24-hour wait: you can approve from Oct 3 at 4:00 pm (in 18 h 30 min).',
    );
    expect(expiryLine(base, 500000)).toBe("Expires Oct 9 at 7:00 pm if you don't answer.");
    expect(expiryLine(base, 5 * 3600)).toBe(
      "Expires in 5 h (Oct 9 at 7:00 pm) if you don't answer.",
    );
    expect(expiryLine(base, 0)).toBe(
      "This has expired. Tonight's run releases it, and she's told why.",
    );
  });
  it('confirms with the cash and her savings before and after, from the database', () => {
    expect(approveHeading(base)).toBe("Approve Robin's $25.00 deposit?");
    expect(approveCashLine(base)).toBe(
      "Only approve once you have Robin's $25.00 in cash. It goes into her savings right away: $402.70 → $427.70.",
    );
    expect(approveHeading(withdrawal)).toBe("Approve Robin's $10.00 withdrawal?");
    expect(approveCashLine(withdrawal)).toBe(
      'Only approve when you hand Robin $10.00 in cash. It comes out of her savings right away: $402.70 → $392.70.',
    );
    expect(declineHeading(withdrawal)).toBe("Decline Robin's $10.00 withdrawal?");
    expect(declineLine(base)).toBe('Nothing changes in her account. She sees your reason.');
    expect(declineLine(withdrawal)).toBe(
      'The money on hold is released back to her. She sees your reason.',
    );
  });
});
