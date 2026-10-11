# Rx2GO QA Knowledge Repository

Git is the durable source of truth for portable QA knowledge.

## Commit to Git
- `knowledge/` — project rules, environment and module knowledge.
- `jira-cases/` — one durable Markdown card per analyzed Jira task.
- `scenarios/` — regression scenarios/candidates approved by QA.
- `tests/`, `pages/`, `api/`, `agents/`, `scripts/` — executable QA automation.
- `docs/` — team documentation.

## Never commit
- `.secrets/`, `.env*` (except `.env.example`).
- `reports/`, `jira-runs/`.
- screenshots, videos, Playwright traces and temporary result folders.
- daily Telegram passwords, OAuth tokens, browser cookies or storage state.

## Launcher workflow
1. Launcher starts and runs `git pull --ff-only` only when the working tree is clean.
2. QA works with Jira tasks and saves project rules/regression scenarios.
3. Open the **Knowledge** tab and review the changed-file count.
4. Enter a useful commit message and click **Commit knowledge**.
5. Click **Synchronize** to pull fast-forward changes and push your commit to `origin`.

If there are uncommitted local changes, synchronization deliberately stops instead of overwriting them.

## Default GitHub repository

This build is preconfigured with `git@github.com:QA-E2E4/rx2go-ai-qa.git`. If `origin` is missing, the Launcher adds it automatically. Existing repository history is preserved; synchronization does not force-push.

