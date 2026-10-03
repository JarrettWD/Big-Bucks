import { readFileSync } from 'node:fs';
import { expect, type Page } from '@playwright/test';
import { totp } from '../scripts/local/totp.ts';

export interface Logins {
  demo: {
    parent: { email: string; password: string; totpSecret: string };
    kids: { username: string; pin: string; displayName: string; isTest: boolean }[];
  };
  lockoutKid: { username: string; pin: string };
  newParent: { email: string; password: string };
}

export function logins(): Logins {
  const demo = JSON.parse(readFileSync('.demo-logins.local', 'utf8'));
  const e2e = JSON.parse(readFileSync('.e2e-logins.local', 'utf8'));
  return { demo, ...e2e };
}

export const kid = (name: 'Robin' | 'Sky') =>
  logins().demo.kids.find((k) => k.displayName === name)!;

/** Types a PIN on the keypad. */
export async function typePin(page: Page, pin: string): Promise<void> {
  for (const d of pin) await page.getByRole('button', { name: d, exact: true }).click();
}

/** The kid login from scratch: username, then PIN. */
export async function kidSignIn(page: Page, username: string, pin: string): Promise<void> {
  await page.goto('./login');
  await page.getByLabel('Your username').fill(username);
  await page.getByRole('button', { name: 'Next' }).click();
  await typePin(page, pin);
}

/** Parent email and password (the first step only). */
export async function parentPassword(page: Page, email: string, password: string): Promise<void> {
  await page.goto('./parent/login');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(password);
  await page.getByRole('button', { name: 'Next' }).click();
  await expect(page).toHaveURL(/\/parent\/mfa$/);
}

/** An authenticator code that won't change in the next few seconds. */
export async function freshCode(secret: string): Promise<string> {
  const left = 30 - Math.floor((Date.now() / 1000) % 30);
  if (left < 5) await new Promise((r) => setTimeout(r, left * 1000 + 500));
  return totp(secret);
}
