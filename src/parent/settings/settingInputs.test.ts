// Dad, 2026-10-19: typing a new deposit cap blanked the screen. The button's wording fell back
// to the cap's starting text ("1,000"), which the money formatter refuses. Every step of typing
// (empty, part-typed, a typo, a normal value) must give words, never throw.
import { describe, expect, it } from 'vitest';
import { formatCents } from '../../lib/money';
import { buttonWords, parseCap, parseDays, parsePercent, TEXT } from './settingsText';

const cap = { initial: '1,000', parse: parseCap };
const capYes = (v: string) => TEXT.yesCap(formatCents(v));

describe('the deposit cap box, one key at a time', () => {
  it.each([
    ['', 'empty'],
    ['1,0001', 'a key added to "1,000"'],
    ['1,00', 'a key deleted from "1,000"'],
    ['1,', 'part-typed with a comma'],
    ['.', 'just a dot'],
    ['12.345', 'too many decimals'],
    ['abc', 'not a number'],
  ])('"%s" (%s) gives words, never a crash', (typed) => {
    expect(() => buttonWords(parseCap(typed), cap, capYes)).not.toThrow();
    expect(buttonWords(parseCap(typed), cap, capYes)).toBe('Yes, change to $1,000.00');
  });
  it('a normal value words the button with that value', () => {
    expect(buttonWords(parseCap('1200'), cap, capYes)).toBe('Yes, change to $1,200.00');
    expect(buttonWords(parseCap('1,250.5'), cap, capYes)).toBe('Yes, change to $1,250.50');
  });
  it('even a starting value that does not parse gives a neutral label', () => {
    expect(buttonWords(parseCap('oops'), { initial: 'oops', parse: parseCap }, capYes)).toBe(
      TEXT.yesCheckFirst,
    );
  });
});

describe('the other parent number boxes never throw while typing', () => {
  const percent = { initial: '2.0', parse: parsePercent };
  const days = {
    initial: '7',
    parse: (t: string) => {
      const d = parseDays(t, 3, 30);
      return typeof d === 'number' ? { value: String(d) } : { error: d };
    },
  };
  it.each(['', '2', '2.', '2.5', '.', '2.1234', '100', 'x'])('a percent: "%s"', (typed) => {
    expect(() =>
      buttonWords(percent.parse(typed), percent, (v) => TEXT.yesPercent(v)),
    ).not.toThrow();
  });
  it.each(['', '1', '10', '0', '31', 'x'])('a number of days: "%s"', (typed) => {
    expect(() => buttonWords(days.parse(typed), days, (v) => TEXT.yes(Number(v)))).not.toThrow();
  });
});
