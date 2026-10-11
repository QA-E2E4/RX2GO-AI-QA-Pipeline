# Rx2GO Smart QA architecture (v0.12.0)

## Pipeline

1. **Requirements Analyst** — Jira requirements only.
2. **One persistent Chrome session** — ADM first factor + Rx2GO app login once.
3. **Microsoft Playwright MCP QA Agent** — operates against the live authenticated browser through CDP. It explores the actual UI, creates run-scoped test data, executes acceptance criteria, and captures UI/network/console evidence.
4. **QA Reviewer** — generates one deterministic Playwright spec from proven MCP actions and validates/repairs it.
5. **Deterministic Playwright run** — reuses the same Chrome.
6. **Failure Triage** (only on FAIL) — classifies product bug vs test/auth/test-data/environment/flaky using runtime artifacts and the live browser.
7. **BrowserStack MCP** (optional) — credentials can be configured with `CONFIGURE BROWSERSTACK MCP.bat`; it is available to Codex for BrowserStack AI/RCA workflows when relevant BrowserStack sessions exist.

## Why this replaces the five-agent pipeline

The previous Test Designer / UI / API agents could only reason about serialized snapshots and frequently guessed selectors, routes, or test data. The Playwright MCP QA Agent instead works interactively in the real page after every action. The reviewer therefore receives evidence from actual browser execution rather than a chain of assumptions.

## Safety

- One authenticated browser session per Jira run.
- Secrets stay in DPAPI/environment variables and are never placed in prompts.
- Fresh test data is mandatory when the Jira/QA comment requires it and mutations are enabled.
- If safe data creation is impossible, the run is `BLOCKED`; historical Jira IDs are not silently substituted.
- BrowserStack credentials, when used, are stored under `%LOCALAPPDATA%\Rx2GO-AI-QA\secrets` with Windows DPAPI.


## v0.12.1 MCP runtime contract

The Playwright MCP registration is not considered usable merely because `codex mcp list` shows `playwright`. The launcher requires the server policy to forward the dynamic `PLAYWRIGHT_MCP_CDP_ENDPOINT` from the current Codex process and to approve Playwright MCP browser tools non-interactively. Before the main Smart QA agent runs, a preflight proves that Playwright MCP can list tabs, snapshot the page, and see the selected Rx2GO host in the same persistent Chrome session.

