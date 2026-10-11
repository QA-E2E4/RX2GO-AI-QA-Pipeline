$ErrorActionPreference = 'Stop'
Write-Host 'Rx2GO AI QA - Codex CLI setup' -ForegroundColor Cyan
Write-Host 'Installing the official OpenAI Codex CLI for Windows...'
irm 'https://chatgpt.com/codex/install.ps1' | iex
$env:Path = [Environment]::GetEnvironmentVariable('Path','User') + ';' + [Environment]::GetEnvironmentVariable('Path','Machine')
Write-Host ''
Write-Host 'Installed version:' -ForegroundColor Green
codex --version
Write-Host ''
Write-Host 'Starting ChatGPT sign-in...' -ForegroundColor Cyan
codex login

