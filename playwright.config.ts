import { defineConfig, devices } from '@playwright/test';

// Smoke tests run against the production build served by `vite preview`, talking
// to the LOCAL Supabase only. Global setup reloads the demo first (this resets the
// local database and gives the demo logins new PINs).
export default defineConfig({
  testDir: './e2e',
  globalSetup: './e2e/global-setup.ts',
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 1 : 0,
  reporter: 'list',
  use: {
    baseURL: 'http://127.0.0.1:4173/Big-Bucks/',
    trace: 'on-first-retry',
  },
  projects: [
    // The screen-size checks and the Graphs tests run first, while the demo is
    // untouched (Robin's GIC is still waiting for her choice); they only read. The
    // other tests change demo data.
    {
      name: 'layout',
      testMatch: /(layout|graphs|dashboard|viewas).spec.ts/,
      use: { ...devices['Pixel 7'] },
    },
    {
      name: 'android-chrome',
      testIgnore:
        /(layout|graphs|dashboard|viewas|approvals|settings|fix|onboarding|nightly|look|learn).spec.ts/,
      dependencies: ['layout'],
      use: { ...devices['Pixel 7'] },
    },
    // Dad's decisions change Robin's requests and balances, so they run after the
    // kid tests that read them.
    {
      name: 'parent-actions',
      testMatch: /approvals.spec.ts/,
      dependencies: ['android-chrome'],
      use: { ...devices['Pixel 7'] },
    },
    // Settings changes rates and the cap, which the tests above read, and adds
    // notices and log rows that the Approvals tests count. So it runs last.
    {
      name: 'parent-settings',
      testMatch: /settings.spec.ts/,
      dependencies: ['parent-actions'],
      use: { ...devices['Pixel 7'] },
    },
    // Fix a mistake changes Robin's savings, which everything above reads.
    {
      name: 'parent-fix',
      testMatch: /fix.spec.ts/,
      dependencies: ['parent-settings'],
      use: { ...devices['Pixel 7'] },
    },
    // Onboarding signs Wren up and switches a feature on (What's new for everyone).
    {
      name: 'onboarding',
      testMatch: /onboarding.spec.ts/,
      dependencies: ['parent-fix'],
      use: { ...devices['Pixel 7'] },
    },
    // Stage 10: Sky's look, badges and three GICs (a GIC ladder). It changes her money.
    {
      name: 'look',
      testMatch: /look.spec.ts/,
      dependencies: ['onboarding'],
      use: { ...devices['Pixel 7'] },
    },
    // Stage 11: the learning features. It sells a little of Sky's fund and switches her view.
    {
      name: 'learn',
      testMatch: /learn.spec.ts/,
      dependencies: ['look'],
      use: { ...devices['Pixel 7'] },
    },
    // The nightly runs move the app clock forward about a week (into the next month near a
    // month's end, when interest is paid and a badge can be earned), so they run after
    // everything (2026-10-29: the badges test had run after them and met Sky's new badge).
    {
      name: 'nightly',
      testMatch: /nightly.spec.ts/,
      dependencies: ['learn'],
      use: { ...devices['Pixel 7'] },
    },
  ],
  webServer: {
    command: 'npm run env:local && npm run build && npm run preview',
    url: 'http://127.0.0.1:4173/Big-Bucks/',
    reuseExistingServer: !process.env.CI,
    timeout: 120_000,
  },
});
