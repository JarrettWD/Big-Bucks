import { describe, expect, it } from 'vitest';
import { TEXT, parseDays, parsePercent, parseWords } from './settingsText';

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

describe('a percent typed by Dad', () => {
  it('keeps it as exact text, never a floating-point number', () => {
    expect(parsePercent('2.5')).toEqual({ value: '2.5' });
    expect(parsePercent(' 1.25 % ')).toEqual({ value: '1.25' });
    expect(parsePercent('2.0')).toEqual({ value: '2' });
    expect(parsePercent('02.50')).toEqual({ value: '2.5' });
    expect(parsePercent('.75')).toEqual({ value: '0.75' });
    expect(parsePercent('0')).toEqual({ value: '0' });
    expect(parsePercent('2.125')).toEqual({ value: '2.125' });
  });
  it('explains what is wrong', () => {
    expect(parsePercent('')).toEqual({ error: 'Type a percent, like 2.5.' });
    expect(parsePercent('two')).toEqual({ error: 'Use numbers and a dot, like 2.5.' });
    expect(parsePercent('2,5')).toEqual({ error: 'Use numbers and a dot, like 2.5.' });
    expect(parsePercent('-1')).toEqual({ error: 'Use numbers and a dot, like 2.5.' });
    expect(parsePercent('100')).toEqual({ error: 'Use a percent below 100.' });
    expect(parsePercent('2.1234')).toEqual({
      error: 'Use at most 3 numbers after the dot, like 2.125.',
    });
  });
});

describe('wording typed by Dad', () => {
  it('needs some words, up to the limit', () => {
    expect(parseWords('  Big day!  ', 300)).toEqual({ value: 'Big day!' });
    expect(parseWords('   ', 300)).toEqual({ error: 'Type some words.' });
    expect(parseWords('a'.repeat(301), 300)).toEqual({
      error: 'Use at most 300 letters (now 301).',
    });
  });
});

describe('rate wording', () => {
  it('says what changes, from when', () => {
    expect(
      TEXT.rateFacts({
        what: 'Savings',
        before: '2.0%',
        after: '1.5%',
        from: 'Oct 12',
        special: false,
      }),
    ).toBe('Savings: 2.0% → 1.5% from Oct 12.');
    expect(
      TEXT.rateFacts({
        what: '1-year GIC',
        before: '5.0%',
        after: '6.5%',
        from: 'Oct 6',
        to: 'Oct 12',
        back_to: '5.0%',
        special: true,
      }),
    ).toBe('1-year GIC special: 6.5% from Oct 6 to Oct 12, then back to 5.0%.');
    expect(TEXT.yesRate({ after: '1.5%', from: 'Oct 12', special: false })).toBe(
      'Yes, save 1.5% from Oct 12',
    );
    expect(TEXT.yesRate({ after: '6.5%', from: 'Oct 6', special: true })).toBe(
      'Yes, save 6.5% special from Oct 6',
    );
    expect(TEXT.yesRate(null)).toBe('Yes, save');
    expect(TEXT.specialUntil('Oct 11', '5.0%')).toBe('Special until Oct 11, then 5.0%');
  });
  it('words a setting change and the notices', () => {
    expect(TEXT.fromTo({ before: '$1,000.00', after: '$800.00', from: 'Oct 5' })).toBe(
      '$1,000.00 → $800.00, from Oct 5.',
    );
    expect(TEXT.fromTo({ before: null, after: 'Everyone', from: 'Oct 5' })).toBe(
      'Not set → Everyone, from Oct 5.',
    );
    expect(TEXT.writtenTitle(30, 42)).toBe('Notes already written (latest 30 of 42)');
    expect(TEXT.writtenTitle(3, 3)).toBe('Notes already written');
    expect(TEXT.editNote({ date: 'Oct 2', fund: 'Nasdaq-100' })).toBe(
      'Edit the Nasdaq-100 note for Oct 2',
    );
  });
});
