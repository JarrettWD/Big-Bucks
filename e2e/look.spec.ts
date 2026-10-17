// "Make it yours" and badges (Stage 10) against the LOCAL Supabase (demo data). Sky is
// the demo's test account; both switches are on for test accounts only, and the demo
// already gave her First GIC (her July GIC). These change Sky's look and buy her three
// small GICs, so they run in order, after every other test:
//   - the sheet: every animal wearing every accessory, every picture loaded;
//   - she picks a colour, an animal and her party hat; the frame takes her colour,
//     the option colours don't change;
//   - her Badges screen: First GIC with its date, the rest "Still to discover";
//   - three GICs on three new dates: the GIC ladder arrives right after the purchase
//     (the app's own check, separate from the money call), with its notice;
//   - Dad's "View as" shows exactly her look and badges, and changes nothing;
//   - the picker and her badges fit every screen size, with large text too.
import { expect, test, type Page } from '@playwright/test';
import { LocalDb } from '../scripts/timemachine/db.ts';
import { kid, kidSignIn, parentSignIn } from './helpers';
import { check, SIZES, TEXT } from './layoutCheck';

test.describe.configure({ mode: 'serial' });

async function sql<T = Record<string, string>>(q: string): Promise<T[]> {
  const db = await LocalDb.connect();
  try {
    return (await db.q(q)) as T[];
  } finally {
    await db.close();
  }
}
const SKY = () =>
  `(select account_id from public.profiles where username = '${kid('Sky').username}')`;

async function signInSky(page: Page) {
  const sky = kid('Sky');
  await kidSignIn(page, sky.username, sky.pin);
  await expect(page.getByText('Hi, Sky!')).toBeVisible();
}

test('the sheet: every animal wears every accessory, and every picture loads', async ({ page }) => {
  await page.setViewportSize({ width: 1000, height: 800 });
  await page.goto('./avatar-sheet?size=96');
  await expect(page.getByRole('heading', { name: 'Avatars and accessories' })).toBeVisible();
  const imgs = page.locator('img');
  await expect(imgs).toHaveCount(16 * 7 + 16 * 6); // every animal in 7 cells, plus 6 accessories each
  await page.waitForFunction(() =>
    [...document.images].every((i) => i.complete && i.naturalWidth > 0),
  );
  await page.screenshot({ path: 'test-results/avatar-sheet.png', fullPage: true });
});

test('she makes it hers: a colour, an animal and the hat her first GIC unlocked', async ({
  page,
}) => {
  await signInSky(page);
  await page.getByRole('link', { name: '🎨 Make it yours' }).click();
  await expect(page.getByRole('heading', { name: 'Make it yours' })).toBeVisible();

  // Only the party hat is hers to wear; the rest say how to earn them.
  await expect(page.getByRole('button', { name: /Party hat/ })).not.toHaveAttribute(
    'aria-disabled',
    'true',
  );
  await expect(
    page.getByRole('button', { name: /Crown Reach your savings goal\./ }),
  ).toHaveAttribute('aria-disabled', 'true');

  await page.getByRole('button', { name: 'Navy' }).click();
  await page.getByRole('button', { name: 'Puppy' }).click();
  await page.getByRole('button', { name: /Party hat/ }).click();
  await page.getByRole('button', { name: 'Looks great!' }).click();
  await expect(page.getByText('Saved!')).toBeVisible();

  const [row] = await sql<{
    theme_colour: string;
    avatar_animal: string;
    avatar_accessory: string;
  }>(
    `select theme_colour, avatar_animal, avatar_accessory from public.accounts where id = ${SKY()}`,
  );
  expect(row).toEqual({
    theme_colour: '#0D47A1',
    avatar_animal: 'puppy',
    avatar_accessory: 'party_hat',
  });
  // Her frame takes Navy; the savings colour (fixed) doesn't.
  await expect(page.locator('.kid__top')).toHaveCSS('background-color', 'rgb(13, 71, 161)');
  await page.getByRole('navigation', { name: 'Main' }).getByRole('link', { name: 'Home' }).click();
  await expect(page.locator('.opt-icon').first()).not.toHaveCSS(
    'background-color',
    'rgb(13, 71, 161)',
  );
  await expect(page.getByRole('link', { name: 'Change your colour and animal' })).toBeVisible();
});

test('her badges: First GIC with its date, the rest still to discover', async ({ page }) => {
  await signInSky(page);
  await page.getByRole('link', { name: '🏅 Your badges' }).click();
  await expect(page.getByRole('heading', { name: /Your badges/ }).first()).toBeVisible();
  const earned = page.locator('section', {
    has: page.getByRole('heading', { name: 'Your badges', exact: true }),
  });
  await expect(earned.getByRole('heading', { name: /First GIC/ })).toBeVisible();
  await expect(earned.getByText(/^Earned /)).toHaveCount(1);
  await expect(earned.getByText('Wearing it ✓')).toBeVisible();
  const todo = page.locator('section', {
    has: page.getByRole('heading', { name: 'Still to discover' }),
  });
  await expect(todo.locator('li')).toHaveCount(5);
  await expect(todo).not.toContainText(/\d of \d|streak/i);
});

test('three GICs on new dates: the GIC ladder arrives right after the purchase', async ({
  page,
}) => {
  const before = await sql<{ n: string }>(
    `select count(*)::text as n from public.badges where account_id = ${SKY()} and badge = 'gic_ladder'`,
  );
  expect(before[0].n).toBe('0');
  await signInSky(page);
  await page
    .getByRole('navigation', { name: 'Main' })
    .getByRole('link', { name: 'Buy / Sell' })
    .click();
  for (const [i, months] of ['9 months', '1 year', '2 years'].entries()) {
    if (i > 0) await page.getByRole('button', { name: 'Make another move' }).click();
    await page.getByLabel('From').selectOption('savings');
    await page.getByLabel('To').selectOption('gic');
    await page.getByLabel('How much?').fill('10');
    await page.getByRole('button', { name: new RegExp(`^${months}`) }).click();
    await page.getByRole('button', { name: 'Next', exact: true }).click();
    await page.getByRole('button', { name: 'Yes, do it' }).click();
    await expect(page.getByRole('heading', { name: '🎉 Done!' })).toBeVisible();
  }
  // The app's own check after the purchase (never inside the money function) gave it.
  await expect
    .poll(
      async () =>
        (
          await sql<{ n: string }>(
            `select count(*)::text as n from public.badges where account_id = ${SKY()} and badge = 'gic_ladder'`,
          )
        )[0].n,
    )
    .toBe('1');
  const [n] = await sql<{ title: string; body: string }>(
    `select title, body from public.notifications where account_id = ${SKY()} and type = 'badge'
      and dedupe_key like 'badge:gic_ladder:%'`,
  );
  expect(n.title).toBe('🪜 Badge: GIC ladder!');
  expect(n.body).toContain('Your animal can wear a top hat now.');
  await page.goto('./kid/notices');
  await expect(page.getByText('🪜 Badge: GIC ladder!')).toBeVisible();
});

test('Dad\'s "View as" shows her look and badges exactly, and changes nothing', async ({
  page,
}) => {
  await parentSignIn(page);
  const [{ id }] = await sql<{ id: string }>(`select ${SKY()}::text as id`);
  await page.goto(`./parent/view/${id}/badges`);
  await expect(page.locator('.kid__top')).toHaveCSS('background-color', 'rgb(13, 71, 161)');
  await expect(page.getByRole('heading', { name: /GIC ladder/ })).toBeVisible();
  await expect(page.getByRole('button', { name: 'Wear it' })).toHaveCount(0);
  await page.goto(`./parent/view/${id}/look`);
  await expect(page.getByText('"View as" can\'t change anything.')).toBeVisible();
  await expect(page.getByRole('button', { name: 'Looks great!' })).toHaveCount(0);
  await page.goto('./parent');
  // Her card (Robin may have badges too, once Badges is on for everyone).
  await expect(
    page
      .locator('li', { hasText: 'Sky' })
      .locator('.dash__badges')
      .filter({ hasText: 'GIC ladder' }),
  ).toBeVisible();
});

for (const size of SIZES) {
  test(`the picker, her badges and Home fit at ${size.name} (${size.width}×${size.height}), normal and large text`, async ({
    page,
  }) => {
    test.setTimeout(120_000);
    await signInSky(page);
    await page.setViewportSize({ width: size.width, height: size.height });
    for (const text of TEXT) {
      for (const [path, name] of [
        ['./kid/look', 'look'],
        ['./kid/badges', 'badges'],
        ['./kid', 'home-me'],
      ] as const) {
        await page.goto(path);
        await page.waitForLoadState('networkidle');
        await check(page, `${name}-${size.name}-${text.name}`, text.scale);
      }
    }
  });
}
