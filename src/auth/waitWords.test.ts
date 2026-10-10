import { describe, expect, it } from 'vitest';
import { waitWords } from './kidLogin';

describe('how long a login break lasts, in words', () => {
  const now = new Date('2026-10-08T12:00:00Z');
  const later = (min: number) => new Date(now.getTime() + min * 60_000);
  it('minutes, up to 90', () => {
    expect(waitWords(later(1), now)).toBe('1 minute');
    expect(waitWords(later(15), now)).toBe('15 minutes');
    expect(waitWords(later(60), now)).toBe('60 minutes');
    expect(waitWords(later(90), now)).toBe('90 minutes');
  });
  it('then hours, rounded up', () => {
    expect(waitWords(later(91), now)).toBe('2 hours');
    expect(waitWords(later(24 * 60), now)).toBe('24 hours');
  });
});
