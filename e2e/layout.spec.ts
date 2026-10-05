// The screen-size rule (CLAUDE.md): every screen works from 360 px phones to
// desktop, portrait and landscape, foldables included, and with large text.
// Nothing may spill sideways, be cut off or overlap, and every button is at
// least 44 px. Full-page screenshots go to test-results/layout/ for a look.
import { expect, test, type Page } from '@playwright/test';
import { LocalDb } from '../scripts/timemachine/db.ts';
import { kid, kidSignIn, parentSignIn } from './helpers';

/** Robin's account id, for "View as Robin". */
async function robinAccount(): Promise<string> {
  const db = await LocalDb.connect();
  try {
    const [r] = await db.q<{ id: string }>(
      `select account_id::text as id from public.profiles where username = 'demo_robin'`,
    );
    return r.id;
  } finally {
    await db.close();
  }
}

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
    test.setTimeout(480_000); // 17 screens × 2 text sizes, with full-page screenshots
    await page.setViewportSize({ width: size.width, height: size.height });
    // The kid login, first (a new device: the username step).
    for (const text of TEXT) {
      await page.goto('./login');
      await expect(page.getByLabel('Your username')).toBeVisible();
      await check(page, `login-${size.name}-${text.name}`, text.scale);
    }
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

      // A history line opened: its working, and the "Something looks wrong?" form.
      await page.locator('.activity__row', { hasText: 'Savings interest' }).first().click();
      await expect(page.getByText('How was this calculated?')).toBeVisible();
      await page.getByRole('button', { name: 'Something looks wrong?' }).click();
      await check(page, `history-open-${size.name}-${text.name}`, text.scale);

      // The notices list. Marking them read is blocked here, so Robin's notices stay
      // new for the Home tests that run after these.
      await page.route('**/rest/v1/rpc/mark_notices_read', (r) =>
        r.fulfill({ status: 200, contentType: 'application/json', body: '0' }),
      );
      await page.goto('./kid/notices');
      await expect(page.locator('.notice').first()).toBeVisible();
      await check(page, `notices-${size.name}-${text.name}`, text.scale);
      await page.unroute('**/rest/v1/rpc/mark_notices_read');

      await page.goto(choose!.replace(/^\/Big-Bucks\//, './'));
      await expect(page.getByRole('heading', { name: 'Your GIC grew!' })).toBeVisible();
      await check(page, `gic-choice-${size.name}-${text.name}`, text.scale);

      // Buy / Sell: as it opens, buying a GIC (every term with what it earns), and
      // breaking a GIC early (the warning). Nothing is submitted.
      await page.goto('./kid/trade');
      await expect(page.locator('.waiting, .trade__waiting .muted').first()).toBeVisible();
      await check(page, `trade-${size.name}-${text.name}`, text.scale);

      await page.getByLabel('From').selectOption('savings');
      await page.getByLabel('To').selectOption('gic');
      await page.getByLabel('How much?').fill('1234.56');
      await expect(page.locator('.term__earns').first()).toBeVisible();
      await page.locator('.term').nth(4).click();
      await check(page, `trade-gic-${size.name}-${text.name}`, text.scale);

      await page.getByRole('button', { name: 'Sell', exact: true }).click();
      const gic = await page
        .getByLabel('From')
        .locator('option[value^="gic:"]')
        .first()
        .getAttribute('value');
      await page.getByLabel('From').selectOption(gic!);
      await expect(page.locator('.trade__warnings li.is-caution')).toBeVisible();
      await check(page, `trade-break-${size.name}-${text.name}`, text.scale);

      // Graphs: all six, the growth graph in dollars with its table open, and a fund
      // with its market-move note.
      for (const g of ['worth', 'growth', 'money', 'mix', 'gics', 'funds']) {
        await page.goto(`./kid/graphs?g=${g}`);
        await expect(page.locator('.graph__figure, .ladder, .mix').first()).toBeVisible();
        await check(page, `graphs-${g}-${size.name}-${text.name}`, text.scale);
      }
      await page.goto('./kid/graphs?g=growth');
      await page.getByRole('button', { name: 'Dollars' }).click();
      await page.getByRole('button', { name: 'Show as a table' }).click();
      await expect(page.locator('.gtable')).toBeVisible();
      await check(page, `graphs-growth-table-${size.name}-${text.name}`, text.scale);
      await page.goto('./kid/graphs?g=funds');
      await page.getByRole('button', { name: 'Nasdaq-100' }).click();
      await expect(page.locator('.notes-list')).toBeVisible();
      await check(page, `graphs-fund-note-${size.name}-${text.name}`, text.scale);
    }
  });
}

// Dad's screens: phone first (his main device), and his PC. Opening a confirmation
// only runs previews (always rolled back), so nothing changes.
for (const size of SIZES) {
  test(`parent screens fit at ${size.name} (${size.width}×${size.height}), normal and large text`, async ({
    page,
  }) => {
    test.setTimeout(480_000);
    await page.setViewportSize({ width: size.width, height: size.height });
    await parentSignIn(page);
    for (const text of TEXT) {
      await page.goto('./parent/approvals');
      await expect(page.locator('.appr__card').first()).toBeVisible();
      await check(page, `parent-approvals-${size.name}-${text.name}`, text.scale);

      // An approval confirmation with a note and its preview, and an answer being written.
      const withdrawal = page.locator('.appr__card', { hasText: 'Withdrawal $10.00' });
      await withdrawal.getByRole('button', { name: 'Approve' }).click();
      await withdrawal.getByLabel('Note to Robin (optional)').fill('Have fun at the fair');
      await expect(withdrawal.locator('.appr__notice')).toContainText('Have fun at the fair');
      await check(page, `parent-approve-${size.name}-${text.name}`, text.scale);
      const question = page.locator('.appr__card', { hasText: 'Why was my interest' });
      await question.getByRole('button', { name: 'Answer' }).click();
      await question
        .getByLabel('Your answer (Robin sees this)')
        .fill('The rate went down a little.');
      await expect(question.locator('.appr__notice')).toBeVisible();
      await check(page, `parent-answer-${size.name}-${text.name}`, text.scale);

      // The dashboard, with the folded test-account lists opened.
      await page.goto('./parent');
      await expect(page.locator('.dash__card').first()).toBeVisible();
      for (const fold of await page.locator('.dash__fold summary').all()) await fold.click();
      await check(page, `parent-dashboard-${size.name}-${text.name}`, text.scale);

      // Settings, with changes being previewed (nothing is saved): request expiry with
      // its history open, then a one-week special with its notices, with every
      // history and the glossary opened.
      await page.goto('./parent/settings');
      const expiry = page.getByRole('region', { name: 'Time to answer a request' });
      await expiry.getByRole('button', { name: 'Change' }).click();
      await expiry.getByLabel('Days to answer (3 to 30)').fill('12');
      await expect(expiry.locator('.set__notice')).toBeVisible();
      await expiry.locator('.set__history summary').click();
      await check(page, `parent-settings-${size.name}-${text.name}`, text.scale);
      const year = page.locator('.set__row', { hasText: '1-year GIC' });
      await year.getByRole('button', { name: 'Change the 1-year GIC rate' }).click();
      await year.getByLabel('New rate (% per year)').fill('6.5');
      await year.getByLabel('Limited-time special').check();
      await expect(year.locator('.set__notice')).toHaveCount(3);
      await page
        .locator('.set__history')
        .evaluateAll((all) => all.forEach((d) => ((d as HTMLDetailsElement).open = true)));
      await check(page, `parent-settings-rate-${size.name}-${text.name}`, text.scale);
      // Cancelling the demo's planned savings cut, previewed (nothing is saved).
      await page.goto('./parent/settings');
      const planned = page.locator('.set__planned').first();
      await planned.getByRole('button', { name: /^Cancel the change planned for/ }).click();
      await expect(planned.locator('.set__notice')).toBeVisible();
      await check(page, `parent-settings-cancel-${size.name}-${text.name}`, text.scale);

      // View as Robin: her Home, her history with a line open, her notices, her graphs.
      const robin = await robinAccount();
      await page.goto(`./parent/view/${robin}`);
      await expect(page.locator('.home__activity .activity__row').first()).toBeVisible();
      await check(page, `viewas-home-${size.name}-${text.name}`, text.scale);
      await page.goto(`./parent/view/${robin}/history`);
      await page.locator('.activity__row', { hasText: 'Savings interest' }).first().click();
      await expect(page.getByText('How was this calculated?').first()).toBeVisible();
      await check(page, `viewas-history-${size.name}-${text.name}`, text.scale);
      await page.goto(`./parent/view/${robin}/notices`);
      await expect(page.locator('.notice').first()).toBeVisible();
      await check(page, `viewas-notices-${size.name}-${text.name}`, text.scale);
      for (const g of ['worth', 'mix', 'funds']) {
        await page.goto(`./parent/view/${robin}/graphs?g=${g}`);
        await expect(page.locator('.graph__figure, .ladder, .mix').first()).toBeVisible();
        await check(page, `viewas-graphs-${g}-${size.name}-${text.name}`, text.scale);
      }
    }
  });
}
