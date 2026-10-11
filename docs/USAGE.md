# Usage

## Static validation

```powershell
npm run typecheck
npm run test:list
```

These checks need no RX2GO credentials and are suitable for pull requests.

## Live suites

```powershell
npm run test:smoke
npm run test:tickets
.\scripts\run-with-daily-password.ps1 -Suite smoke -Environment HOT
```

Live commands require an approved environment and valid runtime credentials. Use ADM only when the rotating gateway password is available. Keep `RUN_MUTATING_TESTS=false` unless the task explicitly authorizes data changes.

## Smart QA from Jira

1. Open the launcher and select the target environment.
2. Load the Jira issue and verify the imported request.
3. Confirm the test-data mutation setting and credentials.
4. Start Smart QA and wait for each agent stage.
5. Review live evidence, deterministic results, triage, and the readable report.
6. Save only reusable knowledge; do not save customer data or transient IDs.

## Reports

Reports and evidence are written to ignored runtime paths. `npm run report:jira` generates a text report from the available run artifacts; `npm run report:html` opens the Playwright report; `npm run report:allure` builds an Allure report when the Allure CLI is installed.

