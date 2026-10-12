# Local-only QA identity and branch configuration

This repository intentionally contains no person's name, private QA login,
developer-specific branch hostname or private GitHub identity.

## Windows launcher and PowerShell

1. From a private workstation, run `./setup.ps1`. Enter the application's
   login and password when prompted. The resulting Windows DPAPI credential
   remains outside this git repository at
   `%LOCALAPPDATA%\Rx2GO-AI-QA\secrets\rx2go-app.credential.xml`.
2. `run.ps1` reads the saved username and encrypted password automatically,
   so no fixed QA login is needed in any public script.
3. If calling `scripts/run-with-daily-password.ps1` directly, configure
   `RX2GO_APP_LOGIN` in your private environment or let it load the saved
   local DPAPI username; if neither is available, the script prompts.
   The Bash runner prompts for a missing username and password.

## Private branch host

Copy `.env.example` to `.env` (the latter is ignored by git). Add your
own values locally without committing them:

    RX2GO_APP_LOGIN=your_qa_account
    BRANCH_BASE_URL=https://your-private-branch-host.example
    BRANCH_LOGIN_URL=https://your-private-branch-host.example/login
    QA_USER=QA_Engineer

The values above are illustrative placeholders, not real credentials or a
working test endpoint. The actual login and branch host are never shipped in
the public example file. Existing HOT / ADM addresses remain unchanged.

The knowledge YAML intentionally uses environment placeholders for BRANCH.
Consumers of that YAML must resolve BRANCH_BASE_URL and BRANCH_LOGIN_URL from
their local runtime configuration before attempting BRANCH tests; reading YAML
as literal text does not automatically expand these placeholders.

## GitHub / history

The repository's canonical URL is
https://github.com/QA-E2E4/RX2GO-AI-QA-Pipeline.
Do not hardcode a developer's old GitHub username or local test account.

Current tracked files have been anonymized, but public Git commit history
may retain old file versions and author metadata. History sanitization is a
separate, potentially disruptive operation and has not been performed.
