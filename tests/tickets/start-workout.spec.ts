import { test } from '../../fixtures/authenticated-page';
import { TicketsQueuePage } from '../../pages/tickets-queue.page';
import { mutatingTestsEnabled } from '../../utils/environment';

// RX2GO-TQ-003: changes ticket state, so it is opt-in.
test('RX2GO-TQ-003 Start Workout automatically takes a ticket into work', async ({ authenticatedPage }) => {
  test.skip(!mutatingTestsEnabled(), 'Set RUN_MUTATING_TESTS=true to allow ticket state changes');

  const tickets = new TicketsQueuePage(authenticatedPage);
  await tickets.open();
  await tickets.startWorkout();
  await tickets.expectWorkoutStarted();
});
