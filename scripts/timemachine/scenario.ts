// The scripted year: Jul 1, 2027 to Jul 1, 2028 (so June's interest posts).
// Kid A is a regular account and kid B a test account, both made up. Every step
// says why it's there. Times are Edmonton wall-clock times.

import { Q } from './model/rational.ts';
import type { Action, FundId, Model } from './model/model.ts';
import { BIG_DROP_DAY } from './prices.ts';
import { dayOf } from './model/calendar.ts';

export const START = '2027-07-01 08:00';
export const END_DAY = '2028-07-01';
/** The jobs don't run on these days, then catch up on Apr 8. */
export const MISSED = { from: '2028-04-01', to: '2028-04-07' };

export type Check =
  { kind: 'request_status'; label: string; status: string } | { kind: 'health'; ok: boolean };

export interface Step {
  at: string;
  do: Action | Check | ((m: Model) => Action);
  expect?: 'ok' | 'refused';
  why: string;
}

const $ = (dollars: number) => BigInt(dollars) * 100n; // whole dollars only

/** Sell by amount: everything she has at the latest close, rounded down to the cent. */
const sellWorthAll =
  (kid: string, fund: FundId, label: string) =>
  (m: Model): Action => {
    const s = m.snapshot(kid);
    const units = s.units.get(fund) ?? Q.ZERO;
    const close = m.latestClose(fund, dayOf(m.clock), m.clock)!;
    return { kind: 'sell', kid, fund, cents: units.mul(close).mul(Q.of(100)).floor(), label };
  };

export const STEPS: Step[] = [
  // July 2027 ---------------------------------------------------------------
  {
    at: '2027-07-01 09:00',
    do: { kind: 'deposit', kid: 'A', cents: $(900), label: 'dA1' },
    why: 'first deposit',
  },
  {
    at: '2027-07-01 09:05',
    do: { kind: 'deposit', kid: 'B', cents: $(700), label: 'dB1' },
    why: 'first deposit',
  },
  { at: '2027-07-01 10:00', do: { kind: 'approve', label: 'dA1' }, why: 'Dad approves' },
  { at: '2027-07-01 10:01', do: { kind: 'approve', label: 'dB1' }, why: 'Dad approves' },
  {
    at: '2027-07-02 09:00',
    do: { kind: 'buy_gic', kid: 'A', cents: $(100), term: 1, label: 'gA1m' },
    why: 'GIC ladder: 1 month',
  },
  {
    at: '2027-07-02 09:01',
    do: { kind: 'buy_gic', kid: 'A', cents: $(100), term: 3, label: 'gA3m' },
    why: 'GIC ladder: 3 months',
  },
  {
    at: '2027-07-02 09:02',
    do: { kind: 'buy_gic', kid: 'A', cents: $(100), term: 6, label: 'gA6m' },
    why: 'GIC ladder: 6 months',
  },
  {
    at: '2027-07-02 09:03',
    do: { kind: 'buy_gic', kid: 'A', cents: $(100), term: 12, label: 'gA12m' },
    why: 'GIC ladder: 1 year',
  },
  {
    at: '2027-07-02 09:30',
    do: { kind: 'buy', kid: 'B', fund: 'dow', cents: $(150), label: 'tB1' },
    why: 'fund buy',
  },
  {
    at: '2027-07-02 09:31',
    do: { kind: 'buy', kid: 'B', fund: 'tsx', cents: $(100), label: 'tB2' },
    why: 'fund buy',
  },
  {
    at: '2027-07-05 10:00',
    do: { kind: 'buy', kid: 'A', fund: 'nasdaq100', cents: $(100), label: 'tA1' },
    why: 'NYSE closed (Independence Day observed): settles Jul 6',
  },
  {
    at: '2027-07-06 10:00',
    do: { kind: 'buy', kid: 'A', fund: 'dow', cents: $(50), label: 'tA2' },
    why: 'fund buy',
  },
  {
    at: '2027-07-06 11:00',
    do: { kind: 'buy', kid: 'A', fund: 'dow', cents: $(20), label: 'tA3' },
    expect: 'refused',
    why: 'second trade in the same fund on the same day',
  },
  {
    at: '2027-07-08 10:00',
    do: { kind: 'withdraw', kid: 'B', cents: $(40), label: 'wB1' },
    why: 'withdrawal request holds $40',
  },
  {
    at: '2027-07-08 18:00',
    do: { kind: 'approve', label: 'wB1' },
    expect: 'refused',
    why: 'withdrawal under 24 hours old',
  },
  {
    at: '2027-07-09 11:00',
    do: { kind: 'approve', label: 'wB1' },
    why: 'withdrawal approved after 24 hours',
  },
  {
    at: '2027-07-12 09:00',
    do: { kind: 'deposit', kid: 'A', cents: $(50), label: 'dA2' },
    why: 'deposit to be declined',
  },
  {
    at: '2027-07-13 09:00',
    do: { kind: 'decline', label: 'dA2', reason: 'Wait until after the trip' },
    why: 'Dad declines with a reason',
  },
  {
    at: '2027-07-20 10:00',
    do: { kind: 'deposit', kid: 'B', cents: $(100), label: 'dB2' },
    why: 'request left unanswered',
  },
  {
    at: '2027-07-27 17:00',
    do: { kind: 'request_status', label: 'dB2', status: 'expired' },
    why: 'expired 7 × 24 hours later (10:00 Jul 27)',
  },
  {
    at: '2027-07-28 09:00',
    do: { kind: 'approve', label: 'dB2' },
    expect: 'refused',
    why: 'too late to approve an expired request',
  },

  // August -------------------------------------------------------------------
  {
    at: '2027-08-02 10:00',
    do: { kind: 'buy', kid: 'B', fund: 'tsx', cents: $(50), label: 'tB3' },
    why: 'TSX closed (Civic Holiday): settles Aug 3',
  },
  // gA1m matures Mon Aug 2 and waits 3 days earning the savings rate.
  {
    at: '2027-08-05 18:00',
    do: { kind: 'choose', gic: 'gA1m', choice: 'renew', newLabel: 'gA1m_r' },
    why: 'matured GIC waited 3 days, then renewed (matures Sun Sep 5)',
  },
  {
    at: '2027-08-16 10:00',
    do: { kind: 'buy_gic', kid: 'A', cents: $(9), term: 1, label: 'gA_tiny' },
    expect: 'refused',
    why: 'GIC under the $10 minimum',
  },
  {
    at: '2027-08-16 10:01',
    do: { kind: 'buy_gic', kid: 'A', cents: $(50), term: 9, label: 'gA9m' },
    why: '9-month GIC (to be broken early)',
  },

  // September: a late close, a rate cut with notice -------------------------------------------
  {
    at: '2027-09-14 09:00',
    do: { kind: 'buy', kid: 'B', fund: 'nasdaq100', cents: $(100), label: 'tB4' },
    why: 'its close arrives a day late, so it waits',
  },
  // gA1m_r matures Sun Sep 5; nobody chooses, so it moves to savings on day 7 (Sep 12).
  {
    at: '2027-09-20 09:00',
    do: {
      kind: 'add_rate',
      rate: { vehicle: 'savings', term: null, rate: '1.5', effective: '2027-09-27' },
    },
    why: "savings rate cut, 7 days' notice",
  },
  {
    at: '2027-09-20 09:01',
    do: {
      kind: 'add_rate',
      rate: { vehicle: 'gic', term: 12, rate: '4.5', effective: '2027-09-27' },
    },
    why: "1-year GIC rate cut, 7 days' notice",
  },
  {
    at: '2027-09-20 09:02',
    do: {
      kind: 'add_rate',
      rate: { vehicle: 'savings', term: null, rate: '1.0', effective: '2027-09-22' },
    },
    expect: 'refused',
    why: "a cut with only 2 days' notice is refused (stage 8 B2)",
  },
  {
    at: '2027-09-24 10:00',
    do: { kind: 'buy_gic', kid: 'A', cents: $(50), term: 12, label: 'gA12b' },
    why: 'locks 5.0% before the cut',
  },

  // October: a special, a TSX holiday, dividends ------------------------------------------------
  {
    at: '2027-10-01 09:00',
    do: {
      kind: 'add_rate',
      rate: {
        vehicle: 'gic',
        term: 12,
        rate: '6.0',
        effective: '2027-10-04',
        end: '2027-10-10',
        special: true,
      },
    },
    why: '1-week special: 1-year GIC at 6%',
  },
  // gA3m matures Sat Oct 2.
  {
    at: '2027-10-04 18:00',
    do: { kind: 'choose', gic: 'gA3m', choice: 'new_term', term: 6, newLabel: 'gA3m_n' },
    why: 'matured GIC moved to a new 6-month term (matures in the missed week)',
  },
  {
    at: '2027-10-06 10:00',
    do: { kind: 'buy_gic', kid: 'B', cents: $(100), term: 12, label: 'gB12s' },
    why: 'buys at the 6% special',
  },
  {
    at: '2027-10-08 16:00',
    do: { kind: 'sell', kid: 'B', fund: 'tsx', cents: $(30), label: 'tB5' },
    why: "after Friday's close, TSX closed Mon (Thanksgiving): settles Tue Oct 12",
  },
  {
    at: '2027-10-11 10:00',
    do: { kind: 'buy', kid: 'B', fund: 'dow', cents: $(30), label: 'tB6' },
    why: 'NYSE open on Canadian Thanksgiving: settles that day',
  },

  // November: a request expiring across Toronto's clock change, the split, an NYSE early close
  {
    at: '2027-11-03 10:00',
    do: { kind: 'withdraw', kid: 'A', cents: $(25), label: 'wA1' },
    why: "left unanswered across Toronto's clock change",
  },
  {
    at: '2027-11-10 17:00',
    do: { kind: 'request_status', label: 'wA1', status: 'expired' },
    why: 'expired 7 × 24 hours later (10:00 am Nov 10: Alberta no longer changes clocks)',
  },
  {
    at: '2027-11-05 14:30',
    do: { kind: 'buy', kid: 'A', fund: 'dow', cents: $(10), label: 'tA_tz1' },
    why: "Toronto summer time: after Friday's 2:00 pm close, settles Mon Nov 8 at 3:00 pm",
  },
  {
    at: '2027-11-08 14:30',
    do: { kind: 'buy', kid: 'B', fund: 'dow', cents: $(10), label: 'tB_tz1' },
    why: 'first Monday after Toronto falls back: before the 3:00 pm close, settles that day',
  },
  {
    at: '2027-11-26 10:30',
    do: { kind: 'buy', kid: 'A', fund: 'dow', cents: $(40), label: 'tA4' },
    why: 'NYSE early close (1:00 pm Toronto): settles at 12:00 pm',
  },
  {
    at: '2027-11-26 12:30',
    do: { kind: 'sell', kid: 'B', fund: 'nasdaq100', cents: $(20), label: 'tB7' },
    why: 'after the early close: settles Mon Nov 29',
  },

  // December: a higher cap, deposits, a TSX early close -----------------------------------------
  {
    at: '2027-12-01 09:00',
    do: { kind: 'set_cap', cents: $(1500), effective: '2027-12-01' },
    why: 'cap raised for Christmas',
  },
  {
    at: '2027-12-03 09:00',
    do: { kind: 'deposit', kid: 'A', cents: $(400), label: 'dA3' },
    why: 'Christmas money (fits the new cap)',
  },
  {
    at: '2027-12-03 09:01',
    do: { kind: 'deposit', kid: 'B', cents: $(500), label: 'dB3' },
    why: 'Christmas money (fits the new cap)',
  },
  // Stage 8 B2: cancelling scheduled changes, and 7 days' notice for cuts --------------------
  {
    at: '2027-11-01 09:00',
    do: {
      kind: 'add_rate',
      rate: { vehicle: 'savings', term: null, rate: '1.0', effective: '2027-11-15', label: 'rCut' },
    },
    expect: 'ok',
    why: 'savings cut announced 14 days ahead',
  },
  {
    at: '2027-11-08 09:00',
    do: { kind: 'cancel', label: 'rCut' },
    expect: 'ok',
    why: 'Dad cancels the cut before it starts: savings interest stays at 1.5%',
  },
  {
    at: '2027-11-20 09:00',
    do: {
      kind: 'add_rate',
      rate: { vehicle: 'gic', term: 9, rate: '5.0', effective: '2027-12-01', label: 'rUp' },
    },
    expect: 'ok',
    why: '9-month GIC raise announced 11 days ahead',
  },
  {
    at: '2027-11-28 09:00',
    do: { kind: 'cancel', label: 'rUp' },
    expect: 'refused',
    why: 'cancelling a promised raise 3 days before it starts is refused',
  },
  {
    at: '2027-12-01 09:01',
    do: { kind: 'set_yield', fund: 'tsx', yield: '2.0', effective: '2027-12-03' },
    expect: 'refused',
    why: "a dividend yield cut with 2 days' notice is refused",
  },
  {
    at: '2027-12-01 09:02',
    do: { kind: 'set_yield', fund: 'tsx', yield: '3.5', effective: '2027-12-01', label: 'yUp' },
    expect: 'ok',
    why: "TSX yield raise from today: January's dividend pays 3.5%",
  },
  {
    at: '2027-12-10 09:00',
    do: { kind: 'set_yield', fund: 'dow', yield: '1.0', effective: '2028-01-20', label: 'yCut' },
    expect: 'ok',
    why: 'Dow yield cut announced 41 days ahead',
  },
  {
    at: '2027-12-15 09:00',
    do: { kind: 'cancel', label: 'yCut' },
    expect: 'ok',
    why: "cancelled: April's Dow dividend still pays 1.8%",
  },
  {
    at: '2027-12-20 09:00',
    do: { kind: 'set_cap', cents: $(500), effective: '2028-01-01', label: 'cCut' },
    expect: 'ok',
    why: 'cap cut to $500 from Jan 1',
  },
  {
    at: '2027-12-27 09:00',
    do: { kind: 'cancel', label: 'cCut' },
    expect: 'ok',
    why: "cancelled: January's deposits still fit under $1,000",
  },
  { at: '2027-12-03 12:00', do: { kind: 'approve', label: 'dA3' }, why: 'Dad approves' },
  { at: '2027-12-03 12:01', do: { kind: 'approve', label: 'dB3' }, why: 'Dad approves' },
  {
    at: '2027-12-24 09:00',
    do: { kind: 'buy', kid: 'A', fund: 'dow', cents: $(20), label: 'tA5' },
    why: 'NYSE closed (Christmas observed): settles Mon Dec 27',
  },
  {
    at: '2027-12-24 10:00',
    do: { kind: 'buy', kid: 'B', fund: 'tsx', cents: $(20), label: 'tB8' },
    why: 'TSX early close (1:00 pm Toronto): settles at 12:00 pm',
  },
  {
    at: '2027-12-24 12:00',
    do: { kind: 'buy', kid: 'A', fund: 'tsx', cents: $(20), label: 'tA6' },
    why: 'exactly at the 12:00 pm TSX early close, so it waits; closed Dec 27–28: settles Dec 29',
  },

  // 2028: renewal, a leap-day maturity, the crash, the inverted month --------------------------
  // gA6m matures Sun Jan 2.
  {
    at: '2028-01-04 18:00',
    do: { kind: 'choose', gic: 'gA6m', choice: 'renew', newLabel: 'gA6m_r' },
    why: 'renewed: principal + interest into a new 6-month GIC',
  },
  // Request expiry changes from 7 to 10 days on Jan 10 (stage 8): each request keeps
  // the expiry it had when she asked.
  {
    at: '2028-01-05 09:00',
    do: { kind: 'set_expiry', days: 10, effective: '2028-01-10' },
    why: 'Dad gives himself 10 days to answer, from Jan 10',
  },
  {
    at: '2028-01-08 10:00',
    do: { kind: 'deposit', kid: 'B', cents: $(20), label: 'dB_x7' },
    why: 'asked before the change: still 7 days',
  },
  {
    at: '2028-01-12 10:00',
    do: { kind: 'withdraw', kid: 'B', cents: $(15), label: 'wB_x10' },
    why: 'asked after the change: 10 days, holding $15',
  },
  {
    at: '2028-01-15 17:00',
    do: { kind: 'request_status', label: 'dB_x7', status: 'expired' },
    why: 'expired 7 × 24 hours later (10:00 Jan 15)',
  },
  {
    at: '2028-01-21 17:00',
    do: { kind: 'request_status', label: 'wB_x10', status: 'pending' },
    why: 'still waiting after 9 days (the old rule would have expired it)',
  },
  {
    at: '2028-01-22 17:00',
    do: { kind: 'request_status', label: 'wB_x10', status: 'expired' },
    why: 'expired 10 × 24 hours later (10:00 Jan 22), releasing the $15',
  },
  {
    at: '2028-01-31 10:00',
    do: { kind: 'buy_gic', kid: 'B', cents: $(60), term: 1, label: 'gB1m' },
    why: 'Jan 31 + 1 month = Feb 29 (leap day)',
  },
  // Fix a mistake (stage 8 B3): new savings lines linked to a line in her history, rounded
  // in her favour. A confirming tap for every reduction, the amount typed again for an
  // addition over $100; never larger than the deposit cap ($1,500 now), never more than
  // the line (for a reduction) or her free savings. February's interest then accrues on
  // the corrected balances.
  {
    at: '2028-02-02 09:00',
    do: {
      kind: 'correct',
      kid: 'A',
      direction: 'add',
      amount: '0.4567',
      line: 'interest',
      checked: false,
    },
    why: 'adds $0.4567, rounded UP to $0.46; small, so no extra check',
  },
  {
    at: '2028-02-02 09:05',
    do: {
      kind: 'correct',
      kid: 'B',
      direction: 'take',
      amount: '5.009',
      line: 'deposit',
      checked: false,
    },
    expect: 'refused',
    why: 'a reduction without the confirming tap',
  },
  {
    at: '2028-02-02 09:06',
    do: {
      kind: 'correct',
      kid: 'B',
      direction: 'take',
      amount: '5.009',
      line: 'deposit',
      checked: true,
    },
    why: 'takes $5.009, rounded DOWN to $5.00, after the tap',
  },
  {
    at: '2028-02-02 09:10',
    do: {
      kind: 'correct',
      kid: 'A',
      direction: 'add',
      amount: '120.5',
      line: 'deposit',
      checked: false,
    },
    expect: 'refused',
    why: 'the typo guard: adding more than $100 without typing it again',
  },
  {
    at: '2028-02-02 09:11',
    do: {
      kind: 'correct',
      kid: 'A',
      direction: 'add',
      amount: '120.5',
      line: 'deposit',
      checked: true,
    },
    why: 'adds $120.50, typed again',
  },
  {
    at: '2028-02-02 09:12',
    do: {
      kind: 'correct',
      kid: 'A',
      direction: 'add',
      amount: '1500.01',
      line: 'deposit',
      checked: true,
    },
    expect: 'refused',
    why: 'larger than the $1,500 deposit cap, even typed again',
  },
  {
    at: '2028-02-02 09:15',
    do: {
      kind: 'correct',
      kid: 'B',
      direction: 'take',
      amount: '50',
      line: 'interest',
      checked: true,
    },
    expect: 'refused',
    why: 'more than the interest line it is linked to',
  },
  {
    at: '2028-02-02 09:16',
    do: {
      kind: 'correct',
      kid: 'B',
      direction: 'take',
      amount: '0.01',
      line: 'interest',
      checked: true,
    },
    why: 'a cent from the same interest line is fine',
  },
  {
    at: '2028-02-02 09:17',
    do: {
      kind: 'correct',
      kid: 'B',
      direction: 'take',
      amount: '9000',
      line: 'deposit',
      checked: true,
    },
    expect: 'refused',
    why: 'more than the cap, the line and her free savings',
  },
  {
    at: '2028-02-23 09:00',
    do: {
      kind: 'add_rate',
      rate: { vehicle: 'gic', term: 1, rate: '5.5', effective: '2028-03-01' },
    },
    why: 'inverted-curve month',
  },
  {
    at: '2028-02-23 09:01',
    do: {
      kind: 'add_rate',
      rate: { vehicle: 'gic', term: 3, rate: '5.0', effective: '2028-03-01' },
    },
    why: 'inverted-curve month',
  },
  {
    at: '2028-02-23 09:02',
    do: {
      kind: 'add_rate',
      rate: { vehicle: 'gic', term: 6, rate: '4.5', effective: '2028-03-01' },
    },
    why: 'inverted-curve month',
  },
  {
    at: '2028-02-23 09:03',
    do: {
      kind: 'add_rate',
      rate: { vehicle: 'gic', term: 12, rate: '4.0', effective: '2028-03-01' },
    },
    why: 'inverted-curve month',
  },
  {
    at: '2028-02-23 09:04',
    do: {
      kind: 'add_rate',
      rate: { vehicle: 'gic', term: 24, rate: '3.5', effective: '2028-03-01' },
    },
    why: 'inverted-curve month',
  },
  {
    at: '2028-02-23 16:00',
    do: sellWorthAll('B', 'nasdaq100', 'tB9'),
    why: `dollar sale; the price falls by the ${BIG_DROP_DAY} close, so she sells everything`,
  },
  // gB1m matures Tue Feb 29.
  {
    at: '2028-03-02 18:00',
    do: { kind: 'choose', gic: 'gB1m', choice: 'to_savings' },
    why: 'leap-day GIC moved to savings after 2 days waiting',
  },
  {
    at: '2028-03-06 10:00',
    do: { kind: 'buy_gic', kid: 'A', cents: $(50), term: 1, label: 'gA1m_inv' },
    why: 'short term pays more in the inverted month (matures in the missed week)',
  },
  {
    at: '2028-03-10 14:30',
    do: { kind: 'buy', kid: 'A', fund: 'dow', cents: $(10), label: 'tA_tz2' },
    why: 'last Friday of Toronto standard time: before the 3:00 pm close, settles that day',
  },
  {
    at: '2028-03-13 14:30',
    do: { kind: 'buy', kid: 'B', fund: 'dow', cents: $(10), label: 'tB_tz2' },
    why: 'first Monday of Toronto summer time: after the 2:00 pm close, settles Tue Mar 14',
  },
  {
    at: '2028-03-15 10:00',
    do: { kind: 'break_gic', gic: 'gA9m' },
    why: 'early break: principal back, interest given up',
  },
  {
    at: '2028-03-20 09:00',
    do: {
      kind: 'add_rate',
      rate: { vehicle: 'gic', term: 1, rate: '2.5', effective: '2028-04-01' },
    },
    why: 'curve back to normal',
  },
  {
    at: '2028-03-20 09:01',
    do: {
      kind: 'add_rate',
      rate: { vehicle: 'gic', term: 3, rate: '3.0', effective: '2028-04-01' },
    },
    why: 'curve back to normal',
  },
  {
    at: '2028-03-20 09:02',
    do: {
      kind: 'add_rate',
      rate: { vehicle: 'gic', term: 6, rate: '4.0', effective: '2028-04-01' },
    },
    why: 'curve back to normal',
  },
  {
    at: '2028-03-20 09:03',
    do: {
      kind: 'add_rate',
      rate: { vehicle: 'gic', term: 12, rate: '4.5', effective: '2028-04-01' },
    },
    why: 'curve back to normal',
  },
  {
    at: '2028-03-20 09:04',
    do: {
      kind: 'add_rate',
      rate: { vehicle: 'gic', term: 24, rate: '6.0', effective: '2028-04-01' },
    },
    why: 'curve back to normal',
  },

  // April: the missed week (Apr 1–7). Kids and Dad still use the app. ------------------------
  {
    at: '2028-04-04 10:00',
    do: { kind: 'deposit', kid: 'B', cents: $(20), label: 'dB4' },
    why: 'deposit during the missed week',
  },
  {
    at: '2028-04-05 10:00',
    do: { kind: 'buy', kid: 'A', fund: 'dow', cents: $(30), label: 'tA7' },
    why: 'trade during the missed week (settles in the catch-up)',
  },
  {
    at: '2028-04-05 11:00',
    do: { kind: 'approve', label: 'dB4' },
    why: 'Dad approves during the missed week',
  },
  {
    at: '2028-04-08 08:00',
    do: { kind: 'health', ok: false },
    why: 'the health check notices the jobs are a week behind',
  },
  {
    at: '2028-04-08 17:00',
    do: { kind: 'health', ok: true },
    why: 'after the catch-up run, all clear',
  },
  // gA1m_inv matured Apr 6 during the missed week; she chooses after it catches up.
  {
    at: '2028-04-10 18:00',
    do: { kind: 'choose', gic: 'gA1m_inv', choice: 'to_savings' },
    why: 'GIC that matured in the missed week, moved to savings',
  },
  // gA3m_n matured Apr 4 during the missed week and moves on its own on day 7 (Apr 11).
  {
    at: '2028-04-13 16:00',
    do: { kind: 'sell', kid: 'B', fund: 'dow', cents: $(15), label: 'tB10' },
    why: 'Good Friday: settles Mon Apr 17',
  },

  // May–June: the cap is lowered below what B has put in --------------------------------------
  {
    at: '2028-04-24 09:00',
    do: { kind: 'set_cap', cents: $(800), effective: '2028-05-01' },
    why: "cap lowered below both kids' net deposits, with 7 days' notice",
  },
  {
    at: '2028-04-24 09:01',
    do: { kind: 'set_cap', cents: $(700), effective: '2028-04-26' },
    expect: 'refused',
    why: "a cap cut with 2 days' notice is refused (stage 8 B2)",
  },
  {
    at: '2028-05-03 10:00',
    do: { kind: 'deposit', kid: 'B', cents: $(10), label: 'dB5' },
    expect: 'refused',
    why: 'no room under the lower cap (nothing is taken away)',
  },
  {
    at: '2028-05-22 10:00',
    do: { kind: 'buy', kid: 'A', fund: 'tsx', cents: $(15), label: 'tA8' },
    why: 'TSX closed (Victoria Day): settles May 23',
  },
  {
    at: '2028-06-15 10:00',
    do: { kind: 'sell_all', kid: 'A', fund: 'nasdaq100', label: 'tA9' },
    why: 'held through the crash, sells all after the recovery',
  },
  {
    at: '2028-06-20 10:00',
    do: { kind: 'withdraw', kid: 'A', cents: $(30), label: 'wA2' },
    why: 'withdrawal',
  },
  {
    at: '2028-06-22 10:00',
    do: { kind: 'approve', label: 'wA2' },
    why: 'Dad approves after 2 days',
  },
];
