import { describe, expect, it } from 'vitest';
import {
  adjustmentLine,
  cleanClose,
  closeLooksOk,
  price2,
  TEXT,
  type ClosePreview,
} from './fixCloseText';

describe('Fix a close wording', () => {
  it('only asks the database about something that looks like a price', () => {
    expect(closeLooksOk('647.05')).toBe(true);
    expect(closeLooksOk('$1,234.5')).toBe(true);
    expect(closeLooksOk('523.3')).toBe(true);
    expect(closeLooksOk('523.')).toBe(false);
    // Official closes are published to the cent (Dad, 2026-11-21).
    expect(closeLooksOk('523.33000000')).toBe(false);
    expect(closeLooksOk('647.055')).toBe(false);
    expect(closeLooksOk('0')).toBe(false);
    expect(closeLooksOk('1.123456789')).toBe(false);
    expect(closeLooksOk('abc')).toBe(false);
    expect(cleanClose('$1,234.50')).toBe('1234.50');
  });

  it('names the girl and what used the close', () => {
    expect(
      adjustmentLine({
        kind: 'buy',
        side: 'buy',
        kid_name: 'Test kid',
        words: 'Adds 0.00003646 units, worth about 2¢.',
      }),
    ).toBe('Test kid’s buy: Adds 0.00003646 units, worth about 2¢.');
    expect(
      adjustmentLine({
        kind: 'no_change',
        side: 'sell',
        kid_name: null,
        words: 'No change: this one was in her favour.',
      }),
    ).toBe('A test account’s sale: No change: this one was in her favour.');
  });

  it('shows the stored close and whether it is final', () => {
    const p = {
      day_words: 'Nov 5',
      old_close_words: '$648.5800',
      fetched_words: 'Nov 5 at 4:30 pm',
      final: true,
    } as ClosePreview;
    expect(TEXT.stored(p)).toBe('Stored close for Nov 5: $648.58 (fetched Nov 5 at 4:30 pm).');
    expect(TEXT.stored({ ...p, final: false })).toBe(
      'Stored close for Nov 5: $648.58 (fetched Nov 5 at 4:30 pm, not final yet).',
    );
  });

  it('shows prices to the cent, without ever rounding one', () => {
    expect(price2('$648.5800')).toBe('$648.58');
    expect(price2('$1,234.5000')).toBe('$1,234.50');
    expect(price2('$0.0500')).toBe('$0.05');
    // A price with more than cents keeps its digits rather than being rounded away.
    expect(price2('$648.5850')).toBe('$648.585');
    expect(price2('$648.58')).toBe('$648.58');
    expect(price2(null)).toBeNull();
    expect(price2('not a price')).toBe('not a price');
  });
});
