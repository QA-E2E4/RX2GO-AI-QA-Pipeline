import { test, expect } from '../../fixtures/authenticated-page';
import { TicketsQueuePage } from '../../pages/tickets-queue.page';
import { mutatingTestsEnabled } from '../../utils/environment';

// RX2GO-TQ-004: first executable layer for Expiration minute.
// This checks that N can be saved. Timing/API verification will be added after
// we capture the actual backend request/response and stable ticket identifier.
test('RX2GO-TQ-004 Expiration minute accepts and saves configured value', async ({ authenticatedPage }) => {
  test.skip(!mutatingTestsEnabled(), 'Set RUN_MUTATING_TESTS=true to allow ticket state changes');

  const tickets = new TicketsQueuePage(authenticatedPage);
  await tickets.open();
  await tickets.startWorkout();
  await tickets.expectWorkoutStarted();

  await tickets.setExpirationMinutes(60);
  await tickets.saveTicket();

  const expiration = authenticatedPage
    .getByLabel(/expiration minute/i)
    .or(authenticatedPage.locator('input[name*="expiration" i]'))
    .first();

  await expect(expiration).toHaveValue('60');
});
