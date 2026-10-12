$ErrorActionPreference = 'Stop'

$localDataRoot = Join-Path $env:LOCALAPPDATA 'Rx2GO-AI-QA'
$secretsDir = Join-Path $localDataRoot 'secrets'
$credentialFile = Join-Path $secretsDir 'rx2go-app.credential.xml'

New-Item -ItemType Directory -Path $secretsDir -Force | Out-Null

$appLogin = $env:RX2GO_APP_LOGIN
if ([string]::IsNullOrWhiteSpace($appLogin)) {
  $appLogin = Read-Host 'Rx2GO application login'
}
if ([string]::IsNullOrWhiteSpace($appLogin)) {
  throw 'RX2GO_APP_LOGIN is required'
}
$password = Read-Host 'Rx2GO application password' -AsSecureString
$credential = [System.Management.Automation.PSCredential]::new($appLogin.Trim(), $password)
$credential | Export-Clixml -Path $credentialFile

Write-Host ''
Write-Host 'Saved with Windows DPAPI for the current Windows user.'
Write-Host "Credential path: $credentialFile"
