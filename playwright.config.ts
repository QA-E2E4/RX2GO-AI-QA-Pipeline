import 'dotenv/config';
import { defineConfig } from '@playwright/test';
import { resolveBaseUrl } from './utils/environment';

export default defineConfig({
  testDir: './tests',
  timeout: 45_000,
  expect: { timeout: 10_000 },
  fullyParallel: false,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 2 : 0,
  workers: process.env.CI ? 2 : 1,

  reporter: [
    ['list'],
    ['html', { outputFolder: 'playwright-report', open: 'never' }],
    ['json', { outputFile: 'reports/results.json' }],
    ['allure-playwright', { resultsDir: 'allure-results' }],
  ],

  use: {
    // Rx2GO web policy:
    // - installed branded Google Chrome
    // - fresh non-persistent Playwright BrowserContext for every test
    // - --incognito is also passed so headed runs visibly use Chrome Incognito
    channel: 'chrome',
    baseURL: resolveBaseUrl(),
    // Do not emulate a fixed 1280x720 Desktop Chrome viewport.
    // Use the real maximized Chrome window size on the QA workstation.
    viewport: null,
    launchOptions: {
      args: ['--incognito', '--start-maximized'],
    },
    trace: 'retain-on-failure',
    screenshot: 'only-on-failure',
    video: 'retain-on-failure',
    actionTimeout: 15_000,
    navigationTimeout: 30_000,
    ignoreHTTPSErrors: false,
  },

  projects: [
    {
      name: 'Google Chrome Incognito',
    },
  ],
});
