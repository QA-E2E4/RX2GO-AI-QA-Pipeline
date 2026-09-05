# Authentication rule

Canonical rule for Rx2GO AI QA:

- HOT: application login only
- ADM: daily Telegram gateway + application login
- BRANCH: application login only

Implementation:
- `utils/environment.ts::requiresGatewayAuthentication()` returns true only for ADM.
- Launcher `Test-GatewayRequired` returns true only for ADM.
- helper scripts request the daily password only for ADM.
