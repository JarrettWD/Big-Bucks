// Kid Home against the LOCAL Supabase (demo data). These change Robin's data
// (a notice read, her waiting GIC renewed), so they run in order.
import { expect, test } from '@playwright/test';
import { LocalDb } from '../scripts/timemachine/db.ts';
import { formatCents } from '../src/lib/money.ts';
import { kid, kidSignIn } from './helpers';

test.describe.configure({ mode: 'serial' });

async function robinsBalances() {
  const db = await LocalDb.connect();
  try {
    const [b] = await db.q<Record<string, string>>(
      `select b.* from public.account_balances b join public.profiles p on p.account_id = b.account_id
        where p.username = 'demo_robin'`,
    );
    return b;
  } finally {
    await db.close();
  }
}

async function dbValue<T>(sql: string): Promise<T> {
  const db = await LocalDb.connect();
  try {
    return Object.values((await db.q(sql))[0] ?? {})[0] as T;
  } finally {
    await db.close();
  }
}

test('Home shows her money exactly as the database works it out', async ({ page }) => {
  const robin = kid('Robin');
  await kidSignIn(page, robin.username, robin.pin);
  const b = await robinsBalances();

  await expect(page.locator('.hero__amount')).toHaveText(formatCents(b.total_worth_cents));
  await expect(page.locator('.home__savings .card__amount')).toHaveText(
    formatCents(b.savings_cents),
  );
  await expect(page.locator('.home__gics .card__amount')).toHaveText(formatCents(b.gic_cents));
  await expect(page.locator('.home__funds .card__amount')).toHaveText(
    formatCents(b.stock_value_cents),
  );

  // All three funds, each with its last market day in words.
  const funds = page.locator('.fund');
  await expect(funds).toHaveCount(3);
  for (const name of ['Dow Jones', 'Nasdaq-100', 'TSX'])
    await expect(funds.filter({ hasText: name })).toHaveCount(1);
  await expect(funds.locator('.move').first()).toHaveText(
    /^(▲ Up|▼ Down) \d+\.\d\d%$|^● No change$/,
  );
  await expect(page.getByRole('button', { name: 'What does "Daily change" mean?' })).toBeVisible();

  // Her mix adds up to 100%.
  const mix = await page.locator('.mix__legend li').allInnerTexts();
  expect(mix.map((t) => Number(t.match(/(\d+)%/)![1])).reduce((a, c) => a + c, 0)).toBe(100);

  // Her waiting GIC, with the date to choose by.
  await expect(page.getByText('Your GIC grew!')).toBeVisible();
  await expect(page.getByRole('link', { name: "Choose what's next" })).toBeVisible();

  // The last 5 lines of her history.
  await expect(page.locator('.home__activity .activity__row')).toHaveCount(5);
});

test('"Got it" marks a notice as read', async ({ page }) => {
  const robin = kid('Robin');
  await kidSignIn(page, robin.username, robin.pin);
  const before = Number(
    await dbValue<string>(
      `select count(*)::text from public.notifications n join public.profiles p on p.account_id = n.account_id
      where p.username = 'demo_robin' and n.read_at is null`,
    ),
  );
  await expect(page.getByRole('link', { name: `Notices, ${before} new` })).toBeVisible();
  await page
    .locator('.banner__card')
    .filter({ has: page.getByRole('button', { name: 'Got it' }) })
    .getByRole('button', { name: 'Got it' })
    .click();
  await expect(
    page.getByRole('link', { name: before - 1 ? `Notices, ${before - 1} new` : 'Notices' }),
  ).toBeVisible();
  const after = Number(
    await dbValue<string>(
      `select count(*)::text from public.notifications n join public.profiles p on p.account_id = n.account_id
      where p.username = 'demo_robin' and n.read_at is null`,
    ),
  );
  expect(after).toBe(before - 1);
});

test('"See all" shows her whole history', async ({ page }) => {
  const robin = kid('Robin');
  await kidSignIn(page, robin.username, robin.pin);
  await page.getByRole('link', { name: 'See all' }).click();
  await expect(page.getByRole('heading', { name: 'Your history' })).toBeVisible();
  const lines = Number(
    await dbValue<string>(
      `select count(*)::text from public.my_activity((select account_id from public.profiles where username = 'demo_robin'), 200)`,
    ),
  );
  await expect(page.locator('section[aria-labelledby="h-history"] .activity__row')).toHaveCount(
    Math.min(lines, 30),
  );
  await expect(page.getByText('Money in').last()).toBeVisible(); // her very first deposit
});

test('she renews her matured GIC, after a clear summary', async ({ page }) => {
  const robin = kid('Robin');
  await kidSignIn(page, robin.username, robin.pin);
  await page.getByRole('link', { name: "Choose what's next" }).click();

  await expect(page.getByRole('heading', { name: 'Your GIC grew!' })).toBeVisible();
  // What happens if she doesn't choose, in plain words.
  await expect(
    page.getByText(
      /If you don't choose by then, your \$[\d,.]+ moves to savings, where it's safe and still earning interest\./,
    ),
  ).toBeVisible();
  await expect(
    page.getByText(/Until you choose, it earns the savings rate \(\d+\.\d+% a year\)\./),
  ).toBeVisible();

  // A different length first, then back, then keep it growing.
  await page.getByRole('button', { name: /Try a different length/ }).click();
  await expect(page.getByRole('group', { name: /How long\?/ })).toBeVisible();
  await page.getByRole('button', { name: /1 year/ }).click();
  await expect(page.getByRole('heading', { name: /into a 1-year GIC at 5\.0%\?$/ })).toBeVisible();
  await page.getByRole('button', { name: 'Go back' }).click();
  await page.getByRole('button', { name: 'Go back' }).click();
  await page.getByRole('button', { name: /Keep it growing/ }).click();

  const gicId = Number(page.url().match(/gic\/(\d+)/)![1]);
  const [balance, interest] = await Promise.all([
    dbValue<string>(`select balance_cents::text from public.gic_positions where gic_id = ${gicId}`),
    dbValue<string>(
      `select public.gic_interest_cents(g.balance_cents, (public.rate_on('gic', g.term_months, public.app_today())).rate, g.term_months)::text
         from public.gic_positions g where g.gic_id = ${gicId}`,
    ),
  ]);
  await expect(
    page.getByRole('heading', { name: `Put ${formatCents(balance)} into a 1-month GIC at 2.5%?` }),
  ).toBeVisible();
  await expect(page.getByText(`It will earn ${formatCents(interest)} of interest.`)).toBeVisible();
  await page.getByRole('button', { name: 'Yes, do it' }).click();

  await expect(page.getByRole('heading', { name: 'Done!' })).toBeVisible();
  expect(
    await dbValue<string>(
      `select maturity_choice::text from public.gic_holdings where id = ${gicId}`,
    ),
  ).toBe('renew');
  expect(
    await dbValue<string>(
      `select count(*)::text from public.gic_holdings where renewed_from_id = ${gicId} and principal_cents = ${balance}`,
    ),
  ).toBe('1');

  await page.getByRole('link', { name: 'Back to Home' }).click();
  await expect(page.getByText('Your GIC grew!')).toHaveCount(0);
  await expect(page.locator('.activity__title').first()).toHaveText(
    'Renewed: a new 1-month GIC at 2.5%',
  );
});
