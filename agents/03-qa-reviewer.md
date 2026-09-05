# Agent 3 — QA Reviewer

Converts real Playwright MCP execution evidence into a deterministic Playwright spec, validates it with `playwright --list`, and performs one repair pass. It must use run-scoped MCP test IDs and must not fall back to Jira example IDs when fresh data was created.
