# Architecture

## Runtime boundary

`Rx2GO-QA-Launcher.ps1` is the Windows process coordinator. It owns the WinForms UI, environment selection, credential hand-off, Chrome lifecycle, Codex process execution, report paths, Knowledge retrieval, and guarded Git synchronization. Child processes receive only the runtime variables needed for the selected operation.

## QA pipeline

```text
Jira request
  -> Requirements Analyst
  -> authenticated Chrome + Playwright MCP QA
  -> QA Reviewer
  -> deterministic Playwright (when a valid spec exists)
  -> conditional Failure Triage
  -> readable report + optional Knowledge learning
```

The live browser is the source of truth for the MCP stage. Deterministic Playwright is a separate verification layer and its failure is not silently converted into a product failure or success. The launcher records the distinction in the report.

## Repository responsibilities

- `agents/` — prompts and role contracts for AI stages.
- `fixtures/`, `utils/` — shared Playwright setup, environment resolution, credential validation, and HTTP Basic Auth helpers.
- `pages/` — page objects for committed UI coverage.
- `tests/` — diagnostics, smoke, and ticket suites.
- `knowledge/` — policies, project rules, and explorer snapshots.
- `scripts/` — repeatable test and reporting helpers.
- `reports/`, `.qa-state/`, browser state, and credentials — local runtime output; never commit.

## Safety invariants

1. Passwords, tokens, cookies, storage state, and private keys stay outside Git.
2. Mutating tests require explicit runtime permission.
3. Git synchronization stages only the launcher-managed project paths.
4. CI performs static validation only and does not access RX2GO.
5. A missing or incomplete evidence stage remains visible as blocked/incomplete.

