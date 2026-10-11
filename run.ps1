param(
  [Parameter(Position=0)]
  [ValidateSet('branch','hot','adm')]
  [string]$Environment = 'branch',

  [Parameter(Position=1)]
  [ValidateSet('smoke','tickets','all')]
  [string]$Suite = 'smoke',

  [switch]$Mutating,
  [switch]$Headed
)

$ErrorActionPreference = 'Stop'
$envName = $Environment.ToUpperInvariant()
$credentialFile = Join-Path (Join-Path $env:LOCALAPPDATA 'Rx2GO-AI-QA') 'secrets\rx2go-app.credential.xml'

if (-not (Test-Path $credentialFile)) {
  Write-Host 'First run: save the Rx2GO application account once:'
  Write-Host '  .\setup.ps1'
  exit 1
}

$credential = Import-Clixml -Path $credentialFile
$appPtr = [IntPtr]::Zero
$dailyPtr = [IntPtr]::Zero

try {
  $appPtr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($credential.Password)
  $env:RX2GO_APP_LOGIN = $credential.UserName
  $env:RX2GO_APP_PASSWORD = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($appPtr)

  if ($envName -eq 'ADM') {
    $dailySecure = Read-Host "Today's Rx2GO gateway password from Telegram" -AsSecureString
    $dailyPtr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($dailySecure)
    $env:RX2GO_GATEWAY_LOGIN = 'admin'
    $env:RX2GO_DAILY_PASSWORD = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($dailyPtr)
  }

  $env:TEST_ENV = $envName
  $env:RUN_MUTATING_TESTS = if ($Mutating) { 'true' } else { 'false' }

  $args = @('playwright', 'test')
  switch ($Suite) {
    'smoke'   { $args += 'tests/smoke' }
    'tickets' { $args += 'tests/tickets' }
    'all'     { }
  }
  if ($Headed) { $args += '--headed' }

  & npx @args
  exit $LASTEXITCODE
}
finally {
  Remove-Item Env:RX2GO_APP_LOGIN -ErrorAction SilentlyContinue
  Remove-Item Env:RX2GO_APP_PASSWORD -ErrorAction SilentlyContinue
  Remove-Item Env:RX2GO_GATEWAY_LOGIN -ErrorAction SilentlyContinue
  Remove-Item Env:RX2GO_DAILY_PASSWORD -ErrorAction SilentlyContinue

  if ($appPtr -ne [IntPtr]::Zero) {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($appPtr)
  }
  if ($dailyPtr -ne [IntPtr]::Zero) {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($dailyPtr)
  }
}

