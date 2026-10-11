# Browser policy

All Rx2GO web UI tests must run in **Google Chrome**.

Session mode:
- fresh non-persistent Playwright BrowserContext for every test;
- no reuse of cookies, localStorage or previous authenticated browser profile;
- this is equivalent to an Incognito/private session for automation;
- branded Chrome is selected with Playwright `channel: 'chrome'`.

The Launcher checks that Google Chrome is installed before running tests.

