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
    // The screen-size checks run first, while the demo is untouched (Robin's GIC
    // is still waiting for her choice); the other tests change demo data.
    { name: 'layout', testMatch: /layout.spec.ts/, use: { ...devices['Pixel 7'] } },
    {
      name: 'android-chrome',
      testIgnore: /layout.spec.ts/,
      dependencies: ['layout'],
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
