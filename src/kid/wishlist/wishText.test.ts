import { describe, expect, it } from 'vitest';
import { DIP_LINE, progressLine, projectionLine, safeHref, showDip, siteName } from './wishText';

const wish = (over: Partial<Parameters<typeof projectionLine>[0]> = {}) => ({
  percent: 40,
  enough: false,
  price_cents: '45000',
  months: 15,
  around: 'January 2028',
  ...over,
});

describe('wish list wording (stage 9)', () => {
  it('says how close she is, from the database percent', () => {
    expect(progressLine(wish())).toBe("You're 40% of the way there.");
    expect(progressLine(wish({ percent: 100, enough: true }))).toBe(
      'You have enough for this! Talk to Mom and Dad about it.',
    );
    expect(progressLine(wish({ price_cents: null, percent: null }))).toBe(
      'Add a rough price to see how close you are.',
    );
  });

  it('words the projected date as a guess, never a promise', () => {
    const line = projectionLine(wish(), '18000');
    expect(line).toBe(
      "If your money keeps growing like your savings does now, and you add nothing, you could have enough around January 2028. That's a guess, not a promise. Adding money gets you there sooner.",
    );
    expect(line).not.toMatch(/\bwill\b/);
  });

  it('past 5 years, says interest alone is slow and adding money is the way', () => {
    expect(projectionLine(wish({ months: null, around: null }), '10000')).toBe(
      'Interest alone would take more than 5 years. Adding money, like birthday or allowance money, is the fastest way there.',
    );
  });

  it('has nothing to project with nothing saved, no price, or enough already', () => {
    expect(projectionLine(wish({ months: null, around: null }), 0)).toBe(
      "Once you have some money saved, you'll see roughly when you could have enough.",
    );
    expect(projectionLine(wish({ price_cents: null, percent: null }), '10000')).toBeNull();
    expect(
      projectionLine(wish({ enough: true, percent: 100, months: 0, around: null }), '50000'),
    ).toBeNull();
  });

  it('explains gently when her funds went down (Dad, 2026-10-16)', () => {
    expect(DIP_LINE).toBe(
      "Your funds went down this week, so you're a bit further away. That's normal: funds go up and down.",
    );
    expect(showDip(true, wish())).toBe(true);
    expect(showDip(false, wish())).toBe(false);
    expect(showDip(true, wish({ enough: true, percent: 100 }))).toBe(false);
    expect(showDip(true, wish({ percent: null }))).toBe(false);
  });
});

describe('links she pastes (stage 9)', () => {
  it('shows only the site, never the whole link', () => {
    expect(siteName('https://www.shop.example.com/toys/bike?id=12&ref=abc')).toBe(
      'shop.example.com',
    );
    expect(siteName('http://example.ca')).toBe('example.ca');
  });
  it('shows look-alike letters in their xn-- form', () => {
    // "аpple" with a Cyrillic а is not apple.com.
    expect(siteName('https://аpple.com/deal')).toBe('xn--pple-43d.com');
  });
  it('refuses anything that is not a web link', () => {
    expect(siteName('javascript:alert(1)')).toBeNull();
    expect(siteName('data:text/html,hi')).toBeNull();
    expect(siteName('ftp://example.com/x')).toBeNull();
    expect(siteName('not a link')).toBeNull();
    expect(siteName(null)).toBeNull();
    expect(safeHref('javascript:alert(1)')).toBeNull();
    expect(safeHref('https://shop.example.com/bike')).toBe('https://shop.example.com/bike');
  });
});
