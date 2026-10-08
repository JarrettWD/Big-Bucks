// The screen-size rule's checker (CLAUDE.md), shared by layout.spec.ts and the
// stage tests that check their own screens at every size.
import { expect, type Page } from '@playwright/test';

export const SIZES = [
  { name: 'small-phone', width: 360, height: 780 },
  { name: 'galaxy-a17', width: 412, height: 915 },
  { name: 'foldable-open', width: 673, height: 841 },
  { name: 'tablet-portrait', width: 800, height: 1280 },
  { name: 'tablet-landscape', width: 1280, height: 800 },
  { name: 'desktop', width: 1440, height: 900 },
];
/** Android's large text: Chrome scales text sizes; here, 130%. */
export const TEXT = [
  { name: 'normal', scale: 1 },
  { name: 'large-text', scale: 1.3 },
];

interface Problem {
  what: string;
  where: string;
}

/** Everything the rule forbids, measured in the page. */
export async function layoutProblems(page: Page): Promise<Problem[]> {
  return page.evaluate(() => {
    const problems: { what: string; where: string }[] = [];
    const vw = document.documentElement.clientWidth;
    const label = (el: Element) =>
      `${el.tagName.toLowerCase()}.${[...el.classList].join('.')} "${(el.textContent ?? '').trim().slice(0, 40)}"`;
    const visible = (el: Element) => {
      const r = el.getBoundingClientRect();
      const s = getComputedStyle(el);
      return r.width > 0 && r.height > 0 && s.visibility !== 'hidden' && s.display !== 'none';
    };

    if (document.documentElement.scrollWidth > vw + 1)
      problems.push({
        what: 'the page scrolls sideways',
        where: `${document.documentElement.scrollWidth} > ${vw}`,
      });

    // Nothing sticks out past the right edge, and no text is clipped inside its box.
    for (const el of document.querySelectorAll('#root *')) {
      if (!visible(el) || el.closest('svg')) continue;
      const r = el.getBoundingClientRect();
      if (r.right > vw + 1)
        problems.push({ what: 'sticks out past the screen edge', where: label(el) });
      const s = getComputedStyle(el);
      if (
        ['hidden', 'clip'].includes(s.overflowX) &&
        el.scrollWidth > el.clientWidth + 1 &&
        el.childElementCount === 0
      )
        problems.push({ what: 'text cut off', where: label(el) });
    }

    // Things side by side must not overlap.
    const pairs: [string, string, string][] = [
      ['.fund', '.fund__text', '.move'],
      ['.activity__row', '.activity__text', '.activity__amount'],
      ['.gic__top', '.gic__amount', '.gic__terms'],
      ['.gic__ready', 'span', '.btn'],
      ['.kid__top', '.kid__hi', '.kid__bell'],
      ['.kid__top', '.kid__bell', '.kid__out'],
      ['.trade__pair', '.field', '.trade__arrow'],
      ['.waiting li', 'span', '.waiting__text'],
    ];
    const overlap = (a: DOMRect, b: DOMRect) =>
      a.left < b.right - 1 && b.left < a.right - 1 && a.top < b.bottom - 1 && b.top < a.bottom - 1;
    for (const [box, a, b] of pairs)
      for (const parent of document.querySelectorAll(box)) {
        const x = parent.querySelector(`:scope > ${a}`);
        const y = parent.querySelector(`:scope > ${b}`);
        if (
          x &&
          y &&
          visible(x) &&
          visible(y) &&
          overlap(x.getBoundingClientRect(), y.getBoundingClientRect())
        )
          problems.push({ what: 'overlaps', where: `${label(x)} and ${label(y)}` });
      }
    const tabs = [...document.querySelectorAll('.kid__tab')].map((t) => t.getBoundingClientRect());
    tabs.forEach((t, i) =>
      tabs
        .slice(i + 1)
        .forEach((u) => overlap(t, u) && problems.push({ what: 'tabs overlap', where: '' })),
    );

    // Big enough to tap. A hidden radio's target is its card (its label).
    const targets =
      '#root a, #root button, #root select, #root textarea, ' +
      '#root input:not([type=radio]):not([type=checkbox]), #root label:has(input[type=radio]), ' +
      '#root label:has(input[type=checkbox])';
    for (const el of document.querySelectorAll(targets)) {
      if (!visible(el)) continue;
      const r = el.getBoundingClientRect();
      if (r.height < 43.5 || r.width < 43.5)
        problems.push({
          what: `too small to tap (${Math.round(r.width)}×${Math.round(r.height)})`,
          where: label(el),
        });
    }

    // Every control has a name a screen reader can say.
    const text = (ids: string | null) =>
      (ids ?? '')
        .split(/\s+/)
        .map((id) => document.getElementById(id)?.textContent ?? '')
        .join(' ');
    for (const el of document.querySelectorAll(
      '#root button, #root a[href], #root input, #root select, #root textarea',
    )) {
      const field = el.matches('input, select, textarea');
      const name =
        el.getAttribute('aria-label') ||
        text(el.getAttribute('aria-labelledby')) ||
        (field
          ? [...((el as HTMLInputElement).labels ?? [])].map((l) => l.textContent).join(' ')
          : el.textContent) ||
        el.getAttribute('title') ||
        '';
      if (!name.trim()) problems.push({ what: 'has no name for screen readers', where: label(el) });
    }

    // Text is readable: 4.5 : 1 against what's behind it (3 : 1 for large text).
    // Checked on the real page, for every element with text of its own. Disabled
    // controls are exempt; text over a gradient (the total-worth panel) is checked
    // by the colour tests instead.
    const rgb = (c: string) => {
      const m = c.match(/rgba?\(([^)]+)\)/);
      if (!m) return null;
      const [r, g, b, a = 1] = m[1]
        .split(/[\s,/]+/)
        .filter(Boolean)
        .map(Number);
      return { r, g, b, a };
    };
    const lum = ({ r, g, b }: { r: number; g: number; b: number }) => {
      const ch = (v: number) => {
        const s = v / 255;
        return s <= 0.03928 ? s / 12.92 : ((s + 0.055) / 1.055) ** 2.4;
      };
      return 0.2126 * ch(r) + 0.7152 * ch(g) + 0.0722 * ch(b);
    };
    for (const el of document.querySelectorAll('#root *')) {
      const own = [...el.childNodes].some((n) => n.nodeType === 3 && n.textContent!.trim());
      if (!own || !visible(el) || el.closest('[aria-hidden="true"], svg, :disabled')) continue;
      let bg: { r: number; g: number; b: number; a: number } | null = null;
      let image = false;
      for (let e: Element | null = el; e; e = e.parentElement) {
        const s = getComputedStyle(e);
        if (s.backgroundImage !== 'none') {
          image = true;
          break;
        }
        const c = rgb(s.backgroundColor);
        if (c && c.a >= 0.99) {
          bg = c;
          break;
        }
      }
      if (image) continue;
      const s = getComputedStyle(el);
      const fg = rgb(s.color);
      if (!fg) continue;
      const back = bg ?? { r: 255, g: 255, b: 255, a: 1 };
      const [hi, lo] = [lum(fg), lum(back)].sort((x, y) => y - x);
      const ratio = (hi + 0.05) / (lo + 0.05);
      const px = parseFloat(s.fontSize);
      const large = px >= 24 || (px >= 18.66 && Number(s.fontWeight) >= 700);
      if (ratio < (large ? 3 : 4.5))
        problems.push({ what: `text contrast ${ratio.toFixed(2)} : 1`, where: label(el) });
    }
    return problems;
  });
}

export async function check(page: Page, file: string, scale: number) {
  if (scale !== 1)
    await page.addStyleTag({ content: `html { font-size: ${scale * 100}% !important; }` });
  await page.waitForTimeout(150);
  expect(await layoutProblems(page), `layout problems on ${file}`).toEqual([]);
  await page.screenshot({ path: `test-results/layout/${file}.png`, fullPage: true });
}
