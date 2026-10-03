import { defineConfig, devices } from '@playwright/test';

// Smoke tests run against the production build served by `vite preview`.
export default defineConfig({
  testDir: './e2e',
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 1 : 0,
  reporter: 'list',
  use: {
    baseURL: 'http://localhost:4173/Big-Bucks/',
    trace: 'on-first-retry',
  },
  projects: [{ name: 'android-chrome', use: { ...devices['Pixel 7'] } }],
  webServer: {
    command: 'npm run build && npm run preview -- --port 4173 --strictPort',
    url: 'http://localhost:4173/Big-Bucks/',
    reuseExistingServer: !process.env.CI,
    timeout: 120_000,
  },
});
