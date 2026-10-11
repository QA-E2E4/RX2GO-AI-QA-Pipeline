# RX2GO AI QA Pipeline

RX2GO AI QA Pipeline is a Windows desktop QA tool for testing the RX2GO administration panel. It combines a PowerShell/WinForms launcher, a staged AI-agent workflow, Microsoft Playwright MCP, and deterministic Playwright tests. The repository is private and is hosted at [QA-E2E4/rx2go-ai-qa](https://github.com/QA-E2E4/rx2go-ai-qa).

The project turns a Jira acceptance request into traceable evidence: understand the request, inspect the live product in an authenticated browser, execute the acceptance criteria, generate or run deterministic checks, review the result, and produce a readable report. Live RX2GO tests are opt-in; static CI validation never contacts RX2GO.

## What is implemented

- Windows GUI launcher in `Rx2GO-QA-Launcher.ps1`, with `.bat` entry points.
- Environment selection for HOT, ADM, and BRANCH test targets.
- Secure runtime credential flow: rotating ADM gateway password is entered per run; application and Jira credentials may be stored with Windows DPAPI by the launcher.
- Fresh or explicitly reused Chrome sessions through Playwright/CDP, with session metadata kept outside Git.
- Jira task loading, requirements analysis, live Playwright MCP execution, QA review, optional failure triage, and deterministic Playwright execution.
- Smoke, diagnostics, ticket, page-object, fixture, and utility code under `tests`, `pages`, `fixtures`, and `utils`.
- Knowledge repository with project rules, policies, explorer snapshots, Jira case cards, and scenarios.
- Readable Jira report generation and optional Allure/HTML reports.
- Safe Git synchronization that stages only declared project paths, excludes runtime evidence and secrets, and uses the QA-E2E4 SSH remote.
- GitHub Actions static validation for dependency installation, TypeScript type checking, and Playwright test discovery. It does not run against a real RX2GO environment.

## Technology stack

- Windows PowerShell 5.1+ and WinForms for the desktop launcher.
- Node.js 22+, npm, TypeScript 5.7, and Playwright Test 1.62.
- Microsoft Playwright MCP through Codex for live browser exploration and execution.
- Optional Codex CLI/ChatGPT sign-in and optional BrowserStack MCP for additional failure analysis.
- YAML/JSON/Markdown knowledge files and Jira/Allure report helpers.

## Architecture

The launcher is the process coordinator and safety boundary. The pipeline stages are:

1. Requirements Analyst — converts the Jira request into explicit acceptance criteria, risks, and a test plan.
2. Playwright MCP QA Agent — uses the authenticated browser to inspect the selected RX2GO environment, execute acceptance criteria, and capture structured evidence.
3. QA Reviewer — checks coverage, evidence integrity, and whether the result is supported by observed product state.
4. Deterministic Playwright — runs committed or generated specs when the workflow produces a valid test path.
5. Failure Triage — runs conditionally after a failure and classifies product, automation, authentication, data, environment, or flaky causes.

Knowledge retrieval and auto-learning are supporting stages. They read or write bounded, reusable project knowledge; transient evidence and credentials remain local. See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Requirements

- Windows 10/11 with PowerShell 5.1 or PowerShell 7.
- Node.js 22 LTS or newer, npm, and Git for Windows.
- Google Chrome for headed/browser-session workflows.
- Codex CLI and ChatGPT authentication for AI-agent runs.
- RX2GO environment access and approved test credentials for live tests only.
- Optional: Jira access, Allure CLI, and BrowserStack MCP.

## Installation

```powershell
git clone git@github.com:QA-E2E4/rx2go-ai-qa.git
cd rx2go-ai-qa
Copy-Item .env.example .env
npm ci
npm run typecheck
npm run test:list
```

For Windows launcher setup, run `setup.ps1` or use `INSTALL CODEX.bat` when Codex CLI is not installed. Do not put passwords or tokens into `.env`; use secure launcher prompts or the CI secret store. Detailed setup notes are in [docs/SETUP.md](docs/SETUP.md).

## Configuration

`.env.example` contains non-secret defaults for `TEST_ENV`, environment URLs, mutation policy, and report metadata. The launcher supplies runtime secrets through environment variables or DPAPI-backed files under `%LOCALAPPDATA%\Rx2GO-AI-QA\secrets`.

Important variables include:

- `TEST_ENV=HOT|ADM|BRANCH` — target environment.
- `HOT_BASE_URL`, `ADM_BASE_URL`, `BRANCH_BASE_URL` — target URLs.
- `RX2GO_GATEWAY_LOGIN` and `RX2GO_DAILY_PASSWORD` — ADM gateway credentials; the daily password is runtime-only.
- `RX2GO_APP_LOGIN` and `RX2GO_APP_PASSWORD` — application credentials; the password is runtime-only.
- `RUN_MUTATING_TESTS=false` — safety switch for tests that change product data.

The default test policy is read-only. Mutating tests are available only through an explicit, approved run configuration. Never use production customer data as test data.

## First launch

1. Start `START QA.bat`.
2. Select HOT, ADM, or BRANCH in the launcher.
3. Complete the secure credential prompts required by the selected environment.
4. Use Quick Run for a known suite, or Jira Task for the AI pipeline.
5. Review the live evidence and final report before saving knowledge or synchronizing Git.

For a non-GUI check, use:

```powershell
npm run test:smoke
npm run test:tickets
.\scripts\run-with-daily-password.ps1 -Suite smoke -Environment HOT
```

The last command requires real credentials and may access RX2GO. It is not part of pull-request publication or static CI.

## Example: Jira task to report

In the Jira Task tab, load an approved issue, confirm the selected environment and mutation policy, then start Smart QA. The launcher coordinates the agent stages, writes run evidence under ignored `reports/` paths, runs eligible deterministic checks, and produces `jira-readable-report.txt`. Use `report:jira` or the launcher report action to render a report for review. A PASS is only reported when available evidence supports it; blocked or incomplete stages remain visible as such.

## Checks and reports

```powershell
npm run typecheck
npm run test:list
npm run test:smoke       # live HOT smoke; opt-in
npm run test:tickets     # live ticket suite; opt-in
npm run report:html
npm run report:jira
npm run report:allure
```

The GitHub Actions workflow runs only `npm ci`, `npm run typecheck`, and `npm run test:list`. It does not claim live test results. Local live tests require RX2GO access and are intentionally not run as part of repository publication.

## Repository safety

The launcher’s managed Git scope includes source, tests, fixtures, utilities, configuration, documentation, and `.github`. It excludes `.env`, credential exports, browser state, screenshots, videos, traces, reports, `node_modules`, and other runtime output. The package lockfile is tracked for reproducible installation. Review `git status` before every commit.

## Limitations and roadmap

Current limitations:

- The application is Windows-first; the launcher is not a cross-platform desktop client.
- Live AI and RX2GO coverage requires external access, valid credentials, Chrome, and Codex authentication.
- The checked-in deterministic suite covers currently implemented RX2GO modules; it is not a complete administration-panel certification.
- BrowserStack and Jira integrations are optional and require separate credentials/configuration.
- No automatic live-environment workflow is enabled in GitHub Actions.

Roadmap candidates, not current guarantees:

- Expand committed page objects and deterministic coverage by module.
- Add a reviewed, secret-backed manual live smoke workflow.
- Improve report attachments and long-running queue observability.
- Add broader cross-browser and accessibility checks after the environment contract is agreed.

## Documentation

- [Architecture](docs/ARCHITECTURE.md)
- [Setup](docs/SETUP.md)
- [Usage](docs/USAGE.md)
- [Troubleshooting](docs/TROUBLESHOOTING.md)
- [Knowledge repository](docs/KNOWLEDGE-REPOSITORY.md)
- [Authentication rules](docs/AUTH-RULE.md)
- [Changelog](docs/CHANGELOG.md)

## License

No license is declared in this repository.

