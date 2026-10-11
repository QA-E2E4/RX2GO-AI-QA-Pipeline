param()

$ErrorActionPreference = 'Stop'
$localDataRoot = Join-Path $env:LOCALAPPDATA 'Rx2GO-AI-QA'
$credentialFile = Join-Path $localDataRoot 'secrets\browserstack.credential.xml'
New-Item -ItemType Directory -Path (Split-Path $credentialFile) -Force | Out-Null

Write-Host ''
Write-Host 'Rx2GO AI QA — BrowserStack MCP (optional RCA / self-healing)'
Write-Host 'Credentials are stored with Windows DPAPI, not in the project.'
Write-Host ''

$username = Read-Host 'BrowserStack username'
if ([string]::IsNullOrWhiteSpace($username)) { throw 'Username is required.' }

$secure = Read-Host 'BrowserStack access key' -AsSecureString
$credential = [System.Management.Automation.PSCredential]::new($username, $secure)
$credential | Export-Clixml -Path $credentialFile

Write-Host '[SETUP] Saved BrowserStack credential with Windows DPAPI.'
Write-Host '[SETUP] Configuring BrowserStack MCP in Codex...'

$commands = @(
    'codex mcp add browserstack -- npx -y @browserstack/mcp-server@latest',
    'codex mcp add browserstack npx -y @browserstack/mcp-server@latest'
)

$ok = $false
foreach ($cmd in $commands) {
    cmd.exe /d /s /c $cmd
    if ($LASTEXITCODE -eq 0) { $ok = $true; break }
}

if (-not $ok) {
    throw 'Could not add BrowserStack MCP to Codex. Run "codex mcp list" and check your Codex version.'
}

Write-Host ''
Write-Host '[OK] BrowserStack MCP configured.'
Write-Host 'Restart Rx2GO AI QA Launcher to refresh status.'
Write-Host ''
Read-Host 'Press Enter to close'

