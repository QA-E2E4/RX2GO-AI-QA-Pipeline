# Troubleshooting

## `npm ci` fails

Confirm Node.js and npm versions, remove only the local `node_modules` directory if it is stale, and run `npm ci` again. Do not delete the lockfile; it is part of the reproducible setup.

## TypeScript or test discovery fails

Run `npm run typecheck` first, then `npm run test:list`. Check the reported import path and confirm that `fixtures/` and `utils/` exist in the checkout. Do not bypass the error by switching to a stale project copy.

## Login or gateway authentication fails

Check `TEST_ENV`, the selected base URL, and the runtime credential prompt. ADM requires the current rotating gateway password plus the application credential. Password values are intentionally absent from logs; re-enter them rather than printing or copying them into a ticket.

## Chrome/CDP session is unavailable

Close only the project-created test Chrome session, restart the launcher, and allow it to create a fresh `.qa-state` profile. Do not reuse a browser profile that contains personal or customer sessions.

## Jira or Codex is unavailable

The deterministic suites can still be run locally. Treat the AI pipeline as blocked when Codex authentication, Jira access, or the selected MCP session is unavailable; do not report a product PASS from a skipped stage.

## Git synchronization is blocked

Review `git status`, SSH access to GitHub, and the remote URL. Uncommitted managed files must be committed by the launcher; unrelated or sensitive files must remain outside the commit. The canonical remote is `git@github.com:QA-E2E4/rx2go-ai-qa.git`. Never force-push or delete history.

