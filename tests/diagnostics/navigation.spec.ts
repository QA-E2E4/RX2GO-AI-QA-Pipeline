import { test, expect } from '../../fixtures/authenticated-page';
import { resolveTicketsQueueUrl } from '../../utils/environment';

test('RX2GO-NAV-001 correct environment URL is opened', async ({ authenticatedPage }) => {
  await authenticatedPage.goto(resolveTicketsQueueUrl(), { waitUntil: 'domcontentloaded' });
  await expect(authenticatedPage).toHaveURL(/\/tickets\/queue/i);
});
