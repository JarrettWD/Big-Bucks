import { describe, expect, it } from 'vitest';
import {
  amountLooksOk,
  beforeAfter,
  checkWhy,
  checkYes,
  roundedLine,
  yesLabel,
  type FixPreview,
} from './fixText';

const base: FixPreview = {
  problem: null,
  warning: null,
  limit_cents: 100000,
  line_left_cents: 42,
  counts_as: 'earned',
  needs_retype: false,
  kid: 'Robin',
  line: null,
  question: null,
  savings_cents: 10042,
  held_cents: 3000,
  free_cents: 7042,
  check_over_cents: 10000,
  cents: 124,
  typed: '$1.2340',
  rounded: true,
  needs_check: false,
  savings_after_cents: 10166,
  free_after_cents: 7166,
  summary: null,
  notices: [],
};

describe('Fix a mistake wording', () => {
  it('only asks the database about something that looks like dollars', () => {
    expect(amountLooksOk('12.50')).toBe(true);
    expect(amountLooksOk('$1,234.5')).toBe(true);
    expect(amountLooksOk('0.0001')).toBe(true);
    expect(amountLooksOk('0')).toBe(false);
    expect(amountLooksOk('-5')).toBe(false);
    expect(amountLooksOk('ten')).toBe(false);
    expect(amountLooksOk('')).toBe(false);
  });
  it('says how the amount was rounded, in her favour', () => {
    expect(roundedLine(base, 'Robin')).toBe(
      "You typed $1.2340. It's rounded up to $1.24, in Robin's favour.",
    );
    expect(roundedLine({ ...base, cents: -123, typed: '$1.2390' }, 'Robin')).toBe(
      "You typed $1.2390. It's rounded down to $1.23, in Robin's favour.",
    );
    expect(roundedLine({ ...base, rounded: false, typed: null }, 'Robin')).toBeNull();
  });
  it('shows savings before and after', () => {
    expect(beforeAfter(base)).toBe('Savings $100.42 → $101.66 (free to use $71.66).');
  });
  it('words the buttons and the extra check', () => {
    expect(yesLabel('add', 124, 'Robin', false)).toBe("Yes, add $1.24 to Robin's savings");
    expect(yesLabel('take', -2000, 'Robin', true)).toBe('Next: check the amount');
    expect(checkYes('take', -2000)).toBe('Yes, take $20.00');
    expect(checkWhy('take', 10000)).toBe('Taking money away always gets a second look.');
    expect(checkWhy('add', 10000)).toBe(
      "It's more than $100.00, so type the amount again in case of a typo.",
    );
  });
});
