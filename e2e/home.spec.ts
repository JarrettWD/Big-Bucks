import { test, expect } from '@playwright/test';

test('home screen shows the name and tagline', async ({ page }) => {
  await page.goto('./');
  await expect(page.getByRole('heading', { name: 'Big Bucks' })).toBeVisible();
  await expect(page.getByText('Watch your bucks grow.')).toBeVisible();
});

test('deep links load the app', async ({ page }) => {
  await page.goto('./some/deep/link');
  await expect(page.getByRole('heading', { name: 'Big Bucks' })).toBeVisible();
});
