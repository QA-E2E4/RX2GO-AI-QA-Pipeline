import { Page } from '@playwright/test';
import { browserTest as base } from './browser-page';
import { LoginPage } from '../pages/login.page';
import { requireCredentials } from '../utils/credentials';
import { getEnvironment, requiresGatewayAuthentication } from '../utils/environment';
import { enableAdmBasicAuthorization } from '../utils/http-basic-auth';

export const test = base.extend<{ authenticatedPage: Page }>({
  authenticatedPage: async ({ qaPage: page }, use, testInfo) => {
    const loginPage = new LoginPage(page);
    const credentials = requireCredentials();
    const environment = getEnvironment();
    const interactiveAdmFirstFactor =
      environment === 'ADM' &&
      process.env.RX2GO_INTERACTIVE_ADM_AUTH === 'true' &&
      !!process.env.RX2GO_CDP_ENDPOINT;

    console.log(`[AUTH] Environment: ${environment}`);
    console.log(`[AUTH] Application user loaded: ${credentials.application.login}`);

    // Persistent Chrome: if we are already inside Rx2GO and not on the
    // application login page, keep the authenticated session.
    const currentUrl = page.url();
    const alreadyInsideApplication =
      /^https?:\/\//i.test(currentUrl) &&
      !/\/login(?:[/?#]|$)/i.test(currentUrl) &&
      !/^about:blank$/i.test(currentUrl);

    if (
      process.env.RX2GO_CDP_ENDPOINT &&
      alreadyInsideApplication &&
      !interactiveAdmFirstFactor
    ) {
      console.log(`[AUTH] Reusing authenticated Chrome session: ${currentUrl}`);
      console.log('[AUTH] ADM first factor is NOT repeated.');
      console.log('[AUTH] Rx2GO application login is NOT repeated.');
      await use(page);
      return;
    }

    if (interactiveAdmFirstFactor) {
      console.log('[AUTH] ADM: native browser first-factor mode is ON.');
      console.log('[AUTH] ADM: Launcher auto-fill was requested for the Chrome HTTP Auth dialog.');
      console.log('[AUTH] ADM: waiting for the Rx2GO application login form after first factor.');

      await page.bringToFront().catch(() => undefined);

      // Chrome was started directly on https://adm.rx2go.ai/login by run-tests.ps1.
      // Do NOT navigate from Playwright and do NOT inject Authorization headers:
      // either action would suppress/bypass the browser-native first-factor dialog.
      const deadline = Date.now() + 180_000;
      let formVisible = false;
      let lastLogAt = 0;

      while (Date.now() < deadline) {
        formVisible = await loginPage.isLoginFormVisible(700);
        if (formVisible) {
          break;
        }

        const now = Date.now();
        if (now - lastLogAt > 5000) {
          console.log(
            `[AUTH] ADM: waiting for first-factor completion... current URL: ${page.url()}`
          );
          lastLogAt = now;
        }

        await page.waitForTimeout(300);
      }

      if (!formVisible) {
        await page.screenshot({
          path: testInfo.outputPath('adm-first-factor-timeout.png'),
          fullPage: true,
        }).catch(() => undefined);

        throw new Error(
          '[AUTH] ADM first factor was not completed within 180 seconds after Launcher auto-fill. ' +
          'Check the daily Telegram password entered in Launcher and retry.'
        );
      }

      console.log('[AUTH] ADM: first factor completed; Rx2GO application login form is visible.');
    } else if (requiresGatewayAuthentication()) {
      // Non-headed/managed ADM mode cannot rely on a human interacting with
      // browser chrome, so keep the header-based fallback for diagnostics/CI.
      console.log('[AUTH] ADM: non-interactive mode; applying HTTP Basic Authorization header.');

      await enableAdmBasicAuthorization(
        page.context(),
        credentials.gateway!.login,
        credentials.gateway!.password
      );

      await loginPage.openApplicationLogin();
      console.log(`[AUTH] ADM: application /login opened. URL: ${page.url()}`);
    } else {
      console.log(`[AUTH] ${environment}: daily gateway is skipped.`);
      await loginPage.openApplicationLogin();
    }

    const formVisible = await loginPage.waitForLoginForm(15_000);

    console.log(`[AUTH] Application login form visible: ${formVisible}`);
    console.log(`[AUTH] Login diagnostics: ${await loginPage.debugVisibleControls()}`);

    if (formVisible) {
      console.log(`[AUTH] Filling Rx2GO application login for "${credentials.application.login}"...`);
      await loginPage.loginApplication(
        credentials.application.login,
        credentials.application.password
      );
      console.log('[AUTH] Application authentication completed.');
    } else {
      await page.screenshot({
        path: testInfo.outputPath('login-form-not-found.png'),
        fullPage: true,
      }).catch(() => undefined);

      throw new Error(
        `[AUTH] Rx2GO application login form was not found after gateway authentication. ` +
        `${await loginPage.debugVisibleControls()}`
      );
    }

    if (/\/login(?:[/?#]|$)/i.test(new URL(page.url()).pathname)) {
      throw new Error(
        `[AUTH] Authentication did not leave /login. ${await loginPage.debugVisibleControls()}`
      );
    }

    console.log(`[AUTH] Authenticated page URL: ${page.url()}`);
    await use(page);
  },
});

export { expect } from '@playwright/test';

