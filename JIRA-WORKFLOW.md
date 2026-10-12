# Jira Task workflow — Rx2GO AI QA v1

## Что делает вкладка Jira Task

1. Принимает ссылку, ключ или текст Jira-задачи.
2. Определяет модуль по тексту задачи.
3. Выделяет явные acceptance criteria / bullets и строит тест-план.
4. Сохраняет исходную задачу и план в `jira-runs/<timestamp>-<KEY>/`.
5. Для `Tickets Queue` запускает существующий Playwright suite.
6. Для ещё не автоматизированных модулей показывает `NOT AUTOMATED` и **не выставляет ложный PASS**.
7. Кнопка `Добавить в Regression` сохраняет сценарий в `regression-candidates/`.

## ChatGPT OAuth и Atlassian

Launcher использует официальный ChatGPT-вход Codex CLI:

- проверяет `codex login status` при старте;
- один раз запускает `codex login`, если вход ещё не выполнен;
- затем автоматически переиспользует OAuth-состояние Codex для AI-анализа текста задачи через `codex exec`;
- не читает cookies ChatGPT и не сохраняет OAuth-токены внутри проекта.

Это **не означает передачу OAuth Atlassian/Rovo** из ChatGPT в локальную программу. Токены подключённых приложений ChatGPT не экспортируются launcher. Поэтому для автоматического получения Jira issue только по ключу/URL нужен отдельный Jira REST/OAuth модуль. Пока полное описание можно вставить в поле Jira Task, а ChatGPT/Codex автоматически разберёт требования и риски.

## Уже автоматизировано

- Tickets Queue load
- My Tickets / All Tickets switch
- Start Workout / auto assignment (mutating)
- Expiration minute save contract (mutating)

## Следующие модули

- Chat
- Dispatcher Queue
- Scanner
- QAQC Queue
- Orders

## QA-комментарии и постоянные правила

Во вкладке `Jira Task` теперь есть два дополнительных поля:

- **Комментарий QA для этой проверки** — действует только для текущего запуска. Он передаётся AI-анализу вместе с Jira-описанием, сохраняется в `jira-runs/.../task.json`, показывается в тест-плане и добавляется в Jira-отчёт.
- **Новое постоянное правило Rx2GO** — после нажатия `Сохранить как правило Rx2GO` записывается в `knowledge/project-rules.json` и автоматически применяется ко всем следующим Jira-задачам.

Пример разового комментария:

```text
Проверить только BRANCH. Обязательно проверить API. Этот сценарий пока не добавлять в regression.
```

Пример постоянного правила:

```text
Существующие ордера использовать нельзя — создавать только новые тестовые.
```

Разовый комментарий не становится постоянным правилом автоматически: это сделано специально, чтобы случайное уточнение к одной задаче не влияло на весь проект.


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
- As soon as the Rx2GO application login form appears, `RX2GO_APP_LOGIN` login is completed automatically.
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
- After the first factor, Playwright completes the `RX2GO_APP_LOGIN` application login
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

`Chrome start -> ADM first factor -> Rx2GO RX2GO_APP_LOGIN login -> Live Page Context -> Agents 2–5 -> same Chrome/CDP -> final Playwright test`

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
- GitHub repository uses SSH origin: `git@github.com:QA-E2E4/RX2GO-AI-QA-Pipeline.git`.
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
