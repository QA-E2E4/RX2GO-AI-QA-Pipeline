$ErrorActionPreference = 'Stop'

$localDataRoot = Join-Path $env:LOCALAPPDATA 'Rx2GO-AI-QA'
$secretsDir = Join-Path $localDataRoot 'secrets'
$credentialFile = Join-Path $secretsDir 'rx2go-app.credential.xml'

New-Item -ItemType Directory -Path $secretsDir -Force | Out-Null

Write-Host 'Rx2GO application user: sergeyqa'
$password = Read-Host 'Rx2GO application password' -AsSecureString
$credential = [System.Management.Automation.PSCredential]::new('sergeyqa', $password)
$credential | Export-Clixml -Path $credentialFile

Write-Host ''
Write-Host 'Saved with Windows DPAPI for the current Windows user.'
Write-Host "Credential path: $credentialFile"
