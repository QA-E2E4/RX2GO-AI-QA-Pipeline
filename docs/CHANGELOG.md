# Changelog

## 0.4.0 — Knowledge + Git
- Added **Knowledge** tab with project-rule, Jira-case, regression-scenario and automated-test counters.
- Added Git repository status, branch, origin and last commit display.
- Added safe startup `git pull --ff-only` only for a clean working tree.
- Added **Commit knowledge** and **Synchronize** actions.
- Jira analysis now writes durable cards to `jira-cases/`.
- **Add to Regression** now writes portable scenario files to `scenarios/`.
- Runtime evidence and secrets stay ignored by Git.

## 0.5.0 — Codex auto-start
- Windows Codex installation switched to the official OpenAI standalone installer.
- Launcher initializes Codex automatically when the GUI opens.
- If Codex is installed and ChatGPT OAuth is valid, no window is opened; status becomes ready automatically.
- If Codex is installed but OAuth is missing/expired, `codex login` opens automatically.
- If Codex is missing, Launcher asks once and can install it automatically, then opens ChatGPT sign-in.
- Node.js/npm are no longer required just to install Codex CLI.

## 0.5.3
- Fixed Windows launcher startup regression from v0.5.2.
- Removed duplicate Git startup sync implementation.
- Kept the safe timer-based `Invoke-StartupKnowledgePull` synchronization.
- Restored `[void]$form.ShowDialog()` so the GUI opens correctly.
# Changelog

## 0.12.40 — unreleased

- Added the complete `fixtures`, `utils`, and `.github/workflows` source required by the Playwright configuration and tests.
- Expanded launcher-managed Git synchronization to include fixtures, utilities, workflow files, and the npm lockfile.
- Updated built-in GitHub addresses to `QA-E2E4/rx2go-ai-qa`.
- Added reproducible npm scripts for TypeScript checking and Playwright test discovery.
- Replaced the main README with an English, code-grounded project guide and added setup, architecture, usage, and troubleshooting documentation.
- Changed GitHub Actions to static validation only; no live RX2GO credentials or environment are used by CI.
- Added issue and pull-request templates.

