import { describe, expect, it } from 'vitest';
import { TEXT, parseDays } from './settingsText';

describe('days typed by Dad', () => {
  it('takes whole days from 3 to 30 only', () => {
    expect(parseDays('3', 3, 30)).toBe(3);
    expect(parseDays(' 10 ', 3, 30)).toBe(10);
    expect(parseDays('30', 3, 30)).toBe(30);
    for (const bad of ['2', '31', '7.5', '-5', 'ten', '010', '07', '100'])
      expect(parseDays(bad, 3, 30)).toBe('Use whole days, from 3 to 30.');
    expect(parseDays('', 3, 30)).toBe('Type a number of days from 3 to 30.');
  });
});

describe('wording', () => {
  it('says when the girls are told', () => {
    expect(TEXT.theySee(null, 2)).toBe('Every kid (2 accounts) will see this right away:');
    expect(TEXT.theySee('Nov 10', 2)).toBe('On Nov 10, every kid (2 accounts) will see:');
    expect(TEXT.theySee('Nov 10', 1)).toBe('On Nov 10, she will see:');
    expect(TEXT.historyWho({ who: 'Starting rule', when: null })).toBe('Starting rule');
    expect(TEXT.historyWho({ who: 'Dad', when: 'Oct 4 at 9:00 pm' })).toBe('Dad, Oct 4 at 9:00 pm');
  });
});
