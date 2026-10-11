# Rx2GO AI QA — графический запуск

Для обычной работы PowerShell-команды вводить не нужно.

## Запуск

Дважды кликните файл:

`START QA.bat`

Откроется окно **Rx2GO AI QA**.

### Первый запуск

Нажмите **Настроить учетку Rx2GO** и один раз сохраните данные второго фактора. Учетные данные сохраняются средствами Windows PowerShell CLIXML и доступны только текущему Windows-пользователю на этом компьютере.

### Окружения

- **BRANCH** — `https://sergey-tester.rx2go.ai/login`, первого gateway-фактора нет.
- **HOT** — gateway `admin` + суточный пароль из Telegram, затем вход в Rx2GO.
- **ADM** — gateway `admin` + суточный пароль из Telegram, затем вход в Rx2GO.

Поле суточного пароля появляется только для ADM; на HOT и BRANCH оно скрыто.

### Что можно выбрать

- **Smoke** — безопасные базовые проверки.
- **Tickets Queue** — тесты очереди тикетов.
- **Все тесты** — весь имеющийся набор.
- **Показывать браузер** — видно действия Playwright.
- **Разрешить изменение тестовых данных** — включает сценарии, которые могут изменять тестовые тикеты.

После запуска в нижней части окна отображается лог и итоговый статус PASS/FAIL.

## Панель результатов

После завершения Playwright лаунчер автоматически читает `reports/results.json` и показывает:

- количество PASS / FAIL / SKIP;
- список упавших сценариев;
- кнопку **Скопировать отчёт для Jira**;
- кнопку **Открыть HTML-отчёт**.

Jira-отчёт содержит окружение, набор тестов, дату, метод, итоговые счётчики и список падений.

## Подключение ChatGPT

На вкладке **Jira Task** launcher показывает статус ChatGPT:

- `ChatGPT подключён` — OAuth уже активен и будет использован автоматически;
- `ChatGPT не подключён` — нажмите **Подключить ChatGPT**;
- `Нужен Codex CLI` — launcher предложит установить официальный пакет `@openai/codex`, затем откроет вход ChatGPT.

Первый вход проходит в браузере через `codex login`. После этого повторно вводить данные ChatGPT при каждом запуске не нужно: launcher проверяет состояние через `codex login status` и использует Codex OAuth для `AI-анализ через ChatGPT`.

Launcher намеренно **не извлекает cookies браузера, не читает ChatGPT session cookie и не переносит OAuth-токены**. Это снижает риск утечки аккаунта.

Подключение Atlassian в ChatGPT — отдельная авторизация. Её токен не выдаётся локальному приложению. Для чтения Jira по одному ключу без вставки описания нужен отдельный Jira OAuth-модуль.

## Комментарии QA и Knowledge Base

Во вкладке `Jira Task`:

1. **Jira-задача** — исходные требования.
2. **Комментарий QA для этой проверки** — разовое указание только текущему прогону.
3. **Новое постоянное правило Rx2GO** — можно сохранить кнопкой в Knowledge Base.

Постоянные правила находятся в `knowledge/project-rules.json` и автоматически применяются к следующим задачам. Launcher блокирует попытку сохранить в эту базу текст, похожий на пароль, token или API key.

## Вкладка Knowledge

`Knowledge` — это общая переносимая память Rx2GO QA.

- **Project rules** — постоянные правила проекта.
- **Jira cases** — карточки задач, которые анализировались/проверялись.
- **Regression scenarios** — сценарии, добавленные QA в регресс.
- **Automated tests** — Playwright `*.spec.ts`.

### GitHub настроен заранее

В этой сборке уже задан репозиторий:

`https://github.com/QA-E2E4/rx2go-ai-qa`

Если Git for Windows установлен, Launcher при старте сам инициализирует локальный Git (если нужно) и добавляет `origin`. Вводить URL вручную не требуется. После первых изменений нажми **Commit knowledge**, затем **Synchronize**. Первый push создаст ветку `main`, если удалённая ветка ещё пустая.

### Обычная работа

Launcher при старте делает `git pull --ff-only` только если рабочая папка чистая. После новой Jira-задачи/правила/регресса открой `Knowledge`, проверь изменения, сделай commit и нажми Synchronize.


## Automatic Git synchronization at startup

On every launcher start, Rx2GO AI QA now attempts a safe synchronization with:

`https://github.com/QA-E2E4/rx2go-ai-qa.git`

Behavior:
- clean working tree -> `git fetch` + `git pull --ff-only`;
- local uncommitted changes -> pull is skipped and local work is preserved;
- non-fast-forward/conflict situation -> no automatic merge is performed;
- Git unavailable -> launcher continues without synchronization.

This keeps the shared Knowledge Base current without risking silent overwrites.


## Codex startup behavior (v0.5.4)

The launcher now checks Codex authentication silently at startup.
It does **not** open the interactive Codex console automatically.

- already signed in -> status shows ChatGPT connected;
- Codex installed but signed out -> use **Подключить ChatGPT** once;
- Codex missing -> use **Установить и подключить**;
- AI actions invoke Codex only when needed.

## Automatic Playwright bootstrap (v0.6.0)

When a test is started, the Launcher now prepares the test runtime automatically:

1. checks Node.js and npm;
2. if Node.js is missing and `winget` is available, installs Node.js LTS;
3. runs `npm install` only when project dependencies are missing or `package.json` changed;
4. installs Playwright Chromium when needed;
5. starts the selected Playwright suite.

The first run can take several minutes. Progress is written directly to the Launcher log.
Use `CHECK TEST ENVIRONMENT.bat` to verify/setup the runtime without running Rx2GO tests.


## Environment authentication — canonical rule (v0.6.2)

- **HOT** — application login only; no daily Telegram password.
- **ADM** — gateway `admin` + daily Telegram password, then application login.
- **BRANCH** — application login only; no daily Telegram password.

All launch paths now use this same rule.


## Google Chrome Incognito policy (v0.6.3)

All UI tests now run in the installed **Google Chrome**, not Playwright Chromium.

Playwright creates a fresh non-persistent browser context for every test, so cookies,
localStorage and previous sessions are not reused. This is the automation equivalent
of an Incognito session.

Before a test starts, the Launcher checks Google Chrome and can install it through
`winget` if Chrome is missing.


## Chrome launch fix (v0.6.4)

Fixed a syntax error in `playwright.config.ts` that prevented Playwright from
starting Google Chrome.

Before every real test run the bootstrap now performs `playwright test --list`.
If the config or test files are invalid, the Launcher reports the error before
attempting to launch a browser.

Headed web runs use branded Google Chrome with `--incognito` and a fresh
non-persistent Playwright context.


## Authentication diagnostics (v0.6.5)

Rx2GO login was rebuilt to make failures diagnosable:

- HOT and BRANCH open `/login` directly;
- ADM uses the gateway first and then application login;
- only visible login/password fields are used;
- the entered login value and password length are verified before submit;
- success requires the login form to disappear or the URL to leave `/login`;
- visible server/UI login errors are included in the Playwright error;
- no password value is written to the log;
- an `auth-failed.png` screenshot is saved when the form remains visible.

Look for `[AUTH]` lines in the Launcher log.


## Tickets Queue smoke + window sizing fix (v0.6.6)

Two issues from the first successful HOT run were fixed:

1. Headed Google Chrome now starts maximized and Playwright uses `viewport: null`,
   so Rx2GO uses the workstation's real browser window instead of the emulated
   `Desktop Chrome` 1280x720 viewport.
2. `RX2GO-TQ-001` no longer uses `getByText(/tickets/i).first()`, which selected
   a hidden duplicate `Tickets Queue` heading. The smoke test now explicitly
   verifies a visible `h1#page-title` / `h1.page-title` containing `Tickets Queue`.


## Keep browser open (v0.6.7)

Quick Start now has **Не закрывать браузер после теста**.

When enabled together with **Показывать браузер**:
- the latest authenticated browser storage state and URL are saved locally in `.qa-state/`;
- after Playwright finishes, Google Chrome is reopened on the last tested page;
- the preserved browser stays open until the QA user closes it manually;
- `.qa-state/` is excluded from Git.


## Same browser stays open (v0.6.8)

`Не закрывать браузер после теста` no longer saves the session and opens a second Chrome.

When the option is enabled:
1. Launcher starts one Google Chrome process with a temporary clean Incognito profile
   and a local DevTools/CDP endpoint.
2. Playwright connects to that exact Chrome instance.
3. Tests execute in the visible browser.
4. When the Playwright worker exits, its CDP connection is dropped.
5. The same Chrome window remains open for manual QA inspection.

There is no close/reopen cycle anymore.


## Single Chrome process (v0.6.9)

The QA page fixture no longer depends on Playwright's built-in `page` fixture.
Therefore **Не закрывать браузер после теста** uses exactly one visible Google Chrome
process: Launcher starts it, Playwright connects over CDP, and after the tests the
connection ends while that same Chrome window remains open.


## Browser lifecycle fix (v0.7.1)

Fixed two browser lifecycle defects:

1. `Smoke` no longer runs authentication as a separate Playwright test.
   Authentication is the first step of the actual smoke scenario.
2. The missing **Не закрывать браузер после теста** checkbox is now a real UI control
   and is enabled by default when headed mode is enabled.

With both browser options enabled the expected lifecycle is:

**one Chrome launch → login → smoke test → PASS/FAIL → same Chrome remains open**

Launcher starts a single external Google Chrome process, Playwright connects through
CDP, and the test code deliberately does not close that browser.


## Absolute environment URLs (v0.7.2)

Fixed navigation in persistent Chrome/CDP mode.

CDP-connected browser contexts do not inherit Playwright `baseURL`, so relative calls
like `page.goto('/login')` could not resolve the Rx2GO environment.

All critical navigation now uses absolute URLs:
- HOT: `https://hot.rx2go.ai/login`
- ADM: `https://adm.rx2go.ai`
- BRANCH: `https://sergey-tester.rx2go.ai/login`
- Tickets Queue: `<environment base>/tickets/queue`

The log now prints `[AUTH] Navigating...` and `[NAV] Opening...` lines with the exact URL.


## ADM native auth + persistent sergeyqa credential (v0.7.3)

ADM authentication now matches the real browser flow:

1. Chrome opens `https://adm.rx2go.ai/login`.
2. The browser-native HTTP Basic Auth challenge is handled automatically through
   Chrome DevTools Protocol:
   - username is always `admin`;
   - password is the daily Telegram code entered in Launcher.
3. After Basic Auth succeeds, the normal Rx2GO login form is filled automatically
   with the stored `sergeyqa` credential.

The `sergeyqa` credential is no longer stored inside the unpacked project folder.
It is saved once under `%LOCALAPPDATA%\Rx2GO-AI-QA\secrets` using Windows DPAPI,
so future Launcher versions reuse it automatically. The Launcher also attempts to
migrate a saved credential from an older nearby `rx2go-ai-qa-*` folder.


## ADM authentication reliability fix (v0.7.4)

ADM no longer waits for Chrome's native auth dialog to be filled. Before navigating,
Playwright adds the HTTP `Authorization: Basic ...` header using the fixed username
`admin` and the Telegram daily code from Launcher. This prevents the browser prompt
from blocking the test.

The second-stage Rx2GO application login always uses fixed username `sergeyqa`; its
password is loaded from Windows DPAPI storage under `%LOCALAPPDATA%\Rx2GO-AI-QA\secrets`.
The log confirms that the credential is loaded, but never prints the password.


## HOT login + absolute navigation fix (v0.7.5)

- Tickets Queue always opens with a full environment URL, never `/tickets/queue`.
- Staying on `/login` is never considered successful authentication.
- Launcher waits up to 15 seconds for the visible Rx2GO login/password fields.
- `sergeyqa` and the saved DPAPI password are filled only after the real form is visible.
- Safe diagnostics show URL and visible input/button counts without printing the password.


## Real Jira task checking (v0.8.0)

The Jira Task tab now verifies the actual Jira issue instead of treating a URL as task text.

Flow:
1. Connect Jira once with **Подключить Jira**. A separate Google Chrome profile is stored
   under `%LOCALAPPDATA%\Rx2GO-AI-QA\jira-chrome-profile`; no Atlassian password is stored by the Launcher.
2. Paste a Jira URL or key such as `SCRUM-4033`.
3. Launcher fetches the issue from the Jira REST API using the authenticated browser session.
4. Summary, description, status, type and priority are passed to ChatGPT/Codex.
5. Codex creates one temporary task-specific Playwright spec under `tests/generated/`.
6. The generated spec is validated with `playwright test --list`.
7. Only then is the task-specific test executed in the selected Rx2GO environment.
8. If Jira cannot be read or a valid task-specific spec cannot be generated, the Launcher
   stops with an explicit error and never reports a fake PASS.

`tests/generated/` and Jira fetch artifacts are excluded from Git until the QA user explicitly
promotes a scenario to regression.


## Jira REST API authentication (v0.8.1)

The browser-session Jira bridge was removed.

For a personal QA pilot, Launcher now uses Atlassian's supported REST API flow for
scripts and ad-hoc tools:

1. Press **Настроить Jira** once.
2. Enter the Atlassian account email and an API token.
3. Launcher verifies the credentials using `/rest/api/3/myself`.
4. The API token is stored with Windows DPAPI under:
   `%LOCALAPPDATA%\Rx2GO-AI-QA\secrets\jira-api.credential.xml`
5. Pasting `SCRUM-4033` or its Jira URL makes Launcher fetch the real issue through
   `/rest/api/3/issue/<KEY>`.
6. Jira browser login/SSO is not used by Launcher at all.

No Jira password, API token, or session cookie is written to Git.


## v0.9.1

Rebuilt on the last working v0.8.1 launcher.

- Jira Task UI uses the proven fixed WinForms layout plus AutoScroll.
- Added **Загрузить Jira** and a source preview containing the real Description and all Jira comments.
- Current bug behavior, expected behavior, reproduction steps and acceptance criteria are separated.
- QA comment remains run guidance.
- Codex generates TypeScript in read-only mode; Launcher writes and validates the spec.
- Generation failures show the exact reason and log path.
- `LauncherBootstrap.ps1` catches startup failures and writes `startup-error.log`.


## v0.9.2 — startup parse fix

Fixed the PowerShell parser error in `New-JiraTestPlan`.
The automation status is now assigned to `$automationStatus` first and then passed to
`$lines.Add(...)`; PowerShell control-flow is no longer embedded directly in a method call.

The launcher was also scanned for similar `.Add(if ...)`, `.Add(switch ...)` and
`.AppendText(if ...)` constructs.


## v0.9.3 — UTF-8 BOM startup fix

Fixed a Windows PowerShell startup failure caused by two UTF-8 BOM markers at the
beginning of `Rx2GO-QA-Launcher.ps1`. The second BOM became an invisible character
in front of `Add-Type`, so PowerShell treated it as an unknown command.

`LauncherBootstrap.ps1` now repairs the launcher's encoding before every start and
normalizes multiple/missing leading UTF-8 BOM markers to exactly one.


## v0.9.4 — Quick Tab NULL startup fix

Fixed the startup runtime error at the browser-mode label. The code previously called
`$quickTab.Controls.Add(...)` before `$quickTab` had been created.

The browser-mode label is now a child of `$configPanel`, which already exists at that point
and is later moved into the Quick Run tab together with the rest of the configuration panel.

A static startup audit now verifies that no `Controls.Add(...)` parent is referenced before
its first assignment.


## v0.9.5 — Knowledge UI TrimStart startup fix

Fixed `Refresh-KnowledgeUI` startup error caused by
`TrimStart('\\','/')`. PowerShell attempted to convert the two-character
string `\\` to `System.Char`.

The relative knowledge path now uses a regex replacement instead:
`-replace '^[\\/]+', ''`.

The Launcher was also scanned for other risky `TrimStart/TrimEnd` calls
with doubled slash strings.


## v0.9.6 — responsive UI rebuild

- Rebuilt the layout of **Quick Run**, **Jira Task**, and **Knowledge** tabs.
- Added responsive container-based layout with GroupBox, TableLayoutPanel, Panel, and SplitContainer.
- Removed overlapping blocks and drifting controls.
- Jira screen is now split into clear sections: integrations, source, QA comment, imported Jira content, rules, settings, execution status, and test plan.
- Quick Run now has distinct areas for launch parameters, actions, results, failed scenarios, and logs.
- Knowledge tab now has clear cards, Git panel, commit panel, and recent changes area.
- Increased minimum window width for a more stable layout.


## v0.9.7 — polished responsive UI + layout self-check

- Cleaned up spacing and alignment in Quick Run so browser mode, ADM code, credentials, and checkboxes no longer overlap.
- Jira settings now use a wrapping FlowLayoutPanel, so checkboxes do not run off-screen when the window is narrower.
- Added consistent primary/secondary button styling and cleaner group sections.
- Launcher recalculates the TabControl size on window resize.
- Added built-in UI bounds validation. The header shows **UI layout OK** when no visible control overflows its parent.
- Layout validation runs on startup and after the user finishes resizing the window.


## v0.9.8 — SplitContainer startup fix

The Quick Run results area no longer uses a `SplitContainer`.
The previous layout set `Panel1MinSize`, `Panel2MinSize`, and `SplitterDistance`
before WinForms had calculated the real container width, causing startup failures.

It is now a two-column responsive `TableLayoutPanel`:
- Results: 45%
- Failed scenarios: 55%

The build also performs a static safety check and refuses packaging if
`Panel1MinSize`, `Panel2MinSize`, or `SplitterDistance` assignments remain in the launcher.


## v0.9.9 — Jira PowerShell 5.1 compatibility

Fixed Jira task loading error `Типы аргумента не совпадают`.

The Jira import layer no longer relies on `System.Collections.Generic.List[object]`
or ambiguous array conversions that can fail under Windows PowerShell 5.1.

Changes:
- comments use normal PowerShell arrays;
- ADF description parsing avoids unsafe collection conversions;
- Jira URI values are explicitly normalized to strings;
- issue loading reports the exact failed stage: issue request / description / comments / mapping;
- detailed fetch errors are written to `reports\jira\jira-fetch-<KEY>.error.log`.


## v0.10.0 — Codex UTF-8 prompt fix

Fixed the reason task-specific tests never reached Playwright.

Windows PowerShell 5.1 redirected the Jira/Cyrillic prompt to Codex using a non-UTF-8
stdin encoding. Codex rejected it with `input is not valid UTF-8`.

Both AI stages now:
1. write the complete prompt to a UTF-8 file without BOM;
2. invoke Codex with stdin redirected from that file;
3. keep the prompt artifact under `reports\ai` for diagnostics.

This applies to:
- Jira requirements analysis;
- task-specific Playwright spec generation.


## v0.11.0 — five-agent QA pipeline

Jira Task is now handled by five separate Codex agent executions:

1. **Jira Analyst** — requirements/current/expected/repro/acceptance.
2. **Test Designer** — strategy, test data, critical assertions, regression scope.
3. **UI Agent** — browser interactions, selectors, visible assertions.
4. **API / Network Agent** — backend/request/response/network/console assertions.
5. **QA Reviewer** — reviews all previous outputs and creates the final executable Playwright spec.

Each agent has its own UTF-8 prompt, output and log under:
`reports\ai\agents\<JIRA-KEY>\`

The Launcher displays five live agent statuses. Playwright starts only after all five stages succeed
and the QA Reviewer output passes `npx playwright test <spec> --list`.


## v0.11.1 — Codex agent deadlock / timeout fix

The five-agent pipeline could stop before creating a Playwright spec because the Launcher
redirected Codex stdout/stderr and waited for process exit before reading those pipes.

`codex exec` produces progress/diagnostic output while it runs. A full redirected pipe can
block the child process, which then appears to the Launcher as an analysis timeout.

v0.11.1:
- starts `ReadToEndAsync()` on stdout and stderr immediately after Codex starts;
- writes the prompt to stdin as raw UTF-8 bytes without BOM;
- uses `--ephemeral` for each QA sub-agent;
- uses low reasoning for specialist agents and medium for the final QA Reviewer;
- increases realistic per-agent timeouts;
- saves partial stdout/stderr even when an agent times out;
- runs a one-time `RX2GO_AGENT_OK` self-test before the first Jira agent pipeline.

Agent artifacts remain under `reports\ai\agents\<JIRA-KEY>\`.


## v0.11.2 — PowerShell variable interpolation parser fix

Fixed Launcher startup parse errors in the five-agent Codex runner.

PowerShell interpreted strings such as `$AgentSlug: ...` as an invalid scoped variable reference.
They now use `${AgentSlug}: ...`.

The build also scans the entire Launcher for unsafe unscoped `$variable:` interpolation before packaging.


## v0.11.3 — visible Jira logs, responsive agent UI, Reviewer auto-repair

- Rebuilt Jira **Проверка и статус** with managed layout containers.
- Added permanent **Лог агентов / Playwright** pane on Jira Task.
- Logs show START/DONE/FAIL, exact error, file path and Playwright output.
- Added open-log-folder and clear-log controls.
- QA Reviewer validates generated spec and performs one repair pass using real Playwright validation errors.
- Playwright starts only after successful validation.
- Layout diagnostics ignore invisible/zero-size controls and use safe interpolation.


## v0.11.4 — QA Reviewer freeze fix

The QA Reviewer itself was completing successfully, but the WinForms Launcher could appear frozen after
generation because Codex and Playwright validation were waited on synchronously in the UI thread.

Changes:
- all Codex waits now use a responsive polling loop with `Application.DoEvents()`;
- Playwright validation uses the same responsive wait;
- project dependencies are prepared once before the five-agent pipeline;
- validation uses only local `node_modules\.bin\playwright.cmd`, never interactive `npx`;
- added `-DependenciesOnly` to `scripts\run-tests.ps1`;
- Agent 5 visibly switches from `generating spec` to `validating Playwright`;
- Reviewer is instructed to avoid broad repository scans when the known Rx2GO files are sufficient.


## v0.11.5 — ADM native first-factor authentication

- Headed ADM runs now start Chrome directly on `https://adm.rx2go.ai/login`.
- The real Chrome HTTP Basic Auth dialog is intentionally preserved.
- The user enters `admin` + today's Telegram code in the browser-native dialog.
- Playwright waits up to 180 seconds for the first factor to complete.
- As soon as the Rx2GO application login form appears, `sergeyqa` login is completed automatically.
- Header-based HTTP Basic authentication remains only as a non-interactive/headless fallback.
- CDP selects the Rx2GO page instead of an incidental blank tab.
- Actual Playwright validation and execution use local `node_modules\.bin\playwright.cmd`; `npx` is no longer used.


## v0.11.6 — unified auth page + automatic ADM first factor

- Quick Run now has one responsive `Access & connections` section.
- The page contains: environment, ADM username `admin`, ADM daily password,
  Rx2GO username, Rx2GO password, Codex CLI status, ChatGPT status.
- Rx2GO password can be saved directly from the page through Windows DPAPI;
  the separate credential popup is no longer required.
- ADM controls keep their geometry when switching environments; they are
  enabled/disabled instead of being dynamically added/removed.
- Quick Run layout was rebuilt on TableLayoutPanel containers to eliminate
  fixed-coordinate overflow and environment-switch layout drift.
- Jira Task no longer owns a duplicate Telegram password field; it uses the
  centralized Quick Run authentication values.
- Headed ADM runs automatically fill the real native Chrome HTTP Basic Auth
  dialog using Windows UI Automation, with a keyboard fallback.
- After the first factor, Playwright completes the `sergeyqa` application login
  and starts the generated test as before.


## v0.11.7 — verified ADM submit + Live Browser Context for Codex

### ADM first factor
- Filling the two native Chrome Basic Auth fields is no longer treated as success.
- The launcher now submits `Войти / Sign in` through four verified fallbacks:
  1. UI Automation `InvokePattern`;
  2. `LegacyIAccessible.DoDefaultAction()`;
  3. real mouse click at the button's native screen coordinates;
  4. focused Enter / keyboard fallback.
- After every method the launcher checks that the native auth prompt actually disappeared.
- If the prompt remains open, the run fails with a clear auth error instead of pretending that first-factor auth succeeded.

### Live Browser Context
The 5 AI agents remain unchanged in count. A non-AI evidence collector now runs after Jira Analyst:

`Agent 1 -> Live Browser Context -> Agent 2 -> Agent 3 -> Agent 4 -> Agent 5`

The collector:
- authenticates against the real selected Rx2GO environment;
- opens the task module (Tickets Queue has a committed route/page object);
- captures current URL/title;
- captures visible page text;
- captures Playwright ARIA snapshot;
- captures visible buttons/inputs/selects/links/roles/testids;
- captures observed XHR/fetch statuses and URLs;
- captures browser console/page errors;
- never captures passwords, cookies, auth headers, input values or request bodies.

Agents 2–5 receive that JSON directly in their prompts. If UI checks are enabled and live page capture fails,
the pipeline stops rather than generating a guessed Playwright flow.


## v0.11.8 — one persistent Chrome for the complete Jira pipeline

The Jira flow no longer creates one Chrome for Live Page Context and another Chrome for the final test.

New lifecycle:

`Chrome start -> ADM first factor -> Rx2GO sergeyqa login -> Live Page Context -> Agents 2–5 -> same Chrome/CDP -> final Playwright test`

Implementation:
- `run-tests.ps1` can save a browser session descriptor containing CDP endpoint and Chrome PID.
- Live Page Context starts Chrome with `-KeepBrowserOpen` and writes that session descriptor.
- The context Playwright worker only disconnects from CDP; it does not close Chrome.
- The Launcher imports and health-checks the CDP endpoint.
- Final Jira Playwright execution receives `-ReuseCdpEndpoint` and reconnects to the same Chrome.
- `authenticated-page.ts` recognizes that the session is already inside Rx2GO and skips both ADM first factor and Rx2GO login.
- No second Chrome is created before Agent 5 / final test.
- If the user disables "Keep browser open", the reused Chrome is closed only after the final test.
- Stale/cross-environment browser sessions are never reused.

## v0.12.0 — Smart QA architecture

Replaces the five planning agents with a three-stage smart pipeline: Requirements Analyst → Microsoft Playwright MCP QA Agent → QA Reviewer. Playwright MCP attaches to the same authenticated Chrome via dynamic CDP, performs real UI actions, prepares run-scoped test data, and executes acceptance criteria before a deterministic Playwright spec is generated. Final Playwright reuses the same browser. On FAIL, a conditional Failure Triage agent classifies product bug vs automation/auth/test-data/environment/flaky. BrowserStack MCP is optional and can be configured separately with `CONFIGURE BROWSERSTACK MCP.bat`.


## v0.12.1 — Playwright MCP actually controls the authenticated Chrome

v0.12.0 could register Playwright MCP but still fail to test. The raw MCP server was launched without Codex `env_vars`, so run-scoped `PLAYWRIGHT_MCP_CDP_ENDPOINT` was not forwarded and the MCP server opened its own `about:blank` browser. In addition, headless `codex exec` used `approval_policy=never`, while Playwright navigation/tab tools requested MCP approval and were rejected.

v0.12.1 fixes both at the Playwright MCP server policy level without disabling the Codex filesystem sandbox:

- `[mcp_servers.playwright]` receives `env_vars` for the dynamic CDP endpoint, timeout, codegen, console level and output directory;
- `default_tools_approval_mode = "approve"` auto-approves Playwright MCP tools for the trusted local Playwright server;
- a mandatory MCP session preflight calls `playwright/browser_tabs` and `playwright/browser_snapshot` and verifies that the URL is the selected Rx2GO environment before Smart QA is allowed to continue;
- Smart QA must use only `playwright/browser_*` tools and must not divert into the bundled Browser/Chrome/Computer Use plugin or node_repl;
- Launcher verifies completed `mcp: playwright/browser_* (completed)` calls from the actual Codex log instead of trusting only the agent JSON;
- `about:blank`, approval-policy failures and missing MCP calls are classified as MCP infrastructure failure, never as a product FAIL/BLOCKED.


## v0.12.2 — persistent browser bootstrap lifecycle fix

- Jira Smart QA no longer uses `live-page-context.spec.ts` as the browser bootstrap.
- Added a minimal `session-bootstrap.spec.ts` that only completes authentication and proves the browser is inside the selected Rx2GO environment.
- No Tickets Queue navigation or DOM-context collection happens during bootstrap.
- The persistent Chrome session is imported and reused by Playwright MCP after bootstrap.
- Bootstrap failure no longer calls `Stop-PersistentBrowserSession` for the newly opened diagnostic browser.
- MCP preflight failure also leaves the authenticated Chrome open.
- Chrome is closed only at the normal end of the complete QA run when the user did not request Keep Browser Open.


## v0.12.3 — PowerShell Host crash fix after successful MCP preflight

- Fixed a Launcher crash caused by assigning to `$host`.
  PowerShell treats `$Host` case-insensitively and it is a built-in read-only variable.
- The environment URL validator now uses `$expectedHost`.
- MCP preflight URL validation is wrapped in a controlled try/catch.
- Successful preflight now logs that the SAME authenticated Chrome was confirmed before Smart QA starts.
- Added a WinForms thread-exception handler so future Launcher UI exceptions are logged with a clear message instead of only the generic .NET Framework dialog.
- The browser is not intentionally closed by this error handler.


## v0.12.4 — readable Jira reports with actually executed cases

- Jira report is now generated from `Playwright MCP QA` live execution evidence.
- Report contains task, module, environment, facility, user, date, method and overall result.
- `ВЫПОЛНЕННЫЕ КЕЙСЫ` lists every acceptance result with PASS/FAIL/BLOCKED and concrete evidence.
- Fresh test-data IDs (order/source/related tickets) are included.
- API/network, console evidence, screenshots, blockers and RCA are included when available.
- Live Smart QA result is distinguished from the final deterministic Playwright result.
- Report is automatically saved as `jira-readable-report.txt` after Smart QA and refreshed after final Playwright/RCA.
- Jira button now copies the readable executed-cases report.
- Smart QA wrapper timeout no longer discards a complete valid PASS/FAIL/BLOCKED final JSON.
- Related-ticket Smart QA execution is instructed to use the smallest fixture (one order + three tickets) and stop unnecessary setup exploration.


## v0.12.5 — task screenshots as real Codex vision input

- Jira Task now supports screenshots supplied by the tester.
- `📷 Буфер` attaches the current clipboard image.
- `Файлы…` supports multiple PNG/JPG/JPEG/BMP screenshots.
- Up to 8 screenshots can be attached to one QA run.
- `Ctrl+V` in Jira task text or QA Comment attaches an image when the clipboard contains a screenshot; normal text paste remains unchanged.
- Images are normalized to PNG and stored only under `reports/task-screenshots`, never committed to Git.
- `Invoke-CodexAgent` now supports `-i/--image` input and attaches screenshots as actual multimodal context.
- Screenshots are supplied to Requirements Analyst, Playwright MCP QA, Smart QA Reviewer/repair, and Failure Triage.
- Analyst is instructed to use screenshots as supplementary evidence without inventing requirements from visuals alone.
- Playwright MCP QA uses screenshots to understand the task, but the current live browser remains runtime source of truth.
- Jira readable report records how many task screenshots were passed to AI.


## v0.12.6 — CDP navigation guard + product/automation result separation

- Added a deterministic spec runtime-safety guard for persistent CDP sessions.
- Generated specs using `page.goto('/relative')` or another literal non-absolute URL are rejected before runtime and sent through Reviewer repair.
- Reviewer/repair prompts explicitly require absolute environment-derived URLs via `resolveBaseUrl()` because reused CDP BrowserContexts do not inherit Playwright `use.baseURL`.
- Smart QA now returns human-readable execution evidence in Russian while preserving literal UI/HTTP/selectors.
- When mutation permission is disabled, Smart QA is explicitly forbidden from creating or changing any Rx2GO entity.
- Launcher rejects Smart QA output that reports `testData.created=true` while Jira mutation permission is disabled.
- Jira readable report now reads mutation permission from the Jira Task checkbox.
- Jira report separates `Итог проверки продукта`, `Live Smart QA`, and `Deterministic Playwright`.
- If live Smart QA PASS is followed by a deterministic failure classified as `TEST_AUTOMATION_BUG`, the product result remains PASS and automation is reported separately as an error.
- Launcher status uses amber `PRODUCT PASS — ошибка deterministic автотеста` instead of falsely showing a product FAIL for this case.
- Failure Triage human-readable fields are requested in Russian.


## v0.12.7 — PASS/FAIL desktop banners and sounds

- Added a non-blocking result banner in the bottom-right corner of the primary Windows screen.
- PASS: green banner + Windows Asterisk success sound.
- FAIL: red banner + Windows Hand/error sound.
- Banner is TopMost, does not block the launcher, can be clicked to close, and auto-closes after about 6.5 seconds.
- Jira notification uses the PRODUCT result, not blindly the deterministic Playwright exit code.
  Therefore `Live Smart QA PASS + TEST_AUTOMATION_BUG` shows a green PASS notification rather than a false red product FAIL.
- FAIL banner can include the Failure Triage summary.
- Quick Run also shows the same PASS/FAIL sound + bottom-right banner after its Playwright run completes.


## v0.12.8 — conditional QA comment semantics + persistent task screenshots

### Fresh test data guard
- Fixed false-positive blocking for conditional QA notes such as:
  `при создании ордера Client ID должен быть 219208881`.
- A conditional constraint no longer means that an order/ticket must be created.
- Fresh data is required only for explicit creation instructions such as:
  `создать тестовый ордер`, `создать несколько тикетов`, `need to create a fresh order`.
- Pipeline logs now show `FRESH DATA POLICY → REQUIRED` or
  `FRESH DATA POLICY → OPTIONAL / NOT REQUIRED`.
- Smart QA prompt explicitly distinguishes conditional test-data constraints from mandatory setup instructions.

### Task screenshots
- Task screenshots are now stored under `%LOCALAPPDATA%\Rx2GO-AI-QA\task-screenshots\<JIRA-KEY>`.
- Screenshots survive extracting and running a newer Launcher version.
- Loading a Jira issue automatically restores screenshots previously attached to that Jira key.
- Screenshots pasted before the Jira key is loaded are migrated into the Jira-key folder when the issue becomes known.
- Clear removes the current task's persistent screenshot files.


## v0.12.9 — Knowledge Git controls + clickable result toast

### Knowledge / Git
- `Проверить GitHub` now performs a real `git ls-remote origin` connectivity/authentication check.
- `Обновить статус` now gives visible timestamped feedback instead of silently repainting unchanged values.
- Added clear action status colors/messages for GitHub check, refresh, Commit and Synchronize.
- `Commit` button is always present in the responsive Knowledge layout and is enabled when there are changes / no initial commit.
- Rebuilt Knowledge Git section with TableLayoutPanel instead of fixed coordinates.
- Rebuilt Commit section with TableLayoutPanel; the Commit button can no longer drift outside the visible area after reparent/resize.
- Removed redundant floating Commit label from responsive layout.

### PASS / FAIL toast
- Clicking anywhere on the green/red result banner now closes it immediately.
- Uses `MouseDown` + `sender.FindForm()` instead of a fragile PowerShell closure over `$toast`.
- Timer stores the form in `Tag`, so auto-close remains reliable.
- Toast appears on the monitor containing the Launcher.


## v0.12.10 — Windows PowerShell 5.1 parser fix

- Fixed Launcher startup failure caused by interpolated strings containing `$timestamp:`.
- Windows PowerShell 5.1 interprets `$name:` as a scoped-variable expression; the launcher now uses `${timestamp}:`.
- Added release-time scanning of all PowerShell files for unsafe unscoped `$variable:` interpolation patterns.


## v0.12.11 — GitHub browser OAuth via Git Credential Manager

- `Проверить GitHub` now recognizes GitHub authentication failures separately from network/repository failures.
- On `Invalid username or token`, `Authentication failed`, or password-authentication errors, Launcher offers `Подключить GitHub через браузер`.
- GitHub passwords/PATs are not stored in the Launcher.
- Uses Git Credential Manager (GCM) browser OAuth and Windows credential storage.
- Before re-authentication, only the stale HTTPS credential scoped to `github.com` is rejected through the standard `git credential reject` protocol.
- The repository keeps its HTTPS origin.
- After browser OAuth, Launcher automatically runs `git ls-remote origin` again and reports success/failure.
- `Synchronize` also detects missing GitHub authentication and offers the same browser-OAuth flow.
- Button renamed to `Проверить / подключить GitHub`.


## v0.12.12 — GitHub SSH, no browser authentication

- GitHub browser OAuth is disabled in Launcher.
- GitHub repository uses SSH origin: `git@github.com:QA-E2E4/rx2go-ai-qa.git`.
- Launcher checks `~/.ssh/id_ed25519` and can generate a local ed25519 key.
- Added `Создать SSH key` and `Скопировать public key` buttons.
- Launcher can start Windows `ssh-agent` when available and add the private key with `ssh-add`.
- `Проверить GitHub SSH` performs `ssh -T git@github.com` and then `git ls-remote origin`.
- GitHub's successful `ssh -T` message is accepted even though GitHub intentionally returns exit code 1.
- If the public key has not been registered in GitHub yet, Launcher copies it to clipboard and shows one-time manual instructions.
- Launcher never opens a browser for GitHub authentication.
- Commit / Synchronize use SSH after setup.
- Existing HTTPS origin is automatically changed to SSH.
- No GitHub PAT/password is stored by Launcher.


## v0.12.13 — consistent Commit / Synchronize Git scope

- Fixed contradiction where Git status counted the whole repository but Commit staged only a smaller subset.
- Managed Git paths now include the Launcher/bootstrap/run/setup/check/install root scripts and safe project config files.
- Commit stages modifications, additions and deletions with `git add -A -- <managed paths>`.
- Runtime/secrets remain excluded.
- `Get-GitState` distinguishes managed project changes from unrelated changes outside the safe list.
- Commit button and status messages use managed changes.
- Synchronize blocks only on uncommitted managed project changes.
- Unrelated dirty files no longer trigger the misleading `Сначала нажми Commit` loop.
- Synchronize fetches first; if remote is ahead while unrelated dirty files exist, Pull stops with a precise safety warning.


## v0.12.14 — first push for a GitHub repository without origin/main

- Fixed `Synchronize` failure `fatal: couldn't find remote ref main`.
- Synchronize now checks the remote branch with `git ls-remote --exit-code --heads origin <branch>` before fetching.
- If `origin/main` does not exist yet, Launcher treats this as a brand-new repository and performs `git push -u origin main`.
- The first push creates the remote branch and upstream tracking in one step.
- Fetch/pull comparison runs only when the remote branch already exists.
- Existing SSH authentication and safe managed/unmanaged dirty-file behavior are preserved.


## v0.12.15 — task-specific retrieval memory from GitHub + local repository

- Added a deterministic `Knowledge Retrieval` stage before every Jira Smart QA run.
- Before retrieval, Launcher performs a safe `git fetch` remote snapshot when possible.
  It does not `pull`, merge, or modify the working tree.
- Retrieval searches:
  - prior `jira-cases`;
  - regression `scenarios`;
  - existing Playwright `tests`;
  - `knowledge` files;
  - `pages` and `api` helpers.
- Historical knowledge/scenarios/Jira cases prefer the fetched GitHub snapshot.
- Executable tests/helpers prefer the current local workspace so generated automation matches the running version.
- Retrieval is task-specific using Jira text, QA Comment, Jira key, resolved module and acceptance criteria.
- A preliminary retrieval is passed to Requirements Analyst.
- After module resolution, retrieval is refined and passed to Playwright MCP QA, QA Reviewer and Failure Triage.
- Prior TEST_AUTOMATION_BUG knowledge is explicitly used as a warning to avoid repeating old automation mistakes.
- Memory never overrides current Jira requirements or live MCP evidence.
- Up to 22 bounded snippets are passed to AI; retrieval artifacts are saved under `reports/knowledge-retrieval/<JIRA-KEY>`.
- Jira readable report lists how many memory files were used and the top memory sources.


## v0.12.16 — SCRUM-3403 date-format false-Fail prevention

- Latest Jira comments can narrow an umbrella task to the current testing batch.
- Analyst extracts the latest partial-scope comment before deciding current-run acceptance.
- External Chrome uses `--lang=en-US`.
- Native `input[type=date]` DOM value is treated as ISO data, not as formatted visible MM/DD/YYYY text.
- A native date field cannot fail only because a non-US screenshot shows localized formatting.
- Date tests use locale + element type/value + current screenshot evidence and prefer non-ambiguous `11/30/2028`.
- Smart QA must not reuse entities marked with another Jira key.
- Added a cross-Jira test-data guard.
- Failure Triage treats wrong-locale native date assertions as automation/environment errors.
- Added `knowledge/date-format-testing.yaml` for retrieval memory.


## v0.12.17 — global Result Integrity Gate + editable imported Jira source

### Global false-result prevention
- Added `Result Integrity Gate` for every Smart QA Jira execution.
- Smart QA must return a machine-readable integrity self-audit:
  - live current-run evidence;
  - current execution scope only;
  - isolated/current-task test data;
  - historical evidence not used as verdict;
  - environment assumptions verified.
- Overall PASS/FAIL is checked against individual acceptance-result statuses.
- FAIL requires a concrete failed acceptance criterion with current-run evidence.
- Ambiguous inferred FAIL evidence is rejected.
- Test-data provenance is included in the MCP JSON contract.
- Cross-Jira data contamination remains independently blocked.
- A built-in integrity self-test runs before the real Smart QA pipeline and stops the run if the guard itself is broken.
- Added `knowledge/test-result-integrity.yaml` for retrieval memory.

### Editable imported Jira text
- `Импортированное описание и комментарии Jira` is now editable.
- Manual edits are visibly marked in the status label.
- Smart QA / Knowledge Retrieval / Requirements Analyst use the edited imported text as the actual Jira source for the run.
- Reloading Jira replaces manual edits with the current Jira content and resets the edited flag.
- Jira-readable report records whether the imported Jira source was manually edited.


## v0.12.18 — duplicate KnowledgeContext fix + SSH-only memory sync

- Fixed PowerShell runtime error: `KnowledgeContext` was supplied twice to Requirements Analyst.
- Requirements Analyst now receives exactly one preliminary retrieval context.
- Playwright MCP QA again receives refined retrieval memory.
- Default Git origin is SSH from the first repository initialization.
- Existing Rx2GO HTTPS origin is silently migrated to SSH.
- Startup Knowledge sync cannot invoke Git Credential Manager/browser OAuth.
- Knowledge Retrieval cannot invoke Git Credential Manager/browser OAuth.
- Remote retrieval uses existing SSH in BatchMode; if SSH is unavailable, the run continues with local Knowledge Base.
- Added release audit for duplicated named arguments in multiline PowerShell calls.


## v0.12.19 — automatic post-run Knowledge Base learning

- Every completed Jira Smart QA run with live MCP evidence now triggers `Knowledge Auto-Learning`.
- Existing `jira-cases/<JIRA>.md` saving remains; Auto-Learning adds distilled reusable project knowledge under `knowledge/learned/<module>/<JIRA>.json`.
- A lightweight Codex Knowledge Curator extracts:
  - stable product facts;
  - navigation/UI facts;
  - API/network contracts;
  - stable test-data rules;
  - automation lessons;
  - regression candidates;
  - advisory project-rule candidates.
- Even if the Curator is unavailable, a deterministic verified acceptance snapshot is still saved.
- Rerunning the same Jira key merges/deduplicates learned string facts rather than creating duplicate files.
- Knowledge learning never changes the product PASS/FAIL result if the curator fails.
- Secrets/session material and transient order/ticket/route IDs are filtered from learned knowledge.
- Historical Retrieval Memory is reference/dedup context only; it cannot be promoted to a new fact without current-run evidence.
- Learned files immediately participate in future Knowledge Retrieval because `knowledge/**` is already part of retrieval sources.
- Knowledge tab displays the number of Auto-Learning files.
- Jira-readable report records how much knowledge was automatically saved.
- Auto-Learning writes Git-managed knowledge files automatically, but does NOT auto-commit or auto-push. Commit/Synchronize remain explicit to avoid unexpectedly pushing project code.


## v0.12.20 — automatic Commit + Push after Jira testing

- After every completed Jira Smart QA run:
  `Auto-Learning -> Auto Commit -> Auto Push over SSH -> Jira readable report`.
- Safe managed project changes are staged automatically, including generated tests,
  knowledge files, Jira cases, helpers, scripts and Launcher/project code.
- Commit message:
  `Auto QA <JIRA-KEY> <PASS|FAIL> yyyy-MM-dd HH:mm`.
- Existing unpushed local commits are also pushed on the next completed Jira run.
- First push creates `origin/<branch>` and upstream automatically.
- GitHub authentication remains SSH-only; browser OAuth is never used.
- If remote is ahead and there are no unrelated dirty files, local commits are rebased automatically before push.
- If unrelated local files are dirty while remote is ahead, auto-sync pauses instead of modifying/stashing those files.
- Failed rebase is automatically aborted.
- Failed push preserves the local commit.
- Git failures never change the product PASS/FAIL verdict.
- Jira report records Auto Git state, commit hash, sync result and warning.
- Knowledge tab shows Auto Commit + Push = ON.


## v0.12.21 — risk-based coverage + explicit Knowledge Base failures

### Broader test design
- Jira acceptance remains mandatory, but Smart QA no longer stops at the literal task text.
- Added a pre-execution Smart Coverage Designer.
- It designs high-value:
  - positive;
  - negative;
  - boundary;
  - regression;
  - integration;
  - UI/backend data consistency;
  - reload/repeat/resilience cases.
- Coverage uses Jira scope, Requirements Analyst risk ideas and Knowledge Retrieval.
- MCP executes relevant P0/P1 negative/regression checks and returns `additionalResults`.
- Additional impacted regression failures can affect overall Jira FAIL.
- Advisory unrelated findings do not distort the Jira result.
- Reviewer includes only additional checks actually proven by live MCP evidence in deterministic Playwright.
- Jira report now has a separate section for negative/boundary/regression cases.

### Knowledge Base visibility
- If remote Knowledge Retrieval fails, the user gets a clear warning and testing continues with local memory.
- If post-run knowledge cannot be stored locally, the user gets a clear warning.
- If GitHub auto-push fails, the user gets a clear warning that local knowledge/commit is preserved.
- Knowledge read/write failures never silently change the product PASS/FAIL verdict.
- Added `knowledge/smart-test-coverage-policy.yaml`.


## v0.12.22 — fixture recovery before BLOCKED + yellow insufficient-data state

Built directly on v0.12.21.

### Fixture recovery
- Smart QA no longer accepts an immediate BLOCKED just because an existing selected entity has empty history / zero rows / unsuitable state.
- When data mutation is enabled and the blocker is fixture/data related, Launcher automatically runs one `Playwright MCP fixture recovery` pass in the SAME authenticated Chrome.
- Recovery must create fresh isolated current-Jira test data and re-run blocked acceptance checks.
- For Activity History/audit requirements, creating an entity alone is insufficient: recovery must generate at least one safe QA-only history entry where a confirmed workflow exists.
- Final BLOCKED is allowed only after a concrete fresh-fixture path was attempted and could not safely produce the needed state.
- Initial blocked evidence is retained in `smart-mcp-initial-blocked.json`; recovery evidence is retained in `smart-mcp-fixture-recovery.json`.

### BLOCKED UI semantics
- BLOCKED is now a first-class agent state, not `FAIL/ошибка`.
- Pipeline label: `недостаточно данных`.
- Main result: `НЕДОСТАТОЧНО ДАННЫХ` in amber.
- Jira report mark: `⚠ НЕДОСТАТОЧНО ДАННЫХ`.
- A clickable amber result toast is shown with an Exclamation system sound.
- BLOCKED does not count as a product FAIL.

### Knowledge lifecycle
- A terminal BLOCKED live run is finalized as a completed QA observation.
- It is saved to the readable Jira report.
- Auto-Learning runs for the blocked observation, so fixture/setup lessons are reusable.
- Auto Commit + Push remains enabled; Git/Knowledge errors do not alter the product result.
- Added `knowledge/fixture-recovery-policy.yaml`.


## v0.12.23 — all test-data actions are always authorized

Built on v0.12.22.

- Mutation of clearly identified QA/test data is now a global always-on policy.
- Jira Task and Quick Launch mutation controls are permanently checked and disabled.
- Agents may create, edit, update, modify, save, submit, transition, assign/unassign,
  link/unlink, remoderate, resolve/reopen, attach/detach, delete, recreate and cleanup
  current-run QA fixtures whenever required by testing.
- Fixture Recovery no longer depends on a mutation checkbox.
- A data-related BLOCKED must first attempt all safe current-run QA mutations that can
  reasonably produce the required state.
- Generated deterministic Playwright tests may reproduce the proven fixture lifecycle,
  including cleanup.
- Safety boundary: never mutate an unmarked pre-existing business/customer entity.
- Historical order/ticket/route IDs from Knowledge Retrieval remain reference-only.
- Jira report explicitly states that test-data actions are always authorized.
- Added `knowledge/test-data-mutation-policy.yaml`.


## v0.12.24 — startup parser hotfix

- Fixed the v0.12.23 startup ParseException at `Rx2GO-QA-Launcher.ps1:9324`.
- The previous build accidentally emitted literal PowerShell characters `` `r`n `` between
  `$jiraMutatingCheck.Checked = $true` and `$mutatingCheck.Checked = $true`.
- They are now two normal PowerShell statements on separate physical lines.
- Added a release-time lexical audit that rejects literal `` `r`n `` tokens when they occur
  in executable PowerShell code outside strings/comments/here-strings.
- All v0.12.23 behavior is preserved: test-data mutation is always ON, fixture recovery,
  risk-based coverage, Knowledge Auto-Learning, Auto Commit + Push, Integrity Gate,
  editable Jira source, and BLOCKED/insufficient-data handling.


## v0.12.25 — Jira Queue with up to 3 isolated parallel Workers

- Added a new responsive `Jira Queue` tab.
- Queue accepts one or many Jira keys/URLs and remembers the environment per task.
- Configurable concurrency: 1–3 Workers (default 3).
- Queue controls: Add, Start, Pause, Resume, Retry, Stop Worker, Remove, priority Up/Down, Open logs.
- Each task runs in a separate hidden Launcher Worker process with its own project runtime, reports and Chrome/CDP session.
- The actual Chrome windows remain visible for QA; only the child Launcher shell is hidden/minimized.
- Worker copies exclude `.git`, `node_modules`, reports, runtime state, `.env` and secrets; `node_modules` is shared via a junction after the parent Playwright preflight.
- Worker Knowledge Retrieval uses the copied local snapshot and never runs Git/browser OAuth.
- Finished worker outputs are merged back only from safe managed paths: `knowledge`, `jira-cases`, `scenarios`, `tests/generated`.
- Learned JSON is merged/deduplicated so concurrent workers do not overwrite accumulated knowledge.
- Git commit/push is serialized by the parent Launcher after each worker merge; workers never push directly.
- New waiting Workers therefore start from the latest already-merged Knowledge Base.
- Queue state is persisted under `%LOCALAPPDATA%\Rx2GO-AI-QA\queue`; interrupted runs return as `INTERRUPTED` and can be retried.
- Parent Quick Run/Jira Run is disabled while the queue is active to avoid shared-state/Git conflicts.
- Parent close prompts before terminating active queue Workers.
- Queue Worker results are reported as PASS / FAIL / BLOCKED / ERROR / STOPPED.
- Added worker heartbeat/status files so the main queue displays ANALYZING / TESTING / REVIEWING / PLAYWRIGHT / RCA phases.
- Added a Queue engine self-test before use.
- Queue UI uses only Dock/TableLayout/FlowLayout/DataGridView managed layout and is included in the existing UI layout-health scan.
- Preserved v0.12.24 features: always-on test-data mutation, fixture recovery, risk-based coverage, editable Jira source, Result Integrity Gate, Auto-Learning, SSH Git and Auto Commit/Push.


## v0.12.26 — Codex limit-safe Fixture Recovery in Jira Queue

Built on v0.12.25.

### Codex usage/rate limit
- Codex non-zero exits are classified (`CODEX_USAGE_LIMIT`, `CODEX_TIMEOUT`, `CODEX_AUTH`, etc.).
- If Fixture Recovery is interrupted by a Codex usage/rate/quota limit, the original live BLOCKED result is preserved.
- The interrupted recovery is never converted to a red product FAIL or fake QA failure.
- Single-task mode shows a clear Codex-limit warning.
- Queue workers do not show hidden modal dialogs.
- Parent Jira Queue detects the usage-limit reason, pauses new worker launches, and shows one clear warning.
- Resume clears the queue circuit breaker after the limit recovers.

### Fixture Recovery token/tool budget
- Recovery prompt is compact: only current narrowed scope, blockers, blocked acceptance, test-data provenance, selected P0/P1 coverage and compact Knowledge snippets.
- Recovery uses low reasoning effort and a shorter 540s wrapper timeout.
- Recovery is explicitly restricted to `playwright/browser_*` browser work.
- Browser plugin / node_repl / native-host / registry / unrelated MCP diagnostics are forbidden.

### Autocomplete correctness
- Recipient / Street Address / Facility / Client / Pharmacy and similar fields are treated as autocomplete controls.
- `fill()` alone is not acceptance.
- The agent must select the real suggestion and verify `Is required` / invalid state disappears before Add/Save.
- This rule applies to both initial Smart QA and Fixture Recovery.

### Preserved v0.12.25 functionality
- Jira Queue with up to 3 isolated workers.
- Worker Chrome/CDP isolation.
- serialized Knowledge merge + Git sync.
- Risk-based coverage, Fixture Recovery, Result Integrity Gate.
- Editable Jira source.
- Auto-Learning and Auto Commit + Push.
- Test-data mutation always ON.


## v0.12.27 — Windows PowerShell 5.1 Queue startup hotfix

- Fixed the v0.12.26 startup crash in `Refresh-QueueGrid`.
- `QueueItems` changed from `Generic.List[object]` to PowerShell-5.1-safe `ArrayList`.
- ArrayList `.Add()` output is suppressed.
- Queue status is null-safe.
- Queue self-test now checks the collection behavior that caused the crash.
- Self-test runs before the first Queue grid refresh.
- Queue rendering has a fail-safe: Queue can disable itself without terminating the main Launcher.
- All v0.12.26 queue/Codex/Fixture Recovery/Auto-Learning/Auto-Git functionality is preserved.


## v0.12.28 — Knowledge/Git reliability + select assertion guard

Built on v0.12.27.

### Knowledge Base
- Fixed Windows PowerShell 5.1 `Argument types do not match` in post-run learned knowledge.
- Knowledge learning string collections and verified acceptance snapshots now use ArrayList.
- Queue learned-knowledge merge uses the same PS5.1-safe collection strategy.
- Added a runtime Knowledge Auto-Learning self-test before writing learned JSON.
- Removed duplicate CuratorStatus assignment.

### Git
- `Invoke-Git` now starts async stdout/stderr reads before waiting, preventing redirected-pipe deadlocks.
- Git wait keeps WinForms responsive.
- Default Git timeout increased to 60s.
- `git add` gets 120s.
- Git argument collections use ArrayList.

### Deterministic Playwright
- Added a reviewer rule and static repair guard for HTML `<select>` assertions.
- Visible labels such as Facility `New York` are asserted through selected-option text (`option:checked`) unless live evidence proves the internal option value equals the label.
- Prevents the SCRUM-4075 false automation failure where DOM value was `2` but visible option was `New York`.

### Jira report
- Final readable report is re-rendered at the true end of the lifecycle after Playwright + RCA + Knowledge Auto-Learning + Git sync.
- Prevents stale reports saying `ФИНАЛЬНЫЙ PLAYWRIGHT: ещё не завершён`.

All v0.12.27 Jira Queue / isolated workers / Codex circuit breaker / Fixture Recovery / risk coverage / mutation-always-on functionality is preserved.


## v0.12.29 — PowerShell parser hotfix for select assertion guard

Built directly on v0.12.28.

- Fixed startup ParseException in `Test-SmartSpecSelectAssertionSafety`.
- Root cause: v0.12.28 used backslash escaping for a single quote inside a single-quoted PowerShell regex string. Windows PowerShell does not use backslash to escape `'`.
- The guard now uses two parser-safe regexes:
  - `toHaveValue('...')`
  - `toHaveValue("...")`
- The SCRUM-4075 select-label protection remains active: visible labels such as `New York` should be asserted through selected-option text unless the internal option value was proven by live evidence.
- No Jira Queue, Fixture Recovery, Knowledge, Git, Auto-Learning, risk-coverage, mutation or UI-layout behavior was intentionally changed.


## v0.12.30 — recover completed Smart QA result after Codex wrapper timeout

Built on v0.12.29.

- Fixed a race observed on SCRUM-4075: the Playwright MCP QA agent completed its live work and produced a valid final FAIL JSON, but the Codex/MCP wrapper did not exit before the 900-second timeout.
- v0.12.29 checked the `-o` output only before terminating the timed-out process.
- v0.12.30 performs a second recovery pass after `Kill()` / `WaitForExit()`, because Codex can flush the final output file while the wrapper is terminating.
- Recovered output is accepted only when it is valid JSON, `status` is PASS/FAIL/BLOCKED, and `mcpUsed=true`.
- Successful recovery continues the normal pipeline instead of marking Playwright MCP QA as an automation error.
- Existing v0.12.29 select assertion guard, Knowledge Auto-Learning, async Git, Jira Queue, Fixture Recovery, risk coverage, Integrity Gate and mutation policy are preserved.


## v0.12.31 — main Smart QA Codex usage-limit handling

Built on v0.12.30.

- Fixed SCRUM-4075 run where the main `02-playwright-mcp-qa` exited with Codex usage-limit error and the Launcher showed a red `MCP QA FAILED`.
- `CODEX_USAGE_LIMIT` is now treated as an infrastructure interruption, not a product or automation FAIL.
- Single-task UI shows amber `CODEX LIMIT — ПАУЗА` and a clear retry message.
- No synthetic product PASS/FAIL is created when final Smart QA JSON is missing.
- Incomplete usage-limit runs do not update post-run product Knowledge.
- Queue Worker completes as BLOCKED with a CODEX_USAGE_LIMIT marker.
- Jira Queue detects the marker and pauses new workers automatically.
- Existing timeout final-JSON recovery from v0.12.30 remains unchanged.
- Jira Queue, Fixture Recovery, select guard, Knowledge Auto-Learning, async Git, Integrity Gate and mutation-always-on are preserved.


## v0.12.32 — Windows PowerShell 5.1 parser hotfix

Built on v0.12.31.

- Fixed Launcher startup ParseException in `Finalize-QueueWorkerItem`.
- Root cause: an `if/else` statement was passed directly inside `-Details (...)`.
- Windows PowerShell 5.1 does not support that expression form.
- Conditional text is now calculated in `$codexLimitDetails` first and then passed as a normal argument.
- Added a release gate that scans all PowerShell files for the same `-Parameter ( if (...) )` anti-pattern.
- No functional behavior from v0.12.31 was intentionally changed.

## v0.12.33 — Task Understanding Contract

- Requirements Analyst separates Jira requirements, Jira comments, QA guidance, screenshots, project rules and Knowledge by authority.
- Adds task goal, in/out scope, state-change model, forbidden side effects, AC1/AC2/... acceptance matrix, source trace, ambiguities and confidence.
- Deterministic Understanding Gate blocks browser execution on weak/mixed requirements, confidence <70%, HIGH ambiguity or unresolved contradiction.
- Existing Test Plan panel shows how the system understood the task; no layout controls were added.
- Coverage Designer, Playwright MCP, Fixture Recovery and Reviewer are locked to the same contractId and acceptance IDs.
- Result Integrity Gate rejects missing/unknown AC IDs, contract mismatch and unverified live context.
- v0.12.32 Queue/Codex/Knowledge/Git/Fixture Recovery functionality is preserved.


## v0.12.34 — Knowledge Explorer for HOT

Added a dedicated Knowledge Explorer to the existing Knowledge tab.

- Modes:
  - Quick crawl — structure
  - Deep crawl — UI + API + Network
  - Selected module
  - Workflow exploration
  - Refresh stale knowledge
- Priority modules: Orders, Scanner, Tickets Queue, Dispatcher, QAQC, Routes/Gigs, Copays, Chat.
- Explorer reuses the same authenticated persistent Chrome and Playwright MCP.
- Quick/deep/module/refresh are read-only.
- Workflow mode may mutate only fresh isolated QA test data and never unmarked business/customer entities.
- Structured output is stored under `knowledge/explorer/`.
- Module knowledge is indexed in `knowledge/explorer/index.json`.
- Observed facts are explicitly marked as non-requirement knowledge.
- Secrets and personal customer/patient data are forbidden from Explorer output.
- Explorer auto-commits only `knowledge/explorer` and pushes when GitHub SSH is ready.
- Existing staged files outside Explorer block auto-commit to avoid mixing unrelated changes.
- Stale refresh threshold defaults to 14 days.
- The Knowledge tab uses managed TableLayoutPanel layout; no absolute final positioning was added.
- Existing v0.12.33 Task Understanding Contract, Jira Queue, Fixture Recovery, Codex handling, Auto-Learning, async Git, Integrity Gate and mutation policy remain.


## v0.12.35 — ADM baseline / HOT delta / BRANCH temporary knowledge

Knowledge Explorer architecture was inverted to match the real Rx2GO deployment flow:

`BRANCH -> HOT -> ADM`

- ADM is now the primary/stable Knowledge baseline.
- HOT Explorer automatically compares against ADM and stores a persistent `HOT_DELTA`.
- BRANCH Explorer automatically compares against HOT and stores a local `BRANCH_TEMPORARY_DELTA`.
- HOT PASS never modifies ADM baseline automatically.
- ADM knowledge changes only when the behavior is re-observed on ADM.
- Environment selector added to Knowledge Explorer: ADM / HOT / BRANCH.
- Baseline is automatic:
  - ADM -> none / primary baseline
  - HOT -> ADM
  - BRANCH -> HOT
- Explorer JSON now includes `knowledgeLayer`, `baselineEnvironment`, `baselineAvailable`, `temporary`, and `baselineComparison`.
- HOT/BRANCH cannot be marked COMPLETE without the required baseline comparison when baseline exists.
- If baseline is missing, HOT/BRANCH exploration is PARTIAL instead of inventing a comparison.
- v0.12.34 HOT-only Explorer files are migrated into `knowledge/explorer/hot/`.
- BRANCH Explorer is local-only and is not auto-committed/pushed.
- Knowledge retrieval is environment-aware:
  - ADM agents receive ADM Explorer knowledge.
  - HOT agents receive ADM baseline + HOT delta, with HOT boosted.
  - BRANCH agents receive ADM + HOT + temporary BRANCH delta, with BRANCH boosted.
- Explorer cannot run while Jira Smart QA or Jira Queue is active, avoiding shared-browser contamination.
- Existing Task Understanding Contract remains authoritative: Explorer observations are advisory, never requirements.


## v0.12.36 — clear Git sync + persistent GitHub SSH status

- Added a persistent `GitHub SSH` status row to the Knowledge tab.
- `Проверить GitHub SSH` now leaves a visible state: CHECKING / CONNECTED / KEY NOT FOUND / KEY NOT REGISTERED / AUTH FAILED / ERROR.
- Successful SSH status includes GitHub user (when returned by GitHub), repository availability, and check time.
- Added `Показать изменения` button with concrete managed/outside Git file paths.
- Git status now distinguishes outside `tracked` vs `untracked` changes.
- Remote-ahead synchronization no longer blocks only because untracked files exist.
- `git pull --ff-only` is attempted with untracked files; Git itself safely refuses if a remote path would overwrite one.
- Tracked changes outside Launcher-managed files still block Pull, and the blocking dialog lists the exact files.
- Added runtime ignore rules for `*.log`, `package-lock.json`, and temporary `knowledge/explorer/branch/`.
- Existing ADM baseline / HOT delta / BRANCH temporary Knowledge architecture is preserved.


## v0.12.37 — Knowledge persistence status

The Knowledge tab now answers the important question directly: **are the accumulated knowledge files really saved in GitHub?**

- Added a prominent status inside the Git repository panel:
  - `✅ ЗНАНИЯ СОХРАНЕНЫ В GITHUB`
  - `🟡 ЕСТЬ ЛОКАЛЬНЫЕ ЗНАНИЯ — НЕ ОТПРАВЛЕНЫ`
  - `🔄 СОХРАНЯЮ ЗНАНИЯ В GITHUB…`
  - `❌ СОХРАНЕНИЕ ЗНАНИЙ НЕ ПОДТВЕРЖДЕНО`
- Added one primary button: `СОХРАНИТЬ ЗНАНИЯ В GITHUB`.
- The button performs the existing safe flow automatically: managed commit when needed → SSH sync → safe pull → push → independent final GitHub verification.
- A local commit alone no longer looks like success.
- A locally clean Git tree alone no longer looks like success.
- Green `SAVED` is shown only after GitHub is reachable and `origin` contains every local managed commit.
- Any new managed knowledge immediately changes the status back to yellow.
- Automatic post-Jira Auto-Learning/Git and Knowledge Explorer runs also refresh this persistence status.
- Old Commit and Git Sync remain as secondary technical tools.
- ADM baseline / HOT delta / BRANCH temporary Knowledge architecture from v0.12.36 is preserved.


## v0.12.38 — Knowledge Git divergence + layout repair

- Fixed the Knowledge Git action panel layout:
  - the primary `СОХРАНИТЬ ЗНАНИЯ В GITHUB` button spans the full action panel width;
  - six technical Git actions are arranged as 2 columns × 3 rows;
  - action area widened from 28% to 34%;
  - shorter technical captions prevent clipping at common Windows resolutions.
- Fixed `Diverging branches can't be fast-forwarded`.
- Git synchronization now distinguishes:
  - remote-only commits -> `pull --ff-only`;
  - local-only commits -> push;
  - local + remote commits -> safe `git rebase origin/<branch>` followed by push.
- Rebase conflicts are never guessed/resolved automatically:
  - conflict file names are collected;
  - `git rebase --abort` restores the original local state;
  - no force-push is used;
  - the user receives a human-readable message that knowledge was not lost.
- Knowledge `SAVED` verification now also requires the local branch not to be behind GitHub.


## v0.12.39 — Full Project Knowledge Explorer

Added `Полный проект — карта + все модули`.

- Full Project no longer depends on the predefined 8-module list.
- Stage 1: Project Mapper uses Playwright MCP to discover the actual accessible Rx2GO product navigation.
- The live project map is saved as `knowledge/explorer/<environment>/project-map.json`.
- Stage 2: Explorer sequentially studies every discovered product capability.
- Dynamic modules get stable safe slugs and are stored under the normal environment module folder.
- `knowledge/explorer/index.json` schema v3 now includes dynamic Project Mapper modules in addition to predefined priority modules.
- Quick and Deep modes remain the fast 8-priority-module options.
- Module and Workflow modes still use the explicit module selector.
- The module selector is disabled automatically for Quick, Deep, Full Project and Refresh.
- Full Project is read-only.
- ADM remains primary baseline; HOT full project is delta vs ADM; BRANCH full project is temporary delta vs HOT.
- Existing Git saved-state, safe divergence handling, Jira Queue, Task Understanding Contract and Smart QA flows are preserved.


## v0.12.40 — ADM Knowledge Explorer authentication

- Fixed Knowledge Explorer not starting on ADM when the daily Telegram password was only available on Quick Run.
- Added `ADM код Telegram` directly to Knowledge Explorer.
- Knowledge and Quick Run daily-password fields are synchronized in memory.
- Explorer validates ADM first-factor data before browser bootstrap and focuses the missing field with a clear Russian message.
- Browser bootstrap and live-context capture read the shared ADM daily-password value.
- The daily password is never written to Knowledge/Git.
- Full Project startup no longer logs `Модулей: 0`; it explicitly says Project Mapper will discover modules first.
- Existing persistent authenticated ADM Chrome session reuse remains supported.

