# Rx2GO environment authentication

## HOT
1. Open `https://hot.rx2go.ai/login`
2. Application login: `RX2GO_APP_LOGIN` + locally encrypted password
3. No Telegram daily code

## BRANCH
The branch address and application login must be supplied privately via `BRANCH_BASE_URL` and `RX2GO_APP_LOGIN`.
1. Open `${BRANCH_BASE_URL}/login`
2. Application login: `RX2GO_APP_LOGIN` + locally encrypted password
3. No Telegram daily code

## ADM
1. Open `https://adm.rx2go.ai/login`
2. Browser-native HTTP Basic Auth challenge:
   - username: `admin`
   - password: daily code from Telegram
3. Application login page:
   - username: `RX2GO_APP_LOGIN`
   - password: locally encrypted persistent credential

Implementation rules:
- the `RX2GO_APP_LOGIN` password is stored under `%LOCALAPPDATA%\Rx2GO-AI-QA\secrets`
  using Windows DPAPI/PowerShell `Export-Clixml`;
- it is never committed to Git;
- ADM daily Telegram code is kept only in the current Launcher session;
- the native Chrome auth dialog is handled via CDP `Fetch.authRequired`, not DOM selectors.
