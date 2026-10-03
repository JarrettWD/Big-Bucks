// The app itself: where it starts, deep links, and the offline screen.
import { expect, test } from '@playwright/test';

test('a signed-out visit starts at the kid login', async ({ page }) => {
  await page.goto('./');
  await expect(page).toHaveURL(/\/login$/);
  await expect(page.getByRole('heading', { name: 'Big Bucks' })).toBeVisible();
  await expect(page.getByText('Watch your bucks grow.')).toBeVisible();
});

test('deep links load the app', async ({ page }) => {
  await page.goto('./some/deep/link');
  await expect(page.getByRole('heading', { name: 'Big Bucks' })).toBeVisible();
});

test('offline, the app says so instead of showing old numbers', async ({ page, context }) => {
  await page.goto('./login');
  await expect(page.getByLabel('Your username')).toBeVisible();
  await context.setOffline(true);
  await expect(page.getByRole('heading', { name: "You're offline" })).toBeVisible();
  await expect(page.getByLabel('Your username')).toHaveCount(0);
  await context.setOffline(false);
  await expect(page.getByLabel('Your username')).toBeVisible();
});

test('the manifest makes it installable as Big Bucks', async ({ request }) => {
  const res = await request.get('./manifest.webmanifest');
  expect(res.ok()).toBe(true);
  const m = await res.json();
  expect(m).toMatchObject({ name: 'Big Bucks', theme_color: '#5B3FD1', display: 'standalone' });
  expect(m.icons.some((i: { purpose?: string }) => i.purpose === 'maskable')).toBe(true);
});
