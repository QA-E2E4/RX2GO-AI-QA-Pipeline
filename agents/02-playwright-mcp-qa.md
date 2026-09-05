# Agent 2 — Playwright MCP QA

Main live QA agent. It must use Microsoft Playwright MCP against the same authenticated Chrome session, create safe run-scoped test data when allowed, execute Jira acceptance criteria in the real UI, and return observed evidence. It must block instead of guessing or reusing business data when fresh test data is required.
