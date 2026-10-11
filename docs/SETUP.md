# Setup

## Local prerequisites

Install Windows PowerShell 5.1 or PowerShell 7, Node.js 22+, npm, Git for Windows, and Google Chrome. Install Codex CLI separately if Smart QA will be used.

## Project setup

```powershell
Copy-Item .env.example .env
npm ci
npm run typecheck
npm run test:list
```

The lockfile is committed so a clean checkout uses the same dependency graph. `npm run test:list` loads the Playwright configuration and enumerates tests without opening a real RX2GO session.

## Launcher setup

Run `START QA.bat` or `powershell -ExecutionPolicy Bypass -File .\Rx2GO-QA-Launcher.ps1`. The launcher can install/configure Codex through the provided setup actions. ChatGPT authentication is handled by Codex; the launcher does not store a ChatGPT token in the repository.

## Credentials

Use the launcher’s secure prompts or the secure runner scripts. Windows DPAPI-backed files are stored under `%LOCALAPPDATA%\Rx2GO-AI-QA\secrets`. Never copy those files into the project folder. `RX2GO_DAILY_PASSWORD`, `RX2GO_APP_PASSWORD`, Jira API tokens, BrowserStack keys, cookies, and browser storage are runtime secrets.

## GitHub synchronization

The canonical remote is `git@github.com:QA-E2E4/rx2go-ai-qa.git`. Add the repository owner’s SSH key to GitHub before using launcher synchronization. The launcher stages the managed paths listed in its `KnowledgePaths` collection, including `fixtures`, `utils`, `.github`, and `package-lock.json`.

