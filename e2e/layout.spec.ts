// The screen-size rule (CLAUDE.md): every screen works from 360 px phones to
// desktop, portrait and landscape, foldables included, and with large text.
// Nothing may spill sideways, be cut off or overlap, and every button is at
// least 44 px. Full-page screenshots go to test-results/layout/ for a look.
import { expect, test, type Page } from '@playwright/test';
import { kid, kidSignIn } from './helpers';

const SIZES = [
  { name: 'small-phone', width: 360, height: 780 },
  { name: 'galaxy-a17', width: 412, height: 915 },
  { name: 'foldable-open', width: 673, height: 841 },
  { name: 'tablet-portrait', width: 800, height: 1280 },
  { name: 'tablet-landscape', width: 1280, height: 800 },
  { name: 'desktop', width: 1440, height: 900 },
];
/** Android's large text: Chrome scales text sizes; here, 130%. */
const TEXT = [
  { name: 'normal', scale: 1 },
  { name: 'large-text', scale: 1.3 },
];

interface Problem {
  what: string;
  where: string;
}

/** Everything the rule forbids, measured in the page. */
async function layoutProblems(page: Page): Promise<Problem[]> {
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

    // Big enough to tap.
    for (const el of document.querySelectorAll('#root a, #root button')) {
      if (!visible(el)) continue;
      const r = el.getBoundingClientRect();
      if (r.height < 43.5 || r.width < 43.5)
        problems.push({
          what: `too small to tap (${Math.round(r.width)}×${Math.round(r.height)})`,
          where: label(el),
        });
    }
    return problems;
  });
}

async function check(page: Page, file: string, scale: number) {
  if (scale !== 1)
    await page.addStyleTag({ content: `html { font-size: ${scale * 100}% !important; }` });
  await page.waitForTimeout(150);
  expect(await layoutProblems(page), `layout problems on ${file}`).toEqual([]);
  await page.screenshot({ path: `test-results/layout/${file}.png`, fullPage: true });
}

for (const size of SIZES) {
  test(`kid screens fit at ${size.name} (${size.width}×${size.height}), normal and large text`, async ({
    page,
  }) => {
    test.setTimeout(90_000); // 3 screens × 2 text sizes, with full-page screenshots
    await page.setViewportSize({ width: size.width, height: size.height });
    const robin = kid('Robin');
    await kidSignIn(page, robin.username, robin.pin);
    await expect(page.locator('.home__activity .activity__row').first()).toBeVisible();
    // Her waiting GIC's choice screen (these tests run before any test changes the demo).
    const choose = await page
      .locator('a[href*="/kid/gic/"]')
      .first()
      .getAttribute('href', { timeout: 5_000 });
    expect(choose, 'Robin has a GIC waiting for her choice').toBeTruthy();

    for (const text of TEXT) {
      await page.goto('./kid');
      await expect(page.locator('.home__activity .activity__row').first()).toBeVisible();
      await check(page, `home-${size.name}-${text.name}`, text.scale);

      await page.goto('./kid/history');
      await expect(page.locator('.activity__row').first()).toBeVisible();
      await check(page, `history-${size.name}-${text.name}`, text.scale);

      await page.goto(choose!.replace(/^\/Big-Bucks\//, './'));
      await expect(page.getByRole('heading', { name: 'Your GIC grew!' })).toBeVisible();
      await check(page, `gic-choice-${size.name}-${text.name}`, text.scale);
    }
  });
}
