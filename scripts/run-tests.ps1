param(
    [ValidateSet('auth','smoke','tickets','all')]
    [string]$Suite = 'smoke',
    [switch]$Headed,
    [switch]$KeepBrowserOpen,
    [string]$TestPath = '',
    [switch]$CheckOnly,
    [switch]$DependenciesOnly,
    [string]$SessionFile = '',
    [string]$ReuseCdpEndpoint = '',
    [int]$ReuseChromePid = 0
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$projectRoot = Split-Path -Parent $PSScriptRoot
Set-Location $projectRoot
$env:RX2GO_HEADED = if ($Headed) { 'true' } else { 'false' }

function Write-Step([string]$Text) {
    Write-Host "[SETUP] $Text"
}

function Refresh-ProcessPath {
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = "$machine;$user"
    if (Test-Path 'C:\Program Files\nodejs') {
        $env:Path = "C:\Program Files\nodejs;$env:Path"
    }
}

Write-Step 'Проверяю Node.js...'
Refresh-ProcessPath

if (-not (Get-Command node.exe -ErrorAction SilentlyContinue)) {
    Write-Step 'Node.js не найден. Пробую установить Node.js LTS автоматически через Windows Package Manager...'
    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    if (-not $winget) {
        throw 'Node.js не установлен, а winget недоступен. Установи Node.js LTS с https://nodejs.org/ и запусти Launcher снова.'
    }

    & winget.exe install --id OpenJS.NodeJS.LTS -e --source winget --accept-source-agreements --accept-package-agreements --silent
    if ($LASTEXITCODE -ne 0) {
        throw "Не удалось автоматически установить Node.js LTS. Код winget: $LASTEXITCODE"
    }
    Refresh-ProcessPath
}

$node = Get-Command node.exe -ErrorAction SilentlyContinue
$npm = Get-Command npm.cmd -ErrorAction SilentlyContinue
if (-not $node -or -not $npm) {
    throw 'Node.js установлен не полностью или новый PATH ещё недоступен. Закрой Launcher, открой снова и повтори запуск.'
}

Write-Step "Node.js: $(& node.exe --version)"
Write-Step "npm: $(& npm.cmd --version)"

$stateDir = Join-Path $projectRoot '.qa-state'
New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
$packageFile = Join-Path $projectRoot 'package.json'
$packageHash = (Get-FileHash $packageFile -Algorithm SHA256).Hash
$packageHashFile = Join-Path $stateDir 'package.sha256'
$installedHash = if (Test-Path $packageHashFile) { (Get-Content $packageHashFile -Raw).Trim() } else { '' }
$playwrightCmd = Join-Path $projectRoot 'node_modules\.bin\playwright.cmd'

if ($installedHash -ne $packageHash -or -not (Test-Path $playwrightCmd)) {
    Write-Step 'Устанавливаю/обновляю зависимости проекта. Первый запуск может занять несколько минут...'
    & npm.cmd install --no-audit --no-fund
    if ($LASTEXITCODE -ne 0) { throw "npm install завершился с кодом $LASTEXITCODE" }
    Set-Content -Path $packageHashFile -Value $packageHash -Encoding ASCII
} else {
    Write-Step 'Зависимости проекта уже установлены.'
}

if ($DependenciesOnly) {
    Write-Host '[OK] Playwright project dependencies are ready.'
    exit 0
}


function Find-GoogleChrome {
    $candidates = @(
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
        "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
        "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
    )
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path $candidate)) { return $candidate }
    }
    return $null
}

Write-Step 'Проверяю Google Chrome...'
$chromePath = Find-GoogleChrome
if (-not $chromePath) {
    Write-Step 'Google Chrome не найден. Пробую установить стабильный Google Chrome через Windows Package Manager...'
    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    if (-not $winget) {
        throw 'Google Chrome не установлен, а winget недоступен. Установи Google Chrome и запусти Launcher снова.'
    }

    & winget.exe install --id Google.Chrome -e --source winget --accept-source-agreements --accept-package-agreements --silent
    if ($LASTEXITCODE -ne 0) {
        throw "Не удалось автоматически установить Google Chrome. Код winget: $LASTEXITCODE"
    }
    $chromePath = Find-GoogleChrome
    if (-not $chromePath) {
        throw 'Google Chrome установлен, но текущий процесс пока его не видит. Закрой Launcher, открой снова и повтори запуск.'
    }
}
Write-Step "Google Chrome: $chromePath"
Write-Step 'Режим браузера: чистый Incognito BrowserContext'


Write-Step 'Проверяю конфигурацию Playwright...'
$validationOutput = & $playwrightCmd test --list 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host $validationOutput
    throw 'Конфигурация Playwright или тестовые файлы содержат ошибку. Браузер не запускался.'
}
Write-Step 'Конфигурация Playwright корректна.'


function Get-FreeTcpPort {
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $port = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
    $listener.Stop()
    return $port
}


function Convert-ToSendKeysSequence {
    param([string]$Text)

    $builder = New-Object System.Text.StringBuilder
    foreach ($ch in $Text.ToCharArray()) {
        switch ([string]$ch) {
            '+' { [void]$builder.Append('{+}') }
            '^' { [void]$builder.Append('{^}') }
            '%' { [void]$builder.Append('{%}') }
            '~' { [void]$builder.Append('{~}') }
            '(' { [void]$builder.Append('{(}') }
            ')' { [void]$builder.Append('{)}') }
            '[' { [void]$builder.Append('{[}') }
            ']' { [void]$builder.Append('{]}') }
            '{' { [void]$builder.Append('{{}') }
            '}' { [void]$builder.Append('{}}') }
            default { [void]$builder.Append($ch) }
        }
    }
    return $builder.ToString()
}

function Get-AdmChromeWindowProcess {
    param([int]$PreferredPid)

    try {
        $preferred = Get-Process -Id $PreferredPid -ErrorAction Stop
        if ($preferred.MainWindowHandle -ne [IntPtr]::Zero) {
            return $preferred
        }
    } catch {}

    $candidates = @(
        Get-Process chrome -ErrorAction SilentlyContinue |
            Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero } |
            Sort-Object StartTime -Descending
    )

    foreach ($candidate in $candidates) {
        if ($candidate.MainWindowTitle -match 'adm\.rx2go\.ai|Войти|Sign in|Login') {
            return $candidate
        }
    }

    return ($candidates | Select-Object -First 1)
}

function Set-UiaTextValue {
    param(
        [System.Windows.Automation.AutomationElement]$Element,
        [string]$Value
    )

    try {
        $rawPattern = $Element.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
        $valuePattern = [System.Windows.Automation.ValuePattern]$rawPattern
        $valuePattern.SetValue($Value)
        return $true
    } catch {
        return $false
    }
}


function Ensure-NativeMouseHelper {
    if ('Rx2GoNativeMouse' -as [type]) { return }

    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class Rx2GoNativeMouse {
    [DllImport("user32.dll")]
    public static extern bool SetCursorPos(int X, int Y);

    [DllImport("user32.dll")]
    public static extern void mouse_event(
        uint dwFlags,
        uint dx,
        uint dy,
        uint dwData,
        UIntPtr dwExtraInfo
    );

    public const uint LEFTDOWN = 0x0002;
    public const uint LEFTUP = 0x0004;

    public static void Click(int x, int y) {
        SetCursorPos(x, y);
        mouse_event(LEFTDOWN, 0, 0, 0, UIntPtr.Zero);
        mouse_event(LEFTUP, 0, 0, 0, UIntPtr.Zero);
    }
}
'@
}

function Get-AdmAuthWindowRoot {
    param([System.Diagnostics.Process]$ChromeProcess)

    $windowProcess = Get-AdmChromeWindowProcess -PreferredPid $ChromeProcess.Id
    if (-not $windowProcess -or $windowProcess.MainWindowHandle -eq [IntPtr]::Zero) {
        return $null
    }

    try {
        return [System.Windows.Automation.AutomationElement]::FromHandle(
            $windowProcess.MainWindowHandle
        )
    }
    catch {
        return $null
    }
}

function Get-AdmAuthControls {
    param([System.Windows.Automation.AutomationElement]$Root)

    if (-not $Root) { return $null }

    $editCondition = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::Edit
    )
    $buttonCondition = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::Button
    )

    $edits = $Root.FindAll(
        [System.Windows.Automation.TreeScope]::Descendants,
        $editCondition
    )
    $buttons = $Root.FindAll(
        [System.Windows.Automation.TreeScope]::Descendants,
        $buttonCondition
    )

    $loginButton = $null
    for ($i = 0; $i -lt $buttons.Count; $i++) {
        $candidate = $buttons.Item($i)
        $name = [string]$candidate.Current.Name
        if ($name -match '^(Войти|Sign in|Sign In|Log in|Log In|Login|OK|Submit)$') {
            $loginButton = $candidate
            break
        }
    }

    return [pscustomobject]@{
        Edits = $edits
        Buttons = $buttons
        LoginButton = $loginButton
    }
}

function Test-AdmAuthPromptPresent {
    param([System.Diagnostics.Process]$ChromeProcess)

    try {
        $root = Get-AdmAuthWindowRoot -ChromeProcess $ChromeProcess
        if (-not $root) { return $false }

        $controls = Get-AdmAuthControls -Root $root
        if (-not $controls) { return $false }

        # Chrome Basic Auth has two edit fields while the prompt is visible.
        return ($controls.Edits.Count -ge 2)
    }
    catch {
        return $false
    }
}

function Wait-AdmAuthPromptDismissed {
    param(
        [System.Diagnostics.Process]$ChromeProcess,
        [int]$TimeoutMs = 5000
    )

    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
    while ([DateTime]::UtcNow -lt $deadline) {
        if (-not (Test-AdmAuthPromptPresent -ChromeProcess $ChromeProcess)) {
            return $true
        }
        Start-Sleep -Milliseconds 150
    }

    return (-not (Test-AdmAuthPromptPresent -ChromeProcess $ChromeProcess))
}

function Invoke-UiaLoginButton {
    param(
        [System.Windows.Automation.AutomationElement]$Button,
        [System.Diagnostics.Process]$ChromeProcess
    )

    if (-not $Button) { return $false }

    # Method 1: standard InvokePattern.
    try {
        $Button.SetFocus()
    } catch {}

    try {
        $rawInvoke = $Button.GetCurrentPattern(
            [System.Windows.Automation.InvokePattern]::Pattern
        )
        $invoke = [System.Windows.Automation.InvokePattern]$rawInvoke
        $invoke.Invoke()

        if (Wait-AdmAuthPromptDismissed -ChromeProcess $ChromeProcess -TimeoutMs 3000) {
            Write-Host '[AUTH] ADM: кнопка Войти нажата через UI Automation InvokePattern.'
            return $true
        }
    } catch {}

    # Method 2: LegacyIAccessible default action.
    try {
        $rawLegacy = $Button.GetCurrentPattern(
            [System.Windows.Automation.LegacyIAccessiblePattern]::Pattern
        )
        $legacy = [System.Windows.Automation.LegacyIAccessiblePattern]$rawLegacy
        $legacy.DoDefaultAction()

        if (Wait-AdmAuthPromptDismissed -ChromeProcess $ChromeProcess -TimeoutMs 3000) {
            Write-Host '[AUTH] ADM: кнопка Войти нажата через LegacyIAccessible.'
            return $true
        }
    } catch {}

    # Method 3: real mouse click in the center of the native Chrome button.
    try {
        Ensure-NativeMouseHelper
        $rect = $Button.Current.BoundingRectangle

        if ($rect.Width -gt 4 -and $rect.Height -gt 4) {
            $x = [int]($rect.Left + ($rect.Width / 2))
            $y = [int]($rect.Top + ($rect.Height / 2))

            [Rx2GoNativeMouse]::Click($x, $y)
            Start-Sleep -Milliseconds 250

            if (Wait-AdmAuthPromptDismissed -ChromeProcess $ChromeProcess -TimeoutMs 3500) {
                Write-Host '[AUTH] ADM: кнопка Войти нажата реальным mouse click.'
                return $true
            }
        }
    } catch {}

    # Method 4: focus + Enter.
    try {
        $windowProcess = Get-AdmChromeWindowProcess -PreferredPid $ChromeProcess.Id
        $shell = New-Object -ComObject WScript.Shell
        if ($windowProcess) {
            [void]$shell.AppActivate($windowProcess.Id)
        }
        try { $Button.SetFocus() } catch {}
        Start-Sleep -Milliseconds 150
        $shell.SendKeys('{ENTER}')

        if (Wait-AdmAuthPromptDismissed -ChromeProcess $ChromeProcess -TimeoutMs 3500) {
            Write-Host '[AUTH] ADM: кнопка Войти подтверждена Enter после фокуса.'
            return $true
        }
    } catch {}

    return $false
}

function Invoke-AdmNativeAuthAutoFill {
    param([System.Diagnostics.Process]$ChromeProcess)

    $gatewayLogin = [string]$env:RX2GO_GATEWAY_LOGIN
    $gatewayPassword = [string]$env:RX2GO_DAILY_PASSWORD

    if ([string]::IsNullOrWhiteSpace($gatewayLogin)) {
        $gatewayLogin = 'admin'
    }

    if ([string]::IsNullOrWhiteSpace($gatewayPassword)) {
        throw 'ADM daily password is empty. Enter it in Launcher before starting the test.'
    }

    Write-Host '[AUTH] ADM: ищу первое окно Chrome и автоматически авторизуюсь...'

    try {
        Add-Type -AssemblyName UIAutomationClient -ErrorAction Stop
        Add-Type -AssemblyName UIAutomationTypes -ErrorAction Stop

        for ($attempt = 1; $attempt -le 50; $attempt++) {
            $root = Get-AdmAuthWindowRoot -ChromeProcess $ChromeProcess

            if ($root) {
                $controls = Get-AdmAuthControls -Root $root

                if ($controls -and $controls.Edits.Count -ge 2) {
                    $loginOk = Set-UiaTextValue `
                        -Element $controls.Edits.Item(0) `
                        -Value $gatewayLogin

                    $passwordOk = Set-UiaTextValue `
                        -Element $controls.Edits.Item(1) `
                        -Value $gatewayPassword

                    if ($loginOk -and $passwordOk) {
                        Write-Host '[AUTH] ADM: login и суточный пароль заполнены.'

                        if (Invoke-UiaLoginButton `
                            -Button $controls.LoginButton `
                            -ChromeProcess $ChromeProcess) {

                            Write-Host '[AUTH] ADM: первый фактор успешно отправлен.'
                            return $true
                        }

                        # Sometimes Chrome exposes the fields but not the button as an
                        # Invoke-able UIA element. Focus password and submit directly.
                        try {
                            $controls.Edits.Item(1).SetFocus()
                            $windowProcess = Get-AdmChromeWindowProcess -PreferredPid $ChromeProcess.Id
                            $shell = New-Object -ComObject WScript.Shell
                            if ($windowProcess) {
                                [void]$shell.AppActivate($windowProcess.Id)
                            }
                            Start-Sleep -Milliseconds 150
                            $shell.SendKeys('{ENTER}')

                            if (Wait-AdmAuthPromptDismissed `
                                -ChromeProcess $ChromeProcess `
                                -TimeoutMs 4000) {

                                Write-Host '[AUTH] ADM: первый фактор отправлен Enter из password field.'
                                return $true
                            }
                        } catch {}
                    }
                }
            }

            Start-Sleep -Milliseconds 200
        }
    }
    catch {
        Write-Host "[AUTH] ADM: UI Automation path failed: $($_.Exception.Message)"
    }

    # Last-resort keyboard fallback.
    try {
        $windowProcess = Get-AdmChromeWindowProcess -PreferredPid $ChromeProcess.Id
        if (-not $windowProcess) {
            return $false
        }

        $shell = New-Object -ComObject WScript.Shell
        if (-not $shell.AppActivate($windowProcess.Id)) {
            [void]$shell.AppActivate('adm.rx2go.ai')
        }

        Start-Sleep -Milliseconds 500
        $shell.SendKeys('^a')
        $shell.SendKeys((Convert-ToSendKeysSequence $gatewayLogin))
        $shell.SendKeys('{TAB}')
        $shell.SendKeys((Convert-ToSendKeysSequence $gatewayPassword))
        $shell.SendKeys('{TAB}')
        $shell.SendKeys('{ENTER}')

        if (Wait-AdmAuthPromptDismissed -ChromeProcess $ChromeProcess -TimeoutMs 5000) {
            Write-Host '[AUTH] ADM: первый фактор отправлен keyboard fallback.'
            return $true
        }
    }
    catch {
        Write-Host "[AUTH] ADM: keyboard fallback failed: $($_.Exception.Message)"
    }

    Write-Host '[AUTH] ADM: окно первого фактора осталось открытым после всех способов submit.'
    return $false
}


function Test-CdpEndpoint {
    param([string]$Endpoint)

    if ([string]::IsNullOrWhiteSpace($Endpoint)) {
        return $false
    }

    try {
        $version = Invoke-RestMethod -Uri "$Endpoint/json/version" -TimeoutSec 2
        return [bool]$version.webSocketDebuggerUrl
    }
    catch {
        return $false
    }
}

function Save-BrowserSessionInfo {
    param(
        [string]$Path,
        [string]$Endpoint,
        [int]$ChromePid,
        [string]$ProfileDir
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return
    }

    $directory = Split-Path -Parent $Path
    if ($directory) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    [pscustomobject]@{
        endpoint = $Endpoint
        chromePid = $ChromePid
        profileDir = $ProfileDir
        environment = [string]$env:TEST_ENV
        createdAt = (Get-Date).ToString('o')
    } |
        ConvertTo-Json -Depth 4 |
        Set-Content -Path $Path -Encoding UTF8

    Write-Step "Browser session saved: $Path"
}


function Start-ExternalChromeForTests {
    param(
        [string]$ChromePath,
        [string]$InitialUrl = 'about:blank',
        [string]$SessionFile = ''
    )

    $port = Get-FreeTcpPort
    $profileDir = Join-Path $projectRoot ".qa-state\chrome-cdp-$PID"
    New-Item -ItemType Directory -Path $profileDir -Force | Out-Null

    Write-Step "Запускаю постоянный Google Chrome для всей QA-сессии..."
    Write-Step "Начальная страница Chrome: $InitialUrl"

    $args = @(
        "--remote-debugging-port=$port",
        "--user-data-dir=$profileDir",
        "--incognito",
        "--start-maximized",
        "--no-first-run",
        "--no-default-browser-check",
        $InitialUrl
    )

    $script:ExternalChromeProcess = Start-Process `
        -FilePath $ChromePath `
        -ArgumentList $args `
        -PassThru

    $endpoint = "http://127.0.0.1:$port"
    $ready = $false

    for ($i = 0; $i -lt 75; $i++) {
        Start-Sleep -Milliseconds 200

        if (Test-CdpEndpoint -Endpoint $endpoint) {
            $ready = $true
            break
        }
    }

    if (-not $ready) {
        throw "Google Chrome запущен, но CDP endpoint $endpoint не стал доступен."
    }

    $env:RX2GO_CDP_ENDPOINT = $endpoint

    Save-BrowserSessionInfo `
        -Path $SessionFile `
        -Endpoint $endpoint `
        -ChromePid $script:ExternalChromeProcess.Id `
        -ProfileDir $profileDir

    Write-Step "Chrome готов. CDP: $endpoint"
    Write-Step "Этот Chrome можно повторно использовать следующим Playwright-процессом."
}

if ($CheckOnly) {
    Write-Host '[OK] Среда для автотестов готова.'
    exit 0
}

$testArgs = @('test')

if (-not [string]::IsNullOrWhiteSpace($TestPath)) {
    $testArgs += $TestPath
    Write-Host "[TEST] Jira generated spec: $TestPath"
}
else {
    switch ($Suite) {
        'auth'    { $testArgs += 'tests/diagnostics/auth.spec.ts' }
        'smoke'   { $testArgs += 'tests/smoke' }
        'tickets' { $testArgs += 'tests/tickets' }
        'all'     { }
    }
}

$reuseExistingChrome = -not [string]::IsNullOrWhiteSpace($ReuseCdpEndpoint)

if ($reuseExistingChrome) {
    if (-not (Test-CdpEndpoint -Endpoint $ReuseCdpEndpoint)) {
        throw "Persistent Chrome session is no longer available: $ReuseCdpEndpoint"
    }

    $env:RX2GO_CDP_ENDPOINT = $ReuseCdpEndpoint
    $env:RX2GO_INTERACTIVE_ADM_AUTH = 'false'

    Write-Host '[BROWSER] Reusing existing authenticated Chrome session.'
    Write-Host "[BROWSER] CDP endpoint: $ReuseCdpEndpoint"
    if ($ReuseChromePid -gt 0) {
        Write-Host "[BROWSER] Chrome PID: $ReuseChromePid"
    }
}

if ($Headed -and -not $reuseExistingChrome) {
    $testArgs += '--headed'
}

Write-Host ''

$interactiveAdm = (
    $Headed -and
    $env:TEST_ENV -eq 'ADM' -and
    -not $reuseExistingChrome
)

$useExternalChrome = (
    $reuseExistingChrome -or
    ($Headed -and ($KeepBrowserOpen -or $interactiveAdm))
)

if ($useExternalChrome -and -not $reuseExistingChrome) {
    $initialUrl = if ($interactiveAdm) {
        'https://adm.rx2go.ai/login'
    }
    else {
        'about:blank'
    }

    Write-Host '[BROWSER] Создаю единственный Chrome для авторизации, Live Context и финального теста.'

    Start-ExternalChromeForTests `
        -ChromePath $chromePath `
        -InitialUrl $initialUrl `
        -SessionFile $SessionFile

    if ($interactiveAdm) {
        $env:RX2GO_INTERACTIVE_ADM_AUTH = 'true'

        Write-Host ''
        Write-Host '[AUTH] ADM: автоматически прохожу первый фактор в нативном окне Chrome.'
        Write-Host '[AUTH] Username: admin'
        Write-Host '[AUTH] Password: взят из поля суточного пароля Launcher.'
        Write-Host '[AUTH] Секреты в лог не выводятся.'

        $admFilled = Invoke-AdmNativeAuthAutoFill `
            -ChromeProcess $script:ExternalChromeProcess

        if (-not $admFilled) {
            throw 'Не удалось автоматически пройти ADM first factor. Проверь суточный пароль и повтори запуск.'
        }

        Write-Host '[AUTH] ADM: первый фактор завершён.'
        Write-Host '[AUTH] Playwright выполнит Rx2GO application login один раз в этом же Chrome.'
        Write-Host ''
    }

    Write-Host '[BROWSER] Playwright подключается к постоянному Chrome через CDP.'
}

Write-Host '[TEST] Запускаю Playwright...'
Write-Host "[TEST] Environment: $env:TEST_ENV"
Write-Host "[TEST] Suite: $Suite"
Write-Host "[TEST] Headed: $Headed"
Write-Host "[TEST] Reuse authenticated Chrome: $reuseExistingChrome"
Write-Host "[TEST] Local Playwright: $playwrightCmd"
Write-Host ''

& $playwrightCmd @testArgs
$exitCode = $LASTEXITCODE

Write-Host ''
Write-Host "[TEST] Playwright завершён. Exit code: $exitCode"
if ($useExternalChrome) {
    if ($KeepBrowserOpen) {
        Write-Host '[BROWSER] Google Chrome оставлен открытым. Это та же сессия, которая использовалась для авторизации и Live Context.'
    }
    elseif ($reuseExistingChrome -and $ReuseChromePid -gt 0) {
        Write-Host '[BROWSER] Финальный тест завершён. Закрываю повторно использованный Chrome...'
        try {
            & taskkill /PID $ReuseChromePid /T /F | Out-Null
        } catch {}
    }
    elseif ($script:ExternalChromeProcess) {
        Write-Host '[BROWSER] Закрываю созданный Chrome после теста...'
        try {
            & taskkill /PID $script:ExternalChromeProcess.Id /T /F | Out-Null
        } catch {}
    }
}
exit $exitCode
