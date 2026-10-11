import { BrowserContext } from '@playwright/test';

export async function enableAdmBasicAuthorization(
  context: BrowserContext,
  username: string,
  password: string
): Promise<void> {
  const token = Buffer.from(`${username}:${password}`, 'utf8').toString('base64');

  await context.setExtraHTTPHeaders({
    Authorization: `Basic ${token}`,
  });
}

export async function clearExtraAuthorization(context: BrowserContext): Promise<void> {
  await context.setExtraHTTPHeaders({});
}

