// The screen-size rule (CLAUDE.md): every screen works from 360 px phones to
// desktop, portrait and landscape, foldables included, and with large text.
// Nothing may spill sideways, be cut off or overlap, and every button is at
// least 44 px. Full-page screenshots go to test-results/layout/ for a look.
import { expect, test } from '@playwright/test';
import { LocalDb } from '../scripts/timemachine/db.ts';
import { kid, kidSignIn, parentSignIn } from './helpers';
import { check, SIZES, TEXT } from './layoutCheck';

/** Wren's account id: the demo kid who hasn't started, for her welcome screens. */
async function wrenAccount(): Promise<string> {
  const db = await LocalDb.connect();
  try {
    const [r] = await db.q<{ id: string }>(
      `select account_id::text as id from public.profiles where username = 'demo_wren'`,
    );
    return r.id;
  } finally {
    await db.close();
  }
}

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

/** Robin's latest deposit line, for Fix a mistake (a reduction can't take more than its line). */
async function robinDepositKey(): Promise<string> {
  const db = await LocalDb.connect();
  try {
    const [r] = await db.q<{ k: string }>(
      `select posting_key as k from public.transactions
        where account_id = (select account_id from public.profiles where username = 'demo_robin')
          and type = 'deposit' order by effective_at desc limit 1`,
    );
    return r.k;
  } finally {
    await db.close();
  }
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

      // Fix a mistake: a reduction previewed, then at its extra check (nothing is saved).
      const robinId = await robinAccount();
      await page.goto(
        `./parent/fix/${robinId}?line=${encodeURIComponent(await robinDepositKey())}`,
      );
      await page.getByLabel('Take from her savings').check();
      await page.getByLabel('Amount in dollars').fill('2.5');
      await page.getByLabel('Note she will read (required)').fill('That was counted twice');
      await expect(page.locator('.set__notice')).toBeVisible();
      await check(page, `parent-fix-${size.name}-${text.name}`, text.scale);
      await page.getByRole('button', { name: 'Next: check the amount' }).click();
      await expect(page.locator('.fix__big')).toBeVisible();
      await check(page, `parent-fix-check-${size.name}-${text.name}`, text.scale);

      // Onboarding, as Wren sees it (through View as, so nothing is signed): the
      // welcome, a tour card with the rates, and the whole agreement.
      const wren = await wrenAccount();
      await page.goto(`./parent/view/${wren}`);
      await expect(page.getByText("Let's set up your Big Bucks with Dad.")).toBeVisible();
      await check(page, `onboarding-home-banner-${size.name}-${text.name}`, text.scale);
      await page.goto(`./parent/view/${wren}/welcome`);
      await expect(page.locator('.welcome__steps')).toBeVisible();
      await check(page, `onboarding-welcome-${size.name}-${text.name}`, text.scale);
      await page.getByRole('button', { name: "Let's get started" }).click();
      await page.getByRole('button', { name: 'Next' }).click();
      await expect(
        page.getByRole('heading', { name: 'Three ways to grow your money' }),
      ).toBeVisible();
      await check(page, `onboarding-tour-${size.name}-${text.name}`, text.scale);
      await page.goto(`./parent/view/${wren}/welcome?step=agreement`);
      await expect(page.locator('.agree__rule')).toHaveCount(15);
      await check(page, `onboarding-agreement-${size.name}-${text.name}`, text.scale);

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
