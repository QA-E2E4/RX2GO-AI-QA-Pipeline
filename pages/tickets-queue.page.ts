import { expect, Locator, Page } from '@playwright/test';
import { resolveTicketsQueueUrl } from '../utils/environment';

export class TicketsQueuePage {
  readonly startWorkoutButton: Locator;
  readonly myTicketsButton: Locator;
  readonly allTicketsButton: Locator;
  readonly finishAndNextButton: Locator;

  constructor(private readonly page: Page) {
    this.startWorkoutButton = page.getByRole('button', { name: /start workout/i }).first();
    this.myTicketsButton = page.getByRole('button', { name: /my tickets/i }).first();
    this.allTicketsButton = page.getByRole('button', { name: /all tickets/i }).first();
    this.finishAndNextButton = page.getByRole('button', { name: /finish\s*&?\s*next/i }).first();
  }

  async open(): Promise<void> {
    const url = resolveTicketsQueueUrl();
    console.log(`[NAV] Opening Tickets Queue: ${url}`);
    await this.page.goto(url, { waitUntil: 'domcontentloaded' });
  }

  async expectLoaded(): Promise<void> {
    await expect(this.page, 'Tickets Queue URL').toHaveURL(/\/tickets\/queue/i);

    const title = this.page
      .locator('h1#page-title:visible, h1.page-title:visible')
      .filter({ hasText: /Tickets Queue/i })
      .first();

    await expect(
      title,
      'Visible Tickets Queue page title should be rendered'
    ).toBeVisible({ timeout: 15_000 });
  }

  async switchToMyTickets(): Promise<void> {
    await expect(this.myTicketsButton).toBeVisible();
    await this.myTicketsButton.click();
  }

  async switchToAllTickets(): Promise<void> {
    await expect(this.allTicketsButton).toBeVisible();
    await this.allTicketsButton.click();
  }

  async startWorkout(): Promise<void> {
    await expect(this.startWorkoutButton).toBeVisible();
    await this.startWorkoutButton.click();
  }

  async expectWorkoutStarted(): Promise<void> {
    await expect(
      this.finishAndNextButton
        .or(this.page.getByText(/workout/i))
        .or(this.page.getByText(/resolved/i))
        .first(),
      'After Start Workout a ticket/workout state should be visible'
    ).toBeVisible();
  }

  async setExpirationMinutes(minutes: number): Promise<void> {
    const expiration = this.page
      .getByLabel(/expiration minute/i)
      .or(this.page.locator('input[name*="expiration" i]'))
      .first();
    await expect(expiration).toBeVisible();
    await expiration.fill(String(minutes));
  }

  async saveTicket(): Promise<void> {
    const save = this.page.getByRole('button', { name: /^save$/i }).first();
    await expect(save).toBeVisible();
    await save.click();
  }
}

