# Codex CLI in Rx2GO AI QA

## Manual installation (Windows)

Official OpenAI installer:

```powershell
powershell -ExecutionPolicy ByPass -c "irm https://chatgpt.com/codex/install.ps1 | iex"
```

Then run once if needed:

```powershell
codex login
```

Choose **Sign in with ChatGPT**.

## Launcher behavior

`START QA.bat` initializes Codex automatically:

1. Detects whether `codex` is installed.
2. Checks `codex login status`.
3. If OAuth is valid, Codex is ready silently.
4. If OAuth is missing/expired, login starts automatically.
5. If Codex is missing, the Launcher asks permission to install the official OpenAI standalone build, then starts login.

Codex CLI is not a Windows background service, so there is no daemon that needs to remain running. The Launcher starts individual Codex commands only when AI analysis is required.

