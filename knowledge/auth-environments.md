# Rx2GO environment authentication

## HOT
1. Open `https://hot.rx2go.ai/login`
2. Application login: `sergeyqa` + locally encrypted password
3. No Telegram daily code

## BRANCH
1. Open `https://sergey-tester.rx2go.ai/login`
2. Application login: `sergeyqa` + locally encrypted password
3. No Telegram daily code

## ADM
1. Open `https://adm.rx2go.ai/login`
2. Browser-native HTTP Basic Auth challenge:
   - username: `admin`
   - password: daily code from Telegram
3. Application login page:
   - username: `sergeyqa`
   - password: locally encrypted persistent credential

Implementation rules:
- the `sergeyqa` password is stored under `%LOCALAPPDATA%\Rx2GO-AI-QA\secrets`
  using Windows DPAPI/PowerShell `Export-Clixml`;
- it is never committed to Git;
- ADM daily Telegram code is kept only in the current Launcher session;
- the native Chrome auth dialog is handled via CDP `Fetch.authRequired`, not DOM selectors.

