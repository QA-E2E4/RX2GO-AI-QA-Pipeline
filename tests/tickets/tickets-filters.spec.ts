import { test, expect } from '../../fixtures/authenticated-page';
import { TicketsQueuePage } from '../../pages/tickets-queue.page';

// RX2GO-TQ-002: safe UI navigation test.
test('RX2GO-TQ-002 My Tickets / All Tickets switch is available', async ({ authenticatedPage }) => {
  const tickets = new TicketsQueuePage(authenticatedPage);
  await tickets.open();
  await tickets.expectLoaded();

  await expect(tickets.myTicketsButton).toBeVisible();
  await expect(tickets.allTicketsButton).toBeVisible();

  await tickets.switchToMyTickets();
  await tickets.switchToAllTickets();
});

