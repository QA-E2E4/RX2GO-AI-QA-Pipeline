export type TestEnvironment = 'HOT' | 'ADM' | 'BRANCH';

export function getEnvironment(): TestEnvironment {
  const raw = (process.env.TEST_ENV || process.env.RX2GO_ENV || 'HOT').toUpperCase();
  if (raw === 'ADM') return 'ADM';
  if (raw === 'BRANCH') return 'BRANCH';
  return 'HOT';
}

export function resolveBaseUrl(environment: TestEnvironment = getEnvironment()): string {
  const configured = {
    HOT: process.env.HOT_BASE_URL,
    ADM: process.env.ADM_BASE_URL,
    BRANCH: process.env.BRANCH_BASE_URL,
  }[environment];

  if (configured?.trim()) {
    return configured.trim().replace(/\/$/, '');
  }

  switch (environment) {
    case 'ADM':
      return 'https://adm.rx2go.ai';
    case 'BRANCH':
      return 'https://sergey-tester.rx2go.ai';
    default:
      return 'https://hot.rx2go.ai';
  }
}

export function resolveLoginUrl(environment: TestEnvironment = getEnvironment()): string {
  return `${resolveBaseUrl(environment)}/login`;
}

export function resolveTicketsQueueUrl(environment: TestEnvironment = getEnvironment()): string {
  return `${resolveBaseUrl(environment)}/tickets/queue`;
}

export function requiresGatewayAuthentication(): boolean {
  return getEnvironment() === 'ADM';
}

export function mutatingTestsEnabled(): boolean {
  return /^(1|true|yes|on)$/i.test(process.env.RUN_MUTATING_TESTS?.trim() || '');
}

