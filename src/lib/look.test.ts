// Stage 10: her colours, animals and accessories. Every colour keeps text readable,
// the lists match the database's (which refuses anything else), and every picture
// the app shows is really in public/avatars.

import { existsSync, readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { describe, expect, it } from 'vitest';
import { contrast } from './colours';
import {
  ACCESSORIES,
  accessoryCorners,
  accessoryScale,
  ANIMALS,
  DEFAULT_THEME,
  INNER,
  placeAccessory,
  THEMES,
  themeContrasts,
  themeOf,
} from './look';

const migration = readFileSync(
  resolve(__dirname, '../../supabase/migrations/20261028000000_badges.sql'),
  'utf8',
);
const sqlArray = (fn: string): string[] => {
  const body = migration.slice(migration.indexOf(`create function public.${fn}()`));
  const m = body.match(/select array\[([^\]]+)\]/);
  if (!m) throw new Error(`no array in ${fn}`);
  return [...m[1].matchAll(/'([^']+)'/g)].map((x) => x[1]);
};

describe('theme colours', () => {
  it('has eight, the brand purple first', () => {
    expect(THEMES).toHaveLength(8);
    expect(DEFAULT_THEME).toBe('#5B3FD1');
  });
  it.each(THEMES)(
    '$name: white text on it is at least 4.5 : 1 (AA, normal and large text)',
    (t) => {
      expect(themeContrasts(t.hex).onWhiteText).toBeGreaterThanOrEqual(4.5);
    },
  );
  it.each(THEMES)('$name: as text or a shape on the page, at least 4.5 : 1', (t) => {
    expect(themeContrasts(t.hex).onPage).toBeGreaterThanOrEqual(4.5);
  });
  it.each(THEMES)('$name: as text on white, at least 4.5 : 1 (links, the active tab)', (t) => {
    expect(contrast(t.hex, '#FFFFFF')).toBeGreaterThanOrEqual(4.5);
  });
  it.each(THEMES)('$name: the gold tagline on it is at least 4.5 : 1', (t) => {
    expect(contrast('#FFD166', t.hex)).toBeGreaterThanOrEqual(4.5);
  });
  it('matches the database list exactly (look_themes)', () => {
    expect(THEMES.map((t) => t.hex)).toEqual(sqlArray('look_themes'));
  });
  it('an unknown or missing colour falls back to the default', () => {
    expect(themeOf('#FF0000').hex).toBe(DEFAULT_THEME);
    expect(themeOf(null).hex).toBe(DEFAULT_THEME);
    expect(themeOf('#00695c').hex).toBe('#00695C');
  });
});

describe('animals and accessories', () => {
  it('has sixteen animals, the moose among them, matching look_animals', () => {
    expect(ANIMALS).toHaveLength(16);
    expect(ANIMALS.map((a) => a.key)).toContain('moose');
    expect(ANIMALS.map((a) => a.key)).toEqual(sqlArray('look_animals'));
  });
  it('has the six accessories the badges unlock, matching the database', () => {
    expect(ACCESSORIES.map((a) => a.key)).toEqual([
      'party_hat',
      'grad_cap',
      'sunglasses',
      'top_hat',
      'bow',
      'crown',
    ]);
    for (const a of ACCESSORIES) expect(migration).toContain(`'${a.key}'`);
  });
  it.each(ANIMALS)('$name has its picture', (a) => {
    expect(existsSync(resolve(__dirname, `../../public/avatars/animals/${a.key}.svg`))).toBe(true);
  });
  it.each(ACCESSORIES)('$name has its picture', (a) => {
    expect(existsSync(resolve(__dirname, `../../public/avatars/accessories/${a.key}.svg`))).toBe(
      true,
    );
  });
  it('ships the Fluent Emoji licence and the attribution', () => {
    expect(
      readFileSync(resolve(__dirname, '../../public/avatars/LICENSE-fluentui-emoji'), 'utf8'),
    ).toContain('MIT License');
    expect(
      readFileSync(resolve(__dirname, '../../public/avatars/ATTRIBUTION.md'), 'utf8'),
    ).toContain('Fluent Emoji');
  });
  it('every accessory sits over every animal, never far off its circle', () => {
    for (const an of ANIMALS)
      for (const acc of ACCESSORIES) {
        const p = placeAccessory(an, acc);
        expect(p.width).toBeGreaterThan(15);
        expect(p.left).toBeGreaterThanOrEqual(-15);
        expect(p.left + p.width).toBeLessThanOrEqual(115);
        expect(p.top).toBeGreaterThanOrEqual(-30);
        expect(p.top).toBeLessThan(100);
      }
  });
  it('the animal box in the code matches Avatar.css', () => {
    const css = readFileSync(resolve(__dirname, '../components/Avatar.css'), 'utf8');
    const inner = css.slice(css.indexOf('.avatar__inner {'));
    expect(inner.slice(0, inner.indexOf('}'))).toContain(`width: ${INNER * 100}%;`);
  });
  // Dad's sheet review: nothing may touch the circle's edge. Every corner of what you
  // see of each accessory, on each animal, stays inside the circle with a 3% margin.
  it('every accessory on every animal stays inside the circle, with a margin', () => {
    const outside: string[] = [];
    for (const an of ANIMALS)
      for (const acc of ACCESSORIES) {
        const worst = Math.max(
          ...accessoryCorners(an, acc).map(([x, y]) => Math.hypot(x - 0.5, y - 0.5)),
        );
        if (worst > 0.47) outside.push(`${an.key} + ${acc.key}: ${worst.toFixed(3)}`);
      }
    expect(outside).toEqual([]);
  });
  it('keeping inside the circle never makes an accessory tiny (70% of its size at least)', () => {
    for (const an of ANIMALS)
      for (const acc of ACCESSORIES) expect(accessoryScale(an, acc)).toBeGreaterThanOrEqual(0.7);
  });
  it('the moose, our mascot, wears everything at full size', () => {
    const moose = ANIMALS.find((a) => a.key === 'moose')!;
    for (const acc of ACCESSORIES) expect(accessoryScale(moose, acc)).toBe(1);
  });
});
