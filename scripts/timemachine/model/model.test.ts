// @vitest-environment node
// Known answers for the reference model, taken from docs/SPEC.md. These prove
// the model itself before it's trusted to check the database.
import { describe, expect, it } from 'vitest';
import { Q } from './rational.ts';
import {
  NIGHTLY_RUN,
  addHours,
  addMonths,
  daysInYear,
  torontoToEdmonton,
  weekday,
} from './calendar.ts';
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
  it('Alberta has no clock changes from Nov 1, 2026: 7 × 24 hours is the same time a week later', () => {
    expect(addHours('2026-10-29 10:00', 168)).toBe('2026-11-05 10:00');
    expect(addHours('2027-11-03 10:00', 168)).toBe('2027-11-10 10:00');
    expect(addHours('2028-03-08 10:00', 168)).toBe('2028-03-15 10:00');
    expect(addHours('2027-08-03 10:00', 168)).toBe('2027-08-10 10:00');
  });
  it('before Alberta stopped changing clocks, the old rule still applies', () => {
    expect(addHours('2025-10-29 10:00', 168)).toBe('2025-11-05 09:00');
    expect(addHours('2026-03-04 10:00', 168)).toBe('2026-03-11 11:00');
  });
  it('4:00 pm Toronto is 2:00 pm in Alberta in Toronto summer time, 3:00 pm otherwise', () => {
    expect(torontoToEdmonton('2026-10-30', '16:00')).toBe('2026-10-30 14:00');
    expect(torontoToEdmonton('2026-11-02', '16:00')).toBe('2026-11-02 15:00');
    expect(torontoToEdmonton('2026-11-27', '13:00')).toBe('2026-11-27 12:00');
    expect(torontoToEdmonton('2027-03-12', '16:00')).toBe('2027-03-12 15:00');
    expect(torontoToEdmonton('2027-03-15', '16:00')).toBe('2027-03-15 14:00');
    expect(torontoToEdmonton('2027-11-05', '16:00')).toBe('2027-11-05 14:00');
    expect(torontoToEdmonton('2027-11-08', '16:00')).toBe('2027-11-08 15:00');
    expect(torontoToEdmonton('2028-03-10', '16:00')).toBe('2028-03-10 15:00');
    expect(torontoToEdmonton('2028-03-13', '16:00')).toBe('2028-03-13 14:00');
  });
  it('the nightly run is after every close', () => {
    expect(NIGHTLY_RUN > '15:00').toBe(true);
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

describe('request expiry (stage 8: a setting, fixed when she asks)', () => {
  it('7 days to start; a change applies only to requests made after it starts', () => {
    const m = funded('2028-01-01 09:00', 10000n);
    expect(
      m.act('2028-01-05 09:00', { kind: 'set_expiry', days: 10, effective: '2028-01-10' }).ok,
    ).toBe(true);
    expect(m.expiryDaysOn('2028-01-09')).toBe(7);
    expect(m.expiryDaysOn('2028-01-10')).toBe(10);
    m.act('2028-01-08 10:00', { kind: 'deposit', kid: 'k', cents: 2000n, label: 'old' });
    m.act('2028-01-12 10:00', { kind: 'deposit', kid: 'k', cents: 2000n, label: 'new' });
    m.advanceTo('2028-01-15 09:59');
    expect(m.requestStatus('old')).toBe('pending');
    m.advanceTo('2028-01-15 10:00');
    expect(m.requestStatus('old')).toBe('expired'); // 7 × 24 hours
    m.advanceTo('2028-01-22 09:59');
    expect(m.requestStatus('new')).toBe('pending');
    m.advanceTo('2028-01-22 10:00');
    expect(m.requestStatus('new')).toBe('expired'); // 10 × 24 hours
  });
  it('refuses anything but 3 to 30 whole days', () => {
    const m = funded('2028-01-01 09:00', 10000n);
    for (const days of [2, 31, 7.5])
      expect(
        m.act('2028-01-02 09:00', { kind: 'set_expiry', days, effective: '2028-01-03' }).ok,
      ).toBe(false);
  });
});

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
    m.addClose('dow', '2027-03-01', '420', '2027-03-01 15:30');
    m.addClose('dow', '2027-03-02', '430', '2027-03-02 15:30');
    m.act('2027-03-01 10:00', { kind: 'buy', kid: 'k', fund: 'dow', cents: 10000n, label: 't1' });
    m.advanceTo('2027-03-01 16:00');
    let s = m.snapshot('k');
    expect(s.units.get('dow')!.toFixed(8)).toBe('0.23809524');
    expect(s.fundValue.get('dow')).toBe(10000n); // 100.0000008 shown as $100.00
    m.advanceTo('2027-03-02 16:00');
    s = m.snapshot('k');
    expect(s.fundValue.get('dow')).toBe(10238n); // 102.3809532 shown as $102.38
    m.act('2027-03-02 16:00', { kind: 'sell_all', kid: 'k', fund: 'dow', label: 't2' });
    m.addClose('dow', '2027-03-03', '430', '2027-03-03 15:30');
    m.advanceTo('2027-03-03 16:00');
    expect(m.postings.find((p) => p.kind === 'sell')!.cents).toBe(10239n); // paid rounded up
  });
  it('a day’s close is known from the nightly run (or later, if it arrives late)', () => {
    const m = new Model('2027-03-01 09:00', holidays);
    m.addClose('dow', '2027-03-01', '420', '2027-03-01 15:30');
    m.addClose('dow', '2027-03-02', '430', '2027-03-02 15:30');
    m.addClose('dow', '2027-03-03', '440', '2027-03-04 10:00'); // a late close
    expect(m.knownClose('dow', '2027-03-02 16:00')?.toFixed(0)).toBe('420');
    expect(m.knownClose('dow', `2027-03-02 ${NIGHTLY_RUN}`)?.toFixed(0)).toBe('430');
    expect(m.knownClose('dow', '2027-03-04 09:00')?.toFixed(0)).toBe('430');
    expect(m.knownClose('dow', '2027-03-04 10:00')?.toFixed(0)).toBe('440');
  });
  it('typing the shown value sells all; more is refused (Dad, stage 7 2b review)', () => {
    const m = funded('2027-03-01 09:00', 20000n);
    m.addClose('tsx', '2027-03-01', '41.13', '2027-03-01 15:30');
    m.addClose('tsx', '2027-03-02', '39.27', '2027-03-02 15:30');
    m.addClose('tsx', '2027-03-03', '39.27', '2027-03-03 15:30');
    m.act('2027-03-01 10:00', { kind: 'buy', kid: 'k', fund: 'tsx', cents: 6000n, label: 't1' });
    m.advanceTo('2027-03-02 16:00');
    expect(m.snapshot('k').units.get('tsx')!.toFixed(8)).toBe('1.45878921');
    expect(m.snapshot('k').fundValue.get('tsx')).toBe(5729n); // 57.2866… shown as $57.29
    const over = m.act('2027-03-03 09:00', {
      kind: 'sell',
      kid: 'k',
      fund: 'tsx',
      cents: 5730n,
      label: 't2',
    });
    expect(over).toEqual({ ok: false, reason: 'more than her units are worth' });
    expect(
      m.act('2027-03-03 09:00', { kind: 'sell', kid: 'k', fund: 'tsx', cents: 5729n, label: 't3' })
        .ok,
    ).toBe(true);
    m.advanceTo('2027-03-03 16:00');
    expect(m.postings.find((p) => p.kind === 'sell')!.cents).toBe(5729n); // all of it, rounded up
    expect(m.snapshot('k').units.get('tsx')!.isZero()).toBe(true);
  });
  it('Friday evening settles at Monday close; early close at 12:00 Edmonton in winter; TSX holiday skipped', () => {
    const m = new Model('2027-10-01 09:00', holidays);
    expect(m.nextClose('dow', '2027-10-08 16:00')).toEqual({
      day: '2027-10-11',
      at: '2027-10-11 14:00',
    });
    expect(m.nextClose('tsx', '2027-10-08 16:00')).toEqual({
      day: '2027-10-12',
      at: '2027-10-12 14:00',
    });
    expect(m.nextClose('dow', '2027-11-26 11:30')).toEqual({
      day: '2027-11-26',
      at: '2027-11-26 12:00',
    });
    expect(m.nextClose('dow', '2027-11-26 12:30')).toEqual({
      day: '2027-11-29',
      at: '2027-11-29 15:00',
    });
    expect(m.nextClose('dow', '2027-11-29 15:00')).toEqual({
      day: '2027-11-30',
      at: '2027-11-30 15:00',
    });
  });
  it('2:30 pm settles the same day in winter, the next day in summer', () => {
    const m = new Model('2027-10-01 09:00', holidays);
    expect(m.nextClose('dow', '2027-11-05 14:30')).toEqual({
      day: '2027-11-08',
      at: '2027-11-08 15:00',
    });
    expect(m.nextClose('dow', '2027-11-08 14:30')).toEqual({
      day: '2027-11-08',
      at: '2027-11-08 15:00',
    });
    expect(m.nextClose('dow', '2028-03-10 14:30')).toEqual({
      day: '2028-03-10',
      at: '2028-03-10 15:00',
    });
    expect(m.nextClose('dow', '2028-03-13 14:30')).toEqual({
      day: '2028-03-14',
      at: '2028-03-14 14:00',
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
    m.addClose('tsx', '2027-03-01', '40.747', '2027-03-01 15:30');
    m.addClose('tsx', '2027-03-02', '40.747', '2027-03-02 15:30');
    m.act('2027-03-01 10:00', { kind: 'buy', kid: 'k', fund: 'tsx', cents: 10000n, label: 'b' });
    m.act('2027-03-02 09:00', { kind: 'sell', kid: 'k', fund: 'tsx', cents: 3000n, label: 's' });
    m.advanceTo('2027-03-02 16:00');
    const sale = m.postings.find((p) => p.kind === 'sell')!;
    expect(sale.units!.toFixed(8)).toBe('0.73625052'); // 30 ÷ 40.747 = 0.7362505215…, rounded down
    expect(sale.cents).toBe(3000n); // 0.73625052 × 40.747 = $29.99999994 → rounded up to $30.00
  });
  it('sells everything when the price falls below what the amount needs', () => {
    const m = funded('2027-03-01 09:00', 20000n);
    m.addClose('dow', '2027-03-01', '100', '2027-03-01 15:30');
    m.addClose('dow', '2027-03-02', '90', '2027-03-02 15:30');
    m.act('2027-03-01 10:00', { kind: 'buy', kid: 'k', fund: 'dow', cents: 5000n, label: 'b' });
    m.act('2027-03-02 09:00', { kind: 'sell', kid: 'k', fund: 'dow', cents: 5000n, label: 's' });
    m.advanceTo('2027-03-02 16:00');
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

describe("seven days' notice for a cut, and cancelling (stage 8 B2)", () => {
  const start = '2027-10-05 10:00'; // today Oct 5; a cut can start Oct 12 at the earliest
  const rate = (r: string, effective: string, label?: string) =>
    ({
      kind: 'add_rate',
      rate: { vehicle: 'savings', term: null, rate: r, effective, label },
    }) as const;

  it('refuses a cut that starts within 7 days, allows one 7 days out, and raises right away', () => {
    const m = new Model(start, holidays);
    expect(m.act(start, rate('1.0', '2027-10-06')).ok).toBe(false);
    expect(m.act(start, rate('1.0', '2027-10-11')).ok).toBe(false);
    expect(m.rateOn('savings', null, '2027-10-11').eq(Q.dec('2.0'))).toBe(true);
    expect(m.act(start, rate('1.5', '2027-10-12')).ok).toBe(true);
    expect(m.act(start, rate('2.5', '2027-10-05')).ok).toBe(true);
    expect(m.rateOn('savings', null, '2027-10-05').eq(Q.dec('2.5'))).toBe(true);
    expect(m.rateOn('savings', null, '2027-10-12').eq(Q.dec('1.5'))).toBe(true);
  });
  it('a cancelled change no longer counts; a promised raise inside the week cannot be cancelled', () => {
    const m = new Model(start, holidays);
    expect(m.act(start, rate('1.5', '2027-10-20', 'cut')).ok).toBe(true);
    expect(m.act(start, { kind: 'cancel', label: 'cut' }).ok).toBe(true);
    expect(m.rateOn('savings', null, '2027-10-20').eq(Q.dec('2.0'))).toBe(true);
    expect(m.act(start, { kind: 'cancel', label: 'cut' }).ok).toBe(false);
    expect(m.act(start, rate('3.0', '2027-10-08', 'raise')).ok).toBe(true);
    expect(m.act(start, { kind: 'cancel', label: 'raise' }).ok).toBe(false);
    expect(m.rateOn('savings', null, '2027-10-08').eq(Q.dec('3.0'))).toBe(true);
  });
  it('so does the deposit cap: a lower cap needs 7 days, a higher one starts today', () => {
    const m = new Model(start, holidays);
    const cap = (cents: bigint, effective: string, label?: string) =>
      ({ kind: 'set_cap', cents, effective, label }) as const;
    expect(m.act(start, cap(80000n, '2027-10-06')).ok).toBe(false);
    expect(m.act(start, cap(80000n, '2027-10-05')).ok).toBe(false);
    expect(m.capOn('2027-10-11')).toBe(100000n);
    expect(m.act(start, cap(80000n, '2027-10-12')).ok).toBe(true);
    expect(m.capOn('2027-10-12')).toBe(80000n);
    expect(m.act(start, cap(150000n, '2027-10-05')).ok).toBe(true);
    expect(m.capOn('2027-10-05')).toBe(150000n);
    expect(m.act(start, cap(160000n, '2027-10-08', 'up')).ok).toBe(true);
    expect(m.act(start, { kind: 'cancel', label: 'up' }).ok).toBe(false);
  });
  it('dividend yields follow the same rule', () => {
    const m = new Model(start, holidays);
    const y = (v: string, effective: string, label?: string) =>
      ({ kind: 'set_yield', fund: 'tsx', yield: v, effective, label }) as const;
    expect(m.act(start, y('2.0', '2027-10-06')).ok).toBe(false);
    expect(m.act(start, y('3.5', '2027-10-05')).ok).toBe(true);
    expect(m.yieldOn('tsx', '2027-10-05').eq(Q.dec('3.5'))).toBe(true);
    expect(m.act(start, y('1.0', '2027-11-01', 'ycut')).ok).toBe(true);
    expect(m.act(start, { kind: 'cancel', label: 'ycut' }).ok).toBe(true);
    expect(m.yieldOn('tsx', '2027-11-01').eq(Q.dec('3.5'))).toBe(true);
  });
});

describe('fixing a mistake (stage 8 B3)', () => {
  // Linked to her latest deposit line ($100.00), as Dad would pick it in her history.
  const fix = (direction: 'add' | 'take', amount: string, checked = false) =>
    ({ kind: 'correct', kid: 'k', direction, amount, line: 'deposit', checked }) as const;

  it('rounds in her favour: an addition up to the cent, a reduction down', () => {
    const m = funded('2027-03-01 09:00', 10000n);
    expect(m.act('2027-03-02 09:00', fix('add', '1.234')).ok).toBe(true);
    expect(m.snapshot('k').savings).toBe(10124n);
    expect(m.act('2027-03-02 09:01', fix('take', '1.239', true)).ok).toBe(true);
    expect(m.snapshot('k').savings).toBe(10001n);
    expect(m.act('2027-03-02 09:02', fix('take', '0.004', true)).ok).toBe(false);
    expect(m.act('2027-03-02 09:03', fix('add', '0.0001')).ok).toBe(true);
    expect(m.snapshot('k').savings).toBe(10002n);
    expect(m.postings.filter((p) => p.kind.startsWith('correction')).map((p) => p.cents)).toEqual([
      124n,
      123n,
      1n,
    ]);
  });
  it('a tap for any reduction; the amount typed again for an addition over $100', () => {
    const m = funded('2027-03-01 09:00', 10000n);
    expect(m.act('2027-03-02 09:00', fix('take', '0.01')).ok).toBe(false);
    expect(m.act('2027-03-02 09:00', fix('add', '100.00')).ok).toBe(true);
    expect(m.act('2027-03-02 09:00', fix('add', '100.0001')).ok).toBe(false);
    expect(m.act('2027-03-02 09:00', fix('add', '100.0001', true)).ok).toBe(true);
  });
  it('no single correction larger than the deposit cap', () => {
    const m = funded('2027-03-01 09:00', 10000n);
    expect(m.act('2027-03-02 09:00', fix('add', '1000.01', true)).ok).toBe(false);
    expect(m.act('2027-03-02 09:00', fix('add', '1000', true)).ok).toBe(true);
    expect(
      m.act('2027-03-02 09:01', { kind: 'set_cap', cents: 5000n, effective: '2027-03-09' }).ok,
    ).toBe(true);
    m.advanceTo('2027-03-09 09:00');
    expect(m.act('2027-03-09 09:00', fix('add', '50.01', true)).ok).toBe(false);
    expect(m.act('2027-03-09 09:00', fix('add', '50.00')).ok).toBe(true);
  });
  it('never takes more than her free savings', () => {
    const m = funded('2027-03-01 09:00', 10000n);
    m.act('2027-03-02 10:00', { kind: 'withdraw', kid: 'k', cents: 3000n, label: 'w' });
    expect(m.act('2027-03-02 10:01', fix('take', '70.01', true)).ok).toBe(false);
    expect(m.act('2027-03-02 10:01', fix('take', '70.009', true)).ok).toBe(true);
    expect(m.snapshot('k').available).toBe(0n);
  });
  it('reductions linked to a line take no more than it, together; additions may be more', () => {
    const m = funded('2027-03-01 09:00', 10000n);
    expect(m.act('2027-03-02 09:00', fix('add', '100')).ok).toBe(true);
    expect(m.act('2027-03-02 09:01', fix('take', '60', true)).ok).toBe(true);
    expect(m.act('2027-03-02 09:02', fix('take', '40.01', true)).ok).toBe(false);
    expect(m.act('2027-03-02 09:03', fix('take', '40', true)).ok).toBe(true);
    expect(m.act('2027-03-02 09:04', fix('take', '0.01', true)).ok).toBe(false);
  });
});
