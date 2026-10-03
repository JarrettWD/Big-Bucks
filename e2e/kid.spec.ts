// Kid logins and the kid shell, against the LOCAL Supabase (demo data).
import { expect, test } from '@playwright/test';
import { kid, kidSignIn, logins, typePin } from './helpers';

test('a kid signs in with her username and PIN and sees her Home', async ({ page }) => {
  const robin = kid('Robin');
  await kidSignIn(page, robin.username, robin.pin);
  await expect(page).toHaveURL(/\/kid$/);
  await expect(page.getByText('Hi, Robin!')).toBeVisible();
  await expect(page.locator('.hero__amount')).toHaveText(/^\$[\d,]+\.\d\d$/); // her total worth
  const tabs = page.getByRole('navigation', { name: 'Main' });
  for (const name of ['Home', 'Graphs', 'Buy / Sell'])
    await expect(tabs.getByRole('link', { name })).toBeVisible();
  // The Wish List is switched on for test accounts only, and Robin's is a regular account.
  await expect(tabs.getByRole('link', { name: 'Wish List' })).toHaveCount(0);
  // (Other tests may read her notices at the same time, so the count can be anything.)
  await expect(page.getByRole('link', { name: /^Notices(, \d+ new)?$/ })).toBeVisible();

  // The "?" explains a money word from the glossary.
  await page.getByRole('button', { name: 'What does "Total worth" mean?' }).click();
  const card = page.getByRole('dialog', { name: 'Total worth' });
  await expect(card).toBeVisible();
  await card.getByRole('button', { name: 'Got it' }).click();
  await expect(page.getByRole('dialog')).toHaveCount(0);
});

test('a test kid sees the Wish List tab (switched on for test accounts)', async ({ page }) => {
  const sky = kid('Sky');
  await kidSignIn(page, sky.username, sky.pin);
  await expect(page.getByText('Hi, Sky!')).toBeVisible();
  await expect(
    page.getByRole('navigation', { name: 'Main' }).getByRole('link', { name: 'Wish List' }),
  ).toBeVisible();
});

test('the device remembers her, so next time she only enters her PIN; "Not you?" switches', async ({
  page,
}) => {
  const robin = kid('Robin');
  await kidSignIn(page, robin.username, robin.pin);
  await expect(page.getByText('Hi, Robin!')).toBeVisible();
  await page.getByRole('button', { name: 'Sign out' }).click();

  await expect(page.getByRole('heading', { name: 'Hi, Robin!' })).toBeVisible();
  await expect(page.getByLabel('Your username')).toHaveCount(0);
  await typePin(page, robin.pin);
  await expect(page).toHaveURL(/\/kid$/);
  await page.getByRole('button', { name: 'Sign out' }).click();

  await page.getByRole('button', { name: 'Not you?' }).click();
  await expect(page.getByLabel('Your username')).toBeVisible();
  await page.reload();
  await expect(page.getByLabel('Your username')).toBeVisible(); // forgotten for good
});

test('a wrong PIN gets a kind message', async ({ page }) => {
  const sky = kid('Sky');
  const wrong = sky.pin === '000000' ? '111111' : '000000';
  await kidSignIn(page, sky.username, wrong);
  await expect(page.getByRole('alert')).toHaveText("That PIN didn't match. Try again.");
  await typePin(page, sky.pin); // and she can still get in
  await expect(page).toHaveURL(/\/kid$/);
});

test('5 wrong PINs in a row lock the login for 15 minutes, even for the right PIN', async ({
  page,
}) => {
  const { lockoutKid } = logins();
  const wrong = lockoutKid.pin === '000000' ? '111111' : '000000';
  await kidSignIn(page, lockoutKid.username, wrong);
  await expect(page.getByRole('alert')).toHaveText("That PIN didn't match. Try again.");
  await typePin(page, wrong);
  await typePin(page, wrong);
  await expect(page.getByRole('alert')).toHaveText(
    "That PIN didn't match. 2 more tries before a 15-minute break.",
  );
  await typePin(page, wrong);
  await expect(page.getByRole('alert')).toHaveText(
    "That PIN didn't match. 1 more try before a 15-minute break.",
  );
  await typePin(page, wrong);
  await expect(page.getByRole('alert')).toHaveText(
    /^Too many tries in a row, so this login is taking a short break\. Try again in 15 minutes, or ask Dad for help\.$/,
  );
  await typePin(page, lockoutKid.pin);
  await expect(page.getByRole('alert')).toContainText('taking a short break');
  await expect(page).toHaveURL(/\/login$/);
});

test('a kid can never reach the parent screens', async ({ page }) => {
  const robin = kid('Robin');
  await kidSignIn(page, robin.username, robin.pin);
  await expect(page).toHaveURL(/\/kid$/);
  for (const path of ['./parent', './parent/settings', './parent/mfa', './parent/login']) {
    await page.goto(path);
    await expect(page).toHaveURL(/\/kid$/);
  }
});

test('the PIN door refuses the parent', async ({ page }) => {
  // The parent's username with any PIN is treated like an unknown username.
  await kidSignIn(page, 'demo_parent', '123456');
  await expect(page.getByRole('alert')).toHaveText("That PIN didn't match. Try again.");
});

test('signing out on one device leaves her other devices signed in', async ({ browser }) => {
  const robin = kid('Robin');
  const phone = await (await browser.newContext()).newPage();
  const tablet = await (await browser.newContext()).newPage();
  await kidSignIn(phone, robin.username, robin.pin);
  await kidSignIn(tablet, robin.username, robin.pin);
  await expect(phone).toHaveURL(/\/kid$/);
  await expect(tablet).toHaveURL(/\/kid$/);

  await tablet.getByRole('button', { name: 'Sign out' }).click();
  await expect(tablet).toHaveURL(/\/login$/);

  await phone.reload();
  await expect(phone.getByText('Hi, Robin!')).toBeVisible();
  await expect(phone).toHaveURL(/\/kid$/);
});
