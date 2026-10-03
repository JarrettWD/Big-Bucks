// Parent sign-in with the authenticator step, against the LOCAL Supabase.
import { readFileSync } from 'node:fs';
import { expect, test } from '@playwright/test';
import { freshCode, logins, parentPassword } from './helpers';
import { totp } from '../scripts/local/totp.ts';

test('a new parent sets up the authenticator on first sign-in, then reaches the dashboard', async ({
  page,
}) => {
  const { newParent } = logins();
  await parentPassword(page, newParent.email, newParent.password);
  await expect(page.getByRole('heading', { name: 'Set up your authenticator' })).toBeVisible();
  await expect(page.getByRole('img', { name: 'QR code for your authenticator app' })).toBeVisible();
  const secret = (await page.getByTestId('totp-secret').textContent())!.trim();

  // A wrong code is refused.
  const wrong = totp(secret) === '000000' ? '111111' : '000000';
  await page.getByLabel('6-digit code').fill(wrong);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page.getByRole('alert')).toContainText("That code didn't work");

  await page.getByLabel('6-digit code').fill(await freshCode(secret));
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/parent$/);
  await expect(page.getByRole('heading', { name: 'Dashboard' })).toBeVisible();
  await expect(page.getByText('Sky')).toBeVisible();
});

test('the demo parent signs in with password and code', async ({ page }) => {
  const { parent } = logins().demo;
  await parentPassword(page, parent.email, parent.password);
  await expect(
    page.getByRole('heading', { name: 'Enter the code from your authenticator app' }),
  ).toBeVisible();
  await page.getByLabel('6-digit code').fill(await freshCode(parent.totpSecret));
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page.getByRole('heading', { name: 'Dashboard' })).toBeVisible();
  await expect(page.getByText('Robin')).toBeVisible();
  await expect(page.getByText('Sky (test account)')).toBeVisible();
});

test('without the authenticator code a parent is blocked, on screen and in the database', async ({
  page,
}) => {
  const { parent } = logins().demo;
  await parentPassword(page, parent.email, parent.password);

  for (const path of ['./parent', './parent/settings']) {
    await page.goto(path);
    await expect(page).toHaveURL(/\/parent\/mfa$/);
  }

  // Straight to the database with that password-only session: parent data and actions are refused.
  const token = await page.evaluate(
    () => JSON.parse(localStorage.getItem('bb.auth') ?? '{}').access_token,
  );
  expect(token).toBeTruthy();
  const anon = readFileSync('.env.local', 'utf8')
    .match(/^VITE_SUPABASE_ANON_KEY=(.*)$/m)![1]
    .trim();
  const headers = {
    apikey: anon,
    Authorization: `Bearer ${token}`,
    'Content-Type': 'application/json',
  };
  const rest = 'http://127.0.0.1:54321/rest/v1';

  const liability = await fetch(`${rest}/rpc/liability_total`, {
    method: 'POST',
    headers,
    body: '{}',
  });
  expect(liability.status).toBe(403);
  const approve = await fetch(`${rest}/rpc/approve_request`, {
    method: 'POST',
    headers,
    body: JSON.stringify({ p_request_id: 1 }),
  });
  expect(approve.status).toBe(403);
  expect(((await approve.json()) as { message: string }).message).toContain('authenticator code');
  // Row-level security shows a password-only parent nobody's accounts or alerts.
  expect(await (await fetch(`${rest}/accounts?select=id`, { headers })).json()).toEqual([]);
  expect(await (await fetch(`${rest}/alerts?select=id`, { headers })).json()).toEqual([]);
});
