import { expect } from '@playwright/test';
import { test } from '../../fixtures/authenticated-page';
import { getEnvironment } from '../../utils/environment';

test('bootstrap one persistent authenticated Rx2GO browser session', async ({
  authenticatedPage: page,
}) => {
  test.setTimeout(180_000);

  const environment = getEnvironment();
  const expectedHost =
    environment === 'ADM'
      ? 'adm.rx2go.ai'
      : environment === 'BRANCH'
        ? 'sergey-tester.rx2go.ai'
        : 'hot.rx2go.ai';

  await page.waitForLoadState('domcontentloaded').catch(() => undefined);

  const url = page.url();
  console.log(`[BOOTSTRAP] Environment: ${environment}`);
  console.log(`[BOOTSTRAP] Authenticated URL: ${url}`);

  expect(
    new URL(url).host,
    `Browser bootstrap must end inside ${expectedHost}`
  ).toBe(expectedHost);

  expect(
    new URL(url).pathname,
    'Browser bootstrap must leave the application login page'
  ).not.toMatch(/^\/login(?:\/|$)/i);

  console.log('[BOOTSTRAP] Persistent authenticated Chrome is ready for MCP.');
});

