import { mkdirSync, readFileSync, rmSync, statSync } from 'node:fs';
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

export const kid = (name: 'Robin' | 'Sky' | 'Wren') =>
  logins().demo.kids.find((k) => k.displayName === name)!;

/**
 * Types a PIN on the keypad, then waits for the login to answer: either the app
 * moves on, or the keypad is ready again with a message. With several tests
 * signing in at once, the local login function can take a few seconds.
 */
export async function typePin(page: Page, pin: string): Promise<void> {
  for (const d of pin) await page.getByRole('button', { name: d, exact: true }).click();
  await page.waitForFunction(
    () =>
      !location.pathname.endsWith('/login') ||
      document.querySelector('.kid-login__pad button:disabled') === null,
    null,
    { timeout: 20_000 },
  );
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

/**
 * One parent sign-in at a time, across all test workers. When one sign-in finishes
 * the code step, Supabase ends the parent's other half-finished sign-ins, so
 * overlapping sign-ins as the same parent would knock each other out. A lock
 * directory is atomic to create; a lock older than 60 seconds is left over from a
 * crashed run and is cleared.
 */
const LOCK = 'test-results/.parent-signin.lock';
async function withSignInLock<T>(run: () => Promise<T>): Promise<T> {
  mkdirSync('test-results', { recursive: true });
  for (;;) {
    try {
      mkdirSync(LOCK);
      break;
    } catch {
      try {
        if (Date.now() - statSync(LOCK).mtimeMs > 60_000)
          rmSync(LOCK, { recursive: true, force: true });
      } catch {
        // gone already
      }
      await new Promise((r) => setTimeout(r, 200 + Math.floor(Math.random() * 300)));
    }
  }
  try {
    return await run();
  } finally {
    rmSync(LOCK, { recursive: true, force: true });
  }
}

/** The demo parent, all the way in: password, then the authenticator code. */
export async function parentSignIn(page: Page): Promise<void> {
  const { parent } = logins().demo;
  await withSignInLock(async () => {
    await parentPassword(page, parent.email, parent.password);
    await page.getByLabel('6-digit code').fill(await freshCode(parent.totpSecret));
    await page.getByRole('button', { name: 'Sign in' }).click();
    await expect(page.getByRole('heading', { name: 'Dashboard' })).toBeVisible({ timeout: 15_000 });
  });
}

/** An authenticator code that won't change in the next few seconds. */
export async function freshCode(secret: string): Promise<string> {
  const left = 30 - Math.floor((Date.now() / 1000) % 30);
  if (left < 5) await new Promise((r) => setTimeout(r, left * 1000 + 500));
  return totp(secret);
}
