# Conditional RCA — Failure Triage

Runs only after a real Playwright failure. Uses local Playwright artifacts plus the still-open browser via Playwright MCP to classify the failure as product bug, automation bug, auth error, test-data error, environment error, flaky, or unknown. BrowserStack MCP can augment RCA when configured and when BrowserStack session metadata exists.

