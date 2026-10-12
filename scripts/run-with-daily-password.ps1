param(
  [ValidateSet('smoke','tickets','all')]
  [string]$Suite = 'smoke',
  [ValidateSet('HOT','ADM','BRANCH')]
  [string]$Environment = 'HOT',
  [switch]$Mutating
)

$dailySecure = $null
$dailyPtr = [IntPtr]::Zero
$appSecure = $null
$appPtr = [IntPtr]::Zero
$removeAppPasswordAfterRun = $false

try {
  if ($Environment -eq 'ADM') {
    $dailySecure = Read-Host 'Enter today''s Rx2GO gateway password from Telegram' -AsSecureString
    $dailyPtr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($dailySecure)
    $dailyPlain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($dailyPtr)
    $env:RX2GO_GATEWAY_LOGIN = 'admin'
    $env:RX2GO_DAILY_PASSWORD = $dailyPlain
  }

  if ([string]::IsNullOrWhiteSpace($env:RX2GO_APP_LOGIN)) {
    $env:RX2GO_APP_LOGIN = (Read-Host 'Rx2GO application login').Trim()
  }
  if ([string]::IsNullOrWhiteSpace($env:RX2GO_APP_LOGIN)) { throw 'RX2GO_APP_LOGIN is required' }

  if (-not $env:RX2GO_APP_PASSWORD) {
    $appSecure = Read-Host 'Enter Rx2GO application password' -AsSecureString
    $appPtr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($appSecure)
    $appPlain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($appPtr)
    $env:RX2GO_APP_PASSWORD = $appPlain
    $removeAppPasswordAfterRun = $true
  }

  $env:TEST_ENV = $Environment
  $env:RUN_MUTATING_TESTS = if ($Mutating) { 'true' } else { 'false' }

  switch ($Suite) {
    'smoke'   { npm run test:smoke }
    'tickets' { npm run test:tickets }
    'all'     { npm test }
  }

  exit $LASTEXITCODE
}
finally {
  Remove-Item Env:RX2GO_DAILY_PASSWORD -ErrorAction SilentlyContinue
  Remove-Item Env:RX2GO_GATEWAY_LOGIN -ErrorAction SilentlyContinue

  if ($removeAppPasswordAfterRun) {
    Remove-Item Env:RX2GO_APP_PASSWORD -ErrorAction SilentlyContinue
  }

  $dailyPlain = $null
  $appPlain = $null

  if ($dailyPtr -ne [IntPtr]::Zero) {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($dailyPtr)
  }
  if ($appPtr -ne [IntPtr]::Zero) {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($appPtr)
  }
}
