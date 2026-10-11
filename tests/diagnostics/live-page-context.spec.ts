import fs from 'node:fs';
import path from 'node:path';
import { expect, Page, Response } from '@playwright/test';
import { test } from '../../fixtures/authenticated-page';
import { TicketsQueuePage } from '../../pages/tickets-queue.page';

type NetworkItem = {
  method: string;
  status: number;
  url: string;
};

function safeUrl(raw: string): string {
  try {
    const url = new URL(raw);
    url.search = '';
    url.hash = '';
    return url.toString();
  } catch {
    return raw.split('?')[0];
  }
}

async function bestEffortFacility(page: Page, hint: string): Promise<string | null> {
  if (!/hawaii|гавай/i.test(hint)) {
    return null;
  }

  const facility = 'Hawaii';

  const select = page
    .getByLabel(/facility/i)
    .or(page.getByRole('combobox', { name: /facility/i }))
    .first();

  if (await select.isVisible().catch(() => false)) {
    try {
      await select.selectOption({ label: facility });
      return facility;
    } catch {
      try {
        await select.click();
        const option = page
          .getByRole('option', { name: facility, exact: true })
          .or(page.getByText(facility, { exact: true }))
          .last();
        if (await option.isVisible().catch(() => false)) {
          await option.click();
          return facility;
        }
      } catch {
        // Context capture must remain observational/best-effort.
      }
    }
  }

  return null;
}

async function openTarget(page: Page, target: string): Promise<void> {
  if (/tickets queue/i.test(target)) {
    const queue = new TicketsQueuePage(page);
    await queue.open();
    await queue.expectLoaded();
    return;
  }

  // For modules without a committed route helper, preserve the post-login page.
  // The captured controls/links allow Codex to reason from the actual UI rather
  // than inventing a route.
  await page.waitForLoadState('domcontentloaded').catch(() => undefined);
}

test('collect live Rx2GO page context for AI agents', async ({ authenticatedPage: page }) => {
  test.setTimeout(180_000);

  const output = process.env.RX2GO_CONTEXT_OUTPUT;
  expect(output, 'RX2GO_CONTEXT_OUTPUT must be set').toBeTruthy();

  const target = process.env.RX2GO_CONTEXT_TARGET || 'Unknown';
  const taskKey = process.env.RX2GO_CONTEXT_TASK || 'ADHOC';
  const hint = process.env.RX2GO_CONTEXT_HINT || '';

  const network: NetworkItem[] = [];
  const consoleErrors: string[] = [];
  const pageErrors: string[] = [];

  page.on('response', (response: Response) => {
    const request = response.request();
    const resourceType = request.resourceType();

    if (
      resourceType === 'xhr' ||
      resourceType === 'fetch' ||
      response.status() >= 400
    ) {
      network.push({
        method: request.method(),
        status: response.status(),
        url: safeUrl(response.url()),
      });
    }
  });

  page.on('console', message => {
    if (message.type() === 'error') {
      consoleErrors.push(message.text().slice(0, 1000));
    }
  });

  page.on('pageerror', error => {
    pageErrors.push(error.message.slice(0, 1000));
  });

  await openTarget(page, target);
  const selectedFacility = await bestEffortFacility(page, hint);

  await page.waitForTimeout(1200);

  const title = await page.title().catch(() => '');
  const visibleText = (await page.locator('body').innerText().catch(() => ''))
    .replace(/\s+\n/g, '\n')
    .slice(0, 30_000);

  let ariaSnapshot = '';
  try {
    ariaSnapshot = (await page.locator('body').ariaSnapshot()).slice(0, 35_000);
  } catch {
    ariaSnapshot = '';
  }

  const controls = await page.evaluate(() => {
    const items = Array.from(
      document.querySelectorAll(
        'button, input, select, textarea, a[href], [role], [data-testid]'
      )
    );

    return items
      .filter(element => {
        const node = element as HTMLElement;
        const style = window.getComputedStyle(node);
        const rect = node.getBoundingClientRect();
        return (
          style.visibility !== 'hidden' &&
          style.display !== 'none' &&
          rect.width > 0 &&
          rect.height > 0
        );
      })
      .slice(0, 500)
      .map(element => {
        const node = element as HTMLElement;
        const input = element as HTMLInputElement;

        const associatedLabel =
          element.id
            ? document.querySelector(`label[for="${CSS.escape(element.id)}"]`)?.textContent
            : '';

        return {
          tag: element.tagName.toLowerCase(),
          role: element.getAttribute('role') || '',
          text: (node.innerText || element.textContent || '').trim().slice(0, 300),
          ariaLabel: element.getAttribute('aria-label') || '',
          label: (associatedLabel || '').trim().slice(0, 300),
          name: element.getAttribute('name') || '',
          placeholder: element.getAttribute('placeholder') || '',
          type: input.type || '',
          testId: element.getAttribute('data-testid') || '',
          href:
            element instanceof HTMLAnchorElement
              ? element.href.split('?')[0]
              : '',
          disabled:
            element instanceof HTMLButtonElement ||
            element instanceof HTMLInputElement ||
            element instanceof HTMLSelectElement ||
            element instanceof HTMLTextAreaElement
              ? element.disabled
              : false,
        };
      });
  });

  const body = {
    capturedAt: new Date().toISOString(),
    taskKey,
    target,
    selectedFacility,
    url: page.url(),
    title,
    visibleText,
    ariaSnapshot,
    controls,
    network: network.slice(-250),
    consoleErrors,
    pageErrors,
    notes: [
      'This file is captured from the real authenticated Rx2GO browser page.',
      'No passwords, cookies, auth headers, input values or request bodies are collected.',
      'Agents must prefer this evidence over invented controls/selectors/routes.',
    ],
  };

  fs.mkdirSync(path.dirname(output!), { recursive: true });
  fs.writeFileSync(output!, JSON.stringify(body, null, 2), 'utf8');

  const screenshot = output!.replace(/\.json$/i, '.png');
  await page.screenshot({ path: screenshot, fullPage: true }).catch(() => undefined);

  console.log(`[CONTEXT] Saved live browser context: ${output}`);
  console.log(`[CONTEXT] Current page: ${page.url()}`);
  console.log(`[CONTEXT] Visible controls captured: ${controls.length}`);
  console.log(`[CONTEXT] Network observations captured: ${network.length}`);
});

