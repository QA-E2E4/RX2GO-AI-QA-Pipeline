import { chromium, test as base, Page } from '@playwright/test';

type BrowserFixtures = {
  qaPage: Page;
};

export const browserTest = base.extend<BrowserFixtures>({
  qaPage: async ({}, use) => {
    const endpoint = process.env.RX2GO_CDP_ENDPOINT;
    const headed = process.env.RX2GO_HEADED === 'true';

    if (endpoint) {
      console.log(`[BROWSER] Persistent Chrome / SAME SESSION: ${endpoint}`);

      const browser = await chromium.connectOverCDP(endpoint);
      const contexts = browser.contexts();

      if (contexts.length === 0) {
        throw new Error('[BROWSER] Persistent Chrome has no accessible context');
      }

      const context = contexts[0];
      const openPages = context.pages().filter(p => !p.isClosed());

      // ADM headed mode opens the real Rx2GO URL before Playwright attaches,
      // so that Chrome can display its native HTTP Basic Auth dialog.
      // Prefer that page over an incidental blank/new-tab page.
      let qaPage =
        openPages.find(p => /rx2go\.ai/i.test(p.url())) ??
        openPages[0];

      if (!qaPage) {
        qaPage = await context.newPage();
      }

      await qaPage.bringToFront().catch(() => undefined);
      await use(qaPage);

      // IMPORTANT:
      // Do not close page/context/browser here.
      // Playwright disconnects when the worker exits.
      // The real Google Chrome process remains open for manual QA inspection.
      return;
    }

    // Managed mode is used only when "Keep browser open" is disabled.
    const browser = await chromium.launch({
      channel: 'chrome',
      headless: !headed,
      args: headed ? ['--incognito', '--start-maximized'] : ['--incognito'],
    });

    const context = await browser.newContext({
      viewport: headed ? null : { width: 1280, height: 720 },
    });

    const qaPage = await context.newPage();

    try {
      await use(qaPage);
    } finally {
      await context.close().catch(() => undefined);
      await browser.close().catch(() => undefined);
    }
  },
});

