import { test, expect } from '../../fixtures/authenticated-page';

test('RX2GO-AUTH-001 application login succeeds', async ({ authenticatedPage }) => {
  await expect(authenticatedPage).not.toHaveURL(/\/login(?:[/?#]|$)/i);
});

