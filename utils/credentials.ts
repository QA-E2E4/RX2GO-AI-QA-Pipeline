import { requiresGatewayAuthentication } from './environment';

export type GatewayCredentials = {
  login: string;
  password: string;
};

export type ApplicationCredentials = {
  login: string;
  password: string;
};

export type Rx2GoCredentials = {
  gateway?: GatewayCredentials;
  application: ApplicationCredentials;
};

export function requireCredentials(): Rx2GoCredentials {
  const applicationLogin = 'sergeyqa';
  const applicationPassword = process.env.RX2GO_APP_PASSWORD;

  if (!applicationPassword) {
    throw new Error(
      'Saved password for sergeyqa was not passed to Playwright. Open Launcher and use «Настроить учетку Rx2GO» once.'
    );
  }

  const credentials: Rx2GoCredentials = {
    application: {
      login: applicationLogin,
      password: applicationPassword,
    },
  };

  if (requiresGatewayAuthentication()) {
    const gatewayLogin = process.env.RX2GO_GATEWAY_LOGIN || 'admin';
    const gatewayPassword = process.env.RX2GO_DAILY_PASSWORD;

    if (!gatewayPassword) {
      throw new Error(
        'RX2GO_DAILY_PASSWORD is required for ADM. Use the secure run script and enter today\'s password from Telegram.'
      );
    }

    credentials.gateway = {
      login: gatewayLogin,
      password: gatewayPassword,
    };
  }

  return credentials;
}

