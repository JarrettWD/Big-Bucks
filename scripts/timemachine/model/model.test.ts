// @vitest-environment node
// Known answers for the reference model, taken from docs/SPEC.md. These prove
// the model itself before it's trusted to check the database.
import { describe, expect, it } from 'vitest';
import { Q } from './rational.ts';
import { addHours, addMonths, daysInYear, weekday } from './calendar.ts';
import { Model, type Holiday } from './model.ts';

const holidays: Holiday[] = [
  { market: 'nyse', date: '2027-11-25', kind: 'closed', closesAt: null },
  { market: 'nyse', date: '2027-11-26', kind: 'early_close', closesAt: '13:00' },
  { market: 'tsx', date: '2027-10-11', kind: 'closed', closesAt: null },
];

function funded(start: string, cents: bigint): Model {
  const m = new Model(start, holidays);
  m.openAccount('k');
  expect(m.act(start, { kind: 'deposit', kid: 'k', cents, label: 'd1' }).ok).toBe(true);
  expect(m.act(start, { kind: 'approve', label: 'd1' }).ok).toBe(true);
  return m;
}

describe('exact fractions', () => {
  it('rounds up, down and to nearest', () => {
    expect(Q.of(2083, 100).ceil()).toBe(21n);
    expect(Q.of(2083, 100).floor()).toBe(20n);
    expect(Q.of(2050, 100).round()).toBe(21n);
    expect(Q.of(2049, 100).round()).toBe(20n);
    expect(Q.dec('0.1').add(Q.dec('0.2')).eq(Q.dec('0.3'))).toBe(true);
  });
});

describe('calendar', () => {
  it('Jan 31 + 1 month = Feb 28 in 2027 and Feb 29 in 2028', () => {
    expect(addMonths('2027-01-31', 1)).toBe('2027-02-28');
    expect(addMonths('2028-01-31', 1)).toBe('2028-02-29');
    expect(addMonths('2027-11-30', 3)).toBe('2028-02-29');
    expect(addMonths('2027-08-15', 12)).toBe('2028-08-15');
  });
  it('knows leap years and weekdays', () => {
    expect(daysInYear(2027)).toBe(365);
    expect(daysInYear(2028)).toBe(366);
    expect(weekday('2028-02-29')).toBe(2); // Tuesday
    expect(weekday('2027-11-26')).toBe(5); // Friday
  });
  it('7 × 24 hours across the November clock change ends an hour earlier on the clock', () => {
    expect(addHours('2027-11-03 10:00', 168)).toBe('2027-11-10 09:00');
    expect(addHours('2028-03-08 10:00', 168)).toBe('2028-03-15 11:00');
    expect(addHours('2027-08-03 10:00', 168)).toBe('2027-08-10 10:00');
  });
});

describe('GIC interest (spec known answers)', () => {
  it('$100 at 5% for 1 year = $105.00', () => {
    const m = funded('2027-01-04 09:00', 10000n);
    expect(
      m.act('2027-01-04 10:00', { kind: 'buy_gic', kid: 'k', cents: 10000n, term: 12, label: 'g' })
        .ok,
    ).toBe(true);
    m.advanceTo('2028-01-04 12:00');
    expect(m.snapshot('k').gics.get('g')).toBe(10500n);
  });
  it('$100 at 2.5% for 1 month = $0.21 (0.2083 rounded up)', () => {
    const m = funded('2027-01-04 09:00', 10000n);
    m.act('2027-01-04 10:00', { kind: 'buy_gic', kid: 'k', cents: 10000n, term: 1, label: 'g' });
    m.advanceTo('2027-02-04 12:00');
    expect(m.snapshot('k').gics.get('g')).toBe(10021n);
  });
  it('a broken GIC pays $0 and returns the principal', () => {
    const m = funded('2027-01-04 09:00', 10000n);
    m.act('2027-01-04 10:00', { kind: 'buy_gic', kid: 'k', cents: 10000n, term: 12, label: 'g' });
    expect(m.act('2027-06-01 10:00', { kind: 'break_gic', gic: 'g' }).ok).toBe(true);
    const s = m.snapshot('k');
    expect(s.gicTotal).toBe(0n);
    expect(s.savings).toBe(10000n + 0n + interestPostedSoFar(m));
  });
  it('a GIC keeps its locked rate after a cut', () => {
    const m = funded('2027-01-04 09:00', 10000n);
    m.act('2027-01-04 10:00', { kind: 'buy_gic', kid: 'k', cents: 10000n, term: 12, label: 'g' });
    m.act('2027-01-05 10:00', {
      kind: 'add_rate',
      rate: { vehicle: 'gic', term: 12, rate: '3.0', effective: '2027-01-12' },
    });
    m.advanceTo('2028-01-04 12:00');
    expect(m.snapshot('k').gics.get('g')).toBe(10500n);
  });
});

function interestPostedSoFar(m: Model): bigint {
  return m.postings.filter((p) => p.kind === 'savings_interest').reduce((s, p) => s + p.cents, 0n);
}

describe('savings interest', () => {
  it('$250 at 2% for 30 days in a non-leap year posts $0.42', () => {
    const m = funded('2027-06-01 09:00', 25000n);
    m.advanceTo('2027-07-01 12:00');
    const posted = m.postings.filter((p) => p.kind === 'savings_interest');
    expect(posted).toHaveLength(1);
    expect(posted[0].cents).toBe(42n);
    expect(posted[0].day).toBe('2027-07-01');
  });
  it('a day in 2028 accrues ÷366', () => {
    const m = funded('2028-03-01 09:00', 36600n);
    m.advanceTo('2028-03-02 12:00');
    const a = m.accrualLog.find((x) => x.day === '2028-03-01')!;
    expect(a.days).toBe(366);
    expect(a.accrued.eq(Q.of(2))).toBe(true); // 36600 × 2% ÷ 366 = 2 cents exactly
  });
});

describe('stock funds', () => {
  it('buying $100 at a close of 420 gives 0.23809524 units; shown nearest, sold rounded up', () => {
    const m = funded('2027-03-01 09:00', 20000n);
    m.addClose('dow', '2027-03-01', '420', '2027-03-01 14:30');
    m.addClose('dow', '2027-03-02', '430', '2027-03-02 14:30');
    m.act('2027-03-01 10:00', { kind: 'buy', kid: 'k', fund: 'dow', cents: 10000n, label: 't1' });
    m.advanceTo('2027-03-01 15:00');
    let s = m.snapshot('k');
    expect(s.units.get('dow')!.toFixed(8)).toBe('0.23809524');
    expect(s.fundValue.get('dow')).toBe(10000n); // 100.0000008 shown as $100.00
    m.advanceTo('2027-03-02 15:00');
    s = m.snapshot('k');
    expect(s.fundValue.get('dow')).toBe(10238n); // 102.3809532 shown as $102.38
    m.act('2027-03-02 16:00', { kind: 'sell_all', kid: 'k', fund: 'dow', label: 't2' });
    m.addClose('dow', '2027-03-03', '430', '2027-03-03 14:30');
    m.advanceTo('2027-03-03 15:00');
    expect(m.postings.find((p) => p.kind === 'sell')!.cents).toBe(10239n); // paid rounded up
  });
  it('Friday evening settles at Monday close; early close at 11:00 Edmonton; TSX holiday skipped', () => {
    const m = new Model('2027-10-01 09:00', holidays);
    expect(m.nextClose('dow', '2027-10-08 16:00')).toEqual({
      day: '2027-10-11',
      at: '2027-10-11 14:00',
    });
    expect(m.nextClose('tsx', '2027-10-08 16:00')).toEqual({
      day: '2027-10-12',
      at: '2027-10-12 14:00',
    });
    expect(m.nextClose('dow', '2027-11-26 10:30')).toEqual({
      day: '2027-11-26',
      at: '2027-11-26 11:00',
    });
    expect(m.nextClose('dow', '2027-11-26 11:30')).toEqual({
      day: '2027-11-29',
      at: '2027-11-29 14:00',
    });
    expect(m.nextClose('dow', '2027-11-29 14:00')).toEqual({
      day: '2027-11-30',
      at: '2027-11-30 14:00',
    });
  });
  it('one trade per fund per day', () => {
    const m = funded('2027-03-01 09:00', 20000n);
    expect(
      m.act('2027-03-01 10:00', { kind: 'buy', kid: 'k', fund: 'dow', cents: 1000n, label: 'a' })
        .ok,
    ).toBe(true);
    expect(
      m.act('2027-03-01 11:00', { kind: 'buy', kid: 'k', fund: 'dow', cents: 1000n, label: 'b' })
        .ok,
    ).toBe(false);
    expect(
      m.act('2027-03-01 11:00', { kind: 'buy', kid: 'k', fund: 'tsx', cents: 1000n, label: 'c' })
        .ok,
    ).toBe(true);
  });
});

describe('selling by dollar amount (Dad, stage 3: units round down)', () => {
  it('pays exactly the amount asked for and she keeps the sliver of a unit', () => {
    const m = funded('2027-03-01 09:00', 20000n);
    m.addClose('tsx', '2027-03-01', '40.747', '2027-03-01 14:30');
    m.addClose('tsx', '2027-03-02', '40.747', '2027-03-02 14:30');
    m.act('2027-03-01 10:00', { kind: 'buy', kid: 'k', fund: 'tsx', cents: 10000n, label: 'b' });
    m.act('2027-03-02 09:00', { kind: 'sell', kid: 'k', fund: 'tsx', cents: 3000n, label: 's' });
    m.advanceTo('2027-03-02 15:00');
    const sale = m.postings.find((p) => p.kind === 'sell')!;
    expect(sale.units!.toFixed(8)).toBe('0.73625052'); // 30 ÷ 40.747 = 0.7362505215…, rounded down
    expect(sale.cents).toBe(3000n); // 0.73625052 × 40.747 = $29.99999994 → rounded up to $30.00
  });
  it('sells everything when the price falls below what the amount needs', () => {
    const m = funded('2027-03-01 09:00', 20000n);
    m.addClose('dow', '2027-03-01', '100', '2027-03-01 14:30');
    m.addClose('dow', '2027-03-02', '90', '2027-03-02 14:30');
    m.act('2027-03-01 10:00', { kind: 'buy', kid: 'k', fund: 'dow', cents: 5000n, label: 'b' });
    m.act('2027-03-02 09:00', { kind: 'sell', kid: 'k', fund: 'dow', cents: 5000n, label: 's' });
    m.advanceTo('2027-03-02 15:00');
    expect(m.snapshot('k').units.get('dow')!.isZero()).toBe(true);
    expect(m.postings.find((p) => p.kind === 'sell')!.cents).toBe(4500n);
  });
});

describe('requests', () => {
  it('the cap counts pending deposits', () => {
    const m = new Model('2027-03-01 09:00', holidays);
    m.openAccount('k');
    expect(
      m.act('2027-03-01 09:00', { kind: 'deposit', kid: 'k', cents: 60000n, label: 'a' }).ok,
    ).toBe(true);
    expect(
      m.act('2027-03-01 09:05', { kind: 'deposit', kid: 'k', cents: 50000n, label: 'b' }).ok,
    ).toBe(false);
    expect(
      m.act('2027-03-01 09:05', { kind: 'deposit', kid: 'k', cents: 40000n, label: 'c' }).ok,
    ).toBe(true);
  });
  it('a withdrawal waits 24 hours and an unanswered request expires after 7 × 24 hours', () => {
    const m = funded('2027-03-01 09:00', 10000n);
    m.act('2027-03-02 10:00', { kind: 'withdraw', kid: 'k', cents: 2000n, label: 'w' });
    expect(m.snapshot('k').available).toBe(8000n);
    expect(m.act('2027-03-03 09:59', { kind: 'approve', label: 'w' }).ok).toBe(false);
    m.act('2027-03-03 10:00', { kind: 'withdraw', kid: 'k', cents: 1000n, label: 'w2' });
    m.advanceTo('2027-03-10 10:01');
    expect(m.requestStatus('w2')).toBe('expired');
    expect(m.snapshot('k').held).toBe(0n);
  });
});
