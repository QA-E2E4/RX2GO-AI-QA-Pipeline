import { expect, Locator, Page } from '@playwright/test';
import { resolveBaseUrl, resolveLoginUrl } from '../utils/environment';

export class LoginPage {
  constructor(private readonly page: Page) {}

  async openGateway(): Promise<void> {
    const url = resolveBaseUrl();
    console.log(`[AUTH] Navigating to gateway URL: ${url}`);
    await this.page.goto(url, { waitUntil: 'domcontentloaded' });
  }

  async openApplicationLogin(): Promise<void> {
    const url = resolveLoginUrl();
    console.log(`[AUTH] Navigating to application login URL: ${url}`);
    await this.page.goto(url, { waitUntil: 'domcontentloaded' });
    await this.page.waitForLoadState('networkidle', { timeout: 5000 }).catch(() => undefined);
  }

  private async firstVisible(locator: Locator): Promise<Locator | null> {
    const count = await locator.count();
    for (let i = 0; i < count; i++) {
      const item = locator.nth(i);
      if (await item.isVisible().catch(() => false)) return item;
    }
    return null;
  }

  private async visibleLoginField(): Promise<Locator | null> {
    return this.firstVisible(
      this.page.locator(
        'input[name="login"], input[name="username"], input[name="email"], input[autocomplete="username"], input[type="email"], input[type="text"]'
      )
    );
  }

  private async visiblePasswordField(): Promise<Locator | null> {
    return this.firstVisible(
      this.page.locator(
        'input[name="password"], input[autocomplete="current-password"], input[type="password"]'
      )
    );
  }

  private async visibleSubmitButton(): Promise<Locator | null> {
    const candidates = this.page.locator('button, input[type="submit"]');
    const count = await candidates.count();

    for (let i = 0; i < count; i++) {
      const item = candidates.nth(i);
      if (!await item.isVisible().catch(() => false)) continue;

      const text = (
        (await item.innerText().catch(() => '')) ||
        (await item.getAttribute('value').catch(() => '')) ||
        ''
      ).trim();

      if (/^(log ?in|login|sign ?in|continue|submit|войти)$/i.test(text)) return item;
    }

    return null;
  }

  async waitForLoginForm(timeout = 15_000): Promise<boolean> {
    const deadline = Date.now() + timeout;

    while (Date.now() < deadline) {
      const login = await this.visibleLoginField();
      const password = await this.visiblePasswordField();

      if (login && password) return true;

      const path = new URL(this.page.url()).pathname;
      if (!/\/login(?:[/?#]|$)/i.test(path)) return false;

      await this.page.waitForTimeout(250);
    }

    return false;
  }

  async isLoginFormVisible(timeout = 1000): Promise<boolean> {
    const deadline = Date.now() + timeout;

    while (Date.now() < deadline) {
      if ((await this.visibleLoginField()) && (await this.visiblePasswordField())) return true;
      await this.page.waitForTimeout(150);
    }

    return false;
  }

  async debugVisibleControls(): Promise<string> {
    const inputs = await this.page.locator('input').count().catch(() => 0);
    const visibleInputs = await this.page.locator('input:visible').count().catch(() => 0);
    const visibleButtons = await this.page.locator('button:visible').count().catch(() => 0);
    return `URL=${this.page.url()} inputs=${inputs} visibleInputs=${visibleInputs} visibleButtons=${visibleButtons}`;
  }

  async loginApplication(login: string, password: string): Promise<void> {
    const loginField = await this.visibleLoginField();
    const passwordField = await this.visiblePasswordField();
    const submit = await this.visibleSubmitButton();

    if (!loginField || !passwordField) {
      throw new Error(`[AUTH] Login fields not found. ${await this.debugVisibleControls()}`);
    }
    if (!submit) {
      throw new Error(`[AUTH] Login button not found. ${await this.debugVisibleControls()}`);
    }

    console.log(`[AUTH] Filling username field with "${login}"`);
    await loginField.fill(login);

    console.log('[AUTH] Filling saved password field (value hidden)');
    await passwordField.fill(password);

    await expect(loginField).toHaveValue(login);

    const actualLength = (await passwordField.inputValue()).length;
    if (actualLength !== password.length) {
      throw new Error(
        `[AUTH] Password field length mismatch: expected ${password.length}, got ${actualLength}`
      );
    }

    console.log('[AUTH] Clicking Rx2GO Login button...');
    await submit.click();

    const deadline = Date.now() + 15_000;
    while (Date.now() < deadline) {
      const path = new URL(this.page.url()).pathname;
      if (!/\/login(?:[/?#]|$)/i.test(path)) {
        console.log(`[AUTH] Login redirect completed: ${this.page.url()}`);
        return;
      }
      await this.page.waitForTimeout(300);
    }

    throw new Error(`[AUTH] Rx2GO login did not leave /login. ${await this.debugVisibleControls()}`);
  }
}

