// Every colour pair the screens use meets WCAG 2.2 AA.
import { readFileSync, readdirSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';
import { BRAND, contrast, INK, MOVE, OPTION, OPTION_TEXT } from './colours';

const W = BRAND.white;

describe('text contrast (4.5 : 1, or 3 : 1 for large text)', () => {
  it.each([
    ['main text on white', INK.ink, W, 4.5],
    ['main text on the page', INK.ink, INK.page, 4.5],
    ['main text on soft panels', INK.ink, INK.purpleTint, 4.5],
    ['secondary text on white', INK.inkSoft, W, 4.5],
    ['secondary text on the page', INK.inkSoft, INK.page, 4.5],
    ['secondary text on soft panels', INK.inkSoft, INK.purpleTint, 4.5],
    ['white on brand purple', W, BRAND.purple, 4.5],
    ['purple text on white', BRAND.purple, W, 4.5],
    ['purple text on soft panels', BRAND.purple, INK.purpleTint, 4.5],
    ['"up" on white', MOVE.up, W, 4.5],
    ['"down" on white', MOVE.down, W, 4.5],
    ['"no change" on white', MOVE.flat, W, 4.5],
    ['GIC pink text on white', OPTION.gic, W, 4.5],
    ['white on GIC pink', W, OPTION.gic, 4.5],
    ['white on TSX teal', W, OPTION.tsx, 4.5],
    ['main text on the gold banner', INK.ink, BRAND.gold, 4.5],
    ['gold headings on purple (large text only)', BRAND.gold, BRAND.purple, 3],
    ['gold headings on deep purple (large text only)', BRAND.gold, INK.purpleDeep, 3],
    ['white on deep purple', W, INK.purpleDeep, 4.5],
    ['purple ? on the white ? circle', BRAND.purple, W, 4.5],
    ['GIC pink text on the page', OPTION_TEXT.gic, INK.page, 4.5],
    ['GIC pink text on white', OPTION_TEXT.gic, W, 4.5],
    ['"up" on the page', MOVE.up, INK.page, 4.5],
    ['"down" on the page', MOVE.down, INK.page, 4.5],
    ['white on the purple button over gold', W, BRAND.purple, 4.5],
  ])('%s', (_name, fg, bg, min) => {
    expect(contrast(fg, bg)).toBeGreaterThanOrEqual(min);
  });
});

describe('coloured shapes (3 : 1 against white, by fill or by outline)', () => {
  it('the outline itself is strong enough', () => {
    expect(contrast(INK.outline, W)).toBeGreaterThanOrEqual(3);
  });
  it.each(Object.entries(OPTION))('%s', (_name, fill) => {
    const best = Math.max(contrast(fill, W), contrast(INK.outline, W));
    expect(best).toBeGreaterThanOrEqual(3);
  });
  it('the two light fills are flagged as needing the outline', () => {
    expect(contrast(OPTION.savings, W)).toBeLessThan(3);
    expect(contrast(OPTION.nasdaq100, W)).toBeLessThan(3);
  });
  it('up and down days are equally strong (a drop is as clear as a rise)', () => {
    const up = contrast(MOVE.up, W);
    const down = contrast(MOVE.down, W);
    expect(Math.abs(up - down)).toBeLessThan(0.5);
    expect(Math.min(up, down)).toBeGreaterThanOrEqual(4.5);
  });
});

// The savings gold must never be used for text: scan the stylesheets.
function cssFiles(dir: string): string[] {
  return readdirSync(dir).flatMap((f) => {
    const p = join(dir, f);
    return statSync(p).isDirectory() ? cssFiles(p) : p.endsWith('.css') ? [p] : [];
  });
}

describe('stylesheets', () => {
  it('never use the savings gold as a text colour', () => {
    const offenders: string[] = [];
    for (const file of cssFiles('src')) {
      readFileSync(file, 'utf8')
        .split('\n')
        .forEach((line, i) => {
          if (/^\s*color\s*:/.test(line) && /(--opt-savings|#e0a400)/i.test(line))
            offenders.push(`${file}:${i + 1}`);
        });
    }
    expect(offenders).toEqual([]);
  });

  it('theme.css uses the same option and move colours as colours.ts', () => {
    const css = readFileSync('src/styles/theme.css', 'utf8').toLowerCase();
    for (const [name, hex] of Object.entries({
      '--opt-savings': OPTION.savings,
      '--opt-gic': OPTION.gic,
      '--opt-gic-text': OPTION_TEXT.gic,
      '--bb-up': MOVE.up,
      '--bb-down': MOVE.down,
      '--bb-outline': INK.outline,
      '--bb-ink': INK.ink,
      '--bb-ink-soft': INK.inkSoft,
    }))
      expect(css).toContain(`${name}: ${hex.toLowerCase()};`);
  });
});
