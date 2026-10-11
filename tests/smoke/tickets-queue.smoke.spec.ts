import { test, expect } from '../../fixtures/authenticated-page';
import { TicketsQueuePage } from '../../pages/tickets-queue.page';

// RX2GO-TQ-001: safe read-only smoke
// Purpose: verify that authenticated user can open Tickets Queue and UI is rendered.
test('RX2GO-TQ-001 Tickets Queue opens successfully', async ({ authenticatedPage }) => {
  const tickets = new TicketsQueuePage(authenticatedPage);

  const responsePromise = authenticatedPage.waitForResponse(
    response => response.url().includes('/tickets') && response.status() >= 400,
    { timeout: 5_000 }
  ).catch(() => null);

  await tickets.open();
  await tickets.expectLoaded();

  const badResponse = await responsePromise;
  expect(badResponse, 'No ticket-related HTTP 4xx/5xx should occur during queue load').toBeNull();
});

