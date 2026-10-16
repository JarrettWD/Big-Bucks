// The Wish List (Stage 9) against the LOCAL Supabase (demo data). Sky is the demo's
// test account, and the Wish List is on for test accounts only. These change Sky's
// wish list, so they run in order:
//   - she adds a wish with a link and a photo, then a second, and reorders them;
//   - a link shows only its site and opens outside the app;
//   - the list never carries photo bytes (each thumbnail loads on its own);
//   - a week later "Still want this?" makes one her goal, which Home shows;
//   - Remove moves a wish to her Done list;
//   - Dad marks "Got it", and nothing on her screens changes;
//   - the Wish List and Dad's Wish lists fit every screen size, with large text too.
import { expect, test, type Page } from '@playwright/test';
import { LocalDb } from '../scripts/timemachine/db.ts';
import { kid, kidSignIn, parentSignIn } from './helpers';
import { check, SIZES, TEXT } from './layoutCheck';

test.describe.configure({ mode: 'serial' });

const KITE = 'Blue kite (e2e)';
const TENT = 'Tent (e2e)';

async function sql<T = Record<string, string>>(q: string): Promise<T[]> {
  const db = await LocalDb.connect();
  try {
    return (await db.q(q)) as T[];
  } finally {
    await db.close();
  }
}

async function openWishList(page: Page) {
  const sky = kid('Sky');
  await kidSignIn(page, sky.username, sky.pin);
  await expect(page.getByText('Hi, Sky!')).toBeVisible();
  await page
    .getByRole('navigation', { name: 'Main' })
    .getByRole('link', { name: 'Wish List' })
    .click();
  await expect(page.getByRole('heading', { name: /Wish List/ })).toBeVisible();
}

const card = (page: Page, name: string) => page.locator('article.wish-card', { hasText: name });

test('she adds wishes with a link and a photo, and reorders them', async ({ page }) => {
  await openWishList(page);
  await expect(page.getByText('Mom and Dad can see your wish list.')).toBeVisible();

  await page.getByRole('button', { name: '+ Add a wish' }).click();
  await page.getByLabel('What is it?').fill(KITE);
  await page.getByLabel('About how much? (you can skip this)').fill('1,000');
  await page.getByRole('radio', { name: '4 stars' }).click();
  await page
    .getByLabel('A link to it (you can skip this)')
    .fill('https://www.kites.example.com/blue?ref=abc123');
  await page.locator('input[type=file]').setInputFiles('public/icons/icon-512.png');
  await expect(page.locator('.wish-form__preview')).toBeVisible({ timeout: 15_000 });
  await page.getByRole('button', { name: 'Add it' }).click();

  const kite = card(page, KITE);
  await expect(kite).toBeVisible();
  // Her progress, as the database works it out.
  const [p] = await sql<{ percent: number }>(
    `select public.wish_percent(b.total_worth_cents, 100000) as percent
       from public.account_balances b join public.profiles p on p.account_id = b.account_id
      where p.username = '${kid('Sky').username}'`,
  );
  await expect(kite.locator('.wish-card__line')).toHaveText(
    `You're ${p.percent}% of the way there.`,
  );
  await expect(kite.getByRole('progressbar')).toHaveAttribute('aria-valuenow', String(p.percent));
  // About $384 toward $1,000 at 2% would take far more than 5 years: no date, the honest line.
  await expect(kite).toContainText('Interest alone would take more than 5 years.');
  // The link: only its site, opening outside Big Bucks; never the link itself.
  await expect(kite.locator('.wish__site')).toHaveText('kites.example.com');
  await expect(kite).not.toContainText('ref=abc123');
  const open = kite.getByRole('link', { name: /Open link/ });
  await expect(open).toHaveAttribute('target', '_blank');
  await expect(open).toHaveAttribute('rel', /noopener/);
  await expect(kite).toContainText('This opens outside Big Bucks.');
  // Its photo, shrunk on the phone: a JPEG of at most 150 KB, thumbnail at most 20 KB.
  await expect(kite.locator('.wish-photo img')).toBeVisible();
  const [sizes] = await sql<{ photo: number; thumb: number; jpeg: boolean }>(
    `select octet_length(ph.photo) as photo, octet_length(ph.thumb) as thumb,
            substring(ph.photo from 1 for 3) = '\\xffd8ff'::bytea as jpeg
       from public.wishlist_photos ph join public.wishlist_items w on w.id = ph.wishlist_item_id
      where w.name = '${KITE}'`,
  );
  expect(sizes.jpeg).toBe(true);
  expect(sizes.photo).toBeLessThanOrEqual(153600);
  expect(sizes.thumb).toBeLessThanOrEqual(20480);
  // Not a goal on day 0.
  await expect(kite.getByRole('button', { name: /Make it my goal/ })).toHaveCount(0);
  await expect(kite.locator('.wish__wait')).toContainText('Still want this on');

  await page.getByRole('button', { name: '+ Add a wish' }).click();
  await page.getByLabel('What is it?').fill(TENT);
  await page.getByLabel('About how much? (you can skip this)').fill('200');
  await page.getByRole('button', { name: 'Add it' }).click();
  await expect(card(page, TENT)).toBeVisible();

  const names = () => page.locator('article.wish-card h2').allInnerTexts();
  const before = await names();
  expect(before.indexOf(KITE)).toBeLessThan(before.indexOf(TENT));
  await page.getByRole('button', { name: `Move ${TENT} up` }).click();
  await expect.poll(async () => (await names()).indexOf(TENT)).toBe(before.indexOf(TENT) - 1);
  await page.reload();
  await expect.poll(async () => (await names()).indexOf(TENT)).toBe(before.indexOf(TENT) - 1);
});

test('the list carries no photo bytes; each thumbnail loads on its own', async ({ page }) => {
  const sky = kid('Sky');
  await kidSignIn(page, sky.username, sky.pin);
  const list = page.waitForResponse((r) => r.url().includes('/rpc/kid_wishlist'));
  const thumb = page.waitForResponse((r) => r.url().includes('/rpc/wish_photo'));
  await page
    .getByRole('navigation', { name: 'Main' })
    .getByRole('link', { name: 'Wish List' })
    .click();
  const body = await (await list).text();
  expect(body).not.toMatch(/\/9j\//); // a JPEG's base64 start
  expect(body.length).toBeLessThan(10_000);
  expect(JSON.parse((await thumb).request().postData() ?? '{}')).toMatchObject({ p_size: 'thumb' });
});

test('a week later, "Still want this?" makes it her goal, shown on Home', async ({ page }) => {
  // Pretend she added the kite a week ago (local copy only).
  await sql(`update public.wishlist_items set wait_from = wait_from - 7 where name = '${KITE}'`);
  await openWishList(page);
  const kite = card(page, KITE);
  await kite.getByRole('button', { name: /Make it my goal/ }).click();
  await expect(kite.getByText('Still want this?')).toBeVisible();
  await kite.getByRole('button', { name: 'Yes, make it my goal' }).click();
  await expect(card(page, KITE).getByText('Your goal')).toBeVisible();

  await page.getByRole('navigation', { name: 'Main' }).getByRole('link', { name: 'Home' }).click();
  const goal = page.locator('.home__goal');
  await expect(goal).toContainText(KITE);
  await expect(goal.getByRole('progressbar')).toBeVisible();
  await expect(goal).toContainText(/You're \d+% of the way there\./);
});

test('Remove moves a wish to her Done list', async ({ page }) => {
  await openWishList(page);
  await card(page, TENT).getByRole('button', { name: 'Remove' }).click();
  await page.getByRole('button', { name: 'Yes, remove it' }).click();
  await expect(card(page, TENT)).toHaveCount(0);
  await expect(page.locator('.wish-done__item', { hasText: TENT })).toContainText('Removed');
});

test('Dad marks "Got it" on his Wish lists, and her screens never show it', async ({
  page,
  browser,
}) => {
  await parentSignIn(page);
  await page.getByRole('link', { name: 'Wish lists' }).click();
  await expect(page.getByRole('heading', { name: 'Wish lists' })).toBeVisible();
  const item = page.locator('.pwish__item', { hasText: KITE });
  await item.getByRole('button', { name: 'Mark "Got it"' }).click();
  await item.getByLabel(/Note for the other parent/).fill('Mom bought it (e2e)');
  await item.getByRole('button', { name: 'Save "Got it"' }).click();
  await expect(item).toContainText('✓ Got it');
  await expect(item).toContainText('Mom bought it (e2e)');
  const [log] = await sql<{ n: string }>(
    `select count(*)::text as n from public.parent_actions where action = 'wishlist_mark' and summary like '%${KITE}%'`,
  );
  expect(Number(log.n)).toBeGreaterThan(0);

  // Her own app, in a fresh browser: nothing says it was bought.
  const kidPage = await (await browser.newContext()).newPage();
  const sky = kid('Sky');
  await kidSignIn(kidPage, sky.username, sky.pin);
  const list = kidPage.waitForResponse((r) => r.url().includes('/rpc/kid_wishlist'));
  await kidPage
    .getByRole('navigation', { name: 'Main' })
    .getByRole('link', { name: 'Wish List' })
    .click();
  const body = await (await list).text();
  expect(body).not.toContain('Mom bought');
  expect(body).not.toContain('marked');
  await expect(card(kidPage, KITE)).toBeVisible();
  await expect(kidPage.locator('#root')).not.toContainText('Mom bought');
  await expect(kidPage.locator('#root')).not.toContainText('✓ Got it');
});

test("the Wish List and Dad's Wish lists fit every screen, with large text too", async ({
  page,
  browser,
}) => {
  test.setTimeout(300_000);
  await openWishList(page);
  for (const size of SIZES) {
    await page.setViewportSize({ width: size.width, height: size.height });
    for (const text of TEXT) {
      await page.reload();
      await expect(card(page, KITE)).toBeVisible();
      await check(page, `wishlist-${size.name}-${text.name}`, text.scale);
    }
  }
  const dad = await (await browser.newContext()).newPage();
  await parentSignIn(dad);
  for (const size of SIZES) {
    await dad.setViewportSize({ width: size.width, height: size.height });
    for (const text of TEXT) {
      await dad.goto('./parent/wishlists');
      await expect(dad.locator('.pwish__item', { hasText: KITE })).toBeVisible();
      await check(dad, `parent-wishlists-${size.name}-${text.name}`, text.scale);
    }
  }
});
