Add-Type -AssemblyName System.Windows.Forms

[System.Windows.Forms.Application]::SetUnhandledExceptionMode(
    [System.Windows.Forms.UnhandledExceptionMode]::CatchException
)

[System.Windows.Forms.Application]::add_ThreadException({
    param($sender, $eventArgs)

    try {
        $message = [string]$eventArgs.Exception.Message
        if (Get-Command Append-AgentLog -ErrorAction SilentlyContinue) {
            Append-AgentLog "UI THREAD EXCEPTION → $message"
        }
    } catch {}

    [System.Windows.Forms.MessageBox]::Show(
        "Внутренняя ошибка Launcher:`r`n`r`n$($eventArgs.Exception.Message)`r`n`r`nОшибка записана в лог. Chrome не закрыт автоматически.",
        'Rx2GO AI QA',
        'OK',
        'Error'
    ) | Out-Null
})
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic

[System.Windows.Forms.Application]::EnableVisualStyles()

$script:ProjectRoot = $PSScriptRoot

# Stable credential storage. DPAPI/Export-Clixml binds the password to the
# current Windows user instead of to one unpacked Launcher folder.
$script:LocalDataRoot = Join-Path $env:LOCALAPPDATA 'Rx2GO-AI-QA'
$script:CredentialFile = Join-Path $script:LocalDataRoot 'secrets\rx2go-app.credential.xml'
$script:JiraCredentialFile = Join-Path $script:LocalDataRoot 'secrets\jira-api.credential.xml'

function Initialize-AppCredentialStorage {
    $targetDir = Split-Path $script:CredentialFile
    New-Item -ItemType Directory -Path $targetDir -Force | Out-Null

    if (Test-Path $script:CredentialFile) { return }

    # Migrate a credential from an older unpacked Rx2GO AI QA folder if one exists.
    try {
        $parent = Split-Path $script:ProjectRoot -Parent
        $candidate = Get-ChildItem -Path $parent -Directory -Filter 'rx2go-ai-qa-*' -ErrorAction SilentlyContinue |
            ForEach-Object {
                $path = Join-Path $_.FullName '.secrets\rx2go-app.credential.xml'
                if (Test-Path $path) { Get-Item $path }
            } |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1

        if ($candidate) {
            Copy-Item $candidate.FullName $script:CredentialFile -Force
        }
    } catch { }
}

Initialize-AppCredentialStorage
$script:RunningProcess = $null
$script:LogFile = $null
$script:LastLogLength = 0
$script:ExitHandled = $false
$script:LastSummary = $null
$script:LastEnvironment = $null
$script:LastSuite = $null
$script:LastStartedAt = $null
$script:CurrentJiraTask = $null
$script:JiraRunActive = $false
    $script:TestPathOverride = $null
$script:LastJiraRunDir = $null
$script:LastJiraPlan = $null
$script:ChatGPTConnected = $false
$script:ChatGPTAuthProcess = $null
$script:ChatGPTAuthTimer = $null
$script:ProjectRulesFile = Join-Path $PSScriptRoot 'knowledge\project-rules.json'
$script:KnowledgePaths = @(
    'knowledge','jira-cases','scenarios','tests','pages','api','agents','scripts','docs',
    'Rx2GO-QA-Launcher.ps1','LauncherBootstrap.ps1','run.ps1','setup.ps1',
    'START QA.bat','START QA DEBUG.bat',
    'CHECK CODEX.bat','CHECK PLAYWRIGHT CONFIG.bat','CHECK RX2GO LOGIN.bat','CHECK TEST ENVIRONMENT.bat',
    'INSTALL CODEX.bat','INSTALL CODEX.ps1','CONFIGURE BROWSERSTACK MCP.bat',
    'README.md','JIRA-WORKFLOW.md','LAUNCHER.md',
    'playwright.config.ts','package.json','tsconfig.json','.gitignore','.env.example','VERSION'
)
$script:DefaultGitRemote = 'https://github.com/Gamazzz/rx2go-ai-qa.git'
$script:GitBusy = $false

$script:JiraFetchedSource = $null
$script:JiraGeneratedSpec = $null
$script:LoadedJiraIssue = $null
$script:LoadedJiraIssueKey = $null
$script:JiraGenerationError = $null
$script:JiraGenerationLog = $null

$script:LastAgentError = $null
$script:AgentRunDir = $null
$script:AgentJiraAnalysis = $null
$script:AgentTestDesign = $null
$script:AgentUiDesign = $null
$script:AgentApiDesign = $null
$script:AgentReviewerSpec = $null
$script:AgentMcpExecution = $null
$script:AgentMcpExecutionRaw = $null
$script:FailureTriage = $null
$script:JiraScreenshotPaths = @()
$script:JiraScreenshotMaxCount = 8
$script:PlaywrightMcpReady = $false
$script:BrowserStackCredentialFile = Join-Path $script:LocalDataRoot 'secrets\browserstack.credential.xml'
$script:BrowserStackMcpConfigured = $false


$script:TestPathOverride = $null



function Test-GitInstalled {
    return $null -ne (Get-Command git -ErrorAction SilentlyContinue)
}

function Invoke-Git([string[]]$Arguments, [int]$TimeoutMs = 20000) {
    if (-not (Test-GitInstalled)) {
        return [pscustomobject]@{ ExitCode = 127; Output = 'Git не установлен'; Error = 'Git не установлен' }
    }
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = 'git.exe'
        $psi.Arguments = ($Arguments | ForEach-Object {
            if ($_ -match '[\s"]') { '"' + ($_ -replace '"','\\"') + '"' } else { $_ }
        }) -join ' '
        $psi.WorkingDirectory = $script:ProjectRoot
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $p = New-Object System.Diagnostics.Process
        $p.StartInfo = $psi
        [void]$p.Start()
        if (-not $p.WaitForExit($TimeoutMs)) {
            try { $p.Kill() } catch { }
            return [pscustomobject]@{ ExitCode = 124; Output = ''; Error = 'Git command timeout' }
        }
        $out = $p.StandardOutput.ReadToEnd().Trim()
        $err = $p.StandardError.ReadToEnd().Trim()
        return [pscustomobject]@{ ExitCode = $p.ExitCode; Output = $out; Error = $err }
    }
    catch {
        return [pscustomobject]@{ ExitCode = 1; Output = ''; Error = $_.Exception.Message }
    }
}


function Get-KnowledgeGitStatusLines {
    $args = New-Object System.Collections.Generic.List[string]
    $args.Add('status')
    $args.Add('--porcelain')
    $args.Add('--')

    foreach ($path in $script:KnowledgePaths) {
        $args.Add([string]$path)
    }

    $result = Invoke-Git @($args)

    if ($result.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($result.Output)) {
        return @()
    }

    return @(
        $result.Output -split "`r?`n" |
            Where-Object { $_ }
    )
}

function Get-AllGitStatusLines {
    $result = Invoke-Git @('status','--porcelain')

    if ($result.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($result.Output)) {
        return @()
    }

    return @(
        $result.Output -split "`r?`n" |
            Where-Object { $_ }
    )
}

function Get-KnowledgeGitPathArgs {
    $paths = New-Object System.Collections.Generic.List[string]

    foreach ($path in $script:KnowledgePaths) {
        if (-not [string]::IsNullOrWhiteSpace([string]$path)) {
            $paths.Add([string]$path)
        }
    }

    return @($paths)
}


function Get-GitState {
    if (-not (Test-GitInstalled)) {
        return [pscustomobject]@{
            Installed=$false; Repository=$false; Branch='—'; Remote='—';
            Dirty=$false; Changes=0; ManagedDirty=$false; ManagedChanges=0; OtherChanges=0;
            LastCommit='—'; Status='Git не установлен'
        }
    }

    $inside = Invoke-Git @('rev-parse','--is-inside-work-tree')

    if ($inside.ExitCode -ne 0 -or $inside.Output -ne 'true') {
        return [pscustomobject]@{
            Installed=$true; Repository=$false; Branch='—'; Remote='—';
            Dirty=$false; Changes=0; ManagedDirty=$false; ManagedChanges=0; OtherChanges=0;
            LastCommit='—'; Status='Репозиторий не инициализирован'
        }
    }

    $branch = (Invoke-Git @('branch','--show-current')).Output
    if (-not $branch) { $branch = 'detached' }

    $remote = (Invoke-Git @('remote','get-url','origin')).Output
    if (-not $remote) { $remote = 'не настроен' }

    $allLines = @(Get-AllGitStatusLines)
    $managedLines = @(Get-KnowledgeGitStatusLines)

    $allCount = $allLines.Count
    $managedCount = $managedLines.Count
    $otherCount = [Math]::Max(0, ($allCount - $managedCount))

    $lastCommit = (Invoke-Git @('log','-1','--pretty=format:%h %s')).Output
    if (-not $lastCommit) { $lastCommit = 'коммитов пока нет' }

    return [pscustomobject]@{
        Installed=$true; Repository=$true; Branch=$branch; Remote=$remote;
        Dirty=($allCount -gt 0); Changes=$allCount;
        ManagedDirty=($managedCount -gt 0); ManagedChanges=$managedCount; OtherChanges=$otherCount;
        LastCommit=$lastCommit;
        Status=$(if ($managedCount -gt 0) {
            "Изменения проекта: $managedCount"
        }
        elseif ($otherCount -gt 0) {
            "Вне управляемых файлов: $otherCount"
        }
        else {
            'Synced locally'
        })
    }
}

function Get-KnowledgeStats {
    $rules = @(Get-Rx2GOProjectRules).Count
    $jiraDir = Join-Path $script:ProjectRoot 'jira-cases'
    $scenarioDir = Join-Path $script:ProjectRoot 'scenarios'
    $testsDir = Join-Path $script:ProjectRoot 'tests'
    $jira = if (Test-Path $jiraDir) { @(Get-ChildItem $jiraDir -File -Filter '*.md' -ErrorAction SilentlyContinue).Count } else { 0 }
    $scenarios = if (Test-Path $scenarioDir) { @(Get-ChildItem $scenarioDir -File -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in @('.yaml','.yml','.json') }).Count } else { 0 }
    $tests = if (Test-Path $testsDir) { @(Get-ChildItem $testsDir -File -Recurse -Filter '*.spec.ts' -ErrorAction SilentlyContinue).Count } else { 0 }
    return [pscustomobject]@{ Rules=$rules; JiraCases=$jira; Scenarios=$scenarios; Tests=$tests }
}

function Get-RecentKnowledgeFiles {
    $roots = @('knowledge','jira-cases','scenarios','tests') | ForEach-Object { Join-Path $script:ProjectRoot $_ }
    $items = @()
    foreach ($root in $roots) {
        if (Test-Path $root) {
            $items += Get-ChildItem $root -File -Recurse -ErrorAction SilentlyContinue
        }
    }
    return @($items | Sort-Object LastWriteTime -Descending | Select-Object -First 12)
}


function Set-KnowledgeActionStatus {
    param(
        [string]$Text,
        [ValidateSet('Info','Success','Warning','Error')]
        [string]$Kind = 'Info'
    )

    if (-not $knowledgeSyncInfo) { return }

    $knowledgeSyncInfo.Text = $Text

    switch ($Kind) {
        'Success' { $knowledgeSyncInfo.ForeColor = [System.Drawing.Color]::FromArgb(32,120,72) }
        'Warning' { $knowledgeSyncInfo.ForeColor = [System.Drawing.Color]::FromArgb(161,98,7) }
        'Error'   { $knowledgeSyncInfo.ForeColor = [System.Drawing.Color]::Firebrick }
        default   { $knowledgeSyncInfo.ForeColor = [System.Drawing.Color]::FromArgb(37,99,235) }
    }

    [System.Windows.Forms.Application]::DoEvents()
}



function Get-GitHubSshPrivateKeyPath {
    $homePath = [Environment]::GetFolderPath('UserProfile')
    return (Join-Path $homePath '.ssh\id_ed25519')
}

function Get-GitHubSshPublicKeyPath {
    return ((Get-GitHubSshPrivateKeyPath) + '.pub')
}

function Get-KnowledgeSshOrigin {
    return 'git@github.com:Gamazzz/rx2go-ai-qa.git'
}

function Test-SshInstalled {
    try {
        $cmd = Get-Command ssh.exe -ErrorAction Stop
        return [bool]$cmd.Source
    }
    catch {
        return $false
    }
}

function Test-SshKeygenInstalled {
    try {
        $cmd = Get-Command ssh-keygen.exe -ErrorAction Stop
        return [bool]$cmd.Source
    }
    catch {
        return $false
    }
}

function Ensure-SshDirectory {
    $privateKey = Get-GitHubSshPrivateKeyPath
    $sshDir = Split-Path $privateKey -Parent

    if (-not (Test-Path $sshDir)) {
        New-Item -ItemType Directory -Path $sshDir -Force | Out-Null
    }

    return $sshDir
}

function Get-GitHubSshPublicKey {
    $publicKey = Get-GitHubSshPublicKeyPath

    if (-not (Test-Path $publicKey)) {
        return $null
    }

    try {
        return (Get-Content -Raw -Path $publicKey -ErrorAction Stop).Trim()
    }
    catch {
        return $null
    }
}

function Copy-GitHubSshPublicKey {
    $key = Get-GitHubSshPublicKey

    if ([string]::IsNullOrWhiteSpace($key)) {
        [System.Windows.Forms.MessageBox]::Show(
            'Публичный SSH-ключ пока не найден. Сначала нажми «Создать SSH key».',
            'Rx2GO QA — GitHub SSH',
            'OK',
            'Information'
        ) | Out-Null
        return $false
    }

    try {
        [System.Windows.Forms.Clipboard]::SetText($key)

        Set-KnowledgeActionStatus `
            -Text 'Публичный SSH key скопирован в буфер обмена ✓' `
            -Kind Success

        return $true
    }
    catch {
        Set-KnowledgeActionStatus `
            -Text "Не удалось скопировать SSH key: $($_.Exception.Message)" `
            -Kind Error
        return $false
    }
}

function Ensure-GitHubSshKey {
    if (-not (Test-SshKeygenInstalled)) {
        Set-KnowledgeActionStatus `
            -Text 'ssh-keygen не найден в Windows.' `
            -Kind Error

        [System.Windows.Forms.MessageBox]::Show(
            "ssh-keygen не найден.`r`n`r`nУстанови компонент OpenSSH Client в Windows и повтори.",
            'Rx2GO QA — GitHub SSH',
            'OK',
            'Warning'
        ) | Out-Null

        return $false
    }

    [void](Ensure-SshDirectory)

    $privateKey = Get-GitHubSshPrivateKeyPath
    $publicKey = Get-GitHubSshPublicKeyPath

    if ((Test-Path $privateKey) -and (Test-Path $publicKey)) {
        Set-KnowledgeActionStatus `
            -Text "SSH key уже существует: $publicKey" `
            -Kind Success
        return $true
    }

    try {
        Set-KnowledgeActionStatus `
            -Text 'Создаю локальный SSH ed25519 key…' `
            -Kind Info

        $comment = "rx2go-ai-qa@$env:COMPUTERNAME"
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = 'ssh-keygen.exe'
        $psi.Arguments = "-t ed25519 -C `"$comment`" -f `"$privateKey`" -N `"`""
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true

        $p = New-Object System.Diagnostics.Process
        $p.StartInfo = $psi
        [void]$p.Start()

        $stdout = $p.StandardOutput.ReadToEnd()
        $stderr = $p.StandardError.ReadToEnd()

        if (-not $p.WaitForExit(30000)) {
            try { $p.Kill() } catch {}
            throw 'ssh-keygen timeout'
        }

        if ($p.ExitCode -ne 0 -or -not (Test-Path $publicKey)) {
            throw "ssh-keygen failed: $stderr $stdout"
        }

        Set-KnowledgeActionStatus `
            -Text "SSH key создан ✓  $publicKey" `
            -Kind Success

        return $true
    }
    catch {
        Set-KnowledgeActionStatus `
            -Text "Не удалось создать SSH key: $($_.Exception.Message)" `
            -Kind Error
        return $false
    }
}

function Ensure-SshAgentRunning {
    if (-not (Test-SshInstalled)) {
        return $false
    }

    try {
        $service = Get-Service -Name 'ssh-agent' -ErrorAction Stop

        if ($service.StartType -eq 'Disabled') {
            try {
                Set-Service -Name 'ssh-agent' -StartupType Manual -ErrorAction Stop
            }
            catch {}
        }

        if ($service.Status -ne 'Running') {
            try {
                Start-Service -Name 'ssh-agent' -ErrorAction Stop
            }
            catch {}
        }

        $service = Get-Service -Name 'ssh-agent' -ErrorAction Stop
        return ($service.Status -eq 'Running')
    }
    catch {
        return $false
    }
}

function Add-GitHubSshKeyToAgent {
    $privateKey = Get-GitHubSshPrivateKeyPath

    if (-not (Test-Path $privateKey)) {
        return $false
    }

    try {
        [void](Ensure-SshAgentRunning)

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = 'ssh-add.exe'
        $psi.Arguments = "`"$privateKey`""
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true

        $p = New-Object System.Diagnostics.Process
        $p.StartInfo = $psi
        [void]$p.Start()

        $stdout = $p.StandardOutput.ReadToEnd()
        $stderr = $p.StandardError.ReadToEnd()

        if (-not $p.WaitForExit(15000)) {
            try { $p.Kill() } catch {}
            return $false
        }

        # ssh-add can report "Identity added" on stderr depending on version.
        return ($p.ExitCode -eq 0)
    }
    catch {
        return $false
    }
}

function Set-KnowledgeOriginToSsh {
    $sshOrigin = Get-KnowledgeSshOrigin

    $git = Get-GitState
    if (-not $git.Repository) {
        Initialize-KnowledgeGit -Silent
        $git = Get-GitState
    }

    if (-not $git.Repository) {
        return $false
    }

    $existingRemote = Invoke-Git @('remote','get-url','origin') 8000

    if ($existingRemote.ExitCode -eq 0) {
        $set = Invoke-Git @('remote','set-url','origin',$sshOrigin) 10000
    }
    else {
        $set = Invoke-Git @('remote','add','origin',$sshOrigin) 10000
    }

    return ($set.ExitCode -eq 0)
}

function Invoke-SshGitHubAuthCheck {
    if (-not (Test-SshInstalled)) {
        return [pscustomobject]@{
            Success = $false
            NeedsKeyRegistration = $false
            Message = 'ssh.exe не найден. Установи Windows OpenSSH Client.'
        }
    }

    $privateKey = Get-GitHubSshPrivateKeyPath

    if (-not (Test-Path $privateKey)) {
        return [pscustomobject]@{
            Success = $false
            NeedsKeyRegistration = $false
            Message = 'SSH key не создан.'
        }
    }

    [void](Add-GitHubSshKeyToAgent)

    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = 'ssh.exe'
        $psi.Arguments = "-T -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -i `"$privateKey`" git@github.com"
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true

        $p = New-Object System.Diagnostics.Process
        $p.StartInfo = $psi
        [void]$p.Start()

        $stdout = $p.StandardOutput.ReadToEnd()
        $stderr = $p.StandardError.ReadToEnd()

        if (-not $p.WaitForExit(20000)) {
            try { $p.Kill() } catch {}

            return [pscustomobject]@{
                Success = $false
                NeedsKeyRegistration = $false
                Message = 'SSH connection timeout.'
            }
        }

        $message = ("$stdout`n$stderr").Trim()

        # GitHub intentionally exits ssh -T with code 1 even on successful auth.
        if ($message -match '(?i)successfully authenticated') {
            return [pscustomobject]@{
                Success = $true
                NeedsKeyRegistration = $false
                Message = $message
            }
        }

        $needsRegistration = (
            $message -match '(?i)permission denied \(publickey\)' -or
            $message -match '(?i)publickey'
        )

        return [pscustomobject]@{
            Success = $false
            NeedsKeyRegistration = $needsRegistration
            Message = $message
        }
    }
    catch {
        return [pscustomobject]@{
            Success = $false
            NeedsKeyRegistration = $false
            Message = $_.Exception.Message
        }
    }
}

function Show-GitHubSshRegistrationInstructions {
    $key = Get-GitHubSshPublicKey

    if ([string]::IsNullOrWhiteSpace($key)) {
        return
    }

    [void](Copy-GitHubSshPublicKey)

    [System.Windows.Forms.MessageBox]::Show(
        "SSH key создан, но GitHub ещё не знает этот ключ.`r`n`r`nПубличный ключ уже скопирован в буфер обмена.`r`n`r`nОдин раз добавь его в GitHub → Settings → SSH and GPG keys → New SSH key.`r`n`r`nПосле этого вернись в Launcher и нажми «Проверить GitHub».`r`n`r`nБраузер Launcher автоматически не открывает.",
        'Rx2GO QA — GitHub SSH',
        'OK',
        'Information'
    ) | Out-Null
}

function Configure-KnowledgeGitHubSsh {
    if ($script:GitBusy) { return $false }

    $script:GitBusy = $true

    try {
        Set-KnowledgeActionStatus `
            -Text 'Настраиваю GitHub через SSH…' `
            -Kind Info

        if (-not (Ensure-GitHubSshKey)) {
            return $false
        }

        if (-not (Set-KnowledgeOriginToSsh)) {
            Set-KnowledgeActionStatus `
                -Text 'Не удалось переключить Git origin на SSH.' `
                -Kind Error
            return $false
        }

        [void](Add-GitHubSshKeyToAgent)

        $check = Invoke-SshGitHubAuthCheck

        if ($check.Success) {
            Set-KnowledgeActionStatus `
                -Text 'GitHub SSH подключён ✓  Браузер не используется.' `
                -Kind Success
            return $true
        }

        if ($check.NeedsKeyRegistration) {
            Set-KnowledgeActionStatus `
                -Text 'SSH key создан. Добавь public key в GitHub один раз.' `
                -Kind Warning

            Show-GitHubSshRegistrationInstructions
            return $false
        }

        $reason = [string]$check.Message
        if ($reason.Length -gt 320) {
            $reason = $reason.Substring(0,317) + '...'
        }

        Set-KnowledgeActionStatus `
            -Text "GitHub SSH не подключён: $reason" `
            -Kind Error

        return $false
    }
    finally {
        $script:GitBusy = $false
        Refresh-KnowledgeUI -PreserveActionText
    }
}

function Test-GitHubAuthenticationError {
    param($GitResult)

    if (-not $GitResult) { return $false }

    $message = (
        [string]$GitResult.Error + "`n" +
        [string]$GitResult.Output
    )

    return (
        $message -match '(?i)authentication failed' -or
        $message -match '(?i)invalid username or token' -or
        $message -match '(?i)password authentication is not supported' -or
        $message -match '(?i)could not read username' -or
        $message -match '(?i)credential'
    )
}

function Get-GitCredentialManagerCommand {
    # Current Git for Windows normally exposes:
    #   git credential-manager ...
    # Older installs can expose:
    #   git credential-manager-core ...
    foreach ($subcommand in @('credential-manager','credential-manager-core')) {
        $probe = Invoke-Git @($subcommand,'--version') 8000

        if ($probe.ExitCode -eq 0) {
            return $subcommand
        }
    }

    return $null
}

function Clear-CachedGitHubCredential {
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = 'git.exe'
        $psi.Arguments = 'credential reject'
        $psi.WorkingDirectory = $script:ProjectRoot
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true

        $p = New-Object System.Diagnostics.Process
        $p.StartInfo = $psi
        [void]$p.Start()

        # Git credential protocol: erase the credential scoped to github.com.
        $p.StandardInput.WriteLine('protocol=https')
        $p.StandardInput.WriteLine('host=github.com')
        $p.StandardInput.WriteLine('')
        $p.StandardInput.Close()

        if (-not $p.WaitForExit(10000)) {
            try { $p.Kill() } catch {}
            return $false
        }

        return ($p.ExitCode -eq 0)
    }
    catch {
        return $false
    }
}


function Invoke-GitHubInteractiveLogin {
    param([string]$CredentialManagerCommand)

    return [pscustomobject]@{
        Success = $false
        Error = 'Browser OAuth отключён. Используется GitHub SSH.'
    }
}

function Connect-KnowledgeGitHub {
    # Compatibility wrapper retained for older UI/event references.
    # v0.12.12 never opens a browser for GitHub authentication.
    return (Configure-KnowledgeGitHubSsh)
}

function Test-KnowledgeGitHubConnection {
    if ($script:GitBusy) { return }

    $script:GitBusy = $true
    $needsSetup = $false

    try {
        Set-KnowledgeActionStatus `
            -Text 'Проверяю GitHub через SSH…' `
            -Kind Info

        if (-not (Test-GitInstalled)) {
            Set-KnowledgeActionStatus -Text 'Git не установлен.' -Kind Error

            [System.Windows.Forms.MessageBox]::Show(
                'Git не установлен. Установи Git for Windows и повтори проверку.',
                'Rx2GO QA — GitHub',
                'OK',
                'Warning'
            ) | Out-Null

            return
        }

        if (-not (Test-SshInstalled)) {
            Set-KnowledgeActionStatus `
                -Text 'Windows OpenSSH Client не найден.' `
                -Kind Error

            [System.Windows.Forms.MessageBox]::Show(
                "Не найден ssh.exe.`r`n`r`nУстанови Optional Feature → OpenSSH Client в Windows.",
                'Rx2GO QA — GitHub SSH',
                'OK',
                'Warning'
            ) | Out-Null

            return
        }

        $privateKey = Get-GitHubSshPrivateKeyPath

        if (-not (Test-Path $privateKey)) {
            $needsSetup = $true
            return
        }

        if (-not (Set-KnowledgeOriginToSsh)) {
            Set-KnowledgeActionStatus `
                -Text 'Не удалось переключить origin на SSH.' `
                -Kind Error
            return
        }

        [void](Add-GitHubSshKeyToAgent)

        $auth = Invoke-SshGitHubAuthCheck

        if (-not $auth.Success) {
            if ($auth.NeedsKeyRegistration) {
                Set-KnowledgeActionStatus `
                    -Text 'SSH key существует, но ещё не добавлен в GitHub.' `
                    -Kind Warning

                Show-GitHubSshRegistrationInstructions
                return
            }

            $reason = [string]$auth.Message
            if ($reason.Length -gt 300) {
                $reason = $reason.Substring(0,297) + '...'
            }

            Set-KnowledgeActionStatus `
                -Text "GitHub SSH недоступен: $reason" `
                -Kind Error

            return
        }

        $remoteCheck = Invoke-Git @('ls-remote','--heads','origin') 30000

        if ($remoteCheck.ExitCode -eq 0) {
            $timestamp = Get-Date -Format 'HH:mm:ss'

            Set-KnowledgeActionStatus `
                -Text "GitHub SSH доступен ✓  origin: $(Get-KnowledgeSshOrigin)  |  ${timestamp}" `
                -Kind Success

            return
        }

        $reason = if ($remoteCheck.Error) {
            [string]$remoteCheck.Error
        } else {
            [string]$remoteCheck.Output
        }

        if ($reason.Length -gt 300) {
            $reason = $reason.Substring(0,297) + '...'
        }

        Set-KnowledgeActionStatus `
            -Text "SSH авторизация есть, но repository недоступен: $reason" `
            -Kind Error
    }
    catch {
        Set-KnowledgeActionStatus `
            -Text "Ошибка GitHub SSH: $($_.Exception.Message)" `
            -Kind Error
    }
    finally {
        $script:GitBusy = $false
        Refresh-KnowledgeUI -PreserveActionText
    }

    if ($needsSetup) {
        $answer = [System.Windows.Forms.MessageBox]::Show(
            "SSH key ещё не настроен.`r`n`r`nСоздать локальный ed25519 key и переключить GitHub repository на SSH?`r`n`r`nБраузер открываться не будет.",
            'Rx2GO QA — GitHub SSH',
            'YesNo',
            'Question'
        )

        if ($answer -eq [System.Windows.Forms.DialogResult]::Yes) {
            [void](Configure-KnowledgeGitHubSsh)
        }
    }
}

function Refresh-KnowledgeStatusInteractive {
    if ($script:GitBusy) { return }

    try {
        Set-KnowledgeActionStatus -Text 'Обновляю локальный Git-статус…' -Kind Info
        Refresh-KnowledgeUI -PreserveActionText

        $git = Get-GitState
        $timestamp = Get-Date -Format 'HH:mm:ss'

        if (-not $git.Installed) {
            Set-KnowledgeActionStatus -Text "Статус ${timestamp}: Git не установлен." -Kind Error
        }
        elseif (-not $git.Repository) {
            Set-KnowledgeActionStatus -Text "Статус ${timestamp}: repository не инициализирован." -Kind Warning
        }
        elseif ($git.ManagedDirty) {
            Set-KnowledgeActionStatus `
                -Text "Статус обновлён ${timestamp}: $($git.ManagedChanges) изменений проекта; вне списка: $($git.OtherChanges)." `
                -Kind Warning
        }
        elseif ($git.OtherChanges -gt 0) {
            Set-KnowledgeActionStatus `
                -Text "Статус обновлён ${timestamp}: управляемые файлы чистые; $($git.OtherChanges) изменение(й) вне списка." `
                -Kind Warning
        }
        else {
            Set-KnowledgeActionStatus `
                -Text "Статус обновлён ${timestamp}: локальный Git чистый." `
                -Kind Success
        }
    }
    catch {
        Set-KnowledgeActionStatus -Text "Не удалось обновить статус: $($_.Exception.Message)" -Kind Error
    }
}


function Refresh-KnowledgeUI {
    param([switch]$PreserveActionText)

    if (-not $knowledgeGitStatus) { return }

    try {
        $stats = Get-KnowledgeStats
        $knowledgeRulesValue.Text = [string]$stats.Rules
        $knowledgeJiraValue.Text = [string]$stats.JiraCases
        $knowledgeRegressionValue.Text = [string]$stats.Scenarios
        $knowledgeTestsValue.Text = [string]$stats.Tests

        $git = Get-GitState

        if (-not $git.Installed) {
            $knowledgeGitStatus.Text = '● Git не установлен'
            $knowledgeGitStatus.ForeColor = [System.Drawing.Color]::Firebrick
        }
        elseif (-not $git.Repository) {
            $knowledgeGitStatus.Text = '● Git repository не настроен'
            $knowledgeGitStatus.ForeColor = [System.Drawing.Color]::FromArgb(161,98,7)
        }
        elseif ($git.ManagedDirty) {
            if ($git.OtherChanges -gt 0) {
                $knowledgeGitStatus.Text = "● $($git.ManagedChanges) изменений проекта + $($git.OtherChanges) вне списка"
            }
            else {
                $knowledgeGitStatus.Text = "● $($git.ManagedChanges) изменений проекта"
            }
            $knowledgeGitStatus.ForeColor = [System.Drawing.Color]::FromArgb(161,98,7)
        }
        elseif ($git.OtherChanges -gt 0) {
            $knowledgeGitStatus.Text = "● Проект чистый; $($git.OtherChanges) изменение(й) вне управляемых файлов"
            $knowledgeGitStatus.ForeColor = [System.Drawing.Color]::FromArgb(161,98,7)
        }
        else {
            $knowledgeGitStatus.Text = '● Git: локально чисто'
            $knowledgeGitStatus.ForeColor = [System.Drawing.Color]::FromArgb(32,120,72)
        }

        $knowledgeBranchValue.Text = $git.Branch
        $knowledgeRemoteValue.Text = $git.Remote
        $knowledgeCommitValue.Text = $git.LastCommit

        # Commit is always visible. Enable it only when there are local changes,
        # but keep it clickable for a fresh/no-commit repository as well.
        if ($knowledgeCommitButton) {
            $knowledgeCommitButton.Visible = $true
            $knowledgeCommitButton.Enabled = (
                $git.Installed -and
                $git.Repository -and
                ($git.ManagedDirty -or $git.LastCommit -eq 'коммитов пока нет')
            )
        }

        if ($knowledgeSyncButton) {
            $knowledgeSyncButton.Enabled = ($git.Installed -and $git.Repository)
        }

        $knowledgeRecentList.Items.Clear()
        $recent = @(Get-RecentKnowledgeFiles)

        if ($recent.Count -eq 0) {
            [void]$knowledgeRecentList.Items.Add('Пока нет сохранённых knowledge-файлов.')
        }
        else {
            foreach ($f in $recent) {
                $rel = $f.FullName.Substring($script:ProjectRoot.Length) -replace '^[\\/]+', ''
                [void]$knowledgeRecentList.Items.Add(('{0:dd.MM HH:mm}  {1}' -f $f.LastWriteTime, $rel))
            }
        }

        if (-not $PreserveActionText -and $knowledgeSyncInfo) {
            if (-not $git.Installed) {
                Set-KnowledgeActionStatus -Text 'Git не установлен.' -Kind Error
            }
            elseif (-not $git.Repository) {
                Set-KnowledgeActionStatus -Text 'Repository не настроен. Нажми «Проверить GitHub SSH».' -Kind Warning
            }
            elseif ($git.ManagedDirty) {
                Set-KnowledgeActionStatus `
                    -Text "$($git.ManagedChanges) изменений проекта. Нажми «Commit», затем «Synchronize»." `
                    -Kind Warning
            }
            elseif ($git.OtherChanges -gt 0) {
                Set-KnowledgeActionStatus `
                    -Text "Управляемые файлы проекта чистые. $($git.OtherChanges) изменение(й) вне безопасного списка не блокируют Commit." `
                    -Kind Warning
            }
            else {
                Set-KnowledgeActionStatus `
                    -Text 'Локальный Git чистый. Можно Synchronize с GitHub.' `
                    -Kind Success
            }
        }
    }
    catch {
        if ($knowledgeGitStatus) {
            $knowledgeGitStatus.Text = "● Ошибка Git UI: $($_.Exception.Message)"
            $knowledgeGitStatus.ForeColor = [System.Drawing.Color]::Firebrick
        }
    }
}

function Initialize-KnowledgeGit([switch]$Silent) {
    if (-not (Test-GitInstalled)) {
        if (-not $Silent) {
            [System.Windows.Forms.MessageBox]::Show('Git не установлен. Установи Git for Windows, затем снова открой Launcher.', 'Rx2GO QA', 'OK', 'Warning') | Out-Null
        }
        return
    }
    $git = Get-GitState
    if (-not $git.Repository) {
        $r = Invoke-Git @('init','-b','main')
        if ($r.ExitCode -ne 0) {
            if (-not $Silent) {
                [System.Windows.Forms.MessageBox]::Show("Не удалось инициализировать Git: $($r.Error)", 'Rx2GO QA', 'OK', 'Error') | Out-Null
            }
            return
        }
    }

    $current = Get-GitState
    if ($current.Remote -eq 'не настроен') {
        $add = Invoke-Git @('remote','add','origin',$script:DefaultGitRemote)
        if ($add.ExitCode -ne 0) {
            if (-not $Silent) {
                [System.Windows.Forms.MessageBox]::Show("Не удалось привязать GitHub автоматически:`r`n$($add.Error)", 'Rx2GO QA', 'OK', 'Error') | Out-Null
            }
            return
        }
        if ($knowledgeSyncInfo) {
            $knowledgeSyncInfo.Text = "GitHub подключён автоматически: $script:DefaultGitRemote"
            $knowledgeSyncInfo.ForeColor = [System.Drawing.Color]::FromArgb(32,120,72)
        }
    }
    Refresh-KnowledgeUI
}



function Commit-KnowledgeChanges {
    if ($script:GitBusy) { return }

    $git = Get-GitState

    if (-not $git.Repository) {
        Initialize-KnowledgeGit
        $git = Get-GitState
        if (-not $git.Repository) { return }
    }

    $script:GitBusy = $true

    try {
        Set-KnowledgeActionStatus `
            -Text 'Подготавливаю безопасные изменения проекта для Commit…' `
            -Kind Info

        $pathArgs = @(Get-KnowledgeGitPathArgs)

        if ($pathArgs.Count -eq 0) {
            throw 'Managed Git path list is empty.'
        }

        $addArgs = New-Object System.Collections.Generic.List[string]
        $addArgs.Add('add')
        $addArgs.Add('-A')
        $addArgs.Add('--')

        foreach ($path in $pathArgs) {
            $addArgs.Add([string]$path)
        }

        $addResult = Invoke-Git @($addArgs) 30000

        if ($addResult.ExitCode -ne 0) {
            throw "git add failed: $($addResult.Error) $($addResult.Output)"
        }

        $staged = Invoke-Git @('diff','--cached','--name-only')

        if ([string]::IsNullOrWhiteSpace($staged.Output)) {
            $git = Get-GitState

            $message = if ($git.OtherChanges -gt 0) {
                "Нет изменений в управляемых файлах проекта для Commit.`r`n`r`nGit видит ещё $($git.OtherChanges) изменение(й) вне безопасного списка. Они специально не коммитятся Launcher."
            }
            else {
                'Нет новых изменений проекта для коммита.'
            }

            Set-KnowledgeActionStatus `
                -Text ($message -replace "`r`n",' ') `
                -Kind Warning

            [System.Windows.Forms.MessageBox]::Show(
                $message,
                'Rx2GO QA — Git',
                'OK',
                'Information'
            ) | Out-Null

            return
        }

        $stagedFiles = @(
            $staged.Output -split "`r?`n" |
                Where-Object { $_ }
        )

        $msg = if (
            $knowledgeCommitMessage -and
            -not [string]::IsNullOrWhiteSpace($knowledgeCommitMessage.Text)
        ) {
            $knowledgeCommitMessage.Text.Trim()
        }
        else {
            'Update Rx2GO AI QA ' + (Get-Date -Format 'yyyy-MM-dd HH:mm')
        }

        $commit = Invoke-Git @('commit','-m',$msg) 30000

        if ($commit.ExitCode -ne 0) {
            $reason = "$($commit.Error)`r`n$($commit.Output)".Trim()

            Set-KnowledgeActionStatus `
                -Text "Commit не выполнен: $reason" `
                -Kind Error

            [System.Windows.Forms.MessageBox]::Show(
                "Git commit не выполнен:`r`n$reason",
                'Rx2GO QA — Git',
                'OK',
                'Error'
            ) | Out-Null

            return
        }

        if ($knowledgeCommitMessage) {
            $knowledgeCommitMessage.Clear()
        }

        Set-KnowledgeActionStatus `
            -Text "Commit создан ✓  Файлов: $($stagedFiles.Count). Теперь можно Synchronize." `
            -Kind Success
    }
    catch {
        Set-KnowledgeActionStatus `
            -Text "Commit error: $($_.Exception.Message)" `
            -Kind Error
    }
    finally {
        $script:GitBusy = $false
        Refresh-KnowledgeUI -PreserveActionText
    }
}



function Sync-KnowledgeRepository {
    if ($script:GitBusy) { return }

    $git = Get-GitState

    if (-not $git.Repository) {
        Initialize-KnowledgeGit
        $git = Get-GitState
        if (-not $git.Repository) { return }
    }

    if ($git.ManagedDirty) {
        [System.Windows.Forms.MessageBox]::Show(
            "Есть $($git.ManagedChanges) несохранённых изменений проекта.`r`n`r`nСначала нажми «Commit», затем Synchronize.",
            'Rx2GO QA',
            'OK',
            'Warning'
        ) | Out-Null

        Refresh-KnowledgeUI
        return
    }

    if (-not (Test-Path (Get-GitHubSshPrivateKeyPath))) {
        $answer = [System.Windows.Forms.MessageBox]::Show(
            "GitHub SSH ещё не настроен.`r`n`r`nСоздать SSH key сейчас?",
            'Rx2GO QA — GitHub SSH',
            'YesNo',
            'Question'
        )

        if ($answer -eq [System.Windows.Forms.DialogResult]::Yes) {
            [void](Configure-KnowledgeGitHubSsh)
        }

        return
    }

    if (-not (Set-KnowledgeOriginToSsh)) {
        Set-KnowledgeActionStatus -Text 'Не удалось настроить SSH origin.' -Kind Error
        return
    }

    $auth = Invoke-SshGitHubAuthCheck

    if (-not $auth.Success) {
        if ($auth.NeedsKeyRegistration) {
            Show-GitHubSshRegistrationInstructions
        }
        else {
            Set-KnowledgeActionStatus `
                -Text "GitHub SSH не авторизован: $($auth.Message)" `
                -Kind Error
        }

        return
    }

    $git = Get-GitState
    $script:GitBusy = $true

    try {
        if ($git.OtherChanges -gt 0) {
            Set-KnowledgeActionStatus `
                -Text "Synchronize: $($git.OtherChanges) изменение(й) вне управляемых файлов не коммитятся; проверяю remote…" `
                -Kind Warning
        }
        else {
            Set-KnowledgeActionStatus `
                -Text 'Синхронизация с GitHub по SSH…' `
                -Kind Info
        }

        # FIRST determine whether the remote branch exists.
        # A brand-new/empty GitHub repository has no origin/main yet.
        # In that case fetch origin main would fail with:
        #   fatal: couldn't find remote ref main
        # This is NOT an error — the correct action is the first push.
        $remoteBranch = Invoke-Git `
            @('ls-remote','--exit-code','--heads','origin',$git.Branch) `
            30000

        $remoteBranchExists = ($remoteBranch.ExitCode -eq 0)

        if (-not $remoteBranchExists) {
            $combinedRemoteMessage = (
                ([string]$remoteBranch.Error) + "`n" +
                ([string]$remoteBranch.Output)
            ).Trim()

            # Authentication was already verified through SSH above.
            # Exit code 2 / empty result from ls-remote --exit-code means the ref
            # simply does not exist yet, so create it with the initial push.
            if (
                $remoteBranch.ExitCode -eq 2 -or
                [string]::IsNullOrWhiteSpace($combinedRemoteMessage)
            ) {
                Set-KnowledgeActionStatus `
                    -Text "В GitHub ещё нет ветки $($git.Branch). Выполняю первый push…" `
                    -Kind Info

                $firstPush = Invoke-Git @(
                    'push','-u','origin',$git.Branch
                ) 60000

                if ($firstPush.ExitCode -ne 0) {
                    $reason = (
                        ([string]$firstPush.Error) + "`n" +
                        ([string]$firstPush.Output)
                    ).Trim()

                    Set-KnowledgeActionStatus `
                        -Text "Первый push не выполнен: $reason" `
                        -Kind Error

                    [System.Windows.Forms.MessageBox]::Show(
                        "Не удалось создать ветку $($git.Branch) в GitHub:`r`n`r`n$reason",
                        'Rx2GO QA — Git SSH',
                        'OK',
                        'Warning'
                    ) | Out-Null

                    return
                }

                Set-KnowledgeActionStatus `
                    -Text "Первый push выполнен ✓  Ветка origin/$($git.Branch) создана и связана с локальной." `
                    -Kind Success

                Refresh-KnowledgeUI -PreserveActionText
                return
            }

            Set-KnowledgeActionStatus `
                -Text "Не удалось проверить remote branch: $combinedRemoteMessage" `
                -Kind Error

            [System.Windows.Forms.MessageBox]::Show(
                "Не удалось проверить ветку origin/$($git.Branch):`r`n`r`n$combinedRemoteMessage",
                'Rx2GO QA — Git SSH',
                'OK',
                'Warning'
            ) | Out-Null

            return
        }

        # Remote branch exists: fetch it and compare histories safely.
        $fetch = Invoke-Git @('fetch','origin',$git.Branch) 60000

        if ($fetch.ExitCode -ne 0) {
            $reason = (
                ([string]$fetch.Error) + "`n" +
                ([string]$fetch.Output)
            ).Trim()

            Set-KnowledgeActionStatus `
                -Text "Fetch по SSH не выполнен: $reason" `
                -Kind Error

            [System.Windows.Forms.MessageBox]::Show(
                "git fetch не выполнен:`r`n`r`n$reason",
                'Rx2GO QA — Git SSH',
                'OK',
                'Warning'
            ) | Out-Null

            return
        }

        $remoteRef = "origin/$($git.Branch)"
        $behindRaw = (Invoke-Git @('rev-list','--count',"HEAD..$remoteRef")).Output
        $aheadRaw = (Invoke-Git @('rev-list','--count',"$remoteRef..HEAD")).Output

        $behind = 0
        $ahead = 0
        [void][int]::TryParse([string]$behindRaw, [ref]$behind)
        [void][int]::TryParse([string]$aheadRaw, [ref]$ahead)

        if ($behind -gt 0) {
            if ($git.OtherChanges -gt 0) {
                Set-KnowledgeActionStatus `
                    -Text "Remote содержит $behind новых commit(ов), но есть $($git.OtherChanges) локальных изменений вне управляемых файлов. Pull остановлен для безопасности." `
                    -Kind Warning

                [System.Windows.Forms.MessageBox]::Show(
                    "GitHub содержит $behind новых commit(ов).`r`n`r`nТакже есть $($git.OtherChanges) локальных изменений вне управляемых файлов проекта.`r`n`r`nLauncher не делает Pull автоматически, чтобы случайно их не перезаписать.",
                    'Rx2GO QA — безопасная синхронизация',
                    'OK',
                    'Warning'
                ) | Out-Null

                return
            }

            $pull = Invoke-Git @(
                'pull','--ff-only','origin',$git.Branch
            ) 60000

            if ($pull.ExitCode -ne 0) {
                $reason = (
                    ([string]$pull.Error) + "`n" +
                    ([string]$pull.Output)
                ).Trim()

                Set-KnowledgeActionStatus `
                    -Text "Pull по SSH не выполнен: $reason" `
                    -Kind Error

                [System.Windows.Forms.MessageBox]::Show(
                    "git pull --ff-only не выполнен:`r`n`r`n$reason",
                    'Rx2GO QA — Git SSH',
                    'OK',
                    'Warning'
                ) | Out-Null

                return
            }
        }

        # Recalculate after optional pull.
        $git = Get-GitState
        $remoteRef = "origin/$($git.Branch)"
        $aheadRaw = (Invoke-Git @('rev-list','--count',"$remoteRef..HEAD")).Output
        $ahead = 0
        [void][int]::TryParse([string]$aheadRaw, [ref]$ahead)

        if ($ahead -gt 0) {
            $push = Invoke-Git @(
                'push','-u','origin',$git.Branch
            ) 60000

            if ($push.ExitCode -ne 0) {
                $reason = (
                    ([string]$push.Error) + "`n" +
                    ([string]$push.Output)
                ).Trim()

                Set-KnowledgeActionStatus `
                    -Text "Push по SSH не выполнен: $reason" `
                    -Kind Error

                [System.Windows.Forms.MessageBox]::Show(
                    "git push не выполнен:`r`n`r`n$reason",
                    'Rx2GO QA — Git SSH',
                    'OK',
                    'Warning'
                ) | Out-Null

                return
            }

            Set-KnowledgeActionStatus `
                -Text "Knowledge синхронизирован с GitHub по SSH ✓  Отправлено commit(ов): $ahead" `
                -Kind Success
        }
        else {
            Set-KnowledgeActionStatus `
                -Text 'GitHub уже синхронизирован ✓  Отправлять нечего.' `
                -Kind Success
        }
    }
    finally {
        $script:GitBusy = $false
        Refresh-KnowledgeUI -PreserveActionText
    }
}

function Save-JiraKnowledgeCase($task, [string]$plan, $result = $null) {
    if (-not $task -or -not $task.Key) { return }
    $dir = Join-Path $script:ProjectRoot 'jira-cases'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $safeKey = ([string]$task.Key -replace '[^A-Za-z0-9_.-]','_')
    $path = Join-Path $dir "$safeKey.md"
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("# $($task.Key) — $($task.Title)")
    $lines.Add('')
    $lines.Add("- Module: $($task.Module)")
    $lines.Add("- Last checked: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
    $lines.Add("- Analysis: $($task.AnalysisSource)")
    if ($result) { $lines.Add("- Result: PASS $($result.Pass) / FAIL $($result.Fail) / SKIP $($result.Skip)") }
    else { $lines.Add('- Result: planned / not completed') }
    $lines.Add('')
    $lines.Add('## Acceptance criteria')
    foreach ($c in @($task.Criteria)) { $lines.Add("- $c") }
    if ($task.QAComment) {
        $lines.Add(''); $lines.Add('## QA comment for this run')
        if (([string]$task.QAComment) -match '(?i)(password|парол|token|secret|api[ -]?key)') {
            $lines.Add('[QA comment omitted from Git knowledge because it may contain a secret.]')
        } else {
            $lines.Add([string]$task.QAComment)
        }
    }
    if (@($task.ProjectRules).Count -gt 0) {
        $lines.Add(''); $lines.Add('## Project rules applied')
        foreach ($r in @($task.ProjectRules)) { $lines.Add("- $r") }
    }
    $lines.Add(''); $lines.Add('## Test plan'); $lines.Add('```text'); $lines.Add($plan); $lines.Add('```')
    if ($result -and @($result.Failed).Count -gt 0) {
        $lines.Add(''); $lines.Add('## Failed scenarios')
        foreach ($f in @($result.Failed)) { $lines.Add("- $f") }
    }
    $lines | Set-Content -Path $path -Encoding UTF8
    Refresh-KnowledgeUI
}

function New-Font([float]$size, [System.Drawing.FontStyle]$style = [System.Drawing.FontStyle]::Regular) {
    return New-Object System.Drawing.Font('Segoe UI', $size, $style)
}

function Test-CodexInstalled {
    return $null -ne (Get-Command codex -ErrorAction SilentlyContinue)
}

function Get-ChatGPTOAuthState {
    if (-not (Test-CodexInstalled)) {
        return [pscustomobject]@{ Connected = $false; Installed = $false; Message = 'Codex CLI не установлен' }
    }

    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = 'cmd.exe'
        $psi.Arguments = '/d /s /c codex login status'
        $psi.WorkingDirectory = $script:ProjectRoot
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $p = New-Object System.Diagnostics.Process
        $p.StartInfo = $psi
        [void]$p.Start()
        if (-not $p.WaitForExit(6000)) {
            try { $p.Kill() } catch { }
            return [pscustomobject]@{ Connected = $false; Installed = $true; Message = 'Не удалось проверить OAuth' }
        }
        $out = ($p.StandardOutput.ReadToEnd() + ' ' + $p.StandardError.ReadToEnd()).Trim()
        if ($p.ExitCode -eq 0) {
            return [pscustomobject]@{ Connected = $true; Installed = $true; Message = $(if ($out) { $out } else { 'ChatGPT подключён' }) }
        }
        return [pscustomobject]@{ Connected = $false; Installed = $true; Message = $(if ($out) { $out } else { 'Нужно войти в ChatGPT' }) }
    }
    catch {
        return [pscustomobject]@{ Connected = $false; Installed = $true; Message = $_.Exception.Message }
    }
}


function Update-ChatGPTOAuthUI {
    $state = Get-ChatGPTOAuthState
    $script:ChatGPTConnected = [bool]$state.Connected

    if ($chatGptStatus) {
        if ($state.Connected) {
            $chatGptStatus.Text = '● ChatGPT подключён'
            $chatGptStatus.ForeColor = [System.Drawing.Color]::FromArgb(32,120,72)
            $chatGptConnectButton.Text = 'Переподключить'
            if ($jiraAiCheck) { $jiraAiCheck.Enabled = $true }
        }
        elseif ($state.Installed) {
            $chatGptStatus.Text = '● ChatGPT не подключён'
            $chatGptStatus.ForeColor = [System.Drawing.Color]::FromArgb(161,98,7)
            $chatGptConnectButton.Text = 'Подключить ChatGPT'
            if ($jiraAiCheck) { $jiraAiCheck.Enabled = $false }
        }
        else {
            $chatGptStatus.Text = '● Нужен Codex CLI'
            $chatGptStatus.ForeColor = [System.Drawing.Color]::DimGray
            $chatGptConnectButton.Text = 'Установить и подключить'
            if ($jiraAiCheck) { $jiraAiCheck.Enabled = $false }
        }
    }

    if ($script:QuickCodexStatus) {
        if ($state.Installed) {
            $mcpText = if ($script:PlaywrightMcpReady -or (Test-PlaywrightMcpConfigured)) {
                $script:PlaywrightMcpReady = $true
                'Playwright MCP зарегистрирован'
            }
            else {
                'Playwright MCP подключится при Jira run'
            }
            $script:QuickCodexStatus.Text = "● Codex CLI: установлен • $mcpText"
            $script:QuickCodexStatus.ForeColor = [System.Drawing.Color]::FromArgb(32,120,72)
        }
        else {
            $script:QuickCodexStatus.Text = '● Codex CLI: не установлен'
            $script:QuickCodexStatus.ForeColor = [System.Drawing.Color]::Firebrick
        }
    }

    if ($script:QuickGptStatus) {
        if ($state.Connected) {
            $bs = if (Test-BrowserStackMcpConfigured) {
                $script:BrowserStackMcpConfigured = $true
                'BrowserStack RCA подключён'
            }
            else {
                'BrowserStack RCA опционально'
            }
            $script:QuickGptStatus.Text = "● ChatGPT: подключён • $bs"
            $script:QuickGptStatus.ForeColor = [System.Drawing.Color]::FromArgb(32,120,72)
        }
        elseif ($state.Installed) {
            $script:QuickGptStatus.Text = '● ChatGPT: требуется вход'
            $script:QuickGptStatus.ForeColor = [System.Drawing.Color]::FromArgb(161,98,7)
        }
        else {
            $script:QuickGptStatus.Text = '● ChatGPT: ожидает Codex CLI'
            $script:QuickGptStatus.ForeColor = [System.Drawing.Color]::DimGray
        }
    }

    if ($script:QuickChatGptButton) {
        if ($state.Connected) {
            $script:QuickChatGptButton.Text = 'Переподключить ChatGPT'
        }
        elseif ($state.Installed) {
            $script:QuickChatGptButton.Text = 'Подключить ChatGPT'
        }
        else {
            $script:QuickChatGptButton.Text = 'Установить Codex + ChatGPT'
        }
    }
}

function Connect-ChatGPTOAuth([bool]$SkipInstallPrompt = $false) {
    if ($script:ChatGPTAuthProcess -and -not $script:ChatGPTAuthProcess.HasExited) { return }

    $installFirst = -not (Test-CodexInstalled)
    if ($installFirst -and -not $SkipInstallPrompt) {
        $answer = [System.Windows.Forms.MessageBox]::Show(
            'Codex CLI не установлен. Установить официальный Codex CLI от OpenAI и затем открыть вход через ChatGPT?',
            'Rx2GO QA', 'YesNo', 'Question')
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    }

    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        if ($installFirst) {
            # Official Windows standalone installer from OpenAI. No Node.js/npm required.
            # Refresh PATH in the child process after install, then immediately start OAuth login.
            $installAndLogin = @'
$ErrorActionPreference = 'Stop'
Write-Host 'Installing official OpenAI Codex CLI...'
irm 'https://chatgpt.com/codex/install.ps1' | iex
$env:Path = [Environment]::GetEnvironmentVariable('Path','User') + ';' + [Environment]::GetEnvironmentVariable('Path','Machine')
Write-Host ''
Write-Host 'Starting ChatGPT sign-in...'
codex login
'@
            $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($installAndLogin))
            $psi.FileName = 'powershell.exe'
            $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded"
            $chatGptStatus.Text = '● Устанавливаю Codex CLI…'
        }
        else {
            $psi.FileName = 'cmd.exe'
            $psi.Arguments = '/d /s /c codex login'
            $chatGptStatus.Text = '● Запускаю вход ChatGPT…'
        }
        $psi.WorkingDirectory = $script:ProjectRoot
        $psi.UseShellExecute = $true
        $script:ChatGPTAuthProcess = [System.Diagnostics.Process]::Start($psi)
        $chatGptStatus.ForeColor = [System.Drawing.Color]::FromArgb(37,99,235)
        $chatGptConnectButton.Enabled = $false
        if ($script:ChatGPTAuthTimer) { $script:ChatGPTAuthTimer.Start() }
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show("Не удалось установить/запустить Codex CLI: $($_.Exception.Message)", 'Rx2GO QA', 'OK', 'Error') | Out-Null
    }
}

function Initialize-CodexOnLauncherStart {
    # Silent startup check only.
    # Codex is a CLI client, not a background service, so the launcher must not
    # open its interactive console on every startup.
    $state = Get-ChatGPTOAuthState
    $script:ChatGPTConnected = [bool]$state.Connected
    Update-ChatGPTOAuthUI

    if ($state.Connected) {
        if ($jiraTaskStatus) {
            $jiraTaskStatus.Text = 'Codex готов — ChatGPT подключён'
            $jiraTaskStatus.ForeColor = [System.Drawing.Color]::FromArgb(32,120,72)
        }
        return
    }

    if (-not $state.Installed) {
        if ($jiraTaskStatus) {
            $jiraTaskStatus.Text = 'Codex CLI не установлен — нажми «Установить и подключить»'
            $jiraTaskStatus.ForeColor = [System.Drawing.Color]::FromArgb(161,98,7)
        }
        return
    }

    # Installed but not authenticated. Do not launch an interactive terminal
    # automatically; let the user start the one-time login explicitly.
    if ($jiraTaskStatus) {
        $jiraTaskStatus.Text = 'Codex установлен — нажми «Подключить ChatGPT» один раз'
        $jiraTaskStatus.ForeColor = [System.Drawing.Color]::FromArgb(161,98,7)
    }
}

function Get-Rx2GOProjectRules {
    if (-not (Test-Path $script:ProjectRulesFile)) { return @() }
    try {
        $raw = Get-Content -Raw -Path $script:ProjectRulesFile -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
        $items = @($raw | ConvertFrom-Json -ErrorAction Stop)
        return @($items | Where-Object { $_.text } | ForEach-Object { [string]$_.text })
    }
    catch { return @() }
}

function Save-Rx2GOProjectRule([string]$ruleText) {
    $value = if ($ruleText) { $ruleText.Trim() } else { '' }
    if ([string]::IsNullOrWhiteSpace($value)) {
        [System.Windows.Forms.MessageBox]::Show('Напиши правило, которое нужно использовать в будущих задачах.', 'Rx2GO QA', 'OK', 'Information') | Out-Null
        return
    }
    if ($value -match '(?i)(password|парол|token|secret|api[ -]?key|ключ[ -]?api)') {
        [System.Windows.Forms.MessageBox]::Show('Похоже, текст содержит секрет или пароль. Такие данные нельзя сохранять в Knowledge Base — используй защищённые credentials/runtime secrets.', 'Rx2GO QA', 'OK', 'Warning') | Out-Null
        return
    }

    $dir = Split-Path -Parent $script:ProjectRulesFile
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $existing = @()
    if (Test-Path $script:ProjectRulesFile) {
        try { $existing = @((Get-Content -Raw $script:ProjectRulesFile) | ConvertFrom-Json) } catch { $existing = @() }
    }
    $duplicate = $existing | Where-Object { ([string]$_.text).Trim().ToLowerInvariant() -eq $value.ToLowerInvariant() }
    if (-not $duplicate) {
        $existing += [pscustomobject]@{
            text = $value
            createdAt = (Get-Date).ToString('o')
            source = 'QA launcher'
        }
        @($existing) | ConvertTo-Json -Depth 6 | Set-Content -Path $script:ProjectRulesFile -Encoding UTF8
    }
    if ($jiraPersistentRuleBox) { $jiraPersistentRuleBox.Clear() }
    if ($jiraRulesCountLabel) {
        $count = @(Get-Rx2GOProjectRules).Count
        $jiraRulesCountLabel.Text = "Сохранено правил: $count"
    }
    if ($jiraTaskStatus) {
        $jiraTaskStatus.Text = if ($duplicate) { 'Такое правило уже есть в Knowledge Base' } else { 'Правило сохранено в Knowledge Base Rx2GO' }
        $jiraTaskStatus.ForeColor = [System.Drawing.Color]::FromArgb(37,99,235)
    }
    Refresh-KnowledgeUI
}


function Get-JiraIssueKey([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $m = [regex]::Match($Text, '(?i)\b([A-Z][A-Z0-9]+-\d+)\b')
    if ($m.Success) { return $m.Groups[1].Value.ToUpperInvariant() }
    return $null
}



function ConvertFrom-JiraAdf($Node) {
    if ($null -eq $Node) { return '' }

    if ($Node -is [string]) {
        return [string]$Node
    }

    $type = ''
    $textValue = ''
    $content = $null

    try { $type = [string]$Node.type } catch { }
    try { $textValue = [string]$Node.text } catch { }
    try { $content = $Node.content } catch { }

    if ($type -eq 'text') {
        return $textValue
    }

    $children = ''
    if ($null -ne $content) {
        foreach ($child in $content) {
            if ($null -ne $child) {
                $children += [string](ConvertFrom-JiraAdf $child)
            }
        }
    }

    switch ($type) {
        'paragraph'   { return $children + "`n" }
        'heading'     { return $children + "`n" }
        'hardBreak'   { return "`n" }
        'listItem'    { return '- ' + ($children.TrimEnd()) + "`n" }
        'bulletList'  { return $children + "`n" }
        'orderedList' { return $children + "`n" }
        default       { return $children }
    }
}

function Get-JiraApiCredentialPlain {
    if (-not (Test-Path $script:JiraCredentialFile)) { return $null }

    try {
        $credential = Import-Clixml -Path $script:JiraCredentialFile
        $ptr = [IntPtr]::Zero
        try {
            $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($credential.Password)
            return @{
                Email = $credential.UserName
                Token = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
            }
        }
        finally {
            if ($ptr -ne [IntPtr]::Zero) {
                [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
            }
        }
    }
    catch {
        return $null
    }
}

function New-JiraAuthorizationHeader([string]$Email, [string]$Token) {
    $raw = "$Email`:$Token"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($raw)
    return 'Basic ' + [Convert]::ToBase64String($bytes)
}


function Invoke-JiraApiGet([string]$Path) {
    $jira = Get-JiraApiCredentialPlain
    if (-not $jira) {
        throw 'JIRA_CREDENTIAL_NOT_CONFIGURED'
    }

    try {
        $authorization = [string](New-JiraAuthorizationHeader ([string]$jira.Email) ([string]$jira.Token))
        $headers = @{
            Authorization = $authorization
            Accept = 'application/json'
        }

        $uri = [string]("https://rx2go.atlassian.net" + [string]$Path)

        return Invoke-RestMethod `
            -Method Get `
            -Uri $uri `
            -Headers $headers `
            -TimeoutSec 30 `
            -ErrorAction Stop
    }
    finally {
        $jira.Token = $null
    }
}

function Test-JiraApiConnection {
    try {
        $me = Invoke-JiraApiGet '/rest/api/3/myself'
        if ($me -and $me.accountId) {
            $script:JiraApiDisplayName = [string]$me.displayName
            return $true
        }
    }
    catch { }
    return $false
}

function Update-JiraConnectionUI {
    if (-not $jiraConnectionStatus) { return }

    if (Test-JiraApiConnection) {
        $name = if ($script:JiraApiDisplayName) { " — $($script:JiraApiDisplayName)" } else { '' }
        $jiraConnectionStatus.Text = "● Jira API подключена$name"
        $jiraConnectionStatus.ForeColor = [System.Drawing.Color]::FromArgb(32,120,72)
        if ($jiraConnectButton) { $jiraConnectButton.Text = 'Настроить Jira' }
    }
    else {
        $jiraConnectionStatus.Text = '● Jira API не настроена'
        $jiraConnectionStatus.ForeColor = [System.Drawing.Color]::FromArgb(161,98,7)
        if ($jiraConnectButton) { $jiraConnectButton.Text = 'Настроить Jira' }
    }
}

function Save-JiraApiCredential {
    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = 'Настройка Jira API'
    $dialog.Size = New-Object System.Drawing.Size(530, 330)
    $dialog.StartPosition = 'CenterParent'
    $dialog.FormBorderStyle = 'FixedDialog'
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false
    $dialog.BackColor = [System.Drawing.Color]::White

    $title = New-Object System.Windows.Forms.Label
    $title.Text = 'Подключение Jira без браузерного входа'
    $title.Font = New-Font 13 ([System.Drawing.FontStyle]::Bold)
    $title.AutoSize = $true
    $title.Location = New-Object System.Drawing.Point(24, 18)
    $dialog.Controls.Add($title)

    $desc = New-Object System.Windows.Forms.Label
    $desc.Text = "Один раз введи Atlassian email и API token.`r`nТокен будет сохранён зашифрованно через Windows DPAPI."
    $desc.Font = New-Font 9
    $desc.AutoSize = $true
    $desc.Location = New-Object System.Drawing.Point(24, 52)
    $dialog.Controls.Add($desc)

    $emailLabel = New-Object System.Windows.Forms.Label
    $emailLabel.Text = 'Atlassian email'
    $emailLabel.AutoSize = $true
    $emailLabel.Location = New-Object System.Drawing.Point(24, 102)
    $dialog.Controls.Add($emailLabel)

    $emailBox = New-Object System.Windows.Forms.TextBox
    $emailBox.Location = New-Object System.Drawing.Point(24, 122)
    $emailBox.Size = New-Object System.Drawing.Size(455, 25)
    $dialog.Controls.Add($emailBox)

    $tokenLabel = New-Object System.Windows.Forms.Label
    $tokenLabel.Text = 'API token'
    $tokenLabel.AutoSize = $true
    $tokenLabel.Location = New-Object System.Drawing.Point(24, 158)
    $dialog.Controls.Add($tokenLabel)

    $tokenBox = New-Object System.Windows.Forms.TextBox
    $tokenBox.Location = New-Object System.Drawing.Point(24, 178)
    $tokenBox.Size = New-Object System.Drawing.Size(455, 25)
    $tokenBox.UseSystemPasswordChar = $true
    $dialog.Controls.Add($tokenBox)

    $openTokenPage = New-Object System.Windows.Forms.Button
    $openTokenPage.Text = 'Создать API token'
    $openTokenPage.Size = New-Object System.Drawing.Size(145, 34)
    $openTokenPage.Location = New-Object System.Drawing.Point(24, 225)
    $openTokenPage.Add_Click({
        Start-Process 'https://id.atlassian.com/manage-profile/security/api-tokens'
    })
    $dialog.Controls.Add($openTokenPage)

    $testSave = New-Object System.Windows.Forms.Button
    $testSave.Text = 'Проверить и сохранить'
    $testSave.Size = New-Object System.Drawing.Size(190, 34)
    $testSave.Location = New-Object System.Drawing.Point(289, 225)
    $testSave.BackColor = [System.Drawing.Color]::FromArgb(37,99,235)
    $testSave.ForeColor = [System.Drawing.Color]::White
    $testSave.FlatStyle = 'Flat'

    $testSave.Add_Click({
        $email = $emailBox.Text.Trim()
        $token = $tokenBox.Text

        if ([string]::IsNullOrWhiteSpace($email) -or [string]::IsNullOrWhiteSpace($token)) {
            [System.Windows.Forms.MessageBox]::Show(
                'Введи Atlassian email и API token.',
                'Rx2GO QA',
                'OK',
                'Warning'
            ) | Out-Null
            return
        }

        try {
            $header = New-JiraAuthorizationHeader $email $token
            $me = Invoke-RestMethod `
                -Method Get `
                -Uri 'https://rx2go.atlassian.net/rest/api/3/myself' `
                -Headers @{ Authorization=$header; Accept='application/json' } `
                -TimeoutSec 30

            if (-not $me.accountId) { throw 'Jira API не вернула accountId' }

            $dir = Split-Path $script:JiraCredentialFile
            New-Item -ItemType Directory -Path $dir -Force | Out-Null

            $secure = ConvertTo-SecureString $token -AsPlainText -Force
            $credential = [System.Management.Automation.PSCredential]::new($email, $secure)
            $credential | Export-Clixml -Path $script:JiraCredentialFile

            $tokenBox.Text = ''
            $dialog.DialogResult = [System.Windows.Forms.DialogResult]::OK
            $dialog.Close()

            [System.Windows.Forms.MessageBox]::Show(
                "Jira подключена: $($me.displayName)",
                'Rx2GO QA',
                'OK',
                'Information'
            ) | Out-Null
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show(
                "Jira API не приняла эти данные.`r`n`r`n$($_.Exception.Message)",
                'Rx2GO QA',
                'OK',
                'Error'
            ) | Out-Null
        }
    })
    $dialog.Controls.Add($testSave)

    $existing = Get-JiraApiCredentialPlain
    if ($existing) {
        $emailBox.Text = $existing.Email
        $existing.Token = $null
    }

    [void]$dialog.ShowDialog($form)
    Update-JiraConnectionUI
}



function Get-JiraCommentsFromApi([string]$IssueKey) {
    $result = @()
    $startAt = 0
    $maxResults = 100

    while ($true) {
        $path = [string](
            "/rest/api/3/issue/" + $IssueKey +
            "/comment?startAt=" + $startAt +
            "&maxResults=" + $maxResults
        )

        $page = Invoke-JiraApiGet $path

        if ($null -eq $page) {
            break
        }

        $received = 0
        if ($null -ne $page.comments) {
            foreach ($comment in $page.comments) {
                $received++

                $body = ''
                if ($null -ne $comment.body) {
                    $body = [string](ConvertFrom-JiraAdf $comment.body)
                }

                $result += [pscustomobject]@{
                    Author = [string]$comment.author.displayName
                    Created = [string]$comment.created
                    Body = $body.Trim()
                }
            }
        }

        $startAt += $received

        $total = 0
        try { $total = [int]$page.total } catch { $total = $startAt }

        if ($received -eq 0 -or $startAt -ge $total) {
            break
        }
    }

    return $result
}


function Get-JiraIssueFromApi([string]$IssueKey) {
    if ([string]::IsNullOrWhiteSpace($IssueKey)) {
        return $null
    }

    $stage = 'prepare'

    try {
        $stage = 'issue request'
        $issuePath = [string](
            "/rest/api/3/issue/" + $IssueKey +
            "?fields=summary,description,status,issuetype,priority,labels,components"
        )

        $issue = Invoke-JiraApiGet $issuePath

        if ($null -eq $issue) {
            throw 'Jira API returned an empty issue response.'
        }

        $stage = 'description'
        $description = ''
        if ($null -ne $issue.fields.description) {
            $description = [string](ConvertFrom-JiraAdf $issue.fields.description)
        }

        $stage = 'comments'
        $comments = @(Get-JiraCommentsFromApi $IssueKey)

        $stage = 'result mapping'
        $components = @()
        if ($null -ne $issue.fields.components) {
            foreach ($component in $issue.fields.components) {
                if ($null -ne $component -and $component.name) {
                    $components += [string]$component.name
                }
            }
        }

        $labels = @()
        if ($null -ne $issue.fields.labels) {
            foreach ($label in $issue.fields.labels) {
                $labels += [string]$label
            }
        }

        return [pscustomobject]@{
            key = [string]$issue.key
            summary = [string]$issue.fields.summary
            description = $description.Trim()
            status = [string]$issue.fields.status.name
            issueType = [string]$issue.fields.issuetype.name
            priority = [string]$issue.fields.priority.name
            labels = $labels
            components = $components
            comments = $comments
            webUrl = [string]("https://rx2go.atlassian.net/browse/" + $IssueKey)
        }
    }
    catch {
        $exceptionType = $_.Exception.GetType().FullName
        $message = $_.Exception.Message
        $script:JiraFetchedSource = "Stage: $stage`r`n$exceptionType`r`n$message"

        $logDir = Join-Path $script:ProjectRoot 'reports\jira'
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        $logFile = Join-Path $logDir ("jira-fetch-" + $IssueKey + ".error.log")

        @(
            "Jira fetch error"
            "Issue: $IssueKey"
            "Stage: $stage"
            "Date: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
            ""
            "Exception: $exceptionType"
            "Message: $message"
            ""
            "Script stack:"
            $_.ScriptStackTrace
        ) | Set-Content -Path $logFile -Encoding UTF8

        $script:JiraFetchedSource += "`r`nLog: $logFile"
        return $null
    }
}


function Convert-JiraIssueToAnalysisText($Issue) {
    if (-not $Issue) { return '' }

    $lines = @()
    $lines += "JIRA KEY: $($Issue.key)"
    $lines += "TITLE: $($Issue.summary)"
    $lines += "ISSUE TYPE: $($Issue.issueType)"
    $lines += "STATUS: $($Issue.status)"
    $lines += "PRIORITY: $($Issue.priority)"
    $lines += ''
    $lines += 'DESCRIPTION FROM JIRA:'
    $lines += [string]$Issue.description
    $lines += ''

    $commentCount = 0
    if ($null -ne $Issue.comments) {
        foreach ($unused in $Issue.comments) { $commentCount++ }
    }

    $lines += "JIRA COMMENTS: $commentCount"

    if ($commentCount -gt 0) {
        foreach ($comment in $Issue.comments) {
            $lines += ''
            $lines += "COMMENT BY $($comment.Author) AT $($comment.Created):"
            $lines += [string]$comment.Body
        }
    }

    return ($lines -join "`r`n")
}

function Format-JiraIssueForPreview($Issue) {
    if (-not $Issue) { return '' }

    $lines = @()
    $lines += [string]("$($Issue.key) — $($Issue.summary)")
    $lines += [string]("Тип: $($Issue.issueType) | Статус: $($Issue.status) | Приоритет: $($Issue.priority)")
    $lines += ''
    $lines += 'DESCRIPTION'
    $lines += '────────────────────────────────────────────────────────'
    $lines += [string]$Issue.description
    $lines += ''

    $commentCount = 0
    if ($null -ne $Issue.comments) {
        foreach ($unused in $Issue.comments) { $commentCount++ }
    }

    $lines += "JIRA COMMENTS: $commentCount"
    $lines += '────────────────────────────────────────────────────────'

    if ($commentCount -eq 0) {
        $lines += 'Нет комментариев.'
    }
    else {
        foreach ($comment in $Issue.comments) {
            $lines += "[$($comment.Created)] $($comment.Author)"
            $lines += [string]$comment.Body
            $lines += ''
        }
    }

    return ($lines -join "`r`n")
}

function Load-JiraIssuePreview {
    $issueKey = Get-JiraIssueKey $jiraTaskBox.Text

    if (-not $issueKey) {
        [System.Windows.Forms.MessageBox]::Show(
            'Вставь Jira key или ссылку, например SCRUM-4033.',
            'Rx2GO QA','OK','Warning'
        ) | Out-Null
        return
    }

    $jiraTaskStatus.Text = "Загружаю $issueKey из Jira…"
    $jiraTaskStatus.ForeColor = [System.Drawing.Color]::FromArgb(37,99,235)
    [System.Windows.Forms.Application]::DoEvents()

    $script:JiraFetchedSource = $null
    $issue = Get-JiraIssueFromApi $issueKey

    if (-not $issue) {
        $jiraTaskStatus.Text = 'Jira не загрузилась'
        $jiraTaskStatus.ForeColor = [System.Drawing.Color]::Firebrick
        [System.Windows.Forms.MessageBox]::Show(
            "Не удалось получить $issueKey через Jira API.`r`n`r`n$($script:JiraFetchedSource)",
            'Rx2GO QA','OK','Error'
        ) | Out-Null
        return
    }

    $script:LoadedJiraIssue = $issue
    $script:LoadedJiraIssueKey = $issueKey
    $script:JiraFetchedSource = Convert-JiraIssueToAnalysisText $issue
    Move-AdhocScreenshotsToIssue -IssueKey $issueKey
    Restore-JiraScreenshotsForIssue -IssueKey $issueKey

    $jiraImportedBox.Text = Format-JiraIssueForPreview $issue
    $jiraImportedBox.SelectionStart = 0
    $jiraImportedBox.ScrollToCaret()

    $jiraImportedInfo.Text = "$issueKey загружена • Jira comments: $(@($issue.comments).Count)"
    $jiraImportedInfo.ForeColor = [System.Drawing.Color]::FromArgb(32,120,72)

    $jiraTaskStatus.Text = "Jira загружена: $issueKey"
    $jiraTaskStatus.ForeColor = [System.Drawing.Color]::FromArgb(32,120,72)
}




function Append-AgentLog {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return }
    $line = "$(Get-Date -Format 'HH:mm:ss')  $Text`r`n"
    if ($script:AgentLogBox) {
        $script:AgentLogBox.AppendText($line)
        $script:AgentLogBox.SelectionStart = $script:AgentLogBox.Text.Length
        $script:AgentLogBox.ScrollToCaret()
    }
    [System.Windows.Forms.Application]::DoEvents()
}

function Get-LogTail {
    param([string]$Path,[int]$MaxLines = 20)
    if (-not $Path -or -not (Test-Path $Path)) { return '' }
    try {
        $lines = @(Get-Content -Path $Path -Tail $MaxLines -ErrorAction Stop)
        return ($lines -join "`r`n")
    } catch { return '' }
}

function Open-AgentLogFolder {
    if (-not $script:AgentRunDir -or -not (Test-Path $script:AgentRunDir)) {
        [System.Windows.Forms.MessageBox]::Show('Папка логов ещё не создана.','Rx2GO QA','OK','Information') | Out-Null
        return
    }
    Start-Process explorer.exe -ArgumentList "`"$script:AgentRunDir`""
}

function Read-Utf8File {
    param([string]$Path)

    if (-not (Test-Path $Path)) { return $null }
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    return [System.IO.File]::ReadAllText($Path, $utf8)
}

function Convert-AgentJson {
    param([string]$Raw)

    if ([string]::IsNullOrWhiteSpace($Raw)) { return $null }

    $value = $Raw.Trim()
    if ($value -match '(?s)```(?:json)?\s*(.*?)\s*```') {
        $value = $Matches[1].Trim()
    }

    try {
        return ($value | ConvertFrom-Json -ErrorAction Stop)
    }
    catch {
        $script:LastAgentError = "JSON parse failed: $($_.Exception.Message)"
        return $null
    }
}


function Set-AgentStatus {
    param(
        [ValidateSet('JiraAnalyst','McpQaAgent','QAReviewer','FailureTriage','TestDesigner','UIAgent','ApiNetworkAgent')]
        [string]$Agent,
        [ValidateSet('WAIT','RUNNING','PASS','FAIL')]
        [string]$State,
        [string]$Details = ''
    )

    $label = $null
    $caption = ''

    switch ($Agent) {
        'JiraAnalyst' {
            $label = $script:AgentJiraAnalystLabel
            $caption = '1. Requirements Analyst'
        }
        'McpQaAgent' {
            $label = $script:AgentTestDesignerLabel
            $caption = '2. Playwright MCP QA'
        }
        'QAReviewer' {
            $label = $script:AgentReviewerLabel
            $caption = '3. QA Reviewer'
        }
        'FailureTriage' {
            $label = $script:AgentApiLabel
            $caption = 'RCA. Failure Triage'
        }
        # Legacy aliases retained so old helper functions do not throw if invoked manually.
        'TestDesigner' { $label = $script:AgentTestDesignerLabel; $caption = '2. Playwright MCP QA' }
        'UIAgent' { $label = $script:AgentUiLabel; $caption = 'Legacy UI Agent' }
        'ApiNetworkAgent' { $label = $script:AgentApiLabel; $caption = 'RCA. Failure Triage' }
    }

    if (-not $label) { return }

    $suffix = switch ($State) {
        'WAIT'    { 'ожидает' }
        'RUNNING' { 'работает…' }
        'PASS'    { 'готов' }
        'FAIL'    { 'ошибка' }
    }

    if ($Details) {
        $label.Text = "$caption — $suffix — $Details"
        $label.Tag = $Details
    }
    else {
        $label.Text = "$caption — $suffix"
        $label.Tag = ''
    }

    switch ($State) {
        'WAIT'    { $label.ForeColor = [System.Drawing.Color]::DimGray }
        'RUNNING' { $label.ForeColor = [System.Drawing.Color]::FromArgb(37,99,235) }
        'PASS'    { $label.ForeColor = [System.Drawing.Color]::FromArgb(32,120,72) }
        'FAIL'    { $label.ForeColor = [System.Drawing.Color]::Firebrick }
    }

    if ($State -ne 'WAIT') {
        $detailText = if ($Details) { " — $Details" } else { '' }
        Append-AgentLog "$caption → $State$detailText"
    }

    [System.Windows.Forms.Application]::DoEvents()
}


function Reset-AgentStatuses {
    Set-AgentStatus -Agent JiraAnalyst -State WAIT
    Set-AgentStatus -Agent McpQaAgent -State WAIT
    Set-AgentStatus -Agent QAReviewer -State WAIT
    Set-AgentStatus -Agent FailureTriage -State WAIT

    $script:LastAgentError = $null
    $script:AgentJiraAnalysis = $null
    $script:AgentTestDesign = $null
    $script:AgentUiDesign = $null
    $script:AgentApiDesign = $null
    $script:AgentReviewerSpec = $null
    $script:AgentMcpExecution = $null
    $script:AgentMcpExecutionRaw = $null
    $script:FailureTriage = $null
    $script:LastAgentLogFile = $null
    $script:LivePageContext = $null
    $script:LivePageContextFile = $null
    $script:LivePageContextLog = $null

    if ($script:AgentLogBox) {
        $script:AgentLogBox.Clear()
        $script:AgentLogBox.AppendText("Smart QA pipeline ready.`r`n")
    }
}

function Wait-ProcessResponsive {
    param(
        [System.Diagnostics.Process]$Process,
        [int]$TimeoutSec,
        [int]$PollMs = 120
    )

    if (-not $Process) { return $false }

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSec)

    while (-not $Process.HasExited) {
        [System.Windows.Forms.Application]::DoEvents()

        if ([DateTime]::UtcNow -ge $deadline) {
            return $false
        }

        Start-Sleep -Milliseconds $PollMs
    }

    try { $Process.WaitForExit() } catch { }
    [System.Windows.Forms.Application]::DoEvents()
    return $true
}


function Invoke-ShortCommand {
    param(
        [string]$CommandLine,
        [int]$TimeoutSec = 30
    )

    $result = [ordered]@{
        ExitCode = -1
        StdOut = ''
        StdErr = ''
        TimedOut = $false
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'cmd.exe'
    $psi.Arguments = "/d /s /c $CommandLine"
    $psi.WorkingDirectory = $script:ProjectRoot
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true

    $p = $null
    try {
        $p = New-Object System.Diagnostics.Process
        $p.StartInfo = $psi
        [void]$p.Start()

        $outTask = $p.StandardOutput.ReadToEndAsync()
        $errTask = $p.StandardError.ReadToEndAsync()

        $finished = Wait-ProcessResponsive -Process $p -TimeoutSec $TimeoutSec
        if (-not $finished) {
            $result.TimedOut = $true
            try { $p.Kill() } catch {}
            try { [void]$p.WaitForExit(3000) } catch {}
        }

        try { $result.StdOut = [string]$outTask.Result } catch {}
        try { $result.StdErr = [string]$errTask.Result } catch {}
        try { $result.ExitCode = [int]$p.ExitCode } catch {}
        return [pscustomobject]$result
    }
    finally {
        if ($p) {
            try { $p.Dispose() } catch {}
        }
    }
}

function Get-CodexMcpListText {
    $result = Invoke-ShortCommand -CommandLine 'codex mcp list' -TimeoutSec 30
    if ($result.TimedOut) { return '' }
    return (([string]$result.StdOut) + "`n" + ([string]$result.StdErr)).Trim()
}


function Test-PlaywrightMcpConfigured {
    $list = Get-CodexMcpListText
    if ([string]::IsNullOrWhiteSpace($list)) { return $false }
    return ($list -match '(?im)^\s*playwright\b|\bplaywright\b.*@playwright/mcp')
}


function Get-CodexConfigFile {
    $codexHome = if (-not [string]::IsNullOrWhiteSpace([string]$env:CODEX_HOME)) {
        [string]$env:CODEX_HOME
    }
    else {
        Join-Path $env:USERPROFILE '.codex'
    }

    return (Join-Path $codexHome 'config.toml')
}

function Ensure-PlaywrightMcpCodexPolicy {
    $configFile = Get-CodexConfigFile

    if (-not (Test-Path $configFile)) {
        $script:LastAgentError = "Codex config not found: $configFile"
        Append-AgentLog "MCP POLICY → FAIL | $($script:LastAgentError)"
        return $false
    }

    try {
        $raw = [System.IO.File]::ReadAllText($configFile, [System.Text.Encoding]::UTF8)
        $pattern = '(?ms)^\[mcp_servers\.playwright\]\s*\r?\n(?<body>.*?)(?=^\[|\z)'
        $match = [regex]::Match($raw, $pattern)

        if (-not $match.Success) {
            $script:LastAgentError = 'Codex config has no [mcp_servers.playwright] block after MCP setup.'
            Append-AgentLog "MCP POLICY → FAIL | $($script:LastAgentError)"
            return $false
        }

        $body = [string]$match.Groups['body'].Value

        # Preserve any user-added passthrough vars and add the ones our dynamic
        # Playwright MCP session needs. codex mcp add does not create env_vars.
        $requiredEnvVars = @(
            'PLAYWRIGHT_MCP_CDP_ENDPOINT',
            'PLAYWRIGHT_MCP_CDP_TIMEOUT',
            'PLAYWRIGHT_MCP_CODEGEN',
            'PLAYWRIGHT_MCP_CONSOLE_LEVEL',
            'PLAYWRIGHT_MCP_OUTPUT_DIR'
        )

        $existingVars = @()
        $envMatch = [regex]::Match($body, '(?m)^\s*env_vars\s*=\s*\[(?<items>[^\]]*)\]\s*$')
        if ($envMatch.Success) {
            $itemMatches = [regex]::Matches([string]$envMatch.Groups['items'].Value, '["''](?<name>[^"'']+)["'']')
            foreach ($item in $itemMatches) {
                $name = [string]$item.Groups['name'].Value
                if (-not [string]::IsNullOrWhiteSpace($name)) {
                    $existingVars += $name
                }
            }
        }

        $allVars = @($existingVars + $requiredEnvVars | Select-Object -Unique)
        $quotedVars = @($allVars | ForEach-Object { '"' + ($_ -replace '"','\\"') + '"' })
        $envLine = 'env_vars = [' + ($quotedVars -join ', ') + ']'
        $approvalLine = 'default_tools_approval_mode = "approve"'

        # Remove stale copies before inserting the canonical policy lines.
        $body = [regex]::Replace(
            $body,
            '(?m)^\s*default_tools_approval_mode\s*=.*(?:\r?\n|$)',
            ''
        )
        $body = [regex]::Replace(
            $body,
            '(?m)^\s*env_vars\s*=\s*\[[^\]]*\]\s*(?:\r?\n|$)',
            ''
        )

        $newBlock = "[mcp_servers.playwright]`r`n$approvalLine`r`n$envLine`r`n$body"
        $updated = $raw.Substring(0, $match.Index) + $newBlock + $raw.Substring($match.Index + $match.Length)

        if ($updated -ne $raw) {
            Write-Utf8NoBomFile -Path $configFile -Content $updated
        }

        $verify = [System.IO.File]::ReadAllText($configFile, [System.Text.Encoding]::UTF8)
        $okApproval = $verify -match '(?ms)^\[mcp_servers\.playwright\].*?^default_tools_approval_mode\s*=\s*["'']approve["'']\s*$'
        $okCdp = $verify -match '(?ms)^\[mcp_servers\.playwright\].*?^env_vars\s*=.*PLAYWRIGHT_MCP_CDP_ENDPOINT'

        if (-not $okApproval -or -not $okCdp) {
            $script:LastAgentError = 'Playwright MCP policy could not be verified in Codex config.'
            Append-AgentLog "MCP POLICY → FAIL | $($script:LastAgentError)"
            return $false
        }

        Append-AgentLog 'MCP POLICY → dynamic CDP env forwarding enabled.'
        Append-AgentLog 'MCP POLICY → Playwright MCP tools auto-approved for headless Codex exec.'
        return $true
    }
    catch {
        $script:LastAgentError = "Could not update Playwright MCP Codex policy: $($_.Exception.Message)"
        Append-AgentLog "MCP POLICY → FAIL | $($script:LastAgentError)"
        return $false
    }
}


function Ensure-PlaywrightMcpForCodex {
    if ($script:PlaywrightMcpReady -and (Test-PlaywrightMcpConfigured)) {
        if (Ensure-PlaywrightMcpCodexPolicy) {
            return $true
        }
        $script:PlaywrightMcpReady = $false
    }

    Append-AgentLog 'MCP PRECHECK → checking Microsoft Playwright MCP in Codex…'
    $jiraTaskStatus.Text = 'Проверяю Playwright MCP для Codex…'
    $jiraTaskStatus.ForeColor = [System.Drawing.Color]::FromArgb(37,99,235)
    [System.Windows.Forms.Application]::DoEvents()

    if (-not (Test-PlaywrightMcpConfigured)) {
        # Register the raw Playwright MCP server once. Dynamic run-scoped values
        # are forwarded through env_vars configured below, rather than baked into
        # this global command.
        $commands = @(
            'codex mcp add playwright -- npx -y @playwright/mcp@latest',
            'codex mcp add playwright npx -y @playwright/mcp@latest'
        )

        $registered = $false
        foreach ($command in $commands) {
            Append-AgentLog "MCP PRECHECK → $command"
            $result = Invoke-ShortCommand -CommandLine $command -TimeoutSec 90

            if ($result.ExitCode -eq 0 -and (Test-PlaywrightMcpConfigured)) {
                $registered = $true
                break
            }
        }

        if (-not $registered) {
            $script:LastAgentError = 'Microsoft Playwright MCP could not be configured for Codex.'
            Append-AgentLog "MCP PRECHECK → FAIL | $($script:LastAgentError)"
            Update-ChatGPTOAuthUI
            return $false
        }
    }

    if (-not (Ensure-PlaywrightMcpCodexPolicy)) {
        Update-ChatGPTOAuthUI
        return $false
    }

    $script:PlaywrightMcpReady = $true
    Append-AgentLog 'MCP PRECHECK → Playwright MCP configured with CDP forwarding + auto-approval.'
    Update-ChatGPTOAuthUI
    return $true
}

function Get-BrowserStackCredentialPlain {
    if (-not (Test-Path $script:BrowserStackCredentialFile)) {
        return $null
    }

    try {
        $credential = Import-Clixml -Path $script:BrowserStackCredentialFile
        return @{
            Username = [string]$credential.UserName
            AccessKey = [string]$credential.GetNetworkCredential().Password
        }
    }
    catch {
        return $null
    }
}

function Test-BrowserStackMcpConfigured {
    $credential = Get-BrowserStackCredentialPlain
    if (-not $credential) { return $false }
    $credential.AccessKey = $null

    $list = Get-CodexMcpListText
    return ($list -match '(?im)^\s*browserstack\b|\bbrowserstack\b.*@browserstack/mcp-server')
}


function Get-LastAgentLogText {
    if ([string]::IsNullOrWhiteSpace([string]$script:LastAgentLogFile) -or
        -not (Test-Path $script:LastAgentLogFile)) {
        return ''
    }

    try {
        return [System.IO.File]::ReadAllText(
            $script:LastAgentLogFile,
            [System.Text.Encoding]::UTF8
        )
    }
    catch {
        return ''
    }
}

function Test-LastAgentUsedPlaywrightMcpSuccessfully {
    param([int]$MinimumCompletedCalls = 1)

    $log = Get-LastAgentLogText
    if ([string]::IsNullOrWhiteSpace($log)) {
        $script:LastAgentError = 'Codex agent log is missing; Playwright MCP usage cannot be verified.'
        return $false
    }

    if ($log -match 'MCP tool call requires approval|user cancelled MCP tool call|approval policy is never') {
        $script:LastAgentError = 'Playwright MCP tool call was blocked by Codex approval policy.'
        return $false
    }

    $completed = [regex]::Matches(
        $log,
        '(?im)^mcp:\s*playwright/browser_[^\s]+\s*\(completed\)\s*$'
    ).Count

    if ($completed -lt $MinimumCompletedCalls) {
        $script:LastAgentError = "Expected at least $MinimumCompletedCalls completed Playwright MCP browser call(s), observed $completed."
        return $false
    }

    return $true
}

function Get-ExpectedEnvironmentHost {
    param([string]$Environment)

    switch (([string]$Environment).ToUpperInvariant()) {
        'ADM' { return 'adm.rx2go.ai' }
        'HOT' { return 'hot.rx2go.ai' }
        'BRANCH' { return 'sergey-tester.rx2go.ai' }
        default { return 'rx2go.ai' }
    }
}

function Test-Rx2GoAgentUrl {
    param(
        [string]$Url,
        [string]$Environment
    )

    if ([string]::IsNullOrWhiteSpace($Url) -or $Url -eq 'about:blank') {
        return $false
    }

    $expectedHost = Get-ExpectedEnvironmentHost -Environment $Environment
    return ($Url -match ('^https?://' + [regex]::Escape($expectedHost) + '(?:[:/]|$)'))
}

function Invoke-PlaywrightMcpSessionPreflight {
    param([string]$Environment)

    Append-AgentLog 'MCP SESSION PREFLIGHT → verifying that Codex sees the SAME authenticated Rx2GO Chrome.'
    $jiraTaskStatus.Text = 'Playwright MCP: проверяю подключение к авторизованному Chrome…'
    $jiraTaskStatus.ForeColor = [System.Drawing.Color]::FromArgb(37,99,235)
    [System.Windows.Forms.Application]::DoEvents()

    $prompt = @"
You are a Playwright MCP connection preflight. Do not test product behavior.

MANDATORY TOOL RULE:
- Use ONLY tools from the MCP server named `playwright`.
- Do NOT use the bundled Browser, Chrome or Computer Use plugins.
- Do NOT use node_repl.
- Do NOT use shell/exec or repository files.

Required actions:
1. Call Playwright MCP browser_tabs to list the current browser tabs.
2. Call Playwright MCP browser_snapshot on the active Rx2GO tab.
3. Read the ACTUAL current URL and page title.
4. Do not navigate and do not close any tab/browser.

Return ONLY JSON:
{
  "mcpUsed": true,
  "url": "actual current URL",
  "title": "actual title",
  "tabCount": 0
}
"@

    $raw = Invoke-CodexAgent `
        -AgentSlug '02a-playwright-mcp-preflight' `
        -Prompt $prompt `
        -TimeoutSec 120 `
        -ReasoningEffort 'low'

    if (-not $raw) {
        return $false
    }

    if (-not (Test-LastAgentUsedPlaywrightMcpSuccessfully -MinimumCompletedCalls 2)) {
        Append-AgentLog "MCP SESSION PREFLIGHT → FAIL | $($script:LastAgentError)"
        return $false
    }

    $parsed = Convert-AgentJson $raw
    if (-not $parsed) {
        return $false
    }

    $url = [string]$parsed.url

    try {
        $validEnvironmentPage = Test-Rx2GoAgentUrl -Url $url -Environment $Environment
    }
    catch {
        $script:LastAgentError = "MCP preflight URL validation exception: $($_.Exception.Message)"
        Append-AgentLog "MCP SESSION PREFLIGHT → INTERNAL FAIL | $($script:LastAgentError)"
        return $false
    }

    if (-not $validEnvironmentPage) {
        $script:LastAgentError = "Playwright MCP is attached to the wrong page: '$url'. Expected $Environment Rx2GO."
        Append-AgentLog "MCP SESSION PREFLIGHT → FAIL | $($script:LastAgentError)"
        return $false
    }

    Append-AgentLog "MCP SESSION PREFLIGHT → PASS | $url"
    Append-AgentLog 'MCP SESSION PREFLIGHT → SAME authenticated Chrome confirmed. Starting Smart QA.'
    return $true
}

function Invoke-CodexAgent {
    param(
        [string]$AgentSlug,
        [string]$Prompt,
        [int]$TimeoutSec = 300,
        [ValidateSet('low','medium','high')]
        [string]$ReasoningEffort = 'low',
        [string[]]$ImagePaths = @()
    )

    $script:LastAgentError = $null

    $key = 'ADHOC'
    if ($script:CurrentJiraTask -and $script:CurrentJiraTask.Key) {
        $key = [string]$script:CurrentJiraTask.Key
    }
    elseif ($script:LoadedJiraIssueKey) {
        $key = [string]$script:LoadedJiraIssueKey
    }

    $key = $key -replace '[^A-Za-z0-9_-]', '_'
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmssfff'

    $agentRoot = Join-Path $script:ProjectRoot "reports\ai\agents\$key"
    New-Item -ItemType Directory -Path $agentRoot -Force | Out-Null
    $script:AgentRunDir = $agentRoot

    $promptFile = Join-Path $agentRoot "$stamp-$AgentSlug.prompt.utf8.txt"
    $outputFile = Join-Path $agentRoot "$stamp-$AgentSlug.output.txt"
    $logFile = Join-Path $agentRoot "$stamp-$AgentSlug.log"
    $script:LastAgentLogFile = $logFile
    Append-AgentLog "START $AgentSlug | timeout ${TimeoutSec}s | reasoning $ReasoningEffort"

    # Keep an exact diagnostic copy and send exactly the same UTF-8 bytes to Codex stdin.
    Write-Utf8NoBomFile -Path $promptFile -Content $Prompt

    $p = $null
    $stdoutTask = $null
    $stderrTask = $null

    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = 'cmd.exe'

        # --ephemeral avoids accumulating Codex rollout sessions for every QA sub-agent.
        # Codex CLI supports real multimodal image input through -i/--image.
        $validImages = @(
            $ImagePaths |
                Where-Object { $_ -and (Test-Path $_) } |
                Select-Object -Unique |
                Select-Object -First $script:JiraScreenshotMaxCount
        )

        $imageArgs = ''
        foreach ($imagePath in $validImages) {
            # Task screenshot paths are generated by the launcher and do not contain quotes.
            $safeImagePath = ([string]$imagePath).Replace('"','')
            $imageArgs += " -i `"$safeImagePath`""
        }

        if ($validImages.Count -gt 0) {
            Append-AgentLog "IMAGES $AgentSlug → $($validImages.Count) screenshot(s) attached as Codex vision input."
        }

        $psi.Arguments = "/d /s /c `"codex exec --ephemeral --skip-git-repo-check -s read-only -c approval_policy=never -c model_reasoning_effort=`"$ReasoningEffort`"$imageArgs -o `"$outputFile`" -`""
        $psi.WorkingDirectory = $script:ProjectRoot
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true

        # Playwright MCP is configured once in Codex. For every Smart QA turn,
        # the MCP server inherits the CDP endpoint of the SAME authenticated Chrome.
        if (-not [string]::IsNullOrWhiteSpace([string]$script:PersistentCdpEndpoint)) {
            $psi.EnvironmentVariables['PLAYWRIGHT_MCP_CDP_ENDPOINT'] = [string]$script:PersistentCdpEndpoint
            $psi.EnvironmentVariables['PLAYWRIGHT_MCP_CDP_TIMEOUT'] = '30000'
            $psi.EnvironmentVariables['PLAYWRIGHT_MCP_CODEGEN'] = 'typescript'
            $psi.EnvironmentVariables['PLAYWRIGHT_MCP_CONSOLE_LEVEL'] = 'info'
            $mcpOutputDir = Join-Path $agentRoot 'playwright-mcp'
            New-Item -ItemType Directory -Path $mcpOutputDir -Force | Out-Null
            $psi.EnvironmentVariables['PLAYWRIGHT_MCP_OUTPUT_DIR'] = $mcpOutputDir
        }

        # BrowserStack MCP is optional. Credentials stay in DPAPI and are only
        # exposed to the child Codex process when the user configured it.
        $browserStack = Get-BrowserStackCredentialPlain
        if ($browserStack) {
            $psi.EnvironmentVariables['BROWSERSTACK_USERNAME'] = [string]$browserStack.Username
            $psi.EnvironmentVariables['BROWSERSTACK_ACCESS_KEY'] = [string]$browserStack.AccessKey
            $browserStack.AccessKey = $null
        }

        $p = New-Object System.Diagnostics.Process
        $p.StartInfo = $psi
        [void]$p.Start()

        # IMPORTANT: start draining both pipes immediately.
        # Waiting before reading can deadlock a verbose codex exec process.
        $stdoutTask = $p.StandardOutput.ReadToEndAsync()
        $stderrTask = $p.StandardError.ReadToEndAsync()

        # Do not use PowerShell StreamWriter encoding. Write exact UTF-8 bytes.
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        $promptBytes = $utf8NoBom.GetBytes($Prompt)
        $p.StandardInput.BaseStream.Write($promptBytes, 0, $promptBytes.Length)
        $p.StandardInput.BaseStream.Flush()
        $p.StandardInput.Close()

        $finished = Wait-ProcessResponsive -Process $p -TimeoutSec $TimeoutSec

        if (-not $finished) {
            # Smart browser agents can finish the QA work and write output-last-message
            # a moment before the Codex/MCP host process itself exits. Do not throw away
            # a complete PASS/FAIL/BLOCKED JSON just because the wrapper hit 900 seconds.
            $recoveredRaw = $null
            $recoveredStatus = $null

            if ($AgentSlug -eq '02-playwright-mcp-qa') {
                $graceDeadline = [DateTime]::UtcNow.AddSeconds(12)

                while ([DateTime]::UtcNow -lt $graceDeadline -and -not $recoveredRaw) {
                    if (Test-Path $outputFile) {
                        try {
                            $candidate = Read-Utf8File $outputFile

                            if (-not [string]::IsNullOrWhiteSpace($candidate)) {
                                $candidateObj = $candidate | ConvertFrom-Json -ErrorAction Stop
                                $candidateStatus = ([string]$candidateObj.status).ToUpperInvariant()

                                if (
                                    @('PASS','FAIL','BLOCKED') -contains $candidateStatus -and
                                    [bool]$candidateObj.mcpUsed
                                ) {
                                    $recoveredRaw = $candidate
                                    $recoveredStatus = $candidateStatus
                                    break
                                }
                            }
                        }
                        catch { }
                    }

                    Start-Sleep -Milliseconds 250
                    [System.Windows.Forms.Application]::DoEvents()
                }
            }

            try { $p.Kill() } catch { }
            try { [void]$p.WaitForExit(5000) } catch { }

            $stdout = ''
            $stderr = ''
            try { $stdout = [string]$stdoutTask.Result } catch { }
            try { $stderr = [string]$stderrTask.Result } catch { }

            if ($recoveredRaw) {
                $script:LastAgentError = $null

                @(
                    "AGENT: $AgentSlug"
                    "RESULT: FINAL JSON RECOVERED AFTER WRAPPER TIMEOUT"
                    "SMART QA STATUS: $recoveredStatus"
                    "TIMEOUT SEC: $TimeoutSec"
                    "REASONING: $ReasoningEffort"
                    "PROMPT: $promptFile"
                    "OUTPUT: $outputFile"
                    ''
                    'NOTE:'
                    'The live QA agent completed and wrote a valid final JSON before the Codex/MCP wrapper process exited.'
                    'The wrapper process was terminated, but the QA result is accepted.'
                    ''
                    'STDERR COLLECTED:'
                    $stderr
                    ''
                    'STDOUT COLLECTED:'
                    $stdout
                ) | Set-Content -Path $logFile -Encoding UTF8

                Append-AgentLog "RECOVERED $AgentSlug → $recoveredStatus | final JSON was already complete at ${TimeoutSec}s"
                return $recoveredRaw
            }

            $script:LastAgentError = "$AgentSlug timeout after $TimeoutSec sec"

            @(
                "AGENT: $AgentSlug"
                "RESULT: TIMEOUT"
                "TIMEOUT SEC: $TimeoutSec"
                "REASONING: $ReasoningEffort"
                "PROMPT: $promptFile"
                "OUTPUT: $outputFile"
                ''
                'STDERR COLLECTED BEFORE TIMEOUT:'
                $stderr
                ''
                'STDOUT COLLECTED BEFORE TIMEOUT:'
                $stdout
            ) | Set-Content -Path $logFile -Encoding UTF8

            Append-AgentLog "TIMEOUT $AgentSlug | $logFile"
            $tail = Get-LogTail -Path $logFile -MaxLines 12
            if ($tail) { Append-AgentLog $tail }
            return $null
        }

        # ReadToEndAsync has already been draining while the child was running.
        $stdout = ''
        $stderr = ''
        try { $stdout = [string]$stdoutTask.Result } catch { }
        try { $stderr = [string]$stderrTask.Result } catch { }

        @(
            "AGENT: $AgentSlug"
            "EXIT CODE: $($p.ExitCode)"
            "REASONING: $ReasoningEffort"
            "PROMPT: $promptFile"
            "OUTPUT: $outputFile"
            ''
            'STDERR:'
            $stderr
            ''
            'STDOUT:'
            $stdout
        ) | Set-Content -Path $logFile -Encoding UTF8

        if ($p.ExitCode -ne 0) {
            if ($stderr -match 'input is not valid UTF-8') {
                $script:LastAgentError = "${AgentSlug}: Codex rejected UTF-8 input"
            }
            elseif ($stderr -match '(?i)not logged in|authentication|login required') {
                $script:LastAgentError = "${AgentSlug}: Codex authentication is required"
            }
            else {
                $short = (($stderr -split "`r?`n") | Where-Object { $_ } | Select-Object -Last 4) -join ' '
                $script:LastAgentError = if ($short) {
                    "$AgentSlug exit $($p.ExitCode): $short"
                }
                else {
                    "$AgentSlug exit $($p.ExitCode)"
                }
            }
            Append-AgentLog "FAIL $AgentSlug | $($script:LastAgentError)"
            Append-AgentLog "LOG $logFile"
            return $null
        }

        if (-not (Test-Path $outputFile)) {
            $script:LastAgentError = "$AgentSlug completed but did not create output-last-message"
            Append-AgentLog "FAIL $AgentSlug | $($script:LastAgentError)"
            Append-AgentLog "LOG $logFile"
            return $null
        }

        $raw = Read-Utf8File $outputFile
        if ([string]::IsNullOrWhiteSpace($raw)) {
            $script:LastAgentError = "$AgentSlug returned an empty final message"
            Append-AgentLog "FAIL $AgentSlug | $($script:LastAgentError)"
            Append-AgentLog "LOG $logFile"
            return $null
        }

        Append-AgentLog "DONE $AgentSlug"
        return $raw
    }
    catch {
        $script:LastAgentError = "${AgentSlug}: $($_.Exception.Message)"

        $extraOut = ''
        $extraErr = ''
        try { if ($stdoutTask) { $extraOut = [string]$stdoutTask.Result } } catch { }
        try { if ($stderrTask) { $extraErr = [string]$stderrTask.Result } } catch { }

        @(
            "AGENT: $AgentSlug"
            "RESULT: EXCEPTION"
            "REASONING: $ReasoningEffort"
            ''
            $_.Exception.ToString()
            ''
            'STDERR:'
            $extraErr
            ''
            'STDOUT:'
            $extraOut
        ) | Set-Content -Path $logFile -Encoding UTF8

        Append-AgentLog "EXCEPTION $AgentSlug | $($script:LastAgentError)"
        Append-AgentLog "LOG $logFile"
        return $null
    }
    finally {
        if ($p) {
            try { $p.Dispose() } catch { }
        }
    }
}



function Ensure-PlaywrightDependencies {
    if ($script:PlaywrightDependenciesReady) {
        return $true
    }

    $playwrightCmd = Join-Path $script:ProjectRoot 'node_modules\.bin\playwright.cmd'
    if (Test-Path $playwrightCmd) {
        $script:PlaywrightDependenciesReady = $true
        Append-AgentLog 'PRECHECK Playwright dependencies already installed.'
        return $true
    }

    Append-AgentLog 'PRECHECK Installing Playwright project dependencies…'
    $jiraTaskStatus.Text = 'Подготавливаю Playwright dependencies…'
    $jiraTaskStatus.ForeColor = [System.Drawing.Color]::FromArgb(37,99,235)
    [System.Windows.Forms.Application]::DoEvents()

    $setupScript = Join-Path $script:ProjectRoot 'scripts\run-tests.ps1'
    if (-not (Test-Path $setupScript)) {
        $script:LastAgentError = "Setup script not found: $setupScript"
        Append-AgentLog $script:LastAgentError
        return $false
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$setupScript`" -DependenciesOnly"
    $psi.WorkingDirectory = $script:ProjectRoot
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true

    $p = $null

    try {
        $p = New-Object System.Diagnostics.Process
        $p.StartInfo = $psi
        [void]$p.Start()

        $outTask = $p.StandardOutput.ReadToEndAsync()
        $errTask = $p.StandardError.ReadToEndAsync()

        $finished = Wait-ProcessResponsive -Process $p -TimeoutSec 600

        if (-not $finished) {
            try { $p.Kill() } catch { }
            try { [void]$p.WaitForExit(3000) } catch { }

            $script:LastAgentError = 'Playwright dependency preparation timeout.'
            Append-AgentLog $script:LastAgentError
            return $false
        }

        $stdout = ''
        $stderr = ''
        try { $stdout = [string]$outTask.Result } catch { }
        try { $stderr = [string]$errTask.Result } catch { }

        if ($stdout) {
            foreach ($line in ($stdout -split "`r?`n")) {
                if ($line) { Append-AgentLog "[SETUP] $line" }
            }
        }

        if ($p.ExitCode -ne 0) {
            $short = (($stderr -split "`r?`n") | Where-Object { $_ } | Select-Object -Last 8) -join ' '
            $script:LastAgentError = if ($short) {
                "Playwright dependency preparation failed: $short"
            }
            else {
                "Playwright dependency preparation failed with exit code $($p.ExitCode)"
            }

            Append-AgentLog $script:LastAgentError
            return $false
        }

        if (-not (Test-Path $playwrightCmd)) {
            $script:LastAgentError = "Dependencies completed but local Playwright was not found: $playwrightCmd"
            Append-AgentLog $script:LastAgentError
            return $false
        }

        $script:PlaywrightDependenciesReady = $true
        Append-AgentLog 'PRECHECK Playwright dependencies READY.'
        return $true
    }
    catch {
        $script:LastAgentError = "Playwright dependency preparation exception: $($_.Exception.Message)"
        Append-AgentLog $script:LastAgentError
        return $false
    }
    finally {
        if ($p) {
            try { $p.Dispose() } catch { }
        }
    }
}

function Test-CodexAgentRunner {
    $previousTask = $script:CurrentJiraTask
    $previousKey = $script:LoadedJiraIssueKey
    $script:CurrentJiraTask = $null
    $script:LoadedJiraIssueKey = 'SELFTEST'

    try {
        $result = Invoke-CodexAgent `
            -AgentSlug '00-self-test' `
            -Prompt 'Return exactly this text and nothing else: RX2GO_AGENT_OK' `
            -TimeoutSec 90 `
            -ReasoningEffort 'low'

        if ($result -and $result.Trim() -eq 'RX2GO_AGENT_OK') {
            return $true
        }

        if (-not $script:LastAgentError) {
            $script:LastAgentError = "Unexpected Codex self-test output: $result"
        }
        return $false
    }
    finally {
        $script:CurrentJiraTask = $previousTask
        $script:LoadedJiraIssueKey = $previousKey
    }
}


function Get-CurrentRx2GOCredentialForRun {
    $login = 'sergeyqa'
    $password = ''

    if ($script:InlineAppLoginBox -and
        -not [string]::IsNullOrWhiteSpace($script:InlineAppLoginBox.Text)) {
        $login = $script:InlineAppLoginBox.Text.Trim()
    }

    if ($script:InlineAppPasswordBox) {
        $password = [string]$script:InlineAppPasswordBox.Text
    }

    if ([string]::IsNullOrWhiteSpace($password)) {
        $saved = Get-AppCredentialPlain
        if ($saved) {
            $login = [string]$saved.Login
            $password = [string]$saved.Password
            if ($script:InlineAppPasswordBox) {
                $script:InlineAppPasswordBox.Text = $password
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($password)) {
        return $null
    }

    return @{
        Login = $login
        Password = $password
    }
}


function Test-PersistentCdpEndpoint {
    param([string]$Endpoint)

    if ([string]::IsNullOrWhiteSpace($Endpoint)) {
        return $false
    }

    try {
        $response = Invoke-RestMethod `
            -Uri "$Endpoint/json/version" `
            -TimeoutSec 2 `
            -ErrorAction Stop

        return [bool]$response.webSocketDebuggerUrl
    }
    catch {
        return $false
    }
}

function Clear-PersistentBrowserSessionState {
    $script:PersistentCdpEndpoint = $null
    $script:PersistentChromePid = 0
    $script:PersistentBrowserEnvironment = $null
    $script:PersistentBrowserSessionFile = $null
}

function Stop-PersistentBrowserSession {
    if ($script:PersistentChromePid -gt 0) {
        try {
            & taskkill /PID $script:PersistentChromePid /T /F | Out-Null
        } catch {}
    }

    Clear-PersistentBrowserSessionState
}

function Import-PersistentBrowserSession {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path $Path)) {
        return $false
    }

    try {
        $session = Get-Content -Raw -Path $Path | ConvertFrom-Json -ErrorAction Stop

        $endpoint = [string]$session.endpoint
        if (-not (Test-PersistentCdpEndpoint -Endpoint $endpoint)) {
            return $false
        }

        $script:PersistentCdpEndpoint = $endpoint
        $script:PersistentChromePid = [int]$session.chromePid
        $script:PersistentBrowserEnvironment = [string]$session.environment
        $script:PersistentBrowserSessionFile = $Path

        return $true
    }
    catch {
        return $false
    }
}

function Can-ReusePersistentBrowserSession {
    param([string]$Environment)

    if ([string]::IsNullOrWhiteSpace([string]$script:PersistentCdpEndpoint)) {
        return $false
    }

    if ([string]$script:PersistentBrowserEnvironment -ne $Environment) {
        return $false
    }

    return (Test-PersistentCdpEndpoint -Endpoint $script:PersistentCdpEndpoint)
}

function Get-LivePageContextForPrompt {
    if ([string]::IsNullOrWhiteSpace([string]$script:LivePageContext)) {
        return 'LIVE PAGE CONTEXT NOT CAPTURED.'
    }

    $value = [string]$script:LivePageContext
    if ($value.Length -gt 65000) {
        return $value.Substring(0, 65000) + "`n[TRUNCATED BY LAUNCHER]"
    }

    return $value
}



function Bootstrap-PersistentBrowserSession {
    param([string]$Environment)

    if (Can-ReusePersistentBrowserSession -Environment $Environment) {
        Append-AgentLog "BROWSER BOOTSTRAP → reuse existing authenticated Chrome $($script:PersistentCdpEndpoint)"
        return $true
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$script:PersistentCdpEndpoint)) {
        Append-AgentLog 'BROWSER BOOTSTRAP → stale/cross-environment session detected; closing OLD session before creating a new one.'
        Stop-PersistentBrowserSession
    }

    $credential = Get-CurrentRx2GOCredentialForRun
    if (-not $credential) {
        $script:LastAgentError = 'Rx2GO password is missing on Quick Run → Access & connections.'
        Append-AgentLog "BROWSER BOOTSTRAP → FAIL | $($script:LastAgentError)"
        return $false
    }

    if ((Test-GatewayRequired $Environment) -and
        [string]::IsNullOrWhiteSpace([string]$dailyPassword.Text)) {

        $credential.Password = $null
        $script:LastAgentError = 'ADM daily Telegram password is missing on Quick Run → Access & connections.'
        Append-AgentLog "BROWSER BOOTSTRAP → FAIL | $($script:LastAgentError)"
        return $false
    }

    $runnerScript = Join-Path $script:ProjectRoot 'scripts\run-tests.ps1'
    $bootstrapSpec = 'tests/diagnostics/session-bootstrap.spec.ts'

    if (-not (Test-Path $runnerScript)) {
        $credential.Password = $null
        $script:LastAgentError = "Runner not found: $runnerScript"
        return $false
    }

    $key = if ($script:CurrentJiraTask -and $script:CurrentJiraTask.Key) {
        [string]$script:CurrentJiraTask.Key
    } else {
        'ADHOC'
    }
    $key = $key -replace '[^A-Za-z0-9_-]', '_'

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $sessionDir = Join-Path $script:ProjectRoot "reports\browser-session\$key"
    New-Item -ItemType Directory -Path $sessionDir -Force | Out-Null

    $sessionFile = Join-Path $sessionDir "$stamp-browser-session.json"
    $bootstrapLog = Join-Path $sessionDir "$stamp-browser-bootstrap.log"

    Append-AgentLog "BROWSER BOOTSTRAP → creating ONE Chrome for $Environment auth + MCP + final Playwright."
    Append-AgentLog 'BROWSER BOOTSTRAP → this stage does NOT open Tickets Queue and does NOT collect DOM context.'
    $jiraTaskStatus.Text = 'Browser bootstrap: авторизация в одном Chrome…'
    $jiraTaskStatus.ForeColor = [System.Drawing.Color]::FromArgb(37,99,235)
    [System.Windows.Forms.Application]::DoEvents()

    $runnerArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$runnerScript`" -Suite all -Headed -KeepBrowserOpen -TestPath `"$bootstrapSpec`" -SessionFile `"$sessionFile`""

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'cmd.exe'
    $psi.Arguments = "/d /s /c chcp 65001 >nul & powershell.exe $runnerArgs"
    $psi.WorkingDirectory = $script:ProjectRoot
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true

    $psi.EnvironmentVariables['TEST_ENV'] = $Environment
    $psi.EnvironmentVariables['RUN_MUTATING_TESTS'] = 'false'
    $psi.EnvironmentVariables['RX2GO_APP_LOGIN'] = [string]$credential.Login
    $psi.EnvironmentVariables['RX2GO_APP_PASSWORD'] = [string]$credential.Password

    if (Test-GatewayRequired $Environment) {
        $psi.EnvironmentVariables['RX2GO_GATEWAY_LOGIN'] = 'admin'
        $psi.EnvironmentVariables['RX2GO_DAILY_PASSWORD'] = [string]$dailyPassword.Text
    }

    $p = $null

    try {
        $p = New-Object System.Diagnostics.Process
        $p.StartInfo = $psi
        [void]$p.Start()

        $outTask = $p.StandardOutput.ReadToEndAsync()
        $errTask = $p.StandardError.ReadToEndAsync()

        $finished = Wait-ProcessResponsive -Process $p -TimeoutSec 240

        if (-not $finished) {
            try { $p.Kill() } catch {}
            try { [void]$p.WaitForExit(3000) } catch {}

            $stdout = ''
            $stderr = ''
            try { $stdout = [string]$outTask.Result } catch {}
            try { $stderr = [string]$errTask.Result } catch {}

            @(
                'RESULT: TIMEOUT'
                "SESSION FILE: $sessionFile"
                ''
                'STDOUT:'
                $stdout
                ''
                'STDERR:'
                $stderr
            ) | Set-Content -Path $bootstrapLog -Encoding UTF8

            # IMPORTANT: if Chrome/session already exists, keep it open for diagnosis.
            if (Test-Path $sessionFile) {
                if (Import-PersistentBrowserSession -Path $sessionFile) {
                    Append-AgentLog "BROWSER BOOTSTRAP → timeout, but Chrome intentionally left OPEN: $($script:PersistentCdpEndpoint)"
                }
            }

            $script:LastAgentError = 'Browser bootstrap timeout. Chrome was left open when a session was available.'
            Append-AgentLog "BROWSER BOOTSTRAP → FAIL | $($script:LastAgentError)"
            Append-AgentLog "BROWSER BOOTSTRAP LOG → $bootstrapLog"
            return $false
        }

        $stdout = ''
        $stderr = ''
        try { $stdout = [string]$outTask.Result } catch {}
        try { $stderr = [string]$errTask.Result } catch {}

        @(
            "EXIT CODE: $($p.ExitCode)"
            "SESSION FILE: $sessionFile"
            ''
            'STDOUT:'
            $stdout
            ''
            'STDERR:'
            $stderr
        ) | Set-Content -Path $bootstrapLog -Encoding UTF8

        # Import the CDP session even on a failed Playwright assertion.
        # This is intentional: never destroy the evidence/browser automatically.
        $sessionImported = $false
        if (Test-Path $sessionFile) {
            $sessionImported = Import-PersistentBrowserSession -Path $sessionFile
        }

        if ($p.ExitCode -ne 0) {
            $short = (($stderr -split "`r?`n") |
                Where-Object { $_ } |
                Select-Object -Last 10) -join ' '

            if (-not $short) {
                $short = (($stdout -split "`r?`n") |
                    Where-Object { $_ } |
                    Select-Object -Last 10) -join ' '
            }

            $script:LastAgentError = if ($short) {
                "Browser bootstrap failed: $short"
            } else {
                "Browser bootstrap failed with exit code $($p.ExitCode)"
            }

            if ($sessionImported) {
                Append-AgentLog "BROWSER BOOTSTRAP → FAIL, Chrome intentionally LEFT OPEN for diagnosis: $($script:PersistentCdpEndpoint)"
            } else {
                Append-AgentLog 'BROWSER BOOTSTRAP → FAIL before a reusable Chrome session became available.'
            }

            Append-AgentLog "BROWSER BOOTSTRAP LOG → $bootstrapLog"
            return $false
        }

        if (-not $sessionImported) {
            $script:LastAgentError = 'Browser bootstrap passed, but persistent CDP session could not be imported.'
            Append-AgentLog "BROWSER BOOTSTRAP → FAIL | $($script:LastAgentError)"
            Append-AgentLog "BROWSER BOOTSTRAP LOG → $bootstrapLog"
            return $false
        }

        Append-AgentLog "BROWSER BOOTSTRAP → PASS | $($script:PersistentCdpEndpoint)"
        Append-AgentLog 'BROWSER BOOTSTRAP → Chrome stays open for MCP preflight, Smart QA and final Playwright.'
        return $true
    }
    catch {
        $script:LastAgentError = "Browser bootstrap exception: $($_.Exception.Message)"
        Append-AgentLog "BROWSER BOOTSTRAP → FAIL | $($script:LastAgentError)"

        # Never auto-kill the new browser from an exception path.
        if (Test-Path $sessionFile) {
            if (Import-PersistentBrowserSession -Path $sessionFile) {
                Append-AgentLog "BROWSER BOOTSTRAP → exception, Chrome intentionally left OPEN: $($script:PersistentCdpEndpoint)"
            }
        }

        return $false
    }
    finally {
        if ($p) {
            try { $p.Dispose() } catch {}
        }
        $credential.Password = $null
    }
}

function Capture-LiveBrowserContext {
    param(
        $Task,
        [string]$QaComment
    )

    $script:LivePageContext = $null
    $script:LivePageContextFile = $null
    $script:LivePageContextLog = $null

    if (-not $jiraUiCheck.Checked) {
        Append-AgentLog 'LIVE PAGE CONTEXT → skipped because UI check is disabled.'
        return $true
    }

    $credential = Get-CurrentRx2GOCredentialForRun

    if (-not $credential) {
        $script:LastAgentError = 'Rx2GO password is missing on Quick Run → Access & connections.'
        Append-AgentLog "LIVE PAGE CONTEXT → FAIL | $($script:LastAgentError)"
        return $false
    }

    $environment = [string]$jiraEnvironmentCombo.SelectedItem

    if ((Test-GatewayRequired $environment) -and
        [string]::IsNullOrWhiteSpace([string]$dailyPassword.Text)) {

        $script:LastAgentError = 'ADM daily Telegram password is missing on Quick Run → Access & connections.'
        Append-AgentLog "LIVE PAGE CONTEXT → FAIL | $($script:LastAgentError)"
        $credential.Password = $null
        return $false
    }

    $runnerScript = Join-Path $script:ProjectRoot 'scripts\run-tests.ps1'
    $contextSpec = 'tests/diagnostics/live-page-context.spec.ts'

    if (-not (Test-Path $runnerScript)) {
        $script:LastAgentError = "Runner not found: $runnerScript"
        $credential.Password = $null
        return $false
    }

    $safeKey = ([string]$Task.Key -replace '[^A-Za-z0-9_-]', '_')
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $contextDir = Join-Path $script:ProjectRoot "reports\page-context\$safeKey"
    New-Item -ItemType Directory -Path $contextDir -Force | Out-Null

    $contextFile = Join-Path $contextDir "$stamp-live-page.json"
    $contextLog = Join-Path $contextDir "$stamp-live-page.log"
    $sessionFile = Join-Path $contextDir "$stamp-browser-session.json"

    $script:LivePageContextFile = $contextFile
    $script:LivePageContextLog = $contextLog

    $reuseSession = Can-ReusePersistentBrowserSession -Environment $environment

    if (-not $reuseSession -and
        -not [string]::IsNullOrWhiteSpace([string]$script:PersistentCdpEndpoint)) {

        # Do not carry an authenticated browser across environments/stale sessions.
        Append-AgentLog 'BROWSER SESSION → existing session is stale or belongs to another environment; closing it.'
        Stop-PersistentBrowserSession
    }

    if ($reuseSession) {
        Append-AgentLog "BROWSER SESSION → reusing authenticated Chrome $($script:PersistentCdpEndpoint)"
        $jiraTaskStatus.Text = 'Live Browser Context: использую уже авторизованный Chrome…'
    }
    else {
        Append-AgentLog "BROWSER SESSION → creating ONE Chrome for $environment auth + Live Context + final test."
        $jiraTaskStatus.Text = 'Live Browser Context: один раз авторизую Chrome и сохраняю сессию…'
    }

    $jiraTaskStatus.ForeColor = [System.Drawing.Color]::FromArgb(37,99,235)
    [System.Windows.Forms.Application]::DoEvents()

    $runnerArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$runnerScript`" -Suite all -Headed -KeepBrowserOpen -TestPath `"$contextSpec`""

    if ($reuseSession) {
        $runnerArgs += " -ReuseCdpEndpoint `"$($script:PersistentCdpEndpoint)`""
        if ($script:PersistentChromePid -gt 0) {
            $runnerArgs += " -ReuseChromePid $($script:PersistentChromePid)"
        }
    }
    else {
        $runnerArgs += " -SessionFile `"$sessionFile`""
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'cmd.exe'
    $psi.Arguments = "/d /s /c chcp 65001 >nul & powershell.exe $runnerArgs"
    $psi.WorkingDirectory = $script:ProjectRoot
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true

    $psi.EnvironmentVariables['TEST_ENV'] = $environment
    $psi.EnvironmentVariables['RUN_MUTATING_TESTS'] = 'false'
    $psi.EnvironmentVariables['RX2GO_APP_LOGIN'] = [string]$credential.Login
    $psi.EnvironmentVariables['RX2GO_APP_PASSWORD'] = [string]$credential.Password
    $psi.EnvironmentVariables['RX2GO_CONTEXT_OUTPUT'] = $contextFile
    $psi.EnvironmentVariables['RX2GO_CONTEXT_TARGET'] = [string]$Task.Module
    $psi.EnvironmentVariables['RX2GO_CONTEXT_TASK'] = [string]$Task.Key
    $psi.EnvironmentVariables['RX2GO_CONTEXT_HINT'] = [string]$QaComment

    if (Test-GatewayRequired $environment) {
        $psi.EnvironmentVariables['RX2GO_GATEWAY_LOGIN'] = 'admin'
        $psi.EnvironmentVariables['RX2GO_DAILY_PASSWORD'] = [string]$dailyPassword.Text
    }

    $p = $null

    try {
        $p = New-Object System.Diagnostics.Process
        $p.StartInfo = $psi
        [void]$p.Start()

        $outTask = $p.StandardOutput.ReadToEndAsync()
        $errTask = $p.StandardError.ReadToEndAsync()

        $finished = Wait-ProcessResponsive -Process $p -TimeoutSec 240

        if (-not $finished) {
            try { $p.Kill() } catch {}
            try { [void]$p.WaitForExit(3000) } catch {}

            $script:LastAgentError = 'Live Browser Context timeout.'
            Append-AgentLog "LIVE PAGE CONTEXT → FAIL | $($script:LastAgentError)"

            if (-not $reuseSession -and (Test-Path $sessionFile)) {
                if (Import-PersistentBrowserSession -Path $sessionFile) {
                    Stop-PersistentBrowserSession
                }
            }

            return $false
        }

        $stdout = ''
        $stderr = ''
        try { $stdout = [string]$outTask.Result } catch {}
        try { $stderr = [string]$errTask.Result } catch {}

        @(
            "EXIT CODE: $($p.ExitCode)"
            "CONTEXT FILE: $contextFile"
            "SESSION FILE: $sessionFile"
            "REUSED SESSION: $reuseSession"
            ''
            'STDOUT:'
            $stdout
            ''
            'STDERR:'
            $stderr
        ) | Set-Content -Path $contextLog -Encoding UTF8

        if ($p.ExitCode -ne 0) {
            $short = (($stderr -split "`r?`n") |
                Where-Object { $_ } |
                Select-Object -Last 10) -join ' '

            if (-not $short) {
                $short = (($stdout -split "`r?`n") |
                    Where-Object { $_ } |
                    Select-Object -Last 10) -join ' '
            }

            $script:LastAgentError = if ($short) {
                "Live Browser Context failed: $short"
            }
            else {
                "Live Browser Context failed with exit code $($p.ExitCode)"
            }

            Append-AgentLog "LIVE PAGE CONTEXT → FAIL | $($script:LastAgentError)"
            Append-AgentLog "LIVE PAGE LOG → $contextLog"

            if (-not $reuseSession -and (Test-Path $sessionFile)) {
                if (Import-PersistentBrowserSession -Path $sessionFile) {
                    Stop-PersistentBrowserSession
                }
            }

            return $false
        }

        if (-not $reuseSession) {
            if (-not (Import-PersistentBrowserSession -Path $sessionFile)) {
                $script:LastAgentError = 'Live Context passed, but the persistent Chrome CDP session could not be imported.'
                Append-AgentLog "BROWSER SESSION → FAIL | $($script:LastAgentError)"
                return $false
            }

            Append-AgentLog "BROWSER SESSION → READY | $($script:PersistentCdpEndpoint)"
            Append-AgentLog 'BROWSER SESSION → auth will NOT be repeated before the final test.'
        }

        if (-not (Test-Path $contextFile)) {
            $script:LastAgentError = "Live Browser Context file was not created: $contextFile"
            Append-AgentLog "LIVE PAGE CONTEXT → FAIL | $($script:LastAgentError)"
            return $false
        }

        $raw = Get-Content -Raw -Path $contextFile -ErrorAction Stop

        if ([string]::IsNullOrWhiteSpace($raw)) {
            $script:LastAgentError = 'Live Browser Context file is empty.'
            Append-AgentLog "LIVE PAGE CONTEXT → FAIL | $($script:LastAgentError)"
            return $false
        }

        $script:LivePageContext = $raw
        Append-AgentLog "LIVE PAGE CONTEXT → READY | $contextFile"
        Append-AgentLog 'LIVE PAGE CONTEXT → Playwright disconnected; Chrome remains open and authenticated.'
        Update-ChatGPTOAuthUI

        try {
            $contextObj = $raw | ConvertFrom-Json -ErrorAction Stop
            Append-AgentLog "LIVE PAGE URL → $($contextObj.url)"
            Append-AgentLog "LIVE PAGE CONTROLS → $(@($contextObj.controls).Count)"
            Append-AgentLog "LIVE PAGE NETWORK → $(@($contextObj.network).Count)"
        } catch {}

        return $true
    }
    catch {
        $script:LastAgentError = "Live Browser Context exception: $($_.Exception.Message)"
        Append-AgentLog "LIVE PAGE CONTEXT → FAIL | $($script:LastAgentError)"
        return $false
    }
    finally {
        if ($p) {
            try { $p.Dispose() } catch {}
        }

        $credential.Password = $null
    }
}

function Invoke-AgentJiraAnalyst {
    param(
        [string]$JiraText,
        [string]$QaComment,
        [string[]]$ProjectRules
    )

    Set-AgentStatus -Agent JiraAnalyst -State RUNNING

    $prompt = @"
You are Agent 1 of the Rx2GO QA pipeline: JIRA ANALYST.

Your only job is requirements analysis. Do not design Playwright code.

Return ONLY valid JSON:
{
  "title": "short task title",
  "module": "Tickets Queue|Chat|Scanner|Dispatcher|QAQC|Orders|Unknown",
  "currentBehavior": ["observed current/bug behavior"],
  "expectedBehavior": ["expected product behavior"],
  "reproductionSteps": ["reproduction step"],
  "acceptanceCriteria": ["testable acceptance requirement"],
  "riskAreas": ["related regression area"],
  "clarificationsFromComments": ["meaningful Jira comment clarification"]
}

TASK SCREENSHOTS:
$(Get-JiraScreenshotPromptSummary)

SCREENSHOT RULES:
- Attached screenshots are supplementary visual evidence from the user.
- Read visible labels, controls, states, layout and error messages when they help explain the task.
- A screenshot may show CURRENT behavior, EXPECTED design, or reproduction context; infer which only when Jira/QA text supports it.
- Do not invent a product requirement solely because something is visible in a screenshot.
- If the screenshot contradicts the Jira text, preserve the Jira requirement and mention the visual ambiguity only in risk/clarification when relevant.

RULES:
- "Сейчас", "Current", "Actual", "Текущее поведение" is CURRENT BUG BEHAVIOR.
- Never turn current bug behavior into acceptance criteria.
- "Как воспроизвести" is reproduction procedure.
- "Ожидаемо", "Expected", "Критерий приёмки", "Acceptance Criteria", "Необходимо" are requirements.
- Jira comments are clarifications, not original Description.
- QA COMMENT is execution guidance, not a Jira requirement.
- Project rules are execution constraints.
- Do not invent missing requirements.
- Do not include credentials or secrets.

JIRA SOURCE:
$JiraText

QA COMMENT:
$QaComment

RX2GO PROJECT RULES:
$($ProjectRules -join "`n- ")
"@

    $raw = Invoke-CodexAgent -AgentSlug '01-jira-analyst' -Prompt $prompt -TimeoutSec 240 -ReasoningEffort 'low' -ImagePaths (Get-JiraScreenshotPaths)
    if (-not $raw) {
        Set-AgentStatus -Agent JiraAnalyst -State FAIL -Details $script:LastAgentError
        return $null
    }

    $parsed = Convert-AgentJson $raw
    if (-not $parsed) {
        Set-AgentStatus -Agent JiraAnalyst -State FAIL -Details $script:LastAgentError
        return $null
    }

    $script:AgentJiraAnalysis = $parsed
    Set-AgentStatus -Agent JiraAnalyst -State PASS
    return $parsed
}

function Invoke-AgentTestDesigner {
    param(
        $Task,
        [string]$JiraText,
        [string]$QaComment,
        [string[]]$ProjectRules
    )

    Set-AgentStatus -Agent TestDesigner -State RUNNING

    $prompt = @"
You are Agent 2 of the Rx2GO QA pipeline: TEST DESIGNER.

Do not write Playwright code. Build a concrete execution plan from the Jira Analyst result.

Return ONLY valid JSON:
{
  "strategy": "short test strategy",
  "preconditions": ["precondition"],
  "testData": ["required test data and how to create it"],
  "uiChecks": ["UI check"],
  "apiChecks": ["API/backend check"],
  "networkChecks": ["network/console check"],
  "regressionChecks": ["regression check"],
  "criticalAssertions": ["assertion that decides PASS/FAIL"],
  "automationNotes": ["implementation note"]
}

TASK:
Key: $($Task.Key)
Title: $($Task.Title)
Module: $($Task.Module)

CURRENT:
$(@($Task.CurrentBehavior) -join "`n- ")

EXPECTED:
$(@($Task.ExpectedBehavior) -join "`n- ")

REPRODUCTION:
$(@($Task.ReproductionSteps) -join "`n- ")

ACCEPTANCE:
$(@($Task.Criteria) -join "`n- ")

FULL JIRA SOURCE:
$JiraText

QA COMMENT:
$QaComment

PROJECT RULES:
$($ProjectRules -join "`n- ")

LIVE BROWSER PAGE CONTEXT — REAL AUTHENTICATED PAGE EVIDENCE:
$(Get-LivePageContextForPrompt)

SELECTED ENVIRONMENT: $([string]$jiraEnvironmentCombo.SelectedItem)
DATA MUTATION ALLOWED: $(if ($jiraMutatingCheck.Checked) { 'YES' } else { 'NO' })

RULES:
- Build checks that prove the acceptance criteria, not generic smoke.
- Honor the QA comment.
- Honor the mutation setting.
- Never use existing production orders if project rules prohibit that.
- Identify exact required test data instead of silently assuming it exists.`n- Treat LIVE BROWSER PAGE CONTEXT as primary UI evidence. Do not invent controls or routes contradicted by it.
"@

    $raw = Invoke-CodexAgent -AgentSlug '02-test-designer' -Prompt $prompt -TimeoutSec 300 -ReasoningEffort 'low'
    if (-not $raw) {
        Set-AgentStatus -Agent TestDesigner -State FAIL -Details $script:LastAgentError
        return $null
    }

    $parsed = Convert-AgentJson $raw
    if (-not $parsed) {
        Set-AgentStatus -Agent TestDesigner -State FAIL -Details $script:LastAgentError
        return $null
    }

    $script:AgentTestDesign = $parsed
    Set-AgentStatus -Agent TestDesigner -State PASS
    return $parsed
}

function Invoke-AgentUi {
    param(
        $Task,
        $TestDesign,
        [string]$QaComment,
        [string[]]$ProjectRules
    )

    Set-AgentStatus -Agent UIAgent -State RUNNING

    $designJson = $TestDesign | ConvertTo-Json -Depth 8 -Compress

    $prompt = @"
You are Agent 3 of the Rx2GO QA pipeline: UI AGENT.

Focus only on browser/UI automation feasibility and assertions.
Do not generate a full spec.

Return ONLY valid JSON:
{
  "navigation": ["page/navigation action"],
  "dataSetupUi": ["UI test-data creation step if required"],
  "interactions": ["interaction"],
  "selectors": ["stable selector strategy"],
  "assertions": ["visible UI assertion"],
  "negativeChecks": ["UI behavior that must not happen"],
  "screenshots": ["useful evidence point"]
}

TASK:
$($Task.Key) — $($Task.Title)

TEST DESIGNER OUTPUT:
$designJson

QA COMMENT:
$QaComment

PROJECT RULES:
$($ProjectRules -join "`n- ")

LIVE BROWSER PAGE CONTEXT — REAL AUTHENTICATED PAGE EVIDENCE:
$(Get-LivePageContextForPrompt)

UI CHECK ENABLED: $(if ($jiraUiCheck.Checked) { 'YES' } else { 'NO' })
BROWSER VISIBLE: $(if ($jiraHeadedCheck.Checked) { 'YES' } else { 'NO' })
DATA MUTATION ALLOWED: $(if ($jiraMutatingCheck.Checked) { 'YES' } else { 'NO' })

RULES:
- Prefer accessible roles, labels, visible text and existing repository page objects/helpers.
- Avoid brittle CSS tied to layout.
- Define assertions that distinguish PASS from the original bug.
- If test data must be created, describe how to create only test data.
- Never hard-code credentials.`n- Base navigation, selectors and interaction feasibility on LIVE BROWSER PAGE CONTEXT. If a control is absent there, do not pretend it exists.
"@

    $raw = Invoke-CodexAgent -AgentSlug '03-ui-agent' -Prompt $prompt -TimeoutSec 300 -ReasoningEffort 'low'
    if (-not $raw) {
        Set-AgentStatus -Agent UIAgent -State FAIL -Details $script:LastAgentError
        return $null
    }

    $parsed = Convert-AgentJson $raw
    if (-not $parsed) {
        Set-AgentStatus -Agent UIAgent -State FAIL -Details $script:LastAgentError
        return $null
    }

    $script:AgentUiDesign = $parsed
    Set-AgentStatus -Agent UIAgent -State PASS
    return $parsed
}

function Invoke-AgentApiNetwork {
    param(
        $Task,
        $TestDesign,
        [string]$QaComment,
        [string[]]$ProjectRules
    )

    Set-AgentStatus -Agent ApiNetworkAgent -State RUNNING

    $designJson = $TestDesign | ConvertTo-Json -Depth 8 -Compress

    $prompt = @"
You are Agent 4 of the Rx2GO QA pipeline: API / NETWORK AGENT.

Focus only on backend, HTTP, network and browser-console verification.
Do not generate a full Playwright spec.

Return ONLY valid JSON:
{
  "apiAssertions": ["API/backend assertion"],
  "expectedStatuses": ["expected HTTP status behavior"],
  "requestResponseChecks": ["request/response consistency check"],
  "networkFailures": ["failed request that should fail the test"],
  "consoleChecks": ["console error/exception check"],
  "dataConsistency": ["UI/backend consistency assertion"]
}

TASK:
$($Task.Key) — $($Task.Title)

TEST DESIGNER OUTPUT:
$designJson

QA COMMENT:
$QaComment

PROJECT RULES:
$($ProjectRules -join "`n- ")

LIVE BROWSER PAGE CONTEXT — OBSERVED NETWORK/CONSOLE/UI EVIDENCE:
$(Get-LivePageContextForPrompt)

API CHECK ENABLED: $(if ($jiraApiCheck.Checked) { 'YES' } else { 'NO' })
NETWORK / CONSOLE ENABLED: $(if ($jiraNetworkCheck.Checked) { 'YES' } else { 'NO' })

RULES:
- Do not invent endpoint paths if the repository/network evidence does not support them.
- Prefer observing real requests generated by the tested UI flow.
- Treat unexpected 4xx/5xx, failed requests and relevant console exceptions as evidence.
- Never log credentials, tokens, cookies or sensitive request headers.`n- Prefer observed network URLs/statuses from LIVE BROWSER PAGE CONTEXT over invented endpoints.
"@

    $raw = Invoke-CodexAgent -AgentSlug '04-api-network-agent' -Prompt $prompt -TimeoutSec 300 -ReasoningEffort 'low'
    if (-not $raw) {
        Set-AgentStatus -Agent ApiNetworkAgent -State FAIL -Details $script:LastAgentError
        return $null
    }

    $parsed = Convert-AgentJson $raw
    if (-not $parsed) {
        Set-AgentStatus -Agent ApiNetworkAgent -State FAIL -Details $script:LastAgentError
        return $null
    }

    $script:AgentApiDesign = $parsed
    Set-AgentStatus -Agent ApiNetworkAgent -State PASS
    return $parsed
}



function Invoke-AgentMcpQa {
    param(
        $Task,
        [string]$JiraText,
        [string]$QaComment,
        [string[]]$ProjectRules
    )

    Set-AgentStatus -Agent McpQaAgent -State RUNNING -Details 'работаю в живом Chrome'
    $script:LastAgentError = $null

    $environment = [string]$jiraEnvironmentCombo.SelectedItem
    $mutating = if ($jiraMutatingCheck.Checked) { 'YES' } else { 'NO' }

    $prompt = @"
You are the main Rx2GO SMART QA AGENT.

CRITICAL: You have Microsoft Playwright MCP connected to the SAME already-authenticated Chrome session.
You MUST actively use the MCP server named `playwright`. Do not merely plan from Jira text or repository files.
Do not close the browser.

MANDATORY BROWSER TOOL RULE:
- Use ONLY `playwright/browser_*` MCP tools for browser work.
- Do NOT use the bundled Browser / Chrome / Computer Use plugins.
- Do NOT use node_repl or any Browser skill.
- Do NOT substitute shell/exec for live browser actions.
- If a Playwright MCP tool is unavailable or blocked, return BLOCKED with that exact infrastructure reason.

Your job is to behave like a senior QA engineer in the live product:
1. Start by taking a live browser snapshot and confirm the current Rx2GO page.
2. Navigate only as needed to the task module.
3. Read the actual current UI before deciding what controls/selectors exist.
4. If the QA comment/task requires fresh test data AND DATA MUTATION ALLOWED=YES, create fresh isolated test data now.
5. If DATA MUTATION ALLOWED=NO, NEVER create, edit, transition, link, delete, remoderate, resolve, assign, submit, save, or otherwise mutate any Rx2GO entity. Use only read-only verification and return BLOCKED when mutation is required to prove the task.
6. Never use Jira example IDs or existing business orders/tickets as a fallback when fresh data is required.
6. If fresh data cannot be created safely with confirmed UI/API behavior, return BLOCKED instead of guessing or using production data.
7. Execute the acceptance criteria in the live browser now. This is not a planning-only turn.
8. Inspect browser console and relevant network requests through Playwright MCP when useful.
9. Record the actual IDs/entities you created, the actual controls you used, and actual evidence from the page.
10. Leave the browser open on a useful final state for the generated Playwright test.

OUTPUT LANGUAGE:
- All human-readable JSON strings must be in Russian: executedSteps, acceptance criterion/evidence, networkEvidence, consoleEvidence, blockers, specGuidance and test-data labels.
- Preserve literal UI labels, selectors, URLs, HTTP methods, endpoint names and technical identifiers exactly when needed.

Return ONLY valid JSON with this exact top-level shape:
{
  "status": "PASS|FAIL|BLOCKED",
  "mcpUsed": true,
  "environment": "$environment",
  "startUrl": "actual URL",
  "endUrl": "actual URL",
  "testData": {
    "created": true,
    "sourceTicketId": "",
    "relatedTicketIds": [],
    "entities": [
      {"type":"ticket|order|other","id":"actual id","label":"purpose"}
    ]
  },
  "executedSteps": ["actual browser action performed"],
  "actualSelectors": ["selector/role/text strategy proven against the live UI"],
  "acceptanceResults": [
    {"criterion":"criterion text","status":"PASS|FAIL|BLOCKED","evidence":"actual evidence"}
  ],
  "networkEvidence": ["actual observed request/status relevant to this task"],
  "consoleEvidence": ["actual console/page error or explicit none observed"],
  "screenshots": ["screenshot artifact path if captured"],
  "blockers": ["blocker if any"],
  "specGuidance": ["concrete guidance for a deterministic Playwright spec"]
}

TASK:
$($Task.Key) — $($Task.Title)
Module: $($Task.Module)

TASK SCREENSHOTS:
$(Get-JiraScreenshotPromptSummary)

VISUAL CONTEXT RULES:
- The attached task screenshots are real image inputs from the tester.
- Inspect them before choosing the live-browser workflow.
- Use them to understand UI location, labels, visual state and the problem being described.
- The live authenticated product remains the source of truth for what happens during this execution.
- Do not treat historical screenshot contents as proof that the current product still behaves the same.

CURRENT / BUG BEHAVIOR:
$(@($Task.CurrentBehavior) -join "`n- ")

EXPECTED:
$(@($Task.ExpectedBehavior) -join "`n- ")

REPRODUCTION:
$(@($Task.ReproductionSteps) -join "`n- ")

ACCEPTANCE:
$(@($Task.Criteria) -join "`n- ")

QA COMMENT:
$QaComment

QA COMMENT SEMANTICS:
- A conditional note such as "при создании ордера Client ID должен быть X" does NOT itself require creating an order.
- Apply such a constraint only if the acceptance scenario otherwise requires creation.
- An explicit instruction such as "создать тестовый ордер/тикет" DOES require fresh run-scoped test data when mutation is allowed.

PROJECT RULES:
$($ProjectRules -join "`n- ")

ENVIRONMENT: $environment
DATA MUTATION ALLOWED: $mutating
UI CHECK: $($jiraUiCheck.Checked)
API CHECK: $($jiraApiCheck.Checked)
NETWORK/CONSOLE CHECK: $($jiraNetworkCheck.Checked)
REGRESSION CHECK: $($jiraRegressionCheck.Checked)

EXECUTION BUDGET:
- Prefer the smallest deterministic fixture that satisfies the task.
- For a Related tickets task, target exactly 1 fresh test order + 3 fresh tickets: 1 source + 2 related.
- Do not create standalone exploratory tickets after one confirmed ticket-creation path is known.
- Once required test data exists, stop setup exploration and execute acceptance criteria immediately.
- Reuse controls/requests already proven in this same live session instead of rediscovering the same flow.
- If a setup attempt fails, inspect the failure before retrying; do not blindly create multiple extra entities.

FINAL SAFETY RULES:
- Never reveal or log credentials, cookies, auth headers, tokens or passwords.
- Do not modify real business data unless it is explicitly created for this test run.
- Respect Rx2GO project test-data policy.
- Do not claim an action succeeded unless you actually observed it in the live browser.
- If the product itself fails an acceptance criterion, status may be FAIL; still return all useful evidence.
- If automation/data setup is impossible or ambiguous, status must be BLOCKED, not guessed.
"@

    $raw = Invoke-CodexAgent `
        -AgentSlug '02-playwright-mcp-qa' `
        -Prompt $prompt `
        -TimeoutSec 900 `
        -ReasoningEffort 'medium' `
        -ImagePaths (Get-JiraScreenshotPaths)

    if (-not $raw) {
        Set-AgentStatus -Agent McpQaAgent -State FAIL -Details $script:LastAgentError
        return $null
    }

    $parsed = Convert-AgentJson $raw
    if (-not $parsed) {
        Set-AgentStatus -Agent McpQaAgent -State FAIL -Details $script:LastAgentError
        return $null
    }

    if (-not $parsed.status) {
        $script:LastAgentError = 'Playwright MCP QA Agent returned JSON without status.'
        Set-AgentStatus -Agent McpQaAgent -State FAIL -Details $script:LastAgentError
        return $null
    }

    if (-not [bool]$parsed.mcpUsed) {
        $script:LastAgentError = 'Playwright MCP QA Agent did not confirm live MCP browser usage.'
        Set-AgentStatus -Agent McpQaAgent -State FAIL -Details 'MCP not used'
        return $null
    }

    if (-not (Test-LastAgentUsedPlaywrightMcpSuccessfully -MinimumCompletedCalls 2)) {
        Set-AgentStatus -Agent McpQaAgent -State FAIL -Details 'MCP calls blocked/missing'
        return $null
    }

    $observedUrl = if (-not [string]::IsNullOrWhiteSpace([string]$parsed.endUrl)) {
        [string]$parsed.endUrl
    }
    else {
        [string]$parsed.startUrl
    }

    if (-not (Test-Rx2GoAgentUrl -Url $observedUrl -Environment $environment)) {
        $script:LastAgentError = "Playwright MCP QA worked on the wrong page: '$observedUrl'."
        Set-AgentStatus -Agent McpQaAgent -State FAIL -Details 'wrong browser/page'
        return $null
    }

    if (-not $jiraMutatingCheck.Checked -and $parsed.testData -and [bool]$parsed.testData.created) {
        $script:LastAgentError = 'Playwright MCP QA violated mutation policy: testData.created=true while Jira mutation permission is disabled.'
        Append-AgentLog "MUTATION POLICY → FAIL | $($script:LastAgentError)"
        Set-AgentStatus -Agent McpQaAgent -State FAIL -Details 'mutation policy violation'
        return $null
    }

    $validStatuses = @('PASS','FAIL','BLOCKED')
    $status = ([string]$parsed.status).ToUpperInvariant()
    if ($validStatuses -notcontains $status) {
        $script:LastAgentError = "Playwright MCP QA Agent returned invalid status: $status"
        Set-AgentStatus -Agent McpQaAgent -State FAIL -Details $script:LastAgentError
        return $null
    }

    $script:AgentMcpExecution = $parsed
    $script:AgentMcpExecutionRaw = $raw

    # A readable Jira report is available immediately after the live acceptance run,
    # even if Reviewer/final Playwright later fails.
    [void](Save-JiraReadableReport)

    $artifact = Join-Path $script:AgentRunDir 'smart-mcp-execution.json'
    Write-Utf8NoBomFile -Path $artifact -Content $raw
    Append-AgentLog "MCP EXECUTION ARTIFACT → $artifact"

    if ($status -eq 'BLOCKED') {
        $reason = (@($parsed.blockers) | Where-Object { $_ } | Select-Object -First 1)
        if (-not $reason) { $reason = 'Live QA execution is blocked.' }
        $script:LastAgentError = [string]$reason
        Set-AgentStatus -Agent McpQaAgent -State FAIL -Details 'BLOCKED'
        return $parsed
    }

    if ($status -eq 'FAIL') {
        Set-AgentStatus -Agent McpQaAgent -State PASS -Details 'product FAIL captured'
    }
    else {
        Set-AgentStatus -Agent McpQaAgent -State PASS -Details 'live acceptance executed'
    }

    return $parsed
}

function Normalize-PlaywrightSpecText {
    param([string]$Raw)
    if ([string]::IsNullOrWhiteSpace($Raw)) { return '' }
    $code = $Raw.Trim()
    if ($code -match '(?s)```(?:typescript|ts)?\s*(.*?)\s*```') { $code = $Matches[1].Trim() }
    $importMatch = [regex]::Match($code, '(?m)^\s*import\s+')
    if ($importMatch.Success -and $importMatch.Index -gt 0) { $code = $code.Substring($importMatch.Index) }
    $code = $code -replace '(?s)\s*```\s*$', ''
    return $code.Trim()
}


function Test-GeneratedPlaywrightSpec {
    param(
        [string]$SpecRelative,
        [string]$LogFile
    )

    $result = [ordered]@{
        Success = $false
        ExitCode = -1
        StdOut = ''
        StdErr = ''
        Error = ''
    }

    $playwrightCmd = Join-Path $script:ProjectRoot 'node_modules\.bin\playwright.cmd'

    if (-not (Test-Path $playwrightCmd)) {
        $result.Error = "Local Playwright is not installed: $playwrightCmd"
        $result.StdErr = $result.Error

        @(
            "SPEC: $SpecRelative"
            'EXIT CODE: -1'
            'SUCCESS: False'
            "ERROR: $($result.Error)"
        ) | Set-Content -Path $LogFile -Encoding UTF8

        return [pscustomobject]$result
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'cmd.exe'
    $psi.Arguments = "/d /s /c `"`"`"$playwrightCmd`"`" test `"`"$SpecRelative`"`" --list`""
    $psi.WorkingDirectory = $script:ProjectRoot
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true

    $p = $null

    try {
        Append-AgentLog "PLAYWRIGHT VALIDATION → $SpecRelative"

        $p = New-Object System.Diagnostics.Process
        $p.StartInfo = $psi
        [void]$p.Start()

        $outTask = $p.StandardOutput.ReadToEndAsync()
        $errTask = $p.StandardError.ReadToEndAsync()

        $finished = Wait-ProcessResponsive -Process $p -TimeoutSec 90

        if (-not $finished) {
            try { $p.Kill() } catch { }
            try { [void]$p.WaitForExit(3000) } catch { }
            $result.Error = 'Playwright --list validation timeout'
        }

        try { $result.StdOut = [string]$outTask.Result } catch { }
        try { $result.StdErr = [string]$errTask.Result } catch { }
        try { $result.ExitCode = [int]$p.ExitCode } catch { }

        if ([string]::IsNullOrWhiteSpace($result.Error)) {
            $result.Success = ($result.ExitCode -eq 0)
        }

        @(
            "SPEC: $SpecRelative"
            "PLAYWRIGHT: $playwrightCmd"
            "EXIT CODE: $($result.ExitCode)"
            "SUCCESS: $($result.Success)"
            "ERROR: $($result.Error)"
            ''
            'STDOUT:'
            $result.StdOut
            ''
            'STDERR:'
            $result.StdErr
        ) | Set-Content -Path $LogFile -Encoding UTF8

        if ($result.Success) {
            Append-AgentLog 'PLAYWRIGHT VALIDATION → PASS'
        }
        else {
            Append-AgentLog "PLAYWRIGHT VALIDATION → FAIL | $($result.Error)"
        }

        return [pscustomobject]$result
    }
    catch {
        $result.Error = $_.Exception.Message
        $_.Exception.ToString() | Set-Content -Path $LogFile -Encoding UTF8
        Append-AgentLog "PLAYWRIGHT VALIDATION → EXCEPTION | $($result.Error)"
        return [pscustomobject]$result
    }
    finally {
        if ($p) {
            try { $p.Dispose() } catch { }
        }
    }
}

function Invoke-AgentQaReviewer {
    param($Task,$TestDesign,$UiDesign,$ApiDesign,[string]$QaComment,[string[]]$ProjectRules)
    Set-AgentStatus -Agent QAReviewer -State RUNNING
    $script:JiraGenerationError = $null
    $script:JiraGenerationLog = $null
    $designerJson = $TestDesign | ConvertTo-Json -Depth 10 -Compress
    $uiJson = $UiDesign | ConvertTo-Json -Depth 10 -Compress
    $apiJson = $ApiDesign | ConvertTo-Json -Depth 10 -Compress
    $prompt = @"
You are Agent 5 of the Rx2GO QA pipeline: QA REVIEWER + FINAL AUTOMATION OWNER.
Review the four specialist outputs and return ONLY one complete raw TypeScript Playwright spec.
Use read-only repository inspection only when needed. Do NOT perform broad repository scans if the known
Rx2GO files are sufficient. Prefer these exact files first:
- fixtures/authenticated-page.ts
- fixtures/browser-page.ts
- pages/tickets-queue.page.ts
- utils/environment.ts
- knowledge/test-data-policy.yaml
- knowledge/tickets.yaml
- playwright.config.ts
- package.json
Return no markdown and no prose.

TASK: $($Task.Key) — $($Task.Title)
Module: $($Task.Module)
CURRENT: $(@($Task.CurrentBehavior) -join "`n- ")
EXPECTED: $(@($Task.ExpectedBehavior) -join "`n- ")
REPRODUCTION: $(@($Task.ReproductionSteps) -join "`n- ")
ACCEPTANCE: $(@($Task.Criteria) -join "`n- ")
AGENT 2: $designerJson
AGENT 3: $uiJson
AGENT 4: $apiJson
QA COMMENT: $QaComment
PROJECT RULES: $($ProjectRules -join "`n- ")

LIVE BROWSER PAGE CONTEXT — REAL AUTHENTICATED PAGE EVIDENCE:
$(Get-LivePageContextForPrompt)

ENVIRONMENT: $([string]$jiraEnvironmentCombo.SelectedItem)
DATA MUTATION ALLOWED: $(if ($jiraMutatingCheck.Checked) { 'YES' } else { 'NO' })

RULES:
- Test the Jira acceptance criteria, not generic page loading.
- Use existing repository fixtures/helpers/page objects where available.
- Never hard-code credentials or secrets.
- Respect data mutation setting.
- Add explicit expect() assertions.
- Do not use test.skip as implementation substitute.
- Response must begin with import and contain only TypeScript.`n- Use LIVE BROWSER PAGE CONTEXT to choose actual visible controls/selectors. Do not generate guessed UI flows when live evidence contradicts them.
"@
    Append-AgentLog 'QA Reviewer: generating final Playwright spec…'
    $raw = Invoke-CodexAgent -AgentSlug '05-qa-reviewer' -Prompt $prompt -TimeoutSec 420 -ReasoningEffort 'medium'
    if (-not $raw) {
        $script:JiraGenerationError = $script:LastAgentError
        Set-AgentStatus -Agent QAReviewer -State FAIL -Details $script:LastAgentError
        return $null
    }
    $code = Normalize-PlaywrightSpecText $raw
    if ($code.Length -lt 80 -or $code -notmatch '(?m)^\s*import\s' -or $code -notmatch '\btest\s*\(') {
        $script:JiraGenerationError = 'QA Reviewer returned text that cannot be recognized as a Playwright TypeScript spec.'
        Append-AgentLog $script:JiraGenerationError
        Set-AgentStatus -Agent QAReviewer -State FAIL -Details $script:JiraGenerationError
        return $null
    }
    $generatedDir = Join-Path $script:ProjectRoot 'tests\generated'
    New-Item -ItemType Directory -Path $generatedDir -Force | Out-Null
    $safeKey = ([string]$Task.Key -replace '[^A-Za-z0-9_-]', '_')
    $stamp = Get-Date -Format 'yyyyMMddHHmmss'
    $specRelative = "tests/generated/$safeKey-$stamp.spec.ts"
    $specAbsolute = Join-Path $script:ProjectRoot ($specRelative -replace '/', '\')
    Write-Utf8NoBomFile -Path $specAbsolute -Content $code
    Append-AgentLog "QA Reviewer: spec saved → $specRelative"
    Set-AgentStatus -Agent QAReviewer -State RUNNING -Details 'spec готов; валидирую Playwright'
    $jiraTaskStatus.Text = 'Agent 5/5: spec создан, проверяю Playwright…'
    [System.Windows.Forms.Application]::DoEvents()

    $validationLog = Join-Path $script:AgentRunDir "$stamp-05-playwright-validation.log"
    $validation = Test-GeneratedPlaywrightSpec -SpecRelative $specRelative -LogFile $validationLog
    $script:JiraGenerationLog = $validationLog
    if (-not $validation.Success) {
        Append-AgentLog 'QA Reviewer: first Playwright validation failed.'
        if ($validation.StdErr) {
            $validationTail = (($validation.StdErr -split "`r?`n") | Where-Object { $_ } | Select-Object -First 12) -join "`r`n"
            if ($validationTail) { Append-AgentLog $validationTail }
        }
        $repairPrompt = @"
You are the Rx2GO QA Reviewer repairing a generated Playwright TypeScript spec.
Return ONLY the corrected complete TypeScript spec. No markdown and no explanation.
TASK: $($Task.Key) — $($Task.Title)
ORIGINAL SPEC:
$code
PLAYWRIGHT STDOUT:
$($validation.StdOut)
PLAYWRIGHT STDERR:
$($validation.StdErr)

LIVE BROWSER PAGE CONTEXT:
$(Get-LivePageContextForPrompt)

RULES:
- Fix compilation/import/fixture/API mistakes reported by Playwright.
- Inspect repository in read-only mode before changing imports/helpers.
- Preserve task-specific acceptance assertions.
- Do not hard-code credentials or secrets.
- Return only TypeScript beginning with imports.
"@
        Set-AgentStatus -Agent QAReviewer -State RUNNING -Details 'чиню spec после validation error'
        $jiraTaskStatus.Text = 'Agent 5/5: исправляю сгенерированный spec…'
        [System.Windows.Forms.Application]::DoEvents()
        Append-AgentLog 'QA Reviewer: automatic repair attempt 1/1…' 
        $repairRaw = Invoke-CodexAgent -AgentSlug '05-qa-reviewer-repair' -Prompt $repairPrompt -TimeoutSec 300 -ReasoningEffort 'medium'
        if ($repairRaw) {
            $repairCode = Normalize-PlaywrightSpecText $repairRaw
            if ($repairCode.Length -ge 80 -and $repairCode -match '(?m)^\s*import\s' -and $repairCode -match '\btest\s*\(') {
                Write-Utf8NoBomFile -Path $specAbsolute -Content $repairCode
                $code = $repairCode
                $repairValidationLog = Join-Path $script:AgentRunDir "$stamp-05-playwright-repair-validation.log"
                $repairValidation = Test-GeneratedPlaywrightSpec -SpecRelative $specRelative -LogFile $repairValidationLog
                $script:JiraGenerationLog = $repairValidationLog
                if ($repairValidation.Success) {
                    Append-AgentLog 'QA Reviewer: repaired spec passed Playwright validation.'
                    $script:AgentReviewerSpec = $specRelative
                    Set-AgentStatus -Agent QAReviewer -State PASS
                    return $specRelative
                }
                $validation = $repairValidation
                $validationLog = $repairValidationLog
            }
        }
        $shortError = ''
        if ($validation.StdErr) { $shortError = (($validation.StdErr -split "`r?`n") | Where-Object { $_ } | Select-Object -First 8) -join ' ' }
        if (-not $shortError) { $shortError = [string]$validation.Error }
        if (-not $shortError) { $shortError = "Playwright validation exit $($validation.ExitCode)" }
        $script:JiraGenerationError = "QA Reviewer spec failed validation after repair: $shortError"
        Append-AgentLog "FAIL QA Reviewer: $($script:JiraGenerationError)"
        Append-AgentLog "VALIDATION LOG: $validationLog"
        Set-AgentStatus -Agent QAReviewer -State FAIL -Details 'Playwright validation failed'
        return $null
    }
    Append-AgentLog 'QA Reviewer: spec passed Playwright validation.'
    $script:AgentReviewerSpec = $specRelative
    Set-AgentStatus -Agent QAReviewer -State PASS
    return $specRelative
}


function Get-LongNumericIds {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }
    return @(
        [regex]::Matches($Text, '(?<!\d)\d{6,}(?!\d)') |
            ForEach-Object { $_.Value } |
            Select-Object -Unique
    )
}


function Test-SmartSpecRuntimeSafety {
    param([string]$Code)

    $result = [ordered]@{
        Success = $true
        Error = ''
    }

    if ([string]::IsNullOrWhiteSpace($Code)) {
        $result.Success = $false
        $result.Error = 'Generated Playwright spec is empty.'
        return [pscustomobject]$result
    }

    # IMPORTANT:
    # The persistent CDP page/context is obtained from browserType.connectOverCDP().
    # Unlike the normal Playwright test-created context, that existing context does
    # not inherit use.baseURL from playwright.config.ts. Therefore:
    #     page.goto('/orders/')
    # fails with "Cannot navigate to invalid URL".
    #
    # Reject literal root-relative goto() calls before runtime and send the spec
    # through the existing Reviewer repair pass.
    $relativeGoto = [regex]::Match(
        $Code,
        '(?ims)\.goto\s*\(\s*([\"''])(\s*/[^\"'']*)\1'
    )

    if ($relativeGoto.Success) {
        $target = [string]$relativeGoto.Groups[2].Value
        $result.Success = $false
        $result.Error = (
            "Generated spec contains root-relative page.goto('$target'). " +
            "Persistent CDP pages do not inherit Playwright baseURL. " +
            "Use an absolute environment URL via resolveBaseUrl(), an observed absolute URL, " +
            "or navigate by a live UI link."
        )
        return [pscustomobject]$result
    }

    # Also catch simple literal non-absolute goto values such as "orders/stat".
    $literalGotos = [regex]::Matches(
        $Code,
        '(?ims)\.goto\s*\(\s*([\"''])([^\"'']+)\1'
    )

    foreach ($match in $literalGotos) {
        $target = ([string]$match.Groups[2].Value).Trim()

        if (
            $target -and
            $target -notmatch '^(?i:https?://|about:|data:|file:)'
        ) {
            $result.Success = $false
            $result.Error = (
                "Generated spec contains non-absolute page.goto('$target'). " +
                "Persistent CDP pages require an absolute URL or environment URL helper."
            )
            return [pscustomobject]$result
        }
    }

    return [pscustomobject]$result
}

function Test-SmartSpecDataSafety {
    param(
        [string]$Code,
        $Task,
        [string]$McpExecutionRaw
    )

    $result = [ordered]@{
        Success = $true
        Error = ''
    }

    if (-not $jiraMutatingCheck.Checked) {
        return [pscustomobject]$result
    }

    $jiraIds = @(Get-LongNumericIds -Text ([string]$Task.Raw))
    $mcpIds = @(Get-LongNumericIds -Text $McpExecutionRaw)

    if ($mcpIds.Count -eq 0) {
        return [pscustomobject]$result
    }

    $bad = @()
    foreach ($id in $jiraIds) {
        if ($mcpIds -notcontains $id -and $Code -match "(?<!\\d)$([regex]::Escape($id))(?!\\d)") {
            $bad += $id
        }
    }

    if ($bad.Count -gt 0) {
        $result.Success = $false
        $result.Error = "Generated spec reused Jira example/business IDs instead of run-scoped MCP data: $($bad -join ', ')"
    }

    return [pscustomobject]$result
}

function Invoke-AgentSmartReviewer {
    param(
        $Task,
        $McpExecution,
        [string]$McpExecutionRaw,
        [string]$QaComment,
        [string[]]$ProjectRules
    )

    Set-AgentStatus -Agent QAReviewer -State RUNNING -Details 'собираю deterministic spec'
    $script:JiraGenerationError = $null
    $script:JiraGenerationLog = $null

    $environment = [string]$jiraEnvironmentCombo.SelectedItem
    $mcpJson = $McpExecution | ConvertTo-Json -Depth 16

    $prompt = @"
You are the final Rx2GO QA REVIEWER and Playwright spec owner.

The main Playwright MCP QA Agent has ALREADY worked in the real authenticated browser and produced run-scoped evidence below.
Your job is to turn that REAL execution evidence into one deterministic Playwright TypeScript spec.

You also have Playwright MCP connected to the same Chrome. Use it only when you need to verify a selector/state that is missing from the evidence. Do not redo broad exploration and do not close the browser.

Return ONLY one complete raw TypeScript Playwright spec. No markdown and no prose.

TASK:
$($Task.Key) — $($Task.Title)
Module: $($Task.Module)

TASK SCREENSHOTS:
$(Get-JiraScreenshotPromptSummary)
Use attached screenshots as secondary visual evidence. The REAL PLAYWRIGHT MCP QA EXECUTION below remains primary runtime evidence.

ACCEPTANCE:
$(@($Task.Criteria) -join "`n- ")

QA COMMENT:
$QaComment

PROJECT RULES:
$($ProjectRules -join "`n- ")

REAL PLAYWRIGHT MCP QA EXECUTION:
$mcpJson

ENVIRONMENT: $environment
DATA MUTATION ALLOWED: $(if ($jiraMutatingCheck.Checked) { 'YES' } else { 'NO' })

MANDATORY RULES:
- Test the actual Jira acceptance criteria, not generic page loading.
- Treat the MCP QA execution as primary evidence for routes, controls, selectors and run-scoped test IDs.
- If fresh test data was created, use those run-scoped IDs. NEVER fall back to historical/example Jira IDs that were not used by the MCP QA execution.
- Do not invent UI controls that were not observed. If a selector is uncertain, use Playwright MCP now to verify it.
- Reuse existing repository fixtures/helpers when appropriate.
- Never hard-code credentials, Telegram codes, cookies, tokens or auth headers.
- Add explicit expect() assertions that decide PASS/FAIL.
- Do not use test.skip as a substitute for implementation.
- Keep the test in the existing authenticated Chrome/CDP session when the fixture provides it.
- CRITICAL CDP NAVIGATION RULE: the reused CDP BrowserContext does NOT inherit Playwright use.baseURL.
- NEVER write page.goto('/path'), page.goto("path") or any other literal relative goto URL.
- If direct navigation is required, import resolveBaseUrl from ../utils/environment or ../../utils/environment as appropriate and navigate to an absolute URL such as `${resolveBaseUrl()}/orders/stat`.
- Prefer an observed live UI link when it is deterministic and already proven by MCP.
- The response must begin with import statements and contain only valid TypeScript.
"@

    Append-AgentLog 'QA Reviewer: generating final spec from live MCP evidence…'
    $raw = Invoke-CodexAgent `
        -AgentSlug '03-qa-reviewer' `
        -Prompt $prompt `
        -TimeoutSec 600 `
        -ReasoningEffort 'medium' `
        -ImagePaths (Get-JiraScreenshotPaths)

    if (-not $raw) {
        $script:JiraGenerationError = $script:LastAgentError
        Set-AgentStatus -Agent QAReviewer -State FAIL -Details $script:LastAgentError
        return $null
    }

    $code = Normalize-PlaywrightSpecText $raw
    if ($code.Length -lt 80 -or $code -notmatch '(?m)^\s*import\s' -or $code -notmatch '\btest\s*\(') {
        $script:JiraGenerationError = 'QA Reviewer did not return a recognizable Playwright TypeScript spec.'
        Set-AgentStatus -Agent QAReviewer -State FAIL -Details $script:JiraGenerationError
        return $null
    }

    $generatedDir = Join-Path $script:ProjectRoot 'tests\generated'
    New-Item -ItemType Directory -Path $generatedDir -Force | Out-Null

    $safeKey = ([string]$Task.Key -replace '[^A-Za-z0-9_-]', '_')
    $stamp = Get-Date -Format 'yyyyMMddHHmmss'
    $specRelative = "tests/generated/$safeKey-$stamp.spec.ts"
    $specAbsolute = Join-Path $script:ProjectRoot ($specRelative -replace '/', '\')

    $runtimeSafety = Test-SmartSpecRuntimeSafety -Code $code
    $dataSafety = Test-SmartSpecDataSafety -Code $code -Task $Task -McpExecutionRaw $McpExecutionRaw
    $repairReason = ''

    if (-not $runtimeSafety.Success) {
        $repairReason = [string]$runtimeSafety.Error
        Append-AgentLog "QA Reviewer CDP navigation guard → FAIL | $repairReason"
    }
    elseif (-not $dataSafety.Success) {
        $repairReason = [string]$dataSafety.Error
        Append-AgentLog "QA Reviewer data safety guard → FAIL | $repairReason"
    }
    else {
        Write-Utf8NoBomFile -Path $specAbsolute -Content $code
        Set-AgentStatus -Agent QAReviewer -State RUNNING -Details 'валидирую Playwright'

        $validationLog = Join-Path $script:AgentRunDir "$stamp-03-playwright-validation.log"
        $validation = Test-GeneratedPlaywrightSpec -SpecRelative $specRelative -LogFile $validationLog
        $script:JiraGenerationLog = $validationLog

        if ($validation.Success) {
            Append-AgentLog 'QA Reviewer: spec passed Playwright validation.'
            $script:AgentReviewerSpec = $specRelative
            Set-AgentStatus -Agent QAReviewer -State PASS
            return $specRelative
        }

        $repairReason = "Playwright validation failed.`nSTDOUT:`n$($validation.StdOut)`nSTDERR:`n$($validation.StdErr)"
    }

    # One repair pass. It covers both compiler/fixture mistakes and unsafe reuse
    # of historical Jira IDs when the live MCP agent created fresh data.
    Set-AgentStatus -Agent QAReviewer -State RUNNING -Details 'repair 1/1'
    Append-AgentLog 'QA Reviewer: automatic repair attempt 1/1…'

    $repairPrompt = @"
You are repairing a generated Rx2GO Playwright TypeScript spec.
Return ONLY the corrected complete TypeScript spec. No markdown, no prose.

TASK: $($Task.Key) — $($Task.Title)
ACCEPTANCE:
$(@($Task.Criteria) -join "`n- ")

REAL PLAYWRIGHT MCP EXECUTION:
$mcpJson

ORIGINAL SPEC:
$code

REPAIR REASON:
$repairReason

RULES:
- Use the REAL run-scoped IDs and selectors from Playwright MCP execution.
- Never use Jira example/business IDs as fallback when fresh data exists.
- Fix imports, fixture names, locator mistakes or TypeScript errors as reported.
- Persistent CDP pages do NOT inherit Playwright baseURL: never use literal relative page.goto('/...') or page.goto('...').
- For direct navigation use an absolute URL built with resolveBaseUrl() or an already observed absolute URL.
- Preserve task-specific acceptance assertions.
- Do not hard-code credentials or secrets.
- Return only valid TypeScript beginning with imports.
"@

    $repairRaw = Invoke-CodexAgent `
        -AgentSlug '03-qa-reviewer-repair' `
        -Prompt $repairPrompt `
        -TimeoutSec 420 `
        -ReasoningEffort 'medium' `
        -ImagePaths (Get-JiraScreenshotPaths)

    if (-not $repairRaw) {
        $script:JiraGenerationError = $script:LastAgentError
        Set-AgentStatus -Agent QAReviewer -State FAIL -Details 'repair failed'
        return $null
    }

    $repairCode = Normalize-PlaywrightSpecText $repairRaw
    if ($repairCode.Length -lt 80 -or $repairCode -notmatch '(?m)^\s*import\s' -or $repairCode -notmatch '\btest\s*\(') {
        $script:JiraGenerationError = 'QA Reviewer repair did not return a valid-looking TypeScript spec.'
        Set-AgentStatus -Agent QAReviewer -State FAIL -Details $script:JiraGenerationError
        return $null
    }

    $runtimeSafety = Test-SmartSpecRuntimeSafety -Code $repairCode
    if (-not $runtimeSafety.Success) {
        $script:JiraGenerationError = [string]$runtimeSafety.Error
        Set-AgentStatus -Agent QAReviewer -State FAIL -Details 'unsafe CDP navigation'
        return $null
    }

    $dataSafety = Test-SmartSpecDataSafety -Code $repairCode -Task $Task -McpExecutionRaw $McpExecutionRaw
    if (-not $dataSafety.Success) {
        $script:JiraGenerationError = [string]$dataSafety.Error
        Set-AgentStatus -Agent QAReviewer -State FAIL -Details 'unsafe test data fallback'
        return $null
    }

    Write-Utf8NoBomFile -Path $specAbsolute -Content $repairCode
    $repairValidationLog = Join-Path $script:AgentRunDir "$stamp-03-playwright-repair-validation.log"
    $repairValidation = Test-GeneratedPlaywrightSpec -SpecRelative $specRelative -LogFile $repairValidationLog
    $script:JiraGenerationLog = $repairValidationLog

    if (-not $repairValidation.Success) {
        $short = if ($repairValidation.StdErr) { $repairValidation.StdErr } else { $repairValidation.Error }
        $script:JiraGenerationError = "Repaired spec still fails Playwright validation: $short"
        Set-AgentStatus -Agent QAReviewer -State FAIL -Details 'validation failed'
        return $null
    }

    Append-AgentLog 'QA Reviewer: repaired spec passed Playwright validation.'
    $script:AgentReviewerSpec = $specRelative
    Set-AgentStatus -Agent QAReviewer -State PASS
    return $specRelative
}

function New-AgentPipelineSummary {
    param(
        $TestDesign,
        $UiDesign,
        $ApiDesign
    )

    $lines = @()
    $lines += ''
    $lines += '5-AGENT PIPELINE:'
    $lines += '1. Jira Analyst — PASS'
    $lines += '2. Test Designer — PASS'
    $lines += '3. UI Agent — PASS'
    $lines += '4. API / Network Agent — PASS'
    $lines += '5. QA Reviewer — PASS'
    $lines += ''

    if ($TestDesign -and $TestDesign.strategy) {
        $lines += "TEST STRATEGY: $($TestDesign.strategy)"
    }

    if ($TestDesign -and $TestDesign.criticalAssertions) {
        $lines += 'CRITICAL ASSERTIONS:'
        foreach ($x in $TestDesign.criticalAssertions) {
            $lines += "- $x"
        }
    }

    if ($UiDesign -and $UiDesign.assertions) {
        $lines += 'UI ASSERTIONS:'
        foreach ($x in $UiDesign.assertions) {
            $lines += "- $x"
        }
    }

    if ($ApiDesign -and $ApiDesign.apiAssertions) {
        $lines += 'API / NETWORK ASSERTIONS:'
        foreach ($x in $ApiDesign.apiAssertions) {
            $lines += "- $x"
        }
    }

    return ($lines -join "`r`n")
}


function New-SmartPipelineSummary {
    param($McpExecution)

    $lines = @()
    $lines += ''
    $lines += 'SMART QA PIPELINE:'
    $lines += '1. Requirements Analyst — PASS'
    $lines += '2. Playwright MCP QA — PASS'
    $lines += '3. QA Reviewer — PASS'
    $lines += ''

    if ($McpExecution) {
        $lines += "LIVE EXECUTION STATUS: $($McpExecution.status)"
        if ($McpExecution.startUrl) { $lines += "START URL: $($McpExecution.startUrl)" }
        if ($McpExecution.endUrl) { $lines += "END URL: $($McpExecution.endUrl)" }

        if (@($McpExecution.testData.entities).Count -gt 0) {
            $lines += 'RUN-SCOPED TEST DATA:'
            foreach ($entity in @($McpExecution.testData.entities)) {
                if ($entity) {
                    $lines += "- $($entity.type): $($entity.id) — $($entity.label)"
                }
            }
        }

        if (@($McpExecution.acceptanceResults).Count -gt 0) {
            $lines += 'LIVE ACCEPTANCE RESULTS:'
            foreach ($r in @($McpExecution.acceptanceResults)) {
                if ($r) {
                    $lines += "- [$($r.status)] $($r.criterion) — $($r.evidence)"
                }
            }
        }

        if (@($McpExecution.blockers).Count -gt 0) {
            $lines += 'BLOCKERS:'
            foreach ($b in @($McpExecution.blockers)) { if ($b) { $lines += "- $b" } }
        }
    }

    return ($lines -join "`r`n")
}

function Invoke-ChatGPTJiraTestGeneration($task, [string]$qaComment, [string[]]$projectRules) {
    $script:JiraGenerationError = $null
    $script:JiraGenerationLog = $null

    if (-not $script:ChatGPTConnected) {
        $script:JiraGenerationError = 'ChatGPT/Codex не подключён.'
        return $null
    }

    $generatedDir = Join-Path $script:ProjectRoot 'tests\generated'
    $aiDir = Join-Path $script:ProjectRoot 'reports\ai'
    New-Item -ItemType Directory -Path $generatedDir -Force | Out-Null
    New-Item -ItemType Directory -Path $aiDir -Force | Out-Null

    $key = ([string]$task.Key -replace '[^A-Za-z0-9_-]', '_')
    $stamp = Get-Date -Format 'yyyyMMddHHmmss'
    $specRelative = "tests/generated/$key-$stamp.spec.ts"
    $specAbsolute = Join-Path $script:ProjectRoot ($specRelative -replace '/', '\')
    $aiOutput = Join-Path $aiDir "jira-test-$key-$stamp.txt"
    $aiLog = Join-Path $aiDir "jira-test-$key-$stamp.log"
    $promptFile = Join-Path $aiDir "jira-test-$key-$stamp.prompt.utf8.txt"

    $mutating = if ($jiraMutatingCheck.Checked) { 'YES' } else { 'NO' }
    $environment = [string]$jiraEnvironmentCombo.SelectedItem

    $prompt = @"
You are the Rx2GO Playwright QA engineer.
Inspect the existing repository in read-only mode.
Return ONLY raw TypeScript source code for ONE Playwright spec. No markdown. No prose.

JIRA SOURCE:
$($task.Raw)

CURRENT / BUG BEHAVIOR:
$(@($task.CurrentBehavior) -join "`n- ")

EXPECTED:
$(@($task.ExpectedBehavior) -join "`n- ")

REPRODUCTION STEPS:
$(@($task.ReproductionSteps) -join "`n- ")

ACCEPTANCE CRITERIA:
$(@($task.Criteria) -join "`n- ")

QA COMMENT:
$qaComment

PROJECT RULES:
$($projectRules -join "`n- ")

ENVIRONMENT: $environment
DATA MUTATION ALLOWED: $mutating

RULES:
- Test the acceptance criterion itself, not only page loading.
- Current bug behavior is not expected behavior.
- QA comment is execution guidance.
- Use existing authenticated fixtures and URL helpers.
- Never hard-code credentials or tokens.
- Respect the data mutation setting.
- Return valid Playwright TypeScript.
"@

    try {
        $jiraTaskStatus.Text = "AI формирует Playwright-тест для $($task.Key)…"
        $jiraTaskStatus.ForeColor = [System.Drawing.Color]::FromArgb(37,99,235)
        [System.Windows.Forms.Application]::DoEvents()

        Write-Utf8NoBomFile -Path $promptFile -Content $prompt

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = 'cmd.exe'
        $psi.Arguments = "/d /s /c `"codex exec --skip-git-repo-check -s read-only -c approval_policy=never -o `"`"$aiOutput`"`" - < `"`"$promptFile`"`"`""
        $psi.WorkingDirectory = $script:ProjectRoot
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true

        $p = New-Object System.Diagnostics.Process
        $p.StartInfo = $psi
        [void]$p.Start()

        if (-not $p.WaitForExit(180000)) {
            try { $p.Kill() } catch {}
            $script:JiraGenerationError = 'Codex generation timeout.'
            return $null
        }

        $stderr = $p.StandardError.ReadToEnd()
        $stdout = $p.StandardOutput.ReadToEnd()
        @("EXIT CODE: $($p.ExitCode)",'STDERR:',$stderr,'STDOUT:',$stdout) | Set-Content $aiLog -Encoding UTF8
        $script:JiraGenerationLog = $aiLog

        if ($p.ExitCode -ne 0) {
            if ($stderr -match 'input is not valid UTF-8') {
                $script:JiraGenerationError = 'Codex отклонил prompt как не-UTF-8. Проверь UTF-8 prompt-файл в reports\ai.'
            }
            else {
                $script:JiraGenerationError = "Codex завершился с кодом $($p.ExitCode)."
            }
            return $null
        }

        if (-not (Test-Path $aiOutput)) {
            $script:JiraGenerationError = 'Codex не создал output-файл.'
            return $null
        }

        $code = (Get-Content -Raw -Path $aiOutput).Trim()
        if ($code -match '(?s)```(?:typescript|ts)?\s*(.*?)\s*```') { $code = $Matches[1].Trim() }

        $importIndex = $code.IndexOf('import ')
        if ($importIndex -gt 0) { $code = $code.Substring($importIndex) }

        if ($code.Length -lt 80 -or $code -notmatch '(?m)^import\s' -or $code -notmatch '\btest\s*\(') {
            $script:JiraGenerationError = 'Ответ Codex не похож на Playwright TypeScript spec.'
            return $null
        }

        $code | Set-Content -Path $specAbsolute -Encoding UTF8

        $vPsi = New-Object System.Diagnostics.ProcessStartInfo
        $vPsi.FileName = 'cmd.exe'
        $vPsi.Arguments = "/d /s /c npx playwright test `"$specRelative`" --list"
        $vPsi.WorkingDirectory = $script:ProjectRoot
        $vPsi.UseShellExecute = $false
        $vPsi.CreateNoWindow = $true
        $vPsi.RedirectStandardOutput = $true
        $vPsi.RedirectStandardError = $true

        $v = [System.Diagnostics.Process]::Start($vPsi)
        if (-not $v.WaitForExit(60000)) {
            try { $v.Kill() } catch {}
            $script:JiraGenerationError = 'Playwright validation timeout.'
            return $null
        }

        $vOut = $v.StandardOutput.ReadToEnd()
        $vErr = $v.StandardError.ReadToEnd()
        Add-Content $aiLog "`r`nPLAYWRIGHT VALIDATION:`r`n$vOut`r`n$vErr"

        if ($v.ExitCode -ne 0) {
            $script:JiraGenerationError = 'Generated spec не прошёл Playwright validation.'
            return $null
        }

        return $specRelative
    }
    catch {
        $script:JiraGenerationError = $_.Exception.Message
        $_.Exception.ToString() | Set-Content $aiLog -Encoding UTF8
        $script:JiraGenerationLog = $aiLog
        return $null
    }
}


function Write-Utf8NoBomFile {
    param(
        [string]$Path,
        [string]$Content
    )

    $directory = Split-Path -Parent $Path
    if ($directory) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}


function Invoke-ChatGPTJiraAnalysis([string]$rawText, [string]$qaComment, [string[]]$projectRules) {
    return Invoke-AgentJiraAnalyst -JiraText $rawText -QaComment $qaComment -ProjectRules $projectRules
}


function Save-AppCredential {
    param([switch]$Silent)

    $login = 'sergeyqa'
    if ($script:InlineAppLoginBox -and -not [string]::IsNullOrWhiteSpace($script:InlineAppLoginBox.Text)) {
        $login = $script:InlineAppLoginBox.Text.Trim()
    }

    $plainPassword = ''
    if ($script:InlineAppPasswordBox) {
        $plainPassword = [string]$script:InlineAppPasswordBox.Text
    }

    if ([string]::IsNullOrWhiteSpace($plainPassword)) {
        if (-not $Silent) {
            [System.Windows.Forms.MessageBox]::Show(
                'Введи пароль Rx2GO в блоке «Доступ и подключения» на вкладке «Быстрый запуск».',
                'Rx2GO QA',
                'OK',
                'Warning'
            ) | Out-Null

            if ($tabs -and $quickTab) { $tabs.SelectedTab = $quickTab }
            if ($script:InlineAppPasswordBox) { $script:InlineAppPasswordBox.Focus() }
        }
        return $false
    }

    try {
        $secretsDir = Split-Path $script:CredentialFile
        New-Item -ItemType Directory -Path $secretsDir -Force | Out-Null

        $secure = ConvertTo-SecureString $plainPassword -AsPlainText -Force
        $credential = [System.Management.Automation.PSCredential]::new($login, $secure)
        $credential | Export-Clixml -Path $script:CredentialFile

        if ($script:QuickCredentialStatus) {
            $script:QuickCredentialStatus.Text = '● пароль Rx2GO сохранён в Windows DPAPI'
            $script:QuickCredentialStatus.ForeColor = [System.Drawing.Color]::FromArgb(32,120,72)
        }

        if (-not $Silent) {
            [System.Windows.Forms.MessageBox]::Show(
                'Пароль Rx2GO сохранён локально и зашифрован Windows DPAPI.',
                'Rx2GO QA',
                'OK',
                'Information'
            ) | Out-Null
        }

        return $true
    }
    catch {
        if ($script:QuickCredentialStatus) {
            $script:QuickCredentialStatus.Text = '● не удалось сохранить пароль Rx2GO'
            $script:QuickCredentialStatus.ForeColor = [System.Drawing.Color]::Firebrick
        }

        if (-not $Silent) {
            [System.Windows.Forms.MessageBox]::Show(
                "Не удалось сохранить пароль Rx2GO: $($_.Exception.Message)",
                'Rx2GO QA',
                'OK',
                'Error'
            ) | Out-Null
        }
        return $false
    }
}

function Get-AppCredentialPlain {
    if (-not (Test-Path $script:CredentialFile)) { return $null }
    $credential = Import-Clixml -Path $script:CredentialFile
    $ptr = [IntPtr]::Zero
    try {
        $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($credential.Password)
        return @{
            Login = 'sergeyqa'
            Password = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
        }
    }
    finally {
        if ($ptr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
    }
}


function Test-GatewayRequired([string]$EnvironmentName) {
    return ([string]$EnvironmentName).ToUpperInvariant() -eq 'ADM'
}


function Set-EnvironmentUI {
    $envName = [string]$environmentCombo.SelectedItem
    $needGateway = Test-GatewayRequired $envName

    switch ($envName) {
        'BRANCH' {
            $urlValue.Text = 'https://sergey-tester.rx2go.ai/login'
            $authValue.Text = 'Rx2GO login only'
        }
        'HOT' {
            $urlValue.Text = 'https://hot.rx2go.ai'
            $authValue.Text = 'Rx2GO login only'
        }
        'ADM' {
            $urlValue.Text = 'https://adm.rx2go.ai/login'
            $authValue.Text = 'ADM first factor → Rx2GO login → test'
        }
    }

    # Keep the complete auth form visible for every environment.
    # Only enable the ADM first-factor controls when they are actually needed.
    $dailyLabel.Visible = $true
    $dailyPassword.Visible = $true
    $dailyHint.Visible = $true

    $dailyPassword.Enabled = $needGateway
    if ($script:GatewayLoginBox) {
        $script:GatewayLoginBox.Enabled = $needGateway
        $script:GatewayLoginBox.BackColor = if ($needGateway) {
            [System.Drawing.Color]::White
        } else {
            [System.Drawing.Color]::FromArgb(241,245,249)
        }
    }

    if ($needGateway) {
        $dailyHint.Text = 'ADM: admin + суточный пароль будут автоматически введены в первое окно Chrome.'
        $dailyHint.ForeColor = [System.Drawing.Color]::FromArgb(37,99,235)
    }
    else {
        $dailyHint.Text = 'Для выбранного окружения первый фактор не требуется.'
        $dailyHint.ForeColor = [System.Drawing.Color]::DimGray
    }

    if ($authValue) {
        $authValue.AutoEllipsis = $true
    }

    [System.Windows.Forms.Application]::DoEvents()
    Update-LayoutHealth
}

function Append-Log([string]$text) {
    if ([string]::IsNullOrEmpty($text)) { return }
    $logBox.AppendText($text)
    $logBox.SelectionStart = $logBox.Text.Length
    $logBox.ScrollToCaret()
    if ($script:JiraRunActive -and $script:AgentLogBox) {
        $script:AgentLogBox.AppendText($text)
        $script:AgentLogBox.SelectionStart = $script:AgentLogBox.Text.Length
        $script:AgentLogBox.ScrollToCaret()
    }
}


function Reset-ResultPanel {
    $passValue.Text = '0'
    $failValue.Text = '0'
    $skipValue.Text = '0'
    $failedList.Items.Clear()
    [void]$failedList.Items.Add('Результаты появятся после запуска.')
    $jiraButton.Enabled = $false
    $htmlButton.Enabled = $false
    $script:LastSummary = $null
}

function Get-PlaywrightSummary {
    $resultsFile = Join-Path $script:ProjectRoot 'reports\results.json'
    $summary = [ordered]@{
        Pass = 0
        Fail = 0
        Skip = 0
        Failed = New-Object System.Collections.ArrayList
        Total = 0
        DurationMs = 0
    }

    if (-not (Test-Path $resultsFile)) { return $summary }

    try {
        $json = Get-Content -Raw -Path $resultsFile | ConvertFrom-Json
    }
    catch {
        return $summary
    }

    function Visit-Suite($suite, [string[]]$parents) {
        $suiteParents = $parents
        if ($suite.title) { $suiteParents = @($parents + [string]$suite.title) }

        foreach ($spec in @($suite.specs)) {
            if (-not $spec) { continue }
            foreach ($test in @($spec.tests)) {
                if (-not $test) { continue }
                $summary.Total++
                $results = @($test.results)
                $last = if ($results.Count -gt 0) { $results[$results.Count - 1] } else { $null }
                $status = if ($last) { [string]$last.status } else { [string]$test.status }
                foreach ($r in $results) {
                    if ($r.duration) { $summary.DurationMs += [int64]$r.duration }
                }

                $titleParts = @()
                foreach ($p in $suiteParents) {
                    if ($p -and $p -notmatch '\.(spec|test)\.(ts|js)$') { $titleParts += $p }
                }
                if ($spec.title) { $titleParts += [string]$spec.title }
                $fullTitle = ($titleParts -join ' › ')
                if ([string]::IsNullOrWhiteSpace($fullTitle)) { $fullTitle = 'Без названия' }

                switch ($status) {
                    'passed' { $summary.Pass++ }
                    'skipped' { $summary.Skip++ }
                    default {
                        $summary.Fail++
                        [void]$summary.Failed.Add($fullTitle)
                    }
                }
            }
        }

        foreach ($child in @($suite.suites)) {
            if ($child) { Visit-Suite $child $suiteParents }
        }
    }

    foreach ($suite in @($json.suites)) {
        if ($suite) { Visit-Suite $suite @() }
    }

    return $summary
}

function Update-ResultPanel {
    $summary = Get-PlaywrightSummary
    $script:LastSummary = $summary

    $passValue.Text = [string]$summary.Pass
    $failValue.Text = [string]$summary.Fail
    $skipValue.Text = [string]$summary.Skip

    $failedList.Items.Clear()
    if ($summary.Fail -eq 0) {
        [void]$failedList.Items.Add('Падений нет.')
    } else {
        foreach ($title in $summary.Failed) {
            [void]$failedList.Items.Add([string]$title)
        }
    }

    $jiraButton.Enabled = $summary.Total -gt 0
    $htmlButton.Enabled = Test-Path (Join-Path $script:ProjectRoot 'playwright-report\index.html')
}

function New-JiraReportText {
    if (-not $script:LastSummary) { return $null }
    $s = $script:LastSummary
    $result = if ($s.Fail -gt 0) { 'FAIL' } elseif ($s.Pass -eq 0 -and $s.Skip -gt 0) { 'SKIP' } else { 'PASS' }
    $date = Get-Date -Format 'dd.MM.yyyy HH:mm'
    $method = 'Smart QA — Codex + Microsoft Playwright MCP + deterministic Playwright'
    $mutating = if ($mutatingCheck.Checked) { 'Да' } else { 'Нет' }

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('*TESTING REPORT*')
    $lines.Add('')
    if ($script:CurrentJiraTask -and $script:CurrentJiraTask.Key) { $lines.Add("*Task:* $($script:CurrentJiraTask.Key) — $($script:CurrentJiraTask.Title)"); $lines.Add('') }
    $lines.Add("*Environment:* $($script:LastEnvironment)")
    $lines.Add("*Suite:* $($script:LastSuite)")
    $lines.Add("*Date:* $date")
    $lines.Add('*User:* QA test user')
    $lines.Add("*Method:* $method")
    $lines.Add("*Mutating tests:* $mutating")
    $lines.Add('')
    $lines.Add("*Result:* $result")
    $lines.Add('')
    $lines.Add("PASS: $($s.Pass)")
    $lines.Add("FAIL: $($s.Fail)")
    $lines.Add("SKIP: $($s.Skip)")
    $lines.Add("TOTAL: $($s.Total)")

    if ($s.Fail -gt 0) {
        $lines.Add('')
        $lines.Add('*Failed scenarios:*')
        foreach ($title in $s.Failed) { $lines.Add("- $title") }
    }

    $lines.Add('')
    $lines.Add('*Evidence:* Playwright HTML report, screenshots/video/trace for failures.')
    return ($lines -join "`r`n")
}

function Copy-JiraReport {
    $text = New-JiraReportText
    if ([string]::IsNullOrWhiteSpace($text)) { return }
    [System.Windows.Forms.Clipboard]::SetText($text)
    $statusLabel.Text = '● Отчёт для Jira скопирован'
    $statusLabel.ForeColor = [System.Drawing.Color]::FromArgb(37, 99, 235)
}

function Open-HtmlReport {
    $report = Join-Path $script:ProjectRoot 'playwright-report\index.html'
    if (Test-Path $report) {
        Start-Process $report
    }
}



function Get-JiraTaskInfo([string]$rawText, $aiAnalysis = $null, [string]$qaComment = '', [string[]]$projectRules = @()) {
    $raw = if ($rawText) { $rawText.Trim() } else { '' }
    $key = 'ADHOC'
    $m = [regex]::Match($raw, '(?i)\b([A-Z][A-Z0-9]+-\d+)\b')
    if ($m.Success) { $key = $m.Groups[1].Value.ToUpperInvariant() }

    $title = if ($script:LoadedJiraIssue -and $script:LoadedJiraIssue.key -eq $key) {
        [string]$script:LoadedJiraIssue.summary
    } else { $key }

    $low = $raw.ToLowerInvariant()
    $module = 'Unknown'
    if ($low -match 'ticket queue|tickets queue|related tickets|ticket|тикет') { $module = 'Tickets Queue' }
    elseif ($low -match 'show chat|chat|чат') { $module = 'Chat' }
    elseif ($low -match 'scanner|сканер') { $module = 'Scanner' }
    elseif ($low -match 'dispatcher|диспетчер') { $module = 'Dispatcher' }
    elseif ($low -match 'qaqc|qa/qc') { $module = 'QAQC' }
    elseif ($low -match 'order|заказ') { $module = 'Orders' }

    $current = @()
    $expected = @()
    $repro = @()
    $criteria = @()
    $risk = @()
    $source = 'Local fallback'

    if ($aiAnalysis) {
        if ($aiAnalysis.title) { $title = [string]$aiAnalysis.title }
        $allowed = @('Tickets Queue','Chat','Scanner','Dispatcher','QAQC','Orders','Unknown')
        if ($aiAnalysis.module -and $allowed -contains [string]$aiAnalysis.module) { $module = [string]$aiAnalysis.module }

        $current = @($aiAnalysis.currentBehavior | Where-Object { $_ } | ForEach-Object { ([string]$_).Trim() })
        $expected = @($aiAnalysis.expectedBehavior | Where-Object { $_ } | ForEach-Object { ([string]$_).Trim() })
        $repro = @($aiAnalysis.reproductionSteps | Where-Object { $_ } | ForEach-Object { ([string]$_).Trim() })
        $criteria = @($aiAnalysis.acceptanceCriteria | Where-Object { $_ } | ForEach-Object { ([string]$_).Trim() })
        $risk = @($aiAnalysis.riskAreas | Where-Object { $_ } | ForEach-Object { ([string]$_).Trim() })
        $source = 'ChatGPT OAuth / Codex'
    }

    if ($criteria.Count -eq 0) {
        $section = ''
        foreach ($rawLine in @($raw -split "`r?`n")) {
            $line = $rawLine.Trim()
            if (-not $line) { continue }

            if ($line -match '(?i)^(сейчас|текущее поведение|current|actual)\s*:?\s*$') { $section='current'; continue }
            if ($line -match '(?i)^(ожидаемо|expected)\s*:?\s*$') { $section='expected'; continue }
            if ($line -match '(?i)^(как воспроизвести|steps to reproduce|repro)\s*:?\s*$') { $section='repro'; continue }
            if ($line -match '(?i)^(критерий при[её]мки|acceptance criteria|необходимо)\s*:?\s*$') { $section='acceptance'; continue }

            $clean = $line -replace '^(?:[-*•]|\d+[.)])\s*',''
            if (-not $clean) { continue }

            switch ($section) {
                'current' { $current += $clean }
                'expected' { $expected += $clean; $criteria += $clean }
                'repro' { $repro += $clean }
                'acceptance' { $criteria += $clean }
            }
        }
    }

    $criteria = @($criteria | Select-Object -Unique)
    if ($criteria.Count -eq 0) {
        $criteria = @('Требование не удалось выделить автоматически — проверь импорт Jira.')
    }

    return [pscustomobject]@{
        Key = $key
        Title = $title
        Module = $module
        Raw = $raw
        CurrentBehavior = @($current | Select-Object -Unique)
        ExpectedBehavior = @($expected | Select-Object -Unique)
        ReproductionSteps = @($repro | Select-Object -Unique)
        Criteria = $criteria
        Automated = $false
        AnalysisSource = $source
        RiskAreas = @($risk)
        QAComment = $qaComment
        ProjectRules = @($projectRules)
        JiraComments = if ($script:LoadedJiraIssue -and $script:LoadedJiraIssue.key -eq $key) { @($script:LoadedJiraIssue.comments) } else { @() }
    }
}


function New-JiraTestPlan($task) {
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("$($task.Key) — $($task.Title)")
    $lines.Add("MODULE: $($task.Module)")
    $lines.Add("ENVIRONMENT: $([string]$jiraEnvironmentCombo.SelectedItem)")
    $lines.Add("ANALYSIS: $($task.AnalysisSource)")
    $lines.Add("JIRA COMMENTS IMPORTED: $(@($task.JiraComments).Count)")
    $lines.Add('')

    if (@($task.CurrentBehavior).Count -gt 0) {
        $lines.Add('CURRENT / BUG BEHAVIOR:')
        foreach ($x in @($task.CurrentBehavior)) { $lines.Add("- $x") }
        $lines.Add('')
    }

    if (@($task.ExpectedBehavior).Count -gt 0) {
        $lines.Add('EXPECTED:')
        foreach ($x in @($task.ExpectedBehavior)) { $lines.Add("- $x") }
        $lines.Add('')
    }

    if (@($task.ReproductionSteps).Count -gt 0) {
        $lines.Add('REPRODUCTION STEPS:')
        $i = 1
        foreach ($x in @($task.ReproductionSteps)) { $lines.Add("$i. $x"); $i++ }
        $lines.Add('')
    }

    $lines.Add('ACCEPTANCE CRITERIA:')
    $i = 1
    foreach ($x in @($task.Criteria)) { $lines.Add("$i. $x"); $i++ }
    $lines.Add('')

    if ($task.QAComment) {
        $lines.Add('QA COMMENT FOR THIS RUN:')
        $lines.Add([string]$task.QAComment)
        $lines.Add('')
    }

    $lines.Add('PLANNED CHECKS:')
    if ($jiraUiCheck.Checked) { $lines.Add('- UI: проверить acceptance criteria в браузере.') }
    if ($jiraApiCheck.Checked) { $lines.Add('- API: проверить связанные запросы и ответы.') }
    if ($jiraNetworkCheck.Checked) { $lines.Add('- Network/Console: проверить ошибки запросов и консоли.') }
    if ($jiraRegressionCheck.Checked) { $lines.Add('- Regression: проверить связанный критический функционал.') }
    $lines.Add('')

    $automationStatus = if ($task.Automated) {
        'AUTOMATION STATUS: TASK-SPEC READY'
    }
    else {
        'AUTOMATION STATUS: TASK-SPEC NOT READY'
    }
    $lines.Add($automationStatus)
    return ($lines -join "`r`n")
}

function Save-JiraRunArtifacts($task, [string]$plan) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $safeKey = ($task.Key -replace '[^A-Za-z0-9_-]', '_')
    $dir = Join-Path $script:ProjectRoot "jira-runs\$stamp-$safeKey"
    New-Item -ItemType Directory -Path $dir -Force | Out-Null

    $criteria = @($task.Criteria)
    $obj = [ordered]@{
        key = $task.Key
        title = $task.Title
        module = $task.Module
        environment = [string]$jiraEnvironmentCombo.SelectedItem
        automated = [bool]$task.Automated
        ui = [bool]$jiraUiCheck.Checked
        api = [bool]$jiraApiCheck.Checked
        regression = [bool]$jiraRegressionCheck.Checked
        networkConsole = [bool]$jiraNetworkCheck.Checked
        acceptanceCriteria = $criteria
        analysisSource = $task.AnalysisSource
        riskAreas = @($task.RiskAreas)
        qaComment = $task.QAComment
        projectRules = @($task.ProjectRules)
        source = $task.Raw
        createdAt = (Get-Date).ToString('o')
    }
    $obj | ConvertTo-Json -Depth 8 | Set-Content -Path (Join-Path $dir 'task.json') -Encoding UTF8
    $plan | Set-Content -Path (Join-Path $dir 'plan.txt') -Encoding UTF8
    $script:LastJiraRunDir = $dir
    return $dir
}

function Add-JiraRegressionCandidate {
    if (-not $script:CurrentJiraTask -or -not $script:LastJiraPlan) { return }
    $moduleName = ([string]$script:CurrentJiraTask.Module -replace '[^A-Za-z0-9_-]','-').ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($moduleName)) { $moduleName = 'unknown' }
    $dir = Join-Path $script:ProjectRoot ("scenarios\\$moduleName")
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $key = ([string]$script:CurrentJiraTask.Key -replace '[^A-Za-z0-9_.-]', '_')
    $path = Join-Path $dir "$key.json"
    $obj = [ordered]@{
        id = $key
        sourceJira = $script:CurrentJiraTask.Key
        title = $script:CurrentJiraTask.Title
        module = $script:CurrentJiraTask.Module
        acceptanceCriteria = @($script:CurrentJiraTask.Criteria)
        riskAreas = @($script:CurrentJiraTask.RiskAreas)
        projectRules = @($script:CurrentJiraTask.ProjectRules)
        status = 'regression-candidate'
        automated = [bool]$script:CurrentJiraTask.Automated
        addedAt = (Get-Date).ToString('o')
    }
    $obj | ConvertTo-Json -Depth 8 | Set-Content -Path $path -Encoding UTF8
    $jiraTaskStatus.Text = "Regression scenario сохранён: scenarios/$moduleName/$key.json"
    $jiraTaskStatus.ForeColor = [System.Drawing.Color]::FromArgb(37, 99, 235)
    Refresh-KnowledgeUI
}


function Complete-JiraRun {
    if (-not $script:JiraRunActive) { return }

    # Keep JiraRunActive true while RCA runs so logs continue to mirror to Jira tab.
    if ($script:LastSummary) {
        $s = $script:LastSummary
        $jiraPassValue.Text = [string]$s.Pass
        $jiraFailValue.Text = [string]$s.Fail
        $jiraSkipValue.Text = [string]$s.Skip

        $triage = $null
        if ($s.Fail -gt 0) {
            $jiraTaskStatus.Text = "FAIL — анализирую причину падения…"
            $jiraTaskStatus.ForeColor = [System.Drawing.Color]::Firebrick
            [System.Windows.Forms.Application]::DoEvents()

            $triage = Invoke-SmartFailureTriage -Summary $s

            if ($triage) {
                $isAutomationOnly = (
                    ([string]$triage.classification).ToUpperInvariant() -eq 'TEST_AUTOMATION_BUG' -and
                    $script:AgentMcpExecution -and
                    ([string]$script:AgentMcpExecution.status).ToUpperInvariant() -eq 'PASS'
                )

                if ($isAutomationOnly) {
                    $jiraTaskStatus.Text = "PRODUCT PASS — ошибка deterministic автотеста: $($triage.summary)"
                    $jiraTaskStatus.ForeColor = [System.Drawing.Color]::FromArgb(161,98,7)
                    Append-AgentLog 'PRODUCT RESULT → PASS from live Smart QA; deterministic Playwright failure classified as TEST_AUTOMATION_BUG.'
                }
                else {
                    $jiraTaskStatus.Text = "FAIL — $($triage.classification): $($triage.summary)"
                    $jiraTaskStatus.ForeColor = [System.Drawing.Color]::Firebrick
                }

                $script:LastJiraPlan += "`r`n`r`nSMART FAILURE TRIAGE:`r`n"
                $script:LastJiraPlan += "Classification: $($triage.classification)`r`n"
                $script:LastJiraPlan += "Confidence: $($triage.confidence)`r`n"
                $script:LastJiraPlan += "Summary: $($triage.summary)`r`n"
                $script:LastJiraPlan += "Action: $($triage.recommendedAction)`r`n"
                $jiraPlanBox.Text = $script:LastJiraPlan
            }
            else {
                $jiraTaskStatus.Text = "FAIL — $($s.Fail) сценариев; RCA недоступен"
                $jiraTaskStatus.ForeColor = [System.Drawing.Color]::Firebrick
            }
        }
        else {
            $jiraTaskStatus.Text = 'PASS — Smart QA + Playwright завершены'
            $jiraTaskStatus.ForeColor = [System.Drawing.Color]::FromArgb(32,120,72)
        }

        if ($script:LastJiraRunDir) {
            $resultObj = [ordered]@{
                pass = $s.Pass
                fail = $s.Fail
                skip = $s.Skip
                total = $s.Total
                failed = @($s.Failed)
                rootCause = if ($triage) { $triage } else { $null }
                finishedAt = (Get-Date).ToString('o')
            }
            $resultObj | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $script:LastJiraRunDir 'result.json') -Encoding UTF8
        }

        Save-JiraKnowledgeCase $script:CurrentJiraTask $script:LastJiraPlan $s
        [void](Save-JiraReadableReport)
    }

    $notifyResult = Get-JiraProductNotificationResult
    if ($notifyResult -eq 'PASS') {
        $taskKey = if ($script:CurrentJiraTask) { [string]$script:CurrentJiraTask.Key } else { 'Jira task' }
        Show-QAResultToast `
            -Result PASS `
            -Title '✓ PASS' `
            -Details "$taskKey — проверка продукта успешно завершена."
    }
    elseif ($notifyResult -eq 'FAIL') {
        $taskKey = if ($script:CurrentJiraTask) { [string]$script:CurrentJiraTask.Key } else { 'Jira task' }
        $failDetails = if ($script:FailureTriage -and $script:FailureTriage.summary) {
            [string]$script:FailureTriage.summary
        } else {
            "$taskKey — проверка завершилась с ошибкой."
        }

        if ($failDetails.Length -gt 105) {
            $failDetails = $failDetails.Substring(0, 102) + '...'
        }

        Show-QAResultToast `
            -Result FAIL `
            -Title '✕ FAIL' `
            -Details "$taskKey — $failDetails"
    }

    $jiraCopyReportButton.Enabled = $true
    $jiraRegressionButton.Enabled = $true

    $script:JiraRunActive = $false

    # The browser stayed alive for potential MCP failure triage. Respect the user's
    # original preference only after the full Smart QA lifecycle is finished.
    if (-not $keepBrowserOpenCheck.Checked) {
        Stop-PersistentBrowserSession
        Append-AgentLog 'BROWSER SESSION → closed after Smart QA + RCA completion.'
    }
    else {
        Append-AgentLog 'BROWSER SESSION → left open by user preference.'
    }
}

function Invoke-SmartFailureTriage {
    param($Summary)

    if (-not $script:CurrentJiraTask -or -not $Summary -or $Summary.Fail -le 0) {
        return $null
    }

    Set-AgentStatus -Agent FailureTriage -State RUNNING -Details 'классифицирую падение'

    $resultsFile = Join-Path $script:ProjectRoot 'reports\results.json'
    $resultsText = ''
    if (Test-Path $resultsFile) {
        try {
            $resultsText = Get-Content -Raw -Path $resultsFile
            if ($resultsText.Length -gt 50000) {
                $resultsText = $resultsText.Substring(0,50000) + "`n[TRUNCATED]"
            }
        } catch {}
    }

    $runLogTail = ''
    if ($script:LogFile -and (Test-Path $script:LogFile)) {
        $runLogTail = Get-LogTail -Path $script:LogFile -MaxLines 120
    }

    $mcpJson = if ($script:AgentMcpExecution) {
        $script:AgentMcpExecution | ConvertTo-Json -Depth 16
    } else { '{}' }

    $browserStackStatus = if (Test-BrowserStackMcpConfigured) {
        'CONFIGURED. Use BrowserStack MCP only if a BrowserStack session/build id is actually present in the run artifacts.'
    } else {
        'NOT CONFIGURED. Perform local RCA from Playwright artifacts + live browser.'
    }

    $prompt = @"
You are the Rx2GO FAILURE TRIAGE AGENT.
The final Playwright run failed. Classify WHY before anyone changes the test or files a product bug.

You have Microsoft Playwright MCP connected to the SAME browser session if it is still alive.
Use it to inspect the current page, visible state, console and relevant network evidence when useful.
Do not mutate product data during triage.

BrowserStack MCP: $browserStackStatus

OUTPUT LANGUAGE:
- Return all human-readable diagnosis fields in Russian.
- Preserve literal exception text, selectors, URLs, filenames and technical identifiers when quoting evidence.

Return ONLY valid JSON:
{
  "classification": "PRODUCT_BUG|TEST_AUTOMATION_BUG|AUTH_ERROR|TEST_DATA_ERROR|ENVIRONMENT_ERROR|FLAKY|UNKNOWN",
  "confidence": "HIGH|MEDIUM|LOW",
  "summary": "short root cause",
  "evidence": ["specific evidence"],
  "failedAt": "exact step/assertion if known",
  "productBehavior": "what product actually did",
  "testProblem": "test defect if any",
  "recommendedAction": "next action",
  "browserStackUsed": false
}

JIRA TASK:
$($script:CurrentJiraTask.Key) — $($script:CurrentJiraTask.Title)

TASK SCREENSHOTS:
$(Get-JiraScreenshotPromptSummary)
If attached, use them only as visual task context; runtime Playwright/MCP evidence decides the failure classification.

ACCEPTANCE:
$(@($script:CurrentJiraTask.Criteria) -join "`n- ")

PRE-RUN LIVE MCP EXECUTION:
$mcpJson

PLAYWRIGHT SUMMARY:
PASS=$($Summary.Pass) FAIL=$($Summary.Fail) SKIP=$($Summary.Skip)
FAILED TESTS:
$(@($Summary.Failed) -join "`n- ")

PLAYWRIGHT RESULTS.JSON:
$resultsText

RUN LOG TAIL:
$runLogTail

RULES:
- Do not automatically call every FAIL a product bug.
- Distinguish bad selector/assertion, auth, missing test data, environment/network and genuine product behavior.
- Prefer concrete runtime evidence over assumptions.
- Never expose credentials/tokens/cookies.
- Do not modify files; return diagnosis only.
"@

    $raw = Invoke-CodexAgent `
        -AgentSlug '04-failure-triage' `
        -Prompt $prompt `
        -TimeoutSec 420 `
        -ReasoningEffort 'medium' `
        -ImagePaths (Get-JiraScreenshotPaths)

    if (-not $raw) {
        Set-AgentStatus -Agent FailureTriage -State FAIL -Details $script:LastAgentError
        return $null
    }

    $parsed = Convert-AgentJson $raw
    if (-not $parsed) {
        Set-AgentStatus -Agent FailureTriage -State FAIL -Details $script:LastAgentError
        return $null
    }

    $script:FailureTriage = $parsed
    Set-AgentStatus -Agent FailureTriage -State PASS -Details ([string]$parsed.classification)

    Append-AgentLog "RCA CLASSIFICATION → $($parsed.classification) | confidence $($parsed.confidence)"
    Append-AgentLog "RCA SUMMARY → $($parsed.summary)"
    Append-AgentLog "RCA ACTION → $($parsed.recommendedAction)"

    if ($script:LastJiraRunDir) {
        $raw | Set-Content -Path (Join-Path $script:LastJiraRunDir 'failure-triage.json') -Encoding UTF8
    }

    return $parsed
}

function Show-AgentPipelineFailure {
    param([string]$Stage,[string]$Reason)
    if ([string]::IsNullOrWhiteSpace($Reason)) { $Reason = 'Unknown agent error' }
    Append-AgentLog "PIPELINE STOPPED at $Stage"
    Append-AgentLog $Reason
    if ($script:LastAgentLogFile) {
        Append-AgentLog "LAST AGENT LOG: $($script:LastAgentLogFile)"
        $tail = Get-LogTail -Path $script:LastAgentLogFile -MaxLines 18
        if ($tail) { Append-AgentLog '--- last log lines ---'; Append-AgentLog $tail }
    }
    if ($script:JiraGenerationLog) { Append-AgentLog "VALIDATION LOG: $($script:JiraGenerationLog)" }
}




function Test-RunRequiresFreshData {
    param(
        $Task,
        [string]$QaComment
    )

    if (-not $jiraMutatingCheck.Checked) { return $false }

    $parts = New-Object System.Collections.Generic.List[string]

    if (-not [string]::IsNullOrWhiteSpace([string]$QaComment)) {
        $parts.Add([string]$QaComment)
    }

    if ($Task -and -not [string]::IsNullOrWhiteSpace([string]$Task.Raw)) {
        $parts.Add([string]$Task.Raw)
    }

    $combined = ($parts -join "`n")
    if ([string]::IsNullOrWhiteSpace($combined)) { return $false }

    $lines = @(
        $combined -split "`r?`n" |
            ForEach-Object { ([string]$_).Trim() } |
            Where-Object { $_ }
    )

    foreach ($line in $lines) {
        $lower = $line.ToLowerInvariant()

        # CONDITIONAL constraints are NOT data-creation instructions.
        # Examples:
        #   "при создании ордера Client ID должен быть 219208881"
        #   "если потребуется создать ордер, использовать ..."
        #   "when creating an order, use client ..."
        #
        # These rules apply only if another part of the scenario actually requires
        # creation. They must not stop the pipeline when the acceptance can be proven
        # read-only.
        if (
            $lower -match '^\s*при\s+создани[ияи]\b' -or
            $lower -match '^\s*если\s+.*\b(созда|create)' -or
            $lower -match '^\s*в\s+случае\s+создани[ияи]\b' -or
            $lower -match '^\s*(when|if)\s+.*\b(creat|creating)\b'
        ) {
            continue
        }

        # Explicit imperative / requirement to create fresh test data.
        $explicitCreate = (
            $lower -match '(^|[\s:;,.!?-])(создать|создай|создайте|создаём|создаем|нужно\s+создать|необходимо\s+создать|требуется\s+создать)\b' -or
            $lower -match '\b(create|create a|create an|create new|create fresh|must create|required to create|need to create)\b'
        )

        if (-not $explicitCreate) {
            continue
        }

        # Require that the creation command is about test/product entities rather
        # than generic prose.
        $mentionsEntity = (
            $lower -match '\b(тикет|тикеты|ticket|tickets|ордер|ордера|order|orders|заказ|заказы|route|маршрут|driver|водител|vendor|client|клиент)\b'
        )

        if ($mentionsEntity) {
            return $true
        }
    }

    return $false
}

function Test-McpFreshDataSatisfied {
    param(
        $Task,
        $McpExecution,
        [string]$QaComment
    )

    if (-not (Test-RunRequiresFreshData -Task $Task -QaComment $QaComment)) {
        return $true
    }

    if (-not $McpExecution -or -not $McpExecution.testData) {
        $script:LastAgentError = 'Fresh test data is required, but MCP QA returned no testData evidence.'
        return $false
    }

    $created = [bool]$McpExecution.testData.created
    $entities = @($McpExecution.testData.entities | Where-Object { $_ -and $_.id })

    if (-not $created -or $entities.Count -eq 0) {
        $script:LastAgentError = 'Fresh test data is required by Jira/QA comment, but MCP QA did not create and return run-scoped entities.'
        return $false
    }

    return $true
}

function Start-JiraTaskCheck {
    if ($script:RunningProcess -and -not $script:RunningProcess.HasExited) { return }

    Reset-AgentStatuses

    $rawInput = $jiraTaskBox.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($rawInput)) {
        [System.Windows.Forms.MessageBox]::Show('Вставь Jira key или ссылку.', 'Rx2GO QA', 'OK', 'Warning') | Out-Null
        return
    }

    if (-not $script:ChatGPTConnected) {
        [System.Windows.Forms.MessageBox]::Show(
            'Для Smart QA сначала подключи ChatGPT/Codex.',
            'Rx2GO QA',
            'OK',
            'Warning'
        ) | Out-Null
        return
    }

    if (-not $script:CodexRunnerVerified) {
        $jiraTaskStatus.Text = 'Проверяю Codex agent runner…'
        $jiraTaskStatus.ForeColor = [System.Drawing.Color]::FromArgb(37,99,235)
        [System.Windows.Forms.Application]::DoEvents()

        if (-not (Test-CodexAgentRunner)) {
            $jiraTaskStatus.Text = "Codex self-test failed: $($script:LastAgentError)"
            $jiraTaskStatus.ForeColor = [System.Drawing.Color]::Firebrick
            [System.Windows.Forms.MessageBox]::Show(
                "Codex runner не прошёл self-test.`r`n`r`n$($script:LastAgentError)`r`n`r`nСмотри reports\ai\agents\SELFTEST.",
                'Rx2GO QA — Codex',
                'OK',
                'Error'
            ) | Out-Null
            return
        }
        $script:CodexRunnerVerified = $true
    }

    if (-not (Ensure-PlaywrightDependencies)) {
        $jiraTaskStatus.Text = "Playwright precheck failed: $($script:LastAgentError)"
        $jiraTaskStatus.ForeColor = [System.Drawing.Color]::Firebrick
        return
    }

    if (-not (Ensure-PlaywrightMcpForCodex)) {
        $jiraTaskStatus.Text = "Playwright MCP precheck failed: $($script:LastAgentError)"
        $jiraTaskStatus.ForeColor = [System.Drawing.Color]::Firebrick
        [System.Windows.Forms.MessageBox]::Show(
            "Microsoft Playwright MCP не подключён к Codex.`r`n`r`n$($script:LastAgentError)`r`n`r`nSmart QA не будет продолжать тест вслепую.",
            'Rx2GO QA — Playwright MCP',
            'OK',
            'Error'
        ) | Out-Null
        return
    }

    $issueKey = Get-JiraIssueKey $rawInput
    $jiraIssue = $null

    if ($issueKey) {
        if ($script:LoadedJiraIssue -and $script:LoadedJiraIssueKey -eq $issueKey) {
            $jiraIssue = $script:LoadedJiraIssue
        }
        else {
            $script:JiraFetchedSource = $null
            $jiraIssue = Get-JiraIssueFromApi $issueKey
            if ($jiraIssue) {
                $script:LoadedJiraIssue = $jiraIssue
                $script:LoadedJiraIssueKey = $issueKey
                Move-AdhocScreenshotsToIssue -IssueKey $issueKey
                Restore-JiraScreenshotsForIssue -IssueKey $issueKey
                $jiraImportedBox.Text = Format-JiraIssueForPreview $jiraIssue
                $jiraImportedInfo.Text = "$issueKey загружена • Jira comments: $(@($jiraIssue.comments).Count)"
            }
        }

        if (-not $jiraIssue) {
            [System.Windows.Forms.MessageBox]::Show(
                "Не удалось загрузить $issueKey через Jira API.`r`n`r`n$($script:JiraFetchedSource)",
                'Rx2GO QA','OK','Error'
            ) | Out-Null
            return
        }
    }

    $qaComment = $jiraQaCommentBox.Text.Trim()
    $projectRules = @(Get-Rx2GOProjectRules)
    $analysisText = if ($jiraIssue) { Convert-JiraIssueToAnalysisText $jiraIssue } else { $rawInput }

    # 1/3 — Requirements Analyst
    $jiraTaskStatus.Text = '1/3 Requirements Analyst: разбираю Jira…'
    $jiraTaskStatus.ForeColor = [System.Drawing.Color]::FromArgb(37,99,235)
    $aiAnalysis = Invoke-AgentJiraAnalyst `
        -JiraText $analysisText `
        -QaComment $qaComment `
        -ProjectRules $projectRules

    if (-not $aiAnalysis) {
        $jiraTaskStatus.Text = "Requirements Analyst failed: $($script:LastAgentError)"
        $jiraTaskStatus.ForeColor = [System.Drawing.Color]::Firebrick
        Show-AgentPipelineFailure -Stage '1/3 — Requirements Analyst' -Reason $script:LastAgentError
        return
    }

    $task = Get-JiraTaskInfo $analysisText $aiAnalysis $qaComment $projectRules
    $script:CurrentJiraTask = $task
    $jiraModuleValue.Text = $task.Module
    $jiraAutomationValue.Text = 'SMART QA RUNNING'
    $jiraAutomationValue.ForeColor = [System.Drawing.Color]::FromArgb(37,99,235)
    $jiraPlanBox.Text = New-JiraTestPlan $task
    [System.Windows.Forms.Application]::DoEvents()

    # Bootstrap ONE authenticated Chrome only.
    # Do NOT run the old Live Browser Context diagnostic here: MCP itself
    # owns live page discovery and must work against this exact persistent session.
    $jiraTaskStatus.Text = 'Browser bootstrap: авторизация и запуск одной Chrome-сессии…'
    if (-not (Bootstrap-PersistentBrowserSession -Environment ([string]$jiraEnvironmentCombo.SelectedItem))) {
        $jiraAutomationValue.Text = 'BROWSER BOOTSTRAP FAILED'
        $jiraAutomationValue.ForeColor = [System.Drawing.Color]::Firebrick
        $jiraTaskStatus.Text = "Browser bootstrap failed: $($script:LastAgentError)"
        $jiraTaskStatus.ForeColor = [System.Drawing.Color]::Firebrick

        Append-AgentLog 'PIPELINE STOPPED before MCP preflight.'
        Append-AgentLog 'Chrome is intentionally NOT killed on bootstrap failure when a session was created.'

        [System.Windows.Forms.MessageBox]::Show(
            "Browser bootstrap не завершён.`r`n`r`n$($script:LastAgentError)`r`n`r`nЕсли Chrome успел открыться, он оставлен открытым для проверки.",
            'Rx2GO QA — Browser bootstrap',
            'OK',
            'Error'
        ) | Out-Null

        return
    }

    if (-not (Can-ReusePersistentBrowserSession -Environment ([string]$jiraEnvironmentCombo.SelectedItem))) {
        $script:LastAgentError = 'Authenticated persistent Chrome session is not available after bootstrap.'
        $jiraTaskStatus.Text = $script:LastAgentError
        $jiraTaskStatus.ForeColor = [System.Drawing.Color]::Firebrick
        return
    }

    Append-AgentLog "PLAYWRIGHT MCP → will attach to SAME Chrome via $($script:PersistentCdpEndpoint)"

    # Verify both missing pieces that caused v0.12.0 to silently block:
    # (1) dynamic CDP endpoint forwarding and (2) MCP tool auto-approval.
    if (-not (Invoke-PlaywrightMcpSessionPreflight -Environment ([string]$jiraEnvironmentCombo.SelectedItem))) {
        $jiraAutomationValue.Text = 'MCP SESSION FAILED'
        $jiraAutomationValue.ForeColor = [System.Drawing.Color]::Firebrick
        $jiraTaskStatus.Text = "Playwright MCP session failed: $($script:LastAgentError)"
        $jiraTaskStatus.ForeColor = [System.Drawing.Color]::Firebrick
        Show-AgentPipelineFailure -Stage 'Playwright MCP session preflight' -Reason $script:LastAgentError

        if (Can-ReusePersistentBrowserSession -Environment ([string]$jiraEnvironmentCombo.SelectedItem)) {
            Append-AgentLog "MCP SESSION FAILED → authenticated Chrome intentionally LEFT OPEN: $($script:PersistentCdpEndpoint)"
        }

        return
    }

    # 2/3 — Main live Playwright MCP QA Agent
    $jiraTaskStatus.Text = '2/3 Playwright MCP QA: исследую живой UI, готовлю данные и выполняю acceptance…'
    $mcpExecution = Invoke-AgentMcpQa `
        -Task $task `
        -JiraText $analysisText `
        -QaComment $qaComment `
        -ProjectRules $projectRules

    if (-not $mcpExecution) {
        $jiraAutomationValue.Text = 'MCP QA FAILED'
        $jiraAutomationValue.ForeColor = [System.Drawing.Color]::Firebrick
        $jiraTaskStatus.Text = "Playwright MCP QA failed: $($script:LastAgentError)"
        $jiraTaskStatus.ForeColor = [System.Drawing.Color]::Firebrick
        Show-AgentPipelineFailure -Stage '2/3 — Playwright MCP QA' -Reason $script:LastAgentError
        return
    }

    if (([string]$mcpExecution.status).ToUpperInvariant() -eq 'BLOCKED') {
        $task.Automated = $false
        $jiraAutomationValue.Text = 'BLOCKED — TEST DATA/UI'
        $jiraAutomationValue.ForeColor = [System.Drawing.Color]::FromArgb(197,119,0)
        $jiraTaskStatus.Text = "BLOCKED: $($script:LastAgentError)"
        $jiraTaskStatus.ForeColor = [System.Drawing.Color]::FromArgb(197,119,0)
        $jiraPlanBox.AppendText((New-SmartPipelineSummary -McpExecution $mcpExecution))
        $jiraCopyReportButton.Enabled = $true
        return
    }

    $freshDataRequired = Test-RunRequiresFreshData -Task $task -QaComment $qaComment
    Append-AgentLog "FRESH DATA POLICY → $(if ($freshDataRequired) { 'REQUIRED' } else { 'OPTIONAL / NOT REQUIRED' })"

    if (-not (Test-McpFreshDataSatisfied -Task $task -McpExecution $mcpExecution -QaComment $qaComment)) {
        $task.Automated = $false
        $jiraAutomationValue.Text = 'BLOCKED — FRESH TEST DATA REQUIRED'
        $jiraAutomationValue.ForeColor = [System.Drawing.Color]::FromArgb(197,119,0)
        $jiraTaskStatus.Text = "BLOCKED: $($script:LastAgentError)"
        $jiraTaskStatus.ForeColor = [System.Drawing.Color]::FromArgb(197,119,0)
        Append-AgentLog "FRESH DATA GUARD → BLOCKED | $($script:LastAgentError)"
        $jiraCopyReportButton.Enabled = $true
        return
    }

    # 3/3 — Reviewer turns proven live evidence into deterministic Playwright.
    $jiraTaskStatus.Text = '3/3 QA Reviewer: собираю Playwright из реальных действий MCP…'
    $generatedSpec = Invoke-AgentSmartReviewer `
        -Task $task `
        -McpExecution $mcpExecution `
        -McpExecutionRaw $script:AgentMcpExecutionRaw `
        -QaComment $qaComment `
        -ProjectRules $projectRules

    if (-not $generatedSpec) {
        $task.Automated = $false
        $script:JiraGeneratedSpec = $null
        $script:TestPathOverride = $null
        $jiraAutomationValue.Text = 'SMART QA GENERATION FAILED'
        $jiraAutomationValue.ForeColor = [System.Drawing.Color]::Firebrick

        $reason = if ($script:JiraGenerationError) { $script:JiraGenerationError }
                  elseif ($script:LastAgentError) { $script:LastAgentError }
                  else { 'Unknown Smart QA generation error' }

        $jiraPlanBox.AppendText("`r`n`r`nSMART QA ERROR:`r`n$reason")
        if ($script:JiraGenerationLog) { $jiraPlanBox.AppendText("`r`nLOG: $($script:JiraGenerationLog)") }
        if ($script:AgentRunDir) { $jiraPlanBox.AppendText("`r`nAGENT OUTPUTS: $($script:AgentRunDir)") }

        $jiraTaskStatus.Text = "Тест не сформирован: $reason"
        $jiraTaskStatus.ForeColor = [System.Drawing.Color]::Firebrick
        Show-AgentPipelineFailure -Stage '3/3 — QA Reviewer' -Reason $reason
        $jiraCopyReportButton.Enabled = $true
        return
    }

    $task.Automated = $true
    $script:JiraGeneratedSpec = $generatedSpec
    $script:TestPathOverride = $generatedSpec

    $jiraAutomationValue.Text = '3/3 SMART QA READY'
    $jiraAutomationValue.ForeColor = [System.Drawing.Color]::FromArgb(32,120,72)

    $plan = New-JiraTestPlan $task
    $plan += New-SmartPipelineSummary -McpExecution $mcpExecution
    $plan += "`r`n`r`nTASK-SPECIFIC PLAYWRIGHT:`r`n$generatedSpec"
    if ($script:AgentRunDir) { $plan += "`r`nAGENT ARTIFACTS:`r`n$($script:AgentRunDir)" }
    if ($script:LivePageContextFile) { $plan += "`r`nBROWSER BOOTSTRAP SNAPSHOT:`r`n$($script:LivePageContextFile)" }

    $script:LastJiraPlan = $plan
    $jiraPlanBox.Text = $plan

    [void](Save-JiraRunArtifacts $task $plan)
    Save-JiraKnowledgeCase $task $plan $null

    $jiraPassValue.Text = '0'
    $jiraFailValue.Text = '0'
    $jiraSkipValue.Text = '0'
    $jiraRegressionButton.Enabled = $true
    $jiraCopyReportButton.Enabled = $false

    $environmentCombo.SelectedItem = [string]$jiraEnvironmentCombo.SelectedItem
    $suiteCombo.SelectedItem = 'Все тесты'
    $headedCheck.Checked = $true
    $mutatingCheck.Checked = $jiraMutatingCheck.Checked

    $script:JiraRunActive = $true
    Append-AgentLog "3/3 SMART QA READY → final Playwright reuses SAME Chrome for $($task.Key)"
    $jiraTaskStatus.Text = "3/3 Smart QA готов → запускаю deterministic Playwright…"
    $jiraTaskStatus.ForeColor = [System.Drawing.Color]::FromArgb(197,119,0)
    Start-QATest
}


function Get-JiraReportFacility {
    if ($script:CurrentJiraTask -and
        -not [string]::IsNullOrWhiteSpace([string]$script:CurrentJiraTask.QAComment)) {

        $comment = [string]$script:CurrentJiraTask.QAComment
        if ($comment -match '(?i)гавай|hawaii') { return 'Hawaii' }
        if ($comment -match '(?i)new york|нью[- ]?йорк') { return 'New York' }
        if ($comment -match '(?i)los angeles|лос[- ]?анджелес') { return 'Los Angeles' }
        if ($comment -match '(?i)florida|флорида') { return 'Florida' }
    }

    return '—'
}



function Show-QAResultToast {
    param(
        [ValidateSet('PASS','FAIL')]
        [string]$Result,
        [string]$Title = '',
        [string]$Details = '',
        [int]$DurationMs = 6500
    )

    try {
        $isPass = ($Result -eq 'PASS')

        if ($isPass) {
            try { [System.Media.SystemSounds]::Asterisk.Play() } catch {}
        }
        else {
            try { [System.Media.SystemSounds]::Hand.Play() } catch {}
        }

        $toast = New-Object System.Windows.Forms.Form
        $toast.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
        $toast.ShowInTaskbar = $false
        $toast.TopMost = $true
        $toast.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
        $toast.Size = New-Object System.Drawing.Size(410, 125)
        $toast.Padding = New-Object System.Windows.Forms.Padding(18, 14, 18, 14)
        $toast.Cursor = [System.Windows.Forms.Cursors]::Hand

        if ($isPass) {
            $toast.BackColor = [System.Drawing.Color]::FromArgb(22, 163, 74)
        }
        else {
            $toast.BackColor = [System.Drawing.Color]::FromArgb(220, 38, 38)
        }

        # Use the screen containing the Launcher when possible, otherwise primary.
        $targetScreen = if ($form -and $form.Visible) {
            [System.Windows.Forms.Screen]::FromControl($form)
        }
        else {
            [System.Windows.Forms.Screen]::PrimaryScreen
        }

        $workArea = $targetScreen.WorkingArea
        $margin = 18

        $toast.Location = New-Object System.Drawing.Point(
            ($workArea.Right - $toast.Width - $margin),
            ($workArea.Bottom - $toast.Height - $margin)
        )

        $titleLabel = New-Object System.Windows.Forms.Label
        $titleLabel.AutoSize = $false
        $titleLabel.Location = New-Object System.Drawing.Point(18, 13)
        $titleLabel.Size = New-Object System.Drawing.Size(370, 34)
        $titleLabel.Font = New-Object System.Drawing.Font(
            'Segoe UI',
            16,
            [System.Drawing.FontStyle]::Bold
        )
        $titleLabel.ForeColor = [System.Drawing.Color]::White
        $titleLabel.BackColor = [System.Drawing.Color]::Transparent
        $titleLabel.Cursor = [System.Windows.Forms.Cursors]::Hand
        $titleLabel.Text = if ($Title) {
            $Title
        }
        elseif ($isPass) {
            '✓ TEST PASSED'
        }
        else {
            '✕ TEST FAILED'
        }

        $detailsLabel = New-Object System.Windows.Forms.Label
        $detailsLabel.AutoSize = $false
        $detailsLabel.Location = New-Object System.Drawing.Point(20, 52)
        $detailsLabel.Size = New-Object System.Drawing.Size(365, 56)
        $detailsLabel.Font = New-Object System.Drawing.Font(
            'Segoe UI',
            10,
            [System.Drawing.FontStyle]::Regular
        )
        $detailsLabel.ForeColor = [System.Drawing.Color]::White
        $detailsLabel.BackColor = [System.Drawing.Color]::Transparent
        $detailsLabel.Cursor = [System.Windows.Forms.Cursors]::Hand
        $detailsLabel.Text = if ($Details) {
            $Details
        }
        elseif ($isPass) {
            'Проверка завершена успешно.'
        }
        else {
            'Проверка завершилась с ошибкой.'
        }

        $toast.Controls.Add($titleLabel)
        $toast.Controls.Add($detailsLabel)

        # Robust close: derive the owning form from the clicked sender.
        # No dependency on a local $toast closure in a later PowerShell event scope.
        $closeToast = {
            param($sender, $eventArgs)

            try {
                $ownerForm = $null

                if ($sender -is [System.Windows.Forms.Form]) {
                    $ownerForm = $sender
                }
                elseif ($sender -is [System.Windows.Forms.Control]) {
                    $ownerForm = $sender.FindForm()
                }

                if ($ownerForm -and -not $ownerForm.IsDisposed) {
                    $ownerForm.Close()
                }
            }
            catch {}
        }

        $toast.Add_MouseDown($closeToast)
        $titleLabel.Add_MouseDown($closeToast)
        $detailsLabel.Add_MouseDown($closeToast)

        $timer = New-Object System.Windows.Forms.Timer
        $timer.Interval = [Math]::Max(1500, $DurationMs)
        $timer.Tag = $toast

        $timer.Add_Tick({
            param($sender, $eventArgs)

            try {
                $sender.Stop()
                $ownerForm = $sender.Tag

                if ($ownerForm -and -not $ownerForm.IsDisposed) {
                    $ownerForm.Close()
                }

                $sender.Dispose()
            }
            catch {}
        })

        $toast.Tag = $timer

        $toast.Add_FormClosed({
            param($sender, $eventArgs)

            try {
                $ownedTimer = $sender.Tag

                if ($ownedTimer) {
                    $ownedTimer.Stop()
                    $ownedTimer.Dispose()
                }

                if ($script:ActiveResultToasts) {
                    [void]$script:ActiveResultToasts.Remove($sender)
                }
            }
            catch {}
        })

        if (-not $script:ActiveResultToasts) {
            $script:ActiveResultToasts = New-Object System.Collections.ArrayList
        }

        [void]$script:ActiveResultToasts.Add($toast)

        $timer.Start()
        $toast.Show()
    }
    catch {
        try {
            Append-AgentLog "RESULT TOAST → failed: $($_.Exception.Message)"
        }
        catch {}
    }
}

function Get-JiraProductNotificationResult {
    # Preserve v0.12.6 semantics:
    # live Smart QA PASS + deterministic TEST_AUTOMATION_BUG = product PASS.
    try {
        $overall = Get-JiraReportOverallResult
        if ($overall -eq 'PASS') { return 'PASS' }
        if ($overall -eq 'FAIL') { return 'FAIL' }
    } catch {}

    if ($script:LastSummary) {
        if ($script:LastSummary.Fail -gt 0) { return 'FAIL' }
        if ($script:LastSummary.Pass -gt 0) { return 'PASS' }
    }

    return $null
}

function Get-JiraReportOverallResult {
    # Product acceptance is decided primarily by the live Playwright MCP execution.
    # A deterministic Playwright failure classified as TEST_AUTOMATION_BUG must not
    # turn a successfully verified product task into a false product FAIL.
    if (
        $script:AgentMcpExecution -and
        ([string]$script:AgentMcpExecution.status).ToUpperInvariant() -eq 'PASS' -and
        $script:FailureTriage -and
        ([string]$script:FailureTriage.classification).ToUpperInvariant() -eq 'TEST_AUTOMATION_BUG'
    ) {
        return 'PASS'
    }

    if ($script:LastSummary) {
        if ($script:LastSummary.Fail -gt 0) { return 'FAIL' }
        if ($script:LastSummary.Pass -eq 0 -and $script:LastSummary.Skip -gt 0) { return 'SKIP' }
        return 'PASS'
    }

    if ($script:AgentMcpExecution -and $script:AgentMcpExecution.status) {
        return ([string]$script:AgentMcpExecution.status).ToUpperInvariant()
    }

    return 'BLOCKED'
}

function Get-JiraStatusMark {
    param([string]$Status)

    switch ($Status.ToUpperInvariant()) {
        'PASS' { return '✅ PASS' }
        'FAIL' { return '❌ FAIL' }
        'SKIP' { return '⏭ SKIP' }
        'BLOCKED' { return '⛔ BLOCKED' }
        default { return $Status }
    }
}

function New-JiraTaskReportText {
    if (-not $script:CurrentJiraTask) { return $null }

    $task = $script:CurrentJiraTask
    $mcp = $script:AgentMcpExecution
    $overall = Get-JiraReportOverallResult
    $overallMark = Get-JiraStatusMark $overall
    $date = Get-Date -Format 'dd.MM.yyyy HH:mm'
    $environment = if ($script:LastEnvironment) {
        [string]$script:LastEnvironment
    } else {
        [string]$jiraEnvironmentCombo.SelectedItem
    }
    $facility = Get-JiraReportFacility
    $user = if ($script:InlineAppLoginBox -and
        -not [string]::IsNullOrWhiteSpace([string]$script:InlineAppLoginBox.Text)) {
        [string]$script:InlineAppLoginBox.Text
    } else {
        'sergeyqa'
    }

    $method = 'Smart QA: Codex + Microsoft Playwright MCP + Playwright'

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('*ОТЧЁТ О ТЕСТИРОВАНИИ*')
    $lines.Add('')
    $lines.Add("*Задача:* $($task.Key) — $($task.Title)")
    $lines.Add("*Модуль:* $($task.Module)")
    $lines.Add("*Окружение:* $environment")
    $lines.Add("*Facility:* $facility")
    $lines.Add("*Пользователь:* $user")
    $lines.Add("*Дата:* $date")
    $lines.Add("*Метод:* $method")
    $lines.Add("*Изменение тестовых данных:* $(if ($jiraMutatingCheck.Checked) { 'разрешено' } else { 'запрещено' })")
    $taskScreens = @(Get-JiraScreenshotPaths)
    if ($taskScreens.Count -gt 0) {
        $lines.Add("*Скриншоты задачи:* $($taskScreens.Count) — переданы AI как visual context")
    }
    $lines.Add("*Итог проверки продукта:* $overallMark")

    if ($mcp -and $mcp.status) {
        $liveStatus = ([string]$mcp.status).ToUpperInvariant()
        $lines.Add("*Live Smart QA:* $(Get-JiraStatusMark $liveStatus)")
    }

    if ($script:LastSummary) {
        if ($script:LastSummary.Fail -gt 0 -and $script:FailureTriage) {
            $lines.Add("*Deterministic Playwright:* ⚠️ ERROR — $($script:FailureTriage.classification)")
        }
        elseif ($script:LastSummary.Fail -gt 0) {
            $lines.Add("*Deterministic Playwright:* ❌ FAIL")
        }
        else {
            $lines.Add("*Deterministic Playwright:* ✅ PASS")
        }
    }

    if ($mcp) {
        $lines.Add('')
        $lines.Add('*ВЫПОЛНЕННЫЕ КЕЙСЫ*')

        $caseNo = 1

        # Test-data setup is an executed precondition, not a Jira acceptance criterion.
        if ($mcp.testData -and [bool]$mcp.testData.created) {
            $setupEvidence = New-Object System.Collections.Generic.List[string]

            if (-not [string]::IsNullOrWhiteSpace([string]$mcp.testData.sourceTicketId)) {
                $setupEvidence.Add("source ticket #$($mcp.testData.sourceTicketId)")
            }

            $relatedIds = @($mcp.testData.relatedTicketIds | Where-Object { $_ })
            if ($relatedIds.Count -gt 0) {
                $setupEvidence.Add("related tickets: $($relatedIds -join ', ')")
            }

            $orders = @(
                $mcp.testData.entities |
                    Where-Object { $_ -and ([string]$_.type).ToLowerInvariant() -eq 'order' } |
                    ForEach-Object { [string]$_.id } |
                    Where-Object { $_ } |
                    Select-Object -Unique
            )
            if ($orders.Count -gt 0) {
                $setupEvidence.Add("test order: $($orders -join ', ')")
            }

            $setupText = if ($setupEvidence.Count -gt 0) {
                $setupEvidence -join '; '
            } else {
                'fresh isolated test data created'
            }

            $lines.Add("$caseNo. ✅ PASS — Подготовка свежих тестовых данных")
            $lines.Add("   Результат: $setupText")
            $caseNo++
        }

        foreach ($case in @($mcp.acceptanceResults)) {
            if (-not $case) { continue }

            $status = if ($case.status) {
                ([string]$case.status).ToUpperInvariant()
            } else {
                'BLOCKED'
            }
            $mark = Get-JiraStatusMark $status
            $criterion = if ($case.criterion) {
                [string]$case.criterion
            } else {
                'Acceptance criterion'
            }

            $lines.Add("$caseNo. $mark — $criterion")

            if (-not [string]::IsNullOrWhiteSpace([string]$case.evidence)) {
                $lines.Add("   Проверено: $([string]$case.evidence)")
            }

            $caseNo++
        }

        # If acceptanceResults are missing, fall back to actual browser steps so the
        # Jira report never degrades to an unhelpful PASS counter.
        if (@($mcp.acceptanceResults).Count -eq 0) {
            foreach ($step in @($mcp.executedSteps | Select-Object -First 12)) {
                if ([string]::IsNullOrWhiteSpace([string]$step)) { continue }
                $lines.Add("$caseNo. ✅ Выполнено — $([string]$step)")
                $caseNo++
            }
        }

        if ($script:LastSummary) {
            $lines.Add('')
            $lines.Add('*ФИНАЛЬНЫЙ PLAYWRIGHT*')
            $lines.Add("PASS: $($script:LastSummary.Pass) | FAIL: $($script:LastSummary.Fail) | SKIP: $($script:LastSummary.Skip) | TOTAL: $($script:LastSummary.Total)")

            if ($script:LastSummary.Fail -gt 0) {
                if (
                    $script:FailureTriage -and
                    ([string]$script:FailureTriage.classification).ToUpperInvariant() -eq 'TEST_AUTOMATION_BUG'
                ) {
                    $lines.Add("⚠️ Deterministic spec error; live product acceptance above remains valid.")
                }

                foreach ($failed in @($script:LastSummary.Failed)) {
                    $lines.Add("❌ $failed")
                }
            }
        }
        else {
            $lines.Add('')
            $lines.Add('*ФИНАЛЬНЫЙ PLAYWRIGHT:* ещё не завершён.')
            if ($mcp -and ([string]$mcp.status).ToUpperInvariant() -eq 'PASS') {
                $lines.Add('Live Smart QA уже подтвердил acceptance criteria; deterministic этап не был завершён.')
            }
        }

        $network = @($mcp.networkEvidence | Where-Object { $_ })
        if ($network.Count -gt 0) {
            $lines.Add('')
            $lines.Add('*API / NETWORK*')
            foreach ($item in @($network | Select-Object -First 8)) {
                $lines.Add("- $([string]$item)")
            }
            if ($network.Count -gt 8) {
                $lines.Add("- … ещё $($network.Count - 8) записей в Smart QA artifact")
            }
        }

        $console = @($mcp.consoleEvidence | Where-Object { $_ })
        if ($console.Count -gt 0) {
            $lines.Add('')
            $lines.Add('*CONSOLE*')
            foreach ($item in @($console | Select-Object -First 4)) {
                $lines.Add("- $([string]$item)")
            }
            if ($console.Count -gt 4) {
                $lines.Add("- … ещё $($console.Count - 4) записей в Smart QA artifact")
            }
        }

        $screens = @($mcp.screenshots | Where-Object { $_ })
        if ($screens.Count -gt 0) {
            $lines.Add('')
            $lines.Add('*АРТЕФАКТЫ*')
            foreach ($shot in $screens) {
                $lines.Add("- Screenshot: $([string]$shot)")
            }
        }

        $blockers = @($mcp.blockers | Where-Object { $_ })
        if ($blockers.Count -gt 0) {
            $lines.Add('')
            $lines.Add('*БЛОКЕРЫ*')
            foreach ($b in $blockers) {
                $lines.Add("- $([string]$b)")
            }
        }
    }
    elseif ($script:LastSummary) {
        $lines.Add('')
        $lines.Add('*ВЫПОЛНЕННЫЕ КЕЙСЫ*')
        $lines.Add("Playwright: PASS $($script:LastSummary.Pass) | FAIL $($script:LastSummary.Fail) | SKIP $($script:LastSummary.Skip)")
        foreach ($failed in @($script:LastSummary.Failed)) {
            $lines.Add("❌ FAIL — $failed")
        }
    }
    else {
        $lines.Add('')
        $lines.Add('*ВЫПОЛНЕННЫЕ КЕЙСЫ:* результат выполнения отсутствует.')
    }

    if ($script:FailureTriage) {
        $lines.Add('')
        $lines.Add('*АНАЛИЗ ПРИЧИНЫ ПАДЕНИЯ*')
        $lines.Add("Классификация: $($script:FailureTriage.classification)")
        $lines.Add("Уверенность: $($script:FailureTriage.confidence)")
        $lines.Add("Причина: $($script:FailureTriage.summary)")
        $lines.Add("Следующее действие: $($script:FailureTriage.recommendedAction)")
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$task.QAComment)) {
        $lines.Add('')
        $lines.Add('*QA COMMENT*')
        $lines.Add([string]$task.QAComment)
    }

    $lines.Add('')
    $lines.Add('*Вывод по продукту:* ' + $overallMark)

    return ($lines -join "`r`n")
}

function Save-JiraReadableReport {
    $report = New-JiraTaskReportText
    if ([string]::IsNullOrWhiteSpace($report)) {
        return $null
    }

    $targetDir = if ($script:LastJiraRunDir -and (Test-Path $script:LastJiraRunDir)) {
        $script:LastJiraRunDir
    }
    elseif ($script:AgentRunDir -and (Test-Path $script:AgentRunDir)) {
        $script:AgentRunDir
    }
    else {
        $fallback = Join-Path $script:ProjectRoot 'reports\jira'
        New-Item -ItemType Directory -Path $fallback -Force | Out-Null
        $fallback
    }

    $path = Join-Path $targetDir 'jira-readable-report.txt'
    Write-Utf8NoBomFile -Path $path -Content $report
    $script:LastJiraReportPath = $path
    Append-AgentLog "JIRA REPORT → $path"

    return $path
}


function Copy-JiraTaskReport {
    if (-not $script:CurrentJiraTask) { return }

    $report = New-JiraTaskReportText
    if ([string]::IsNullOrWhiteSpace($report)) { return }

    [void](Save-JiraReadableReport)
    [System.Windows.Forms.Clipboard]::SetText($report)

    $jiraTaskStatus.Text = 'Понятный Jira-отчёт с выполненными кейсами скопирован'
    $jiraTaskStatus.ForeColor = [System.Drawing.Color]::FromArgb(37,99,235)
}

function Set-RunningState([bool]$running) {
    $environmentCombo.Enabled = -not $running
    $suiteCombo.Enabled = -not $running
    $headedCheck.Enabled = -not $running
    $mutatingCheck.Enabled = -not $running
    $dailyPassword.Enabled = (-not $running) -and (Test-GatewayRequired ([string]$environmentCombo.SelectedItem))
    if ($script:GatewayLoginBox) {
        $script:GatewayLoginBox.Enabled = (-not $running) -and (Test-GatewayRequired ([string]$environmentCombo.SelectedItem))
    }
    if ($script:InlineAppPasswordBox) { $script:InlineAppPasswordBox.Enabled = -not $running }
    if ($script:InlineAppLoginBox) { $script:InlineAppLoginBox.Enabled = -not $running }
    if ($script:QuickChatGptButton) { $script:QuickChatGptButton.Enabled = -not $running }
    if ($script:QuickRecheckConnectionsButton) { $script:QuickRecheckConnectionsButton.Enabled = -not $running }
    $credentialButton.Enabled = -not $running
    $runButton.Enabled = -not $running
    $cancelButton.Enabled = $running
    if ($jiraRunButton) { $jiraRunButton.Enabled = -not $running }
    if ($jiraTaskBox) { $jiraTaskBox.Enabled = -not $running }
    if ($jiraQaCommentBox) { $jiraQaCommentBox.Enabled = -not $running }
    if ($jiraScreenshotPasteButton) { $jiraScreenshotPasteButton.Enabled = -not $running }
    if ($jiraScreenshotFilesButton) { $jiraScreenshotFilesButton.Enabled = -not $running }
    if ($jiraScreenshotClearButton) {
        $jiraScreenshotClearButton.Enabled = (-not $running) -and (@(Get-JiraScreenshotPaths).Count -gt 0)
    }
    if ($jiraPersistentRuleBox) { $jiraPersistentRuleBox.Enabled = -not $running }
    if ($jiraSaveRuleButton) { $jiraSaveRuleButton.Enabled = -not $running }
}

function Start-QATest {
    if ($script:RunningProcess -and -not $script:RunningProcess.HasExited) { return }

    $appLogin = 'sergeyqa'
    if ($script:InlineAppLoginBox -and -not [string]::IsNullOrWhiteSpace($script:InlineAppLoginBox.Text)) {
        $appLogin = $script:InlineAppLoginBox.Text.Trim()
    }

    $appPasswordPlain = ''
    if ($script:InlineAppPasswordBox) {
        $appPasswordPlain = [string]$script:InlineAppPasswordBox.Text
    }

    if ([string]::IsNullOrWhiteSpace($appPasswordPlain)) {
        $savedApp = Get-AppCredentialPlain
        if ($savedApp) {
            $appLogin = [string]$savedApp.Login
            $appPasswordPlain = [string]$savedApp.Password
            if ($script:InlineAppPasswordBox) { $script:InlineAppPasswordBox.Text = $appPasswordPlain }
        }
    }

    if ([string]::IsNullOrWhiteSpace($appPasswordPlain)) {
        [System.Windows.Forms.MessageBox]::Show(
            'Введи пароль Rx2GO на этой странице в блоке «Доступ и подключения».',
            'Rx2GO QA',
            'OK',
            'Warning'
        ) | Out-Null
        if ($tabs -and $quickTab) { $tabs.SelectedTab = $quickTab }
        if ($script:InlineAppPasswordBox) { $script:InlineAppPasswordBox.Focus() }
        return
    }

    $app = @{
        Login = $appLogin
        Password = $appPasswordPlain
    }

    # The page is the source of truth. Persist the current Rx2GO password safely.
    [void](Save-AppCredential -Silent)

    $envName = [string]$environmentCombo.SelectedItem
    if ((Test-GatewayRequired $envName) -and [string]::IsNullOrWhiteSpace($dailyPassword.Text)) {
        [System.Windows.Forms.MessageBox]::Show('Введи суточный пароль из Telegram в блоке «Доступ и подключения». Логин admin уже указан.', 'Rx2GO QA', 'OK', 'Warning') | Out-Null
        $dailyPassword.Focus()
        return
    }

    $suiteName = [string]$suiteCombo.SelectedItem
    $testTarget = switch ($suiteName) {
        'Smoke' { 'tests/smoke' }
        'Tickets Queue' { 'tests/tickets' }
        'Все тесты' { '' }
    }

    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $logsDir = Join-Path $script:ProjectRoot 'reports\launcher'
    New-Item -ItemType Directory -Path $logsDir -Force | Out-Null
    $script:LogFile = Join-Path $logsDir "run-$timestamp.log"
    $script:LastLogLength = 0
    $script:ExitHandled = $false
    $script:LastEnvironment = $envName
    $script:LastSuite = $suiteName
    $script:LastStartedAt = Get-Date
    Reset-ResultPanel
    $previousResults = Join-Path $script:ProjectRoot 'reports\results.json'
    Remove-Item $previousResults -Force -ErrorAction SilentlyContinue

    $suiteKey = switch ($suiteName) {
        'Smoke' { 'smoke' }
        'Tickets Queue' { 'tickets' }
        'Все тесты' { 'all' }
    }
    $runnerScript = Join-Path $script:ProjectRoot 'scripts\run-tests.ps1'
    if (-not (Test-Path $runnerScript)) {
        [System.Windows.Forms.MessageBox]::Show('Не найден scripts\run-tests.ps1. Распакуй архив полностью в обычную папку и запусти снова.', 'Rx2GO QA', 'OK', 'Error') | Out-Null
        return
    }

    $runnerArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$runnerScript`" -Suite $suiteKey"
    if ($script:TestPathOverride) {
        $runnerArgs += " -TestPath `"$($script:TestPathOverride)`""
    }

    $reusePersistentBrowser = (
        $script:JiraRunActive -and
        (Can-ReusePersistentBrowserSession -Environment $envName)
    )

    if ($reusePersistentBrowser) {
        # The Live Context browser is already through ADM + Rx2GO auth.
        # Force CDP/visible mode and do not create a second Chrome.
        $runnerArgs += ' -Headed'
        $runnerArgs += " -ReuseCdpEndpoint `"$($script:PersistentCdpEndpoint)`""

        if ($script:PersistentChromePid -gt 0) {
            $runnerArgs += " -ReuseChromePid $($script:PersistentChromePid)"
        }

        # Smart Jira runs keep the browser alive through final result triage.
        # Complete-JiraRun closes it afterwards if the user did not request Keep Browser Open.
        $runnerArgs += ' -KeepBrowserOpen'
    }
    else {
        if ($headedCheck.Checked) {
            $runnerArgs += ' -Headed'
        }

        if ($keepBrowserOpenCheck.Checked -and $headedCheck.Checked) {
            $runnerArgs += ' -KeepBrowserOpen'
        }
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'cmd.exe'
    $psi.Arguments = "/d /s /c chcp 65001 >nul & powershell.exe $runnerArgs >> `"$($script:LogFile)`" 2>&1"
    $psi.WorkingDirectory = $script:ProjectRoot
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    $psi.EnvironmentVariables['TEST_ENV'] = $envName
    $psi.EnvironmentVariables['RUN_MUTATING_TESTS'] = $(if ($mutatingCheck.Checked) { 'true' } else { 'false' })
    $psi.EnvironmentVariables['RX2GO_APP_LOGIN'] = $app.Login
    $psi.EnvironmentVariables['RX2GO_APP_PASSWORD'] = $app.Password
    if (Test-GatewayRequired $envName) {
        $psi.EnvironmentVariables['RX2GO_GATEWAY_LOGIN'] = 'admin'
        $psi.EnvironmentVariables['RX2GO_DAILY_PASSWORD'] = $dailyPassword.Text
    }

    $logBox.Clear()
    Append-Log("Rx2GO AI QA`r`n")
    Append-Log("Окружение: $envName`r`n")
    Append-Log("Набор: $suiteName`r`n")
    Append-Log("Изменение данных: $(if ($mutatingCheck.Checked) { 'ДА' } else { 'НЕТ' })`r`n")
    Append-Log("Браузер на экране: $(if ($headedCheck.Checked) { 'ДА' } else { 'НЕТ' })`r`n")
    Append-Log("────────────────────────────────────────`r`n")
    Append-Log("Проверяю Node.js / npm / Playwright / Google Chrome…`r`n")
    Append-Log("Авторизация будет записана в лог строками [AUTH] без вывода пароля.`r`n")
    Append-Log("Учетная запись Rx2GO загружена: sergeyqa (пароль сохранён в Windows DPAPI).`r`n")
    if ($reusePersistentBrowser) {
        Append-Log("BROWSER SESSION: использую тот же Chrome, который уже авторизован и использовался для Live Page Context.`r`n")
        Append-Log("AUTH: первый фактор ADM и Rx2GO login повторно НЕ выполняются.`r`n")
        Append-AgentLog "FINAL PLAYWRIGHT → reusing authenticated Chrome $($script:PersistentCdpEndpoint)"
    }
    elseif ($envName -eq 'ADM' -and $headedCheck.Checked) {
        Append-Log("ADM: Launcher автоматически заполнит системное окно первого фактора: admin + суточный пароль.`r`n")
        Append-Log("ADM: после первого фактора Rx2GO login будет выполнен автоматически.`r`n")
    }
    if ($reusePersistentBrowser) {
        Append-Log("Chrome уже запущен и остаётся тем же самым окном до конца теста.`r`n")
    }
    elseif ($headedCheck.Checked) {
        Append-Log("Chrome будет запущен развёрнутым, без фиксированного viewport 1280x720.`r`n")
        if ($keepBrowserOpenCheck.Checked) {
            Append-Log("Одно окно Chrome используется от авторизации до конца теста и остаётся открытым.`r`n")
        }
    }

    $statusLabel.Text = '● Тестирование выполняется'
    $statusLabel.ForeColor = [System.Drawing.Color]::FromArgb(197, 119, 0)
    $progress.Style = 'Marquee'
    Set-RunningState $true

    try {
        $script:RunningProcess = New-Object System.Diagnostics.Process
        $script:RunningProcess.StartInfo = $psi
        [void]$script:RunningProcess.Start()
        $timer.Start()
    }
    catch {
        Set-RunningState $false
        $progress.Style = 'Blocks'
        $statusLabel.Text = '● Не удалось запустить'
        $statusLabel.ForeColor = [System.Drawing.Color]::Firebrick
        Append-Log("`r`nОшибка запуска: $($_.Exception.Message)`r`n")
    }
    finally {
        $app.Password = $null
    }
}

function Stop-QATest {
    if ($script:RunningProcess -and -not $script:RunningProcess.HasExited) {
        try {
            & taskkill /PID $script:RunningProcess.Id /T /F | Out-Null
            Append-Log("`r`nТестирование остановлено пользователем.`r`n")
        } catch { }
    }
}

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Rx2GO AI QA'
$form.Size = New-Object System.Drawing.Size(1360, 960)
$form.MinimumSize = New-Object System.Drawing.Size(1200, 860)
$form.StartPosition = 'CenterScreen'
$form.BackColor = [System.Drawing.Color]::FromArgb(246, 248, 251)
$form.Font = New-Font 9

$header = New-Object System.Windows.Forms.Panel
$header.Dock = 'Top'
$header.Height = 88
$header.BackColor = [System.Drawing.Color]::FromArgb(31, 41, 55)
$form.Controls.Add($header)

$title = New-Object System.Windows.Forms.Label
$title.Text = 'Rx2GO AI QA'
$title.Font = New-Font 22 ([System.Drawing.FontStyle]::Bold)
$title.ForeColor = [System.Drawing.Color]::White
$title.AutoSize = $true
$title.Location = New-Object System.Drawing.Point(28, 15)
$header.Controls.Add($title)

$subtitle = New-Object System.Windows.Forms.Label
$subtitle.Text = 'Запуск автоматического тестирования'
$subtitle.Font = New-Font 10
$subtitle.ForeColor = [System.Drawing.Color]::FromArgb(203, 213, 225)
$subtitle.AutoSize = $true
$subtitle.Location = New-Object System.Drawing.Point(31, 54)
$header.Controls.Add($subtitle)

$layoutHealthLabel = New-Object System.Windows.Forms.Label
$layoutHealthLabel.Text = '● UI layout check…'
$layoutHealthLabel.Font = New-Font 9 ([System.Drawing.FontStyle]::Bold)
$layoutHealthLabel.ForeColor = [System.Drawing.Color]::FromArgb(148,163,184)
$layoutHealthLabel.AutoSize = $true
$layoutHealthLabel.Anchor = 'Top,Right'
$layoutHealthLabel.Location = New-Object System.Drawing.Point(1090,34)
$layoutHealthLabel.Cursor = [System.Windows.Forms.Cursors]::Hand
$layoutHealthLabel.Add_Click({
    if ($layoutHealthLabel.Tag) {
        [System.Windows.Forms.MessageBox]::Show(
            [string]$layoutHealthLabel.Tag,
            'Rx2GO AI QA — UI layout check',
            'OK',
            'Information'
        ) | Out-Null
    }
})
$header.Controls.Add($layoutHealthLabel)


$configPanel = New-Object System.Windows.Forms.Panel
$configPanel.Location = New-Object System.Drawing.Point(24, 108)
$configPanel.Size = New-Object System.Drawing.Size(915, 292)
$configPanel.BackColor = [System.Drawing.Color]::White
$configPanel.BorderStyle = 'FixedSingle'
$form.Controls.Add($configPanel)

$envLabel = New-Object System.Windows.Forms.Label
$envLabel.Text = '1. Окружение'
$envLabel.Font = New-Font 11 ([System.Drawing.FontStyle]::Bold)
$envLabel.AutoSize = $true
$envLabel.Location = New-Object System.Drawing.Point(20, 16)
$configPanel.Controls.Add($envLabel)

$environmentCombo = New-Object System.Windows.Forms.ComboBox
$environmentCombo.DropDownStyle = 'DropDownList'
$environmentCombo.Font = New-Font 11
$environmentCombo.Items.AddRange(@('BRANCH','HOT','ADM'))
$environmentCombo.SelectedIndex = 0
$environmentCombo.Location = New-Object System.Drawing.Point(20, 44)
$environmentCombo.Size = New-Object System.Drawing.Size(180, 32)
$configPanel.Controls.Add($environmentCombo)

$urlCaption = New-Object System.Windows.Forms.Label
$urlCaption.Text = 'URL:'
$urlCaption.Font = New-Font 9 ([System.Drawing.FontStyle]::Bold)
$urlCaption.AutoSize = $true
$urlCaption.Location = New-Object System.Drawing.Point(225, 45)
$configPanel.Controls.Add($urlCaption)

$urlValue = New-Object System.Windows.Forms.Label
$urlValue.Font = New-Font 9
$urlValue.AutoSize = $true
$urlValue.Location = New-Object System.Drawing.Point(265, 45)
$configPanel.Controls.Add($urlValue)

$authCaption = New-Object System.Windows.Forms.Label
$authCaption.Text = 'Авторизация:'
$authCaption.Font = New-Font 9 ([System.Drawing.FontStyle]::Bold)
$authCaption.AutoSize = $true
$authCaption.Location = New-Object System.Drawing.Point(225, 68)
$configPanel.Controls.Add($authCaption)

$authValue = New-Object System.Windows.Forms.Label
$authValue.Font = New-Font 9
$authValue.AutoSize = $true
$authValue.Location = New-Object System.Drawing.Point(310, 68)
$configPanel.Controls.Add($authValue)

$suiteLabel = New-Object System.Windows.Forms.Label
$suiteLabel.Text = '2. Что проверить'
$suiteLabel.Font = New-Font 11 ([System.Drawing.FontStyle]::Bold)
$suiteLabel.AutoSize = $true
$suiteLabel.Location = New-Object System.Drawing.Point(20, 105)
$configPanel.Controls.Add($suiteLabel)

$suiteCombo = New-Object System.Windows.Forms.ComboBox
$suiteCombo.DropDownStyle = 'DropDownList'
$suiteCombo.Font = New-Font 11
$suiteCombo.Items.AddRange(@('Smoke','Tickets Queue','Все тесты'))
$suiteCombo.SelectedIndex = 0
$suiteCombo.Location = New-Object System.Drawing.Point(20, 135)
$suiteCombo.Size = New-Object System.Drawing.Size(240, 32)
$configPanel.Controls.Add($suiteCombo)


$browserModeLabel = New-Object System.Windows.Forms.Label
$browserModeLabel.Text = 'Браузер: Google Chrome • Incognito'
$browserModeLabel.AutoSize = $true
$browserModeLabel.Font = New-Font 9 ([System.Drawing.FontStyle]::Bold)
$browserModeLabel.ForeColor = [System.Drawing.Color]::FromArgb(37,99,235)
$browserModeLabel.Location = New-Object System.Drawing.Point(20, 242)
$configPanel.Controls.Add($browserModeLabel)

$headedCheck = New-Object System.Windows.Forms.CheckBox
$headedCheck.Text = 'Показывать браузер во время теста'
$headedCheck.Font = New-Font 9
$headedCheck.Checked = $true
$headedCheck.AutoSize = $true
$headedCheck.Location = New-Object System.Drawing.Point(280, 130)
$configPanel.Controls.Add($headedCheck)

$keepBrowserOpenCheck = New-Object System.Windows.Forms.CheckBox
$keepBrowserOpenCheck.Text = 'Не закрывать браузер после теста'
$keepBrowserOpenCheck.Font = New-Font 9
$keepBrowserOpenCheck.Checked = $true
$keepBrowserOpenCheck.AutoSize = $true
$keepBrowserOpenCheck.Location = New-Object System.Drawing.Point(520, 130)
$configPanel.Controls.Add($keepBrowserOpenCheck)

$headedCheck.Add_CheckedChanged({
    $keepBrowserOpenCheck.Enabled = $headedCheck.Checked
    if (-not $headedCheck.Checked) {
        $keepBrowserOpenCheck.Checked = $false
    }
})

$mutatingCheck = New-Object System.Windows.Forms.CheckBox
$mutatingCheck.Text = 'Разрешить изменение тестовых данных'
$mutatingCheck.Font = New-Font 9
$mutatingCheck.Checked = $false
$mutatingCheck.AutoSize = $true
$mutatingCheck.Location = New-Object System.Drawing.Point(785, 130)
$configPanel.Controls.Add($mutatingCheck)

$dailyLabel = New-Object System.Windows.Forms.Label
$dailyLabel.Text = '3. Суточный код из Telegram (ADM)'
$dailyLabel.Font = New-Font 11 ([System.Drawing.FontStyle]::Bold)
$dailyLabel.AutoSize = $true
$dailyLabel.Location = New-Object System.Drawing.Point(20, 174)
$configPanel.Controls.Add($dailyLabel)

$dailyPassword = New-Object System.Windows.Forms.TextBox
$dailyPassword.Font = New-Font 11
$dailyPassword.UseSystemPasswordChar = $true
$dailyPassword.Location = New-Object System.Drawing.Point(20, 204)
$dailyPassword.Size = New-Object System.Drawing.Size(300, 32)
$configPanel.Controls.Add($dailyPassword)

$dailyHint = New-Object System.Windows.Forms.Label
$dailyHint.Text = 'На ADM Chrome покажет окно первого фактора. Логин: admin. Введи сегодняшний код из Telegram.'
$dailyHint.Font = New-Font 9
$dailyHint.ForeColor = [System.Drawing.Color]::DimGray
$dailyHint.AutoSize = $true
$dailyHint.Location = New-Object System.Drawing.Point(340, 210)
$configPanel.Controls.Add($dailyHint)

$credentialButton = New-Object System.Windows.Forms.Button
$credentialButton.Text = '⚙ Настроить учетку Rx2GO'
$credentialButton.Font = New-Font 9
$credentialButton.Size = New-Object System.Drawing.Size(210, 34)
$credentialButton.Location = New-Object System.Drawing.Point(850, 199)
$credentialButton.Add_Click({ Save-AppCredential })
$configPanel.Controls.Add($credentialButton)

$runButton = New-Object System.Windows.Forms.Button
$runButton.Text = '▶  ЗАПУСТИТЬ ТЕСТИРОВАНИЕ'
$runButton.Font = New-Font 12 ([System.Drawing.FontStyle]::Bold)
$runButton.Size = New-Object System.Drawing.Size(305, 52)
$runButton.Location = New-Object System.Drawing.Point(24, 417)
$runButton.BackColor = [System.Drawing.Color]::FromArgb(37, 99, 235)
$runButton.ForeColor = [System.Drawing.Color]::White
$runButton.FlatStyle = 'Flat'
$runButton.Add_Click({ $script:CurrentJiraTask = $null; $script:JiraRunActive = $false; Start-QATest })
$form.Controls.Add($runButton)

$cancelButton = New-Object System.Windows.Forms.Button
$cancelButton.Text = 'Остановить'
$cancelButton.Font = New-Font 10
$cancelButton.Size = New-Object System.Drawing.Size(120, 52)
$cancelButton.Location = New-Object System.Drawing.Point(340, 417)
$cancelButton.Enabled = $false
$cancelButton.Add_Click({ Stop-QATest })
$form.Controls.Add($cancelButton)

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Text = '● Готово к запуску'
$statusLabel.Font = New-Font 10 ([System.Drawing.FontStyle]::Bold)
$statusLabel.ForeColor = [System.Drawing.Color]::FromArgb(32, 120, 72)
$statusLabel.AutoSize = $true
$statusLabel.Location = New-Object System.Drawing.Point(485, 425)
$form.Controls.Add($statusLabel)

$progress = New-Object System.Windows.Forms.ProgressBar
$progress.Location = New-Object System.Drawing.Point(485, 450)
$progress.Size = New-Object System.Drawing.Size(454, 16)
$form.Controls.Add($progress)

$resultsTitle = New-Object System.Windows.Forms.Label
$resultsTitle.Text = 'Результат тестирования'
$resultsTitle.Font = New-Font 11 ([System.Drawing.FontStyle]::Bold)
$resultsTitle.AutoSize = $true
$resultsTitle.Location = New-Object System.Drawing.Point(24, 493)
$form.Controls.Add($resultsTitle)

function Add-SummaryCard([string]$caption, [System.Drawing.Color]$accent, [int]$x) {
    $panel = New-Object System.Windows.Forms.Panel
    $panel.Location = New-Object System.Drawing.Point($x, 522)
    $panel.Size = New-Object System.Drawing.Size(130, 88)
    $panel.BackColor = [System.Drawing.Color]::White
    $panel.BorderStyle = 'FixedSingle'
    $form.Controls.Add($panel)

    $cap = New-Object System.Windows.Forms.Label
    $cap.Text = $caption
    $cap.Font = New-Font 9 ([System.Drawing.FontStyle]::Bold)
    $cap.ForeColor = $accent
    $cap.AutoSize = $true
    $cap.Location = New-Object System.Drawing.Point(14, 12)
    $panel.Controls.Add($cap)

    $value = New-Object System.Windows.Forms.Label
    $value.Text = '0'
    $value.Font = New-Font 25 ([System.Drawing.FontStyle]::Bold)
    $value.ForeColor = [System.Drawing.Color]::FromArgb(31, 41, 55)
    $value.AutoSize = $true
    $value.Location = New-Object System.Drawing.Point(12, 35)
    $panel.Controls.Add($value)
    return $value
}

$passValue = Add-SummaryCard 'PASS' ([System.Drawing.Color]::FromArgb(32, 120, 72)) 24
$failValue = Add-SummaryCard 'FAIL' ([System.Drawing.Color]::Firebrick) 164
$skipValue = Add-SummaryCard 'SKIP' ([System.Drawing.Color]::FromArgb(161, 98, 7)) 304

$failedTitle = New-Object System.Windows.Forms.Label
$failedTitle.Text = 'Упавшие сценарии'
$failedTitle.Font = New-Font 9 ([System.Drawing.FontStyle]::Bold)
$failedTitle.AutoSize = $true
$failedTitle.Location = New-Object System.Drawing.Point(465, 501)
$form.Controls.Add($failedTitle)

$failedList = New-Object System.Windows.Forms.ListBox
$failedList.Font = New-Font 9
$failedList.Location = New-Object System.Drawing.Point(465, 522)
$failedList.Size = New-Object System.Drawing.Size(474, 88)
$failedList.HorizontalScrollbar = $true
[void]$failedList.Items.Add('Результаты появятся после запуска.')
$form.Controls.Add($failedList)

$jiraButton = New-Object System.Windows.Forms.Button
$jiraButton.Text = '📋 Скопировать отчёт для Jira'
$jiraButton.Font = New-Font 9 ([System.Drawing.FontStyle]::Bold)
$jiraButton.Size = New-Object System.Drawing.Size(230, 38)
$jiraButton.Location = New-Object System.Drawing.Point(24, 625)
$jiraButton.Enabled = $false
$jiraButton.Add_Click({ Copy-JiraReport })
$form.Controls.Add($jiraButton)

$htmlButton = New-Object System.Windows.Forms.Button
$htmlButton.Text = 'Открыть HTML-отчёт'
$htmlButton.Font = New-Font 9
$htmlButton.Size = New-Object System.Drawing.Size(180, 38)
$htmlButton.Location = New-Object System.Drawing.Point(265, 625)
$htmlButton.Enabled = $false
$htmlButton.Add_Click({ Open-HtmlReport })
$form.Controls.Add($htmlButton)

$logTitle = New-Object System.Windows.Forms.Label
$logTitle.Text = 'Ход тестирования'
$logTitle.Font = New-Font 11 ([System.Drawing.FontStyle]::Bold)
$logTitle.AutoSize = $true
$logTitle.Location = New-Object System.Drawing.Point(24, 681)
$form.Controls.Add($logTitle)

$logBox = New-Object System.Windows.Forms.RichTextBox
$logBox.Location = New-Object System.Drawing.Point(24, 710)
$logBox.Size = New-Object System.Drawing.Size(915, 150)
$logBox.Anchor = 'Top,Bottom,Left,Right'
$logBox.ReadOnly = $true
$logBox.BackColor = [System.Drawing.Color]::FromArgb(17, 24, 39)
$logBox.ForeColor = [System.Drawing.Color]::FromArgb(229, 231, 235)
$logBox.Font = New-Object System.Drawing.Font('Consolas', 9)
$logBox.Text = "Выбери окружение и нажми «Запустить тестирование».`r`n"
$form.Controls.Add($logBox)

$environmentCombo.Add_SelectedIndexChanged({ Set-EnvironmentUI })

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 400
$timer.Add_Tick({
    if ($script:LogFile -and (Test-Path $script:LogFile)) {
        try {
            $content = [System.IO.File]::ReadAllText($script:LogFile)
            if ($content.Length -gt $script:LastLogLength) {
                Append-Log($content.Substring($script:LastLogLength))
                $script:LastLogLength = $content.Length
            }
        } catch { }
    }

    if ($script:RunningProcess -and $script:RunningProcess.HasExited -and -not $script:ExitHandled) {
        $script:ExitHandled = $true
        $timer.Stop()
        $exitCode = $script:RunningProcess.ExitCode
        $progress.Style = 'Blocks'
        $progress.Value = if ($exitCode -eq 0) { 100 } else { 0 }
        Set-RunningState $false
        Update-ResultPanel
        if ($exitCode -eq 0 -and $script:LastSummary.Fail -eq 0) {
            $statusLabel.Text = '● PASS — тестирование завершено'
            $statusLabel.ForeColor = [System.Drawing.Color]::FromArgb(32, 120, 72)
            Append-Log("`r`n────────────────────────────────────────`r`nPASS — тестирование завершено.`r`n")
        } else {
            $statusLabel.Text = "● FAIL — $($script:LastSummary.Fail) тест(ов)"
            $statusLabel.ForeColor = [System.Drawing.Color]::Firebrick
            Append-Log("`r`n────────────────────────────────────────`r`nFAIL — тестирование завершилось с кодом $exitCode.`r`n")
        }
        Append-Log("Итого: PASS $($script:LastSummary.Pass) | FAIL $($script:LastSummary.Fail) | SKIP $($script:LastSummary.Skip)`r`n")

        if (-not $script:JiraRunActive) {
            if ($exitCode -eq 0 -and $script:LastSummary.Fail -eq 0) {
                Show-QAResultToast `
                    -Result PASS `
                    -Title '✓ PASS' `
                    -Details "Быстрый запуск: PASS $($script:LastSummary.Pass) | FAIL 0 | SKIP $($script:LastSummary.Skip)"
            }
            else {
                Show-QAResultToast `
                    -Result FAIL `
                    -Title '✕ FAIL' `
                    -Details "Быстрый запуск: PASS $($script:LastSummary.Pass) | FAIL $($script:LastSummary.Fail) | SKIP $($script:LastSummary.Skip)"
            }
        }

        Complete-JiraRun
    }
})


$form.Add_ResizeEnd({
    Resize-LauncherChrome
    Update-LayoutHealth
})

$form.Add_FormClosing({
    if ($script:RunningProcess -and -not $script:RunningProcess.HasExited) {
        $answer = [System.Windows.Forms.MessageBox]::Show('Тестирование еще выполняется. Остановить его и закрыть программу?', 'Rx2GO QA', 'YesNo', 'Warning')
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
            $_.Cancel = $true
        } else {
            Stop-QATest
        }
    }
})



function Get-JiraScreenshotPaths {
    $result = New-Object System.Collections.Generic.List[string]

    foreach ($path in @($script:JiraScreenshotPaths)) {
        if ([string]::IsNullOrWhiteSpace([string]$path)) { continue }
        if (-not (Test-Path $path)) { continue }
        if ($result -contains [string]$path) { continue }

        $result.Add([string]$path)
        if ($result.Count -ge $script:JiraScreenshotMaxCount) { break }
    }

    $script:JiraScreenshotPaths = @($result)
    return @($result)
}


function Get-JiraScreenshotStorageDir {
    $key = $null

    if ($script:LoadedJiraIssueKey) {
        $key = [string]$script:LoadedJiraIssueKey
    }
    elseif ($jiraTaskBox -and -not [string]::IsNullOrWhiteSpace([string]$jiraTaskBox.Text)) {
        $key = Get-JiraIssueKey ([string]$jiraTaskBox.Text)
    }

    if ([string]::IsNullOrWhiteSpace($key)) {
        $key = 'ADHOC'
    }

    $safeKey = $key -replace '[^A-Za-z0-9_-]', '_'

    # Persistent location: survives unpacking a new Launcher version.
    $dir = Join-Path $script:LocalDataRoot "task-screenshots\$safeKey"
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    return $dir
}



function Move-AdhocScreenshotsToIssue {
    param([string]$IssueKey)

    if ([string]::IsNullOrWhiteSpace($IssueKey)) { return }

    $current = @(Get-JiraScreenshotPaths)
    if ($current.Count -eq 0) { return }

    $targetSafe = $IssueKey -replace '[^A-Za-z0-9_-]', '_'
    $targetDir = Join-Path $script:LocalDataRoot "task-screenshots\$targetSafe"
    New-Item -ItemType Directory -Path $targetDir -Force | Out-Null

    $moved = New-Object System.Collections.Generic.List[string]

    foreach ($source in $current) {
        if (-not (Test-Path $source)) { continue }

        try {
            $parent = Split-Path $source -Parent
            if ($parent -ieq $targetDir) {
                $moved.Add($source)
                continue
            }

            $name = Split-Path $source -Leaf
            $dest = Join-Path $targetDir $name

            if (Test-Path $dest) {
                $stem = [System.IO.Path]::GetFileNameWithoutExtension($name)
                $ext = [System.IO.Path]::GetExtension($name)
                $dest = Join-Path $targetDir "$stem-$(Get-Date -Format 'HHmmssfff')$ext"
            }

            Copy-Item -Path $source -Destination $dest -Force
            $moved.Add($dest)
        }
        catch {
            Append-AgentLog "TASK SCREENSHOT → migration warning: $($_.Exception.Message)"
        }
    }

    if ($moved.Count -gt 0) {
        $script:JiraScreenshotPaths = @($moved)
        Update-JiraScreenshotUI
    }
}

function Restore-JiraScreenshotsForIssue {
    param([string]$IssueKey)

    if ([string]::IsNullOrWhiteSpace($IssueKey)) {
        Update-JiraScreenshotUI
        return
    }

    $safeKey = $IssueKey -replace '[^A-Za-z0-9_-]', '_'
    $dir = Join-Path $script:LocalDataRoot "task-screenshots\$safeKey"

    if (-not (Test-Path $dir)) {
        $script:JiraScreenshotPaths = @()
        Update-JiraScreenshotUI
        return
    }

    $files = @(
        Get-ChildItem -Path $dir -File -ErrorAction SilentlyContinue |
            Where-Object { @('.png','.jpg','.jpeg','.bmp') -contains $_.Extension.ToLowerInvariant() } |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First $script:JiraScreenshotMaxCount |
            Sort-Object LastWriteTime |
            ForEach-Object { $_.FullName }
    )

    $script:JiraScreenshotPaths = @($files)
    Update-JiraScreenshotUI

    if ($files.Count -gt 0) {
        Append-AgentLog "TASK SCREENSHOTS → restored $($files.Count) persistent screenshot(s) for $IssueKey."
    }
}

function Get-JiraScreenshotPromptSummary {
    $paths = @(Get-JiraScreenshotPaths)

    if ($paths.Count -eq 0) {
        return 'NONE'
    }

    $names = @(
        $paths |
            ForEach-Object { Split-Path $_ -Leaf }
    )

    return "$($paths.Count) persistent screenshot(s) attached as real Codex image input: $($names -join ', ')"
}

function Update-JiraScreenshotUI {
    $paths = @(Get-JiraScreenshotPaths)
    $count = $paths.Count

    if ($jiraScreenshotPasteButton) {
        $jiraScreenshotPasteButton.Text = "📷 Буфер ($count)"
    }

    if ($jiraScreenshotInfo) {
        if ($count -eq 0) {
            $jiraScreenshotInfo.Text = 'Скриншоты не прикреплены'
            $jiraScreenshotInfo.ForeColor = [System.Drawing.Color]::DimGray
        }
        else {
            $names = @($paths | ForEach-Object { Split-Path $_ -Leaf })
            $jiraScreenshotInfo.Text = "$count прикреплено: $($names -join ', ')"
            $jiraScreenshotInfo.ForeColor = [System.Drawing.Color]::FromArgb(32,120,72)
        }
    }

    if ($jiraScreenshotClearButton) {
        $jiraScreenshotClearButton.Enabled = ($count -gt 0)
    }
}

function Add-JiraScreenshotFile {
    param([string]$SourcePath)

    if ([string]::IsNullOrWhiteSpace($SourcePath) -or -not (Test-Path $SourcePath)) {
        return $false
    }

    $existing = @(Get-JiraScreenshotPaths)
    if ($existing.Count -ge $script:JiraScreenshotMaxCount) {
        [System.Windows.Forms.MessageBox]::Show(
            "Можно прикрепить максимум $($script:JiraScreenshotMaxCount) скриншотов к одной проверке.",
            'Rx2GO QA — Screenshots',
            'OK',
            'Warning'
        ) | Out-Null
        return $false
    }

    try {
        $file = Get-Item $SourcePath -ErrorAction Stop

        if ($file.Length -gt 20MB) {
            throw 'Файл больше 20 MB.'
        }

        $allowed = @('.png','.jpg','.jpeg','.bmp')
        if ($allowed -notcontains $file.Extension.ToLowerInvariant()) {
            throw 'Поддерживаются PNG, JPG, JPEG и BMP.'
        }

        # Normalize all task screenshots to PNG. This gives Codex a predictable
        # image format and also avoids carrying EXIF metadata from local files.
        $image = $null
        try {
            $image = [System.Drawing.Image]::FromFile($file.FullName)

            $dir = Get-JiraScreenshotStorageDir
            $base = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
            $base = $base -replace '[^A-Za-z0-9А-Яа-яЁё._-]', '_'
            if ([string]::IsNullOrWhiteSpace($base)) { $base = 'screenshot' }

            $stamp = Get-Date -Format 'yyyyMMdd-HHmmssfff'
            $dest = Join-Path $dir "$stamp-$base.png"

            $image.Save(
                $dest,
                [System.Drawing.Imaging.ImageFormat]::Png
            )
        }
        finally {
            if ($image) { $image.Dispose() }
        }

        $script:JiraScreenshotPaths = @($existing + $dest)
        Update-JiraScreenshotUI
        Append-AgentLog "TASK SCREENSHOT → attached $(Split-Path $dest -Leaf)"
        return $true
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            "Не удалось добавить скриншот:`r`n$($_.Exception.Message)",
            'Rx2GO QA — Screenshots',
            'OK',
            'Error'
        ) | Out-Null
        return $false
    }
}

function Add-JiraScreenshotFromClipboard {
    try {
        if (-not [System.Windows.Forms.Clipboard]::ContainsImage()) {
            [System.Windows.Forms.MessageBox]::Show(
                'В буфере обмена сейчас нет изображения.',
                'Rx2GO QA — Screenshots',
                'OK',
                'Information'
            ) | Out-Null
            return $false
        }

        $existing = @(Get-JiraScreenshotPaths)
        if ($existing.Count -ge $script:JiraScreenshotMaxCount) {
            [System.Windows.Forms.MessageBox]::Show(
                "Можно прикрепить максимум $($script:JiraScreenshotMaxCount) скриншотов.",
                'Rx2GO QA — Screenshots',
                'OK',
                'Warning'
            ) | Out-Null
            return $false
        }

        $image = [System.Windows.Forms.Clipboard]::GetImage()
        if (-not $image) { return $false }

        try {
            $dir = Get-JiraScreenshotStorageDir
            $stamp = Get-Date -Format 'yyyyMMdd-HHmmssfff'
            $dest = Join-Path $dir "$stamp-clipboard.png"

            $image.Save(
                $dest,
                [System.Drawing.Imaging.ImageFormat]::Png
            )

            $script:JiraScreenshotPaths = @($existing + $dest)
            Update-JiraScreenshotUI
            Append-AgentLog "TASK SCREENSHOT → pasted from clipboard: $(Split-Path $dest -Leaf)"
            return $true
        }
        finally {
            $image.Dispose()
        }
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            "Не удалось вставить скриншот из буфера:`r`n$($_.Exception.Message)",
            'Rx2GO QA — Screenshots',
            'OK',
            'Error'
        ) | Out-Null
        return $false
    }
}

function Add-JiraScreenshotFiles {
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Title = 'Выбери скриншоты для анализа Jira-задачи'
    $dialog.Filter = 'Images (*.png;*.jpg;*.jpeg;*.bmp)|*.png;*.jpg;*.jpeg;*.bmp'
    $dialog.Multiselect = $true

    try {
        if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
            return
        }

        foreach ($file in @($dialog.FileNames)) {
            if (@(Get-JiraScreenshotPaths).Count -ge $script:JiraScreenshotMaxCount) {
                break
            }
            [void](Add-JiraScreenshotFile -SourcePath $file)
        }
    }
    finally {
        $dialog.Dispose()
    }
}


function Clear-JiraScreenshots {
    $paths = @(Get-JiraScreenshotPaths)

    foreach ($path in $paths) {
        try {
            if (
                $path -and
                (Test-Path $path) -and
                ([string]$path).StartsWith([string]$script:LocalDataRoot, [System.StringComparison]::OrdinalIgnoreCase)
            ) {
                Remove-Item -Path $path -Force -ErrorAction SilentlyContinue
            }
        } catch {}
    }

    $script:JiraScreenshotPaths = @()
    Update-JiraScreenshotUI
    Append-AgentLog 'TASK SCREENSHOTS → cleared from current task and persistent task context.'
}

function Invoke-JiraScreenshotPasteShortcut {
    param($Sender, $EventArgs)

    if (
        $EventArgs.Control -and
        $EventArgs.KeyCode -eq [System.Windows.Forms.Keys]::V -and
        [System.Windows.Forms.Clipboard]::ContainsImage()
    ) {
        [void](Add-JiraScreenshotFromClipboard)
        $EventArgs.SuppressKeyPress = $true
        $EventArgs.Handled = $true
    }
}

# --- Tabs: Quick Run + Jira Task ---
$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Location = New-Object System.Drawing.Point(12, 96)
$tabs.Size = New-Object System.Drawing.Size(950, 790)
$tabs.Anchor = 'Top,Bottom,Left,Right'
$form.Controls.Add($tabs)
$tabs.BringToFront()

$quickTab = New-Object System.Windows.Forms.TabPage
$quickTab.Text = 'Быстрый запуск'
$quickTab.BackColor = [System.Drawing.Color]::FromArgb(246,248,251)
$tabs.TabPages.Add($quickTab) | Out-Null

$jiraTab = New-Object System.Windows.Forms.TabPage
$jiraTab.Text = 'Jira Task'
$jiraTab.BackColor = [System.Drawing.Color]::FromArgb(246,248,251)
$jiraTab.AutoScroll = $true
$tabs.TabPages.Add($jiraTab) | Out-Null

$knowledgeTab = New-Object System.Windows.Forms.TabPage
$knowledgeTab.Text = 'Knowledge'
$knowledgeTab.BackColor = [System.Drawing.Color]::FromArgb(246,248,251)
$knowledgeTab.AutoScroll = $true
$tabs.TabPages.Add($knowledgeTab) | Out-Null

$quickControls = @($configPanel,$runButton,$cancelButton,$statusLabel,$progress,$resultsTitle,$passValue.Parent,$failValue.Parent,$skipValue.Parent,$failedTitle,$failedList,$jiraButton,$htmlButton,$logTitle,$logBox)
foreach ($c in $quickControls) {
    if (-not $c) { continue }
    $old = $c.Location
    $form.Controls.Remove($c)
    $c.Location = New-Object System.Drawing.Point(($old.X - 12), ($old.Y - 96))
    $quickTab.Controls.Add($c)
}

# Jira Task source
$jiraSourceLabel = New-Object System.Windows.Forms.Label
$jiraSourceLabel.Text = '1. Jira-задача'
$jiraSourceLabel.Font = New-Font 11 ([System.Drawing.FontStyle]::Bold)
$jiraSourceLabel.AutoSize = $true
$jiraSourceLabel.Location = New-Object System.Drawing.Point(18, 18)
$jiraTab.Controls.Add($jiraSourceLabel)

$jiraSourceHint = New-Object System.Windows.Forms.Label
$jiraSourceHint.Text = 'Вставь ключ/ссылку/описание. Скриншот можно вставить Ctrl+V или кнопкой 📷; он попадёт в визуальный контекст AI.'
$jiraSourceHint.Font = New-Font 9
$jiraSourceHint.ForeColor = [System.Drawing.Color]::DimGray
$jiraSourceHint.AutoSize = $true
$jiraSourceHint.Location = New-Object System.Drawing.Point(18, 44)
$jiraTab.Controls.Add($jiraSourceHint)

$chatGptStatus = New-Object System.Windows.Forms.Label
$chatGptStatus.Text = '● Проверка ChatGPT…'
$chatGptStatus.Font = New-Font 9 ([System.Drawing.FontStyle]::Bold)
$chatGptStatus.ForeColor = [System.Drawing.Color]::DimGray
$chatGptStatus.AutoSize = $true
$chatGptStatus.Location = New-Object System.Drawing.Point(650, 12)
$jiraTab.Controls.Add($chatGptStatus)

$chatGptConnectButton = New-Object System.Windows.Forms.Button
$chatGptConnectButton.Text = 'Подключить ChatGPT'
$chatGptConnectButton.Font = New-Font 8
$chatGptConnectButton.Size = New-Object System.Drawing.Size(170, 28)
$chatGptConnectButton.Location = New-Object System.Drawing.Point(820, 6)
$chatGptConnectButton.Add_Click({ Connect-ChatGPTOAuth })
$jiraTab.Controls.Add($chatGptConnectButton)

$jiraAiCheck = New-Object System.Windows.Forms.CheckBox
$jiraAiCheck.Text = 'AI-анализ через ChatGPT'
$jiraAiCheck.Checked = $true
$jiraAiCheck.AutoSize = $true
$jiraAiCheck.Location = New-Object System.Drawing.Point(650, 72)
$jiraTab.Controls.Add($jiraAiCheck)


$jiraConnectionStatus = New-Object System.Windows.Forms.Label
$jiraConnectionStatus.Text = '● Проверка Jira API…'
$jiraConnectionStatus.Font = New-Font 9 ([System.Drawing.FontStyle]::Bold)
$jiraConnectionStatus.ForeColor = [System.Drawing.Color]::DimGray
$jiraConnectionStatus.AutoSize = $true
$jiraConnectionStatus.Location = New-Object System.Drawing.Point(650, 44)
$jiraTab.Controls.Add($jiraConnectionStatus)

$jiraConnectButton = New-Object System.Windows.Forms.Button
$jiraConnectButton.Text = 'Настроить Jira'
$jiraConnectButton.Font = New-Font 8
$jiraConnectButton.Size = New-Object System.Drawing.Size(170, 28)
$jiraConnectButton.Location = New-Object System.Drawing.Point(820, 38)
$jiraConnectButton.Add_Click({ Save-JiraApiCredential })
$jiraTab.Controls.Add($jiraConnectButton)

$jiraTaskBox = New-Object System.Windows.Forms.TextBox
$jiraTaskBox.Multiline = $true
$jiraTaskBox.ScrollBars = 'Vertical'
$jiraTaskBox.Font = New-Font 10
$jiraTaskBox.Location = New-Object System.Drawing.Point(18, 92)
$jiraTaskBox.Size = New-Object System.Drawing.Size(610, 96)
$jiraTaskBox.Anchor = 'Top,Left'
$jiraTab.Controls.Add($jiraTaskBox)
$jiraTaskBox.Add_TextChanged({
    $script:LoadedJiraIssue = $null
    $script:LoadedJiraIssueKey = $null
    if ($jiraImportedInfo) {
        $jiraImportedInfo.Text = 'Jira ещё не загружена'
        $jiraImportedInfo.ForeColor = [System.Drawing.Color]::DimGray
    }
})


$jiraQaCommentLabel = New-Object System.Windows.Forms.Label
$jiraQaCommentLabel.Text = '2. Комментарий QA для этой проверки'
$jiraQaCommentLabel.Font = New-Font 9 ([System.Drawing.FontStyle]::Bold)
$jiraQaCommentLabel.AutoSize = $true
$jiraQaCommentLabel.Location = New-Object System.Drawing.Point(650, 92)
$jiraTab.Controls.Add($jiraQaCommentLabel)

$jiraQaCommentBox = New-Object System.Windows.Forms.TextBox
$jiraQaCommentBox.Multiline = $true
$jiraQaCommentBox.ScrollBars = 'Vertical'
$jiraQaCommentBox.Font = New-Font 9
$jiraQaCommentBox.Location = New-Object System.Drawing.Point(650, 116)
$jiraQaCommentBox.Size = New-Object System.Drawing.Size(500, 72)
$jiraQaCommentBox.Anchor = 'Top,Right'
$jiraTab.Controls.Add($jiraQaCommentBox)

# Task screenshots: clipboard paste or local image files.
$jiraScreenshotPasteButton = New-Object System.Windows.Forms.Button
$jiraScreenshotPasteButton.Text = '📷 Буфер (0)'
$jiraScreenshotPasteButton.Font = New-Font 8
$jiraScreenshotPasteButton.Size = New-Object System.Drawing.Size(145, 30)
$jiraScreenshotPasteButton.Location = New-Object System.Drawing.Point(650, 198)
$jiraScreenshotPasteButton.Add_Click({ [void](Add-JiraScreenshotFromClipboard) })
$jiraTab.Controls.Add($jiraScreenshotPasteButton)

$jiraScreenshotFilesButton = New-Object System.Windows.Forms.Button
$jiraScreenshotFilesButton.Text = 'Файлы…'
$jiraScreenshotFilesButton.Font = New-Font 8
$jiraScreenshotFilesButton.Size = New-Object System.Drawing.Size(95, 30)
$jiraScreenshotFilesButton.Location = New-Object System.Drawing.Point(800, 198)
$jiraScreenshotFilesButton.Add_Click({ Add-JiraScreenshotFiles })
$jiraTab.Controls.Add($jiraScreenshotFilesButton)

$jiraScreenshotClearButton = New-Object System.Windows.Forms.Button
$jiraScreenshotClearButton.Text = 'Очистить'
$jiraScreenshotClearButton.Font = New-Font 8
$jiraScreenshotClearButton.Size = New-Object System.Drawing.Size(90, 30)
$jiraScreenshotClearButton.Location = New-Object System.Drawing.Point(900, 198)
$jiraScreenshotClearButton.Enabled = $false
$jiraScreenshotClearButton.Add_Click({ Clear-JiraScreenshots })
$jiraTab.Controls.Add($jiraScreenshotClearButton)

$jiraScreenshotInfo = New-Object System.Windows.Forms.Label
$jiraScreenshotInfo.Text = 'Скриншоты не прикреплены'
$jiraScreenshotInfo.Font = New-Font 8
$jiraScreenshotInfo.ForeColor = [System.Drawing.Color]::DimGray
$jiraScreenshotInfo.AutoEllipsis = $true
$jiraScreenshotInfo.Location = New-Object System.Drawing.Point(995, 205)
$jiraScreenshotInfo.Size = New-Object System.Drawing.Size(155, 18)
$jiraTab.Controls.Add($jiraScreenshotInfo)
Update-JiraScreenshotUI

# Ctrl+V with an image inside either Jira text field attaches the image.
$jiraTaskBox.Add_KeyDown({ param($sender,$e) Invoke-JiraScreenshotPasteShortcut $sender $e })
$jiraQaCommentBox.Add_KeyDown({ param($sender,$e) Invoke-JiraScreenshotPasteShortcut $sender $e })

$jiraLoadButton = New-Object System.Windows.Forms.Button
$jiraLoadButton.Text = 'Загрузить Jira'
$jiraLoadButton.Font = New-Font 9 ([System.Drawing.FontStyle]::Bold)
$jiraLoadButton.Size = New-Object System.Drawing.Size(150, 32)
$jiraLoadButton.Location = New-Object System.Drawing.Point(18, 200)
$jiraLoadButton.Add_Click({ Load-JiraIssuePreview })
$jiraTab.Controls.Add($jiraLoadButton)

$jiraImportedInfo = New-Object System.Windows.Forms.Label
$jiraImportedInfo.Text = 'Jira ещё не загружена'
$jiraImportedInfo.Font = New-Font 8
$jiraImportedInfo.ForeColor = [System.Drawing.Color]::DimGray
$jiraImportedInfo.AutoSize = $true
$jiraImportedInfo.Location = New-Object System.Drawing.Point(180, 208)
$jiraTab.Controls.Add($jiraImportedInfo)

$jiraImportedBox = New-Object System.Windows.Forms.RichTextBox
$jiraImportedBox.ReadOnly = $true
$jiraImportedBox.Font = New-Object System.Drawing.Font('Consolas', 9)
$jiraImportedBox.BackColor = [System.Drawing.Color]::White
$jiraImportedBox.Location = New-Object System.Drawing.Point(18, 240)
$jiraImportedBox.Size = New-Object System.Drawing.Size(1132, 150)
$jiraImportedBox.Anchor = 'Top,Left,Right'
$jiraImportedBox.Text = 'Нажми «Загрузить Jira». Здесь будут реальный Description и все Jira comments.'
$jiraTab.Controls.Add($jiraImportedBox)


$jiraRuleLabel = New-Object System.Windows.Forms.Label
$jiraRuleLabel.Text = '3. Новое постоянное правило Rx2GO'
$jiraRuleLabel.Font = New-Font 9 ([System.Drawing.FontStyle]::Bold)
$jiraRuleLabel.AutoSize = $true
$jiraRuleLabel.Location = New-Object System.Drawing.Point(18, 408)
$jiraTab.Controls.Add($jiraRuleLabel)

$jiraRulesCountLabel = New-Object System.Windows.Forms.Label
$jiraRulesCountLabel.Text = "Сохранено правил: $(@(Get-Rx2GOProjectRules).Count)"
$jiraRulesCountLabel.Font = New-Font 8
$jiraRulesCountLabel.ForeColor = [System.Drawing.Color]::DimGray
$jiraRulesCountLabel.AutoSize = $true
$jiraRulesCountLabel.Location = New-Object System.Drawing.Point(250, 410)
$jiraTab.Controls.Add($jiraRulesCountLabel)

$jiraPersistentRuleBox = New-Object System.Windows.Forms.TextBox
$jiraPersistentRuleBox.Multiline = $true
$jiraPersistentRuleBox.ScrollBars = 'Vertical'
$jiraPersistentRuleBox.Font = New-Font 9
$jiraPersistentRuleBox.Location = New-Object System.Drawing.Point(18, 432)
$jiraPersistentRuleBox.Size = New-Object System.Drawing.Size(900, 52)
$jiraTab.Controls.Add($jiraPersistentRuleBox)

$jiraSaveRuleButton = New-Object System.Windows.Forms.Button
$jiraSaveRuleButton.Text = '💾 Сохранить как правило Rx2GO'
$jiraSaveRuleButton.Font = New-Font 9 ([System.Drawing.FontStyle]::Bold)
$jiraSaveRuleButton.Size = New-Object System.Drawing.Size(225, 52)
$jiraSaveRuleButton.Location = New-Object System.Drawing.Point(930, 432)
$jiraSaveRuleButton.Add_Click({ Save-Rx2GOProjectRule $jiraPersistentRuleBox.Text })
$jiraTab.Controls.Add($jiraSaveRuleButton)

$jiraEnvLabel = New-Object System.Windows.Forms.Label
$jiraEnvLabel.Text = '4. Окружение и проверки'
$jiraEnvLabel.Font = New-Font 10 ([System.Drawing.FontStyle]::Bold)
$jiraEnvLabel.AutoSize = $true
$jiraEnvLabel.Location = New-Object System.Drawing.Point(18, 498)
$jiraTab.Controls.Add($jiraEnvLabel)

$jiraEnvironmentCombo = New-Object System.Windows.Forms.ComboBox
$jiraEnvironmentCombo.DropDownStyle = 'DropDownList'
$jiraEnvironmentCombo.Font = New-Font 10
$jiraEnvironmentCombo.Items.AddRange(@('BRANCH','HOT','ADM'))
$jiraEnvironmentCombo.SelectedIndex = 0
$jiraEnvironmentCombo.Location = New-Object System.Drawing.Point(18, 524)
$jiraEnvironmentCombo.Size = New-Object System.Drawing.Size(150, 30)
$jiraTab.Controls.Add($jiraEnvironmentCombo)

$jiraUiCheck = New-Object System.Windows.Forms.CheckBox
$jiraUiCheck.Text = 'UI'
$jiraUiCheck.Checked = $true
$jiraUiCheck.AutoSize = $true
$jiraUiCheck.Location = New-Object System.Drawing.Point(195, 528)
$jiraTab.Controls.Add($jiraUiCheck)

$jiraApiCheck = New-Object System.Windows.Forms.CheckBox
$jiraApiCheck.Text = 'API'
$jiraApiCheck.Checked = $true
$jiraApiCheck.AutoSize = $true
$jiraApiCheck.Location = New-Object System.Drawing.Point(255, 528)
$jiraTab.Controls.Add($jiraApiCheck)

$jiraRegressionCheck = New-Object System.Windows.Forms.CheckBox
$jiraRegressionCheck.Text = 'Regression'
$jiraRegressionCheck.Checked = $true
$jiraRegressionCheck.AutoSize = $true
$jiraRegressionCheck.Location = New-Object System.Drawing.Point(320, 528)
$jiraTab.Controls.Add($jiraRegressionCheck)

$jiraNetworkCheck = New-Object System.Windows.Forms.CheckBox
$jiraNetworkCheck.Text = 'Network / Console'
$jiraNetworkCheck.Checked = $true
$jiraNetworkCheck.AutoSize = $true
$jiraNetworkCheck.Location = New-Object System.Drawing.Point(420, 528)
$jiraTab.Controls.Add($jiraNetworkCheck)

$jiraHeadedCheck = New-Object System.Windows.Forms.CheckBox
$jiraHeadedCheck.Text = 'Показывать браузер'
$jiraHeadedCheck.Checked = $true
$jiraHeadedCheck.AutoSize = $true
$jiraHeadedCheck.Location = New-Object System.Drawing.Point(580, 528)
$jiraTab.Controls.Add($jiraHeadedCheck)

$jiraMutatingCheck = New-Object System.Windows.Forms.CheckBox
$jiraMutatingCheck.Text = 'Разрешить изменение данных'
$jiraMutatingCheck.Checked = $false
$jiraMutatingCheck.AutoSize = $true
$jiraMutatingCheck.Location = New-Object System.Drawing.Point(740, 528)
$jiraTab.Controls.Add($jiraMutatingCheck)

$jiraDailyLabel = New-Object System.Windows.Forms.Label
$jiraDailyLabel.Text = 'Код из Telegram для первого фактора ADM'
$jiraDailyLabel.AutoSize = $true
$jiraDailyLabel.Location = New-Object System.Drawing.Point(18, 566)
$jiraTab.Controls.Add($jiraDailyLabel)

$jiraDailyPassword = New-Object System.Windows.Forms.TextBox
$jiraDailyPassword.UseSystemPasswordChar = $true
$jiraDailyPassword.Font = New-Font 10
$jiraDailyPassword.Location = New-Object System.Drawing.Point(250, 560)
$jiraDailyPassword.Size = New-Object System.Drawing.Size(220, 28)
$jiraTab.Controls.Add($jiraDailyPassword)

$jiraEnvironmentCombo.Add_SelectedIndexChanged({
    # Authentication data is entered once on the Quick Run tab.
    $jiraDailyLabel.Visible = $false
    $jiraDailyPassword.Visible = $false
})
$jiraDailyLabel.Visible = $false
$jiraDailyPassword.Visible = $false

$jiraRunButton = New-Object System.Windows.Forms.Button
$jiraRunButton.Text = '▶  ПРОВЕРИТЬ ЗАДАЧУ'
$jiraRunButton.Font = New-Font 11 ([System.Drawing.FontStyle]::Bold)
$jiraRunButton.Size = New-Object System.Drawing.Size(260, 46)
$jiraRunButton.Location = New-Object System.Drawing.Point(18, 608)
$jiraRunButton.BackColor = [System.Drawing.Color]::FromArgb(37,99,235)
$jiraRunButton.ForeColor = [System.Drawing.Color]::White
$jiraRunButton.FlatStyle = 'Flat'
$jiraRunButton.Add_Click({ Start-JiraTaskCheck })
$jiraTab.Controls.Add($jiraRunButton)

$jiraModuleCaption = New-Object System.Windows.Forms.Label
$jiraModuleCaption.Text = 'Модуль:'
$jiraModuleCaption.Font = New-Font 9 ([System.Drawing.FontStyle]::Bold)
$jiraModuleCaption.AutoSize = $true
$jiraModuleCaption.Location = New-Object System.Drawing.Point(305, 614)
$jiraTab.Controls.Add($jiraModuleCaption)
$jiraModuleValue = New-Object System.Windows.Forms.Label
$jiraModuleValue.Text = '—'
$jiraModuleValue.AutoSize = $true
$jiraModuleValue.Location = New-Object System.Drawing.Point(365, 614)
$jiraTab.Controls.Add($jiraModuleValue)

$jiraAutomationCaption = New-Object System.Windows.Forms.Label
$jiraAutomationCaption.Text = 'Автоматизация:'
$jiraAutomationCaption.Font = New-Font 9 ([System.Drawing.FontStyle]::Bold)
$jiraAutomationCaption.AutoSize = $true
$jiraAutomationCaption.Location = New-Object System.Drawing.Point(305, 638)
$jiraTab.Controls.Add($jiraAutomationCaption)
$jiraAutomationValue = New-Object System.Windows.Forms.Label
$jiraAutomationValue.Text = '—'
$jiraAutomationValue.AutoSize = $true
$jiraAutomationValue.Location = New-Object System.Drawing.Point(405, 638)
$jiraTab.Controls.Add($jiraAutomationValue)

$jiraTaskStatus = New-Object System.Windows.Forms.Label
$jiraTaskStatus.Text = 'Готово к анализу задачи'
$jiraTaskStatus.Font = New-Font 9 ([System.Drawing.FontStyle]::Bold)
$jiraTaskStatus.ForeColor = [System.Drawing.Color]::FromArgb(32,120,72)
$jiraTaskStatus.AutoSize = $true
$jiraTaskStatus.Location = New-Object System.Drawing.Point(590, 620)
$jiraTab.Controls.Add($jiraTaskStatus)

$jiraPlanTitle = New-Object System.Windows.Forms.Label
$jiraPlanTitle.Text = 'Тест-план'
$jiraPlanTitle.Font = New-Font 10 ([System.Drawing.FontStyle]::Bold)
$jiraPlanTitle.AutoSize = $true
$jiraPlanTitle.Location = New-Object System.Drawing.Point(18, 666)
$jiraTab.Controls.Add($jiraPlanTitle)

$jiraPlanBox = New-Object System.Windows.Forms.RichTextBox
$jiraPlanBox.ReadOnly = $true
$jiraPlanBox.Font = New-Object System.Drawing.Font('Consolas', 9)
$jiraPlanBox.BackColor = [System.Drawing.Color]::White
$jiraPlanBox.Location = New-Object System.Drawing.Point(18, 692)
$jiraPlanBox.Size = New-Object System.Drawing.Size(1132, 170)
$jiraPlanBox.Anchor = 'Top,Left,Right'
$jiraPlanBox.Text = 'После нажатия «Проверить задачу» здесь появятся acceptance criteria и план проверок.'
$jiraTab.Controls.Add($jiraPlanBox)

function Add-JiraSummary([string]$caption, [System.Drawing.Color]$accent, [int]$x) {
    $panel = New-Object System.Windows.Forms.Panel
    $panel.Location = New-Object System.Drawing.Point($x, 878)
    $panel.Size = New-Object System.Drawing.Size(105, 64)
    $panel.BackColor = [System.Drawing.Color]::White
    $panel.BorderStyle = 'FixedSingle'
    $jiraTab.Controls.Add($panel)
    $cap = New-Object System.Windows.Forms.Label
    $cap.Text = $caption
    $cap.Font = New-Font 8 ([System.Drawing.FontStyle]::Bold)
    $cap.ForeColor = $accent
    $cap.AutoSize = $true
    $cap.Location = New-Object System.Drawing.Point(10,8)
    $panel.Controls.Add($cap)
    $val = New-Object System.Windows.Forms.Label
    $val.Text = '0'
    $val.Font = New-Font 18 ([System.Drawing.FontStyle]::Bold)
    $val.AutoSize = $true
    $val.Location = New-Object System.Drawing.Point(9,28)
    $panel.Controls.Add($val)
    return $val
}
$jiraPassValue = Add-JiraSummary 'PASS' ([System.Drawing.Color]::FromArgb(32,120,72)) 18
$jiraFailValue = Add-JiraSummary 'FAIL' ([System.Drawing.Color]::Firebrick) 133
$jiraSkipValue = Add-JiraSummary 'SKIP' ([System.Drawing.Color]::FromArgb(161,98,7)) 248

$jiraCopyReportButton = New-Object System.Windows.Forms.Button
$jiraCopyReportButton.Text = '📋 Скопировать Jira-отчёт с кейсами'
$jiraCopyReportButton.Font = New-Font 9 ([System.Drawing.FontStyle]::Bold)
$jiraCopyReportButton.Size = New-Object System.Drawing.Size(235, 38)
$jiraCopyReportButton.Location = New-Object System.Drawing.Point(390, 892)
$jiraCopyReportButton.Enabled = $false
$jiraCopyReportButton.Add_Click({ Copy-JiraTaskReport })
$jiraTab.Controls.Add($jiraCopyReportButton)

$jiraRegressionButton = New-Object System.Windows.Forms.Button
$jiraRegressionButton.Text = '+ Добавить в Regression'
$jiraRegressionButton.Font = New-Font 9
$jiraRegressionButton.Size = New-Object System.Drawing.Size(220, 38)
$jiraRegressionButton.Location = New-Object System.Drawing.Point(640, 892)
$jiraRegressionButton.Enabled = $false
$jiraRegressionButton.Add_Click({ Add-JiraRegressionCandidate })
$jiraTab.Controls.Add($jiraRegressionButton)

$jiraNote = New-Object System.Windows.Forms.Label
$jiraNote.Text = 'Jira читается напрямую через REST API. Email + API token хранятся локально через Windows DPAPI. ChatGPT анализирует полное описание и создаёт task-specific Playwright-тест.'
$jiraNote.Font = New-Font 8
$jiraNote.ForeColor = [System.Drawing.Color]::DimGray
$jiraNote.AutoSize = $true
$jiraNote.Location = New-Object System.Drawing.Point(18, 948)
$jiraTab.Controls.Add($jiraNote)


# --- Knowledge tab ---
$knowledgeTitle = New-Object System.Windows.Forms.Label
$knowledgeTitle.Text = 'Общая память Rx2GO QA'
$knowledgeTitle.Font = New-Font 15 ([System.Drawing.FontStyle]::Bold)
$knowledgeTitle.AutoSize = $true
$knowledgeTitle.Location = New-Object System.Drawing.Point(20,18)
$knowledgeTab.Controls.Add($knowledgeTitle)

$knowledgeHint = New-Object System.Windows.Forms.Label
$knowledgeHint.Text = 'Переносимые знания хранятся в Git. Секреты, временные отчёты, screenshots и traces в репозиторий не попадают.'
$knowledgeHint.Font = New-Font 9
$knowledgeHint.ForeColor = [System.Drawing.Color]::DimGray
$knowledgeHint.AutoSize = $true
$knowledgeHint.Location = New-Object System.Drawing.Point(20,48)
$knowledgeTab.Controls.Add($knowledgeHint)

function Add-KnowledgeCard([string]$caption, [int]$x) {
    $panel = New-Object System.Windows.Forms.Panel
    $panel.Location = New-Object System.Drawing.Point($x,82)
    $panel.Size = New-Object System.Drawing.Size(200,92)
    $panel.BackColor = [System.Drawing.Color]::White
    $panel.BorderStyle = 'FixedSingle'
    $knowledgeTab.Controls.Add($panel)
    $cap = New-Object System.Windows.Forms.Label
    $cap.Text = $caption
    $cap.Font = New-Font 9 ([System.Drawing.FontStyle]::Bold)
    $cap.ForeColor = [System.Drawing.Color]::DimGray
    $cap.AutoSize = $true
    $cap.Location = New-Object System.Drawing.Point(12,12)
    $panel.Controls.Add($cap)
    $val = New-Object System.Windows.Forms.Label
    $val.Text = '0'
    $val.Font = New-Font 24 ([System.Drawing.FontStyle]::Bold)
    $val.AutoSize = $true
    $val.Location = New-Object System.Drawing.Point(10,38)
    $panel.Controls.Add($val)
    return $val
}
$knowledgeRulesValue = Add-KnowledgeCard 'Project rules' 20
$knowledgeJiraValue = Add-KnowledgeCard 'Jira cases' 230
$knowledgeRegressionValue = Add-KnowledgeCard 'Regression scenarios' 440
$knowledgeTestsValue = Add-KnowledgeCard 'Automated tests' 650

$knowledgeGitPanel = New-Object System.Windows.Forms.Panel
$knowledgeGitPanel.Location = New-Object System.Drawing.Point(20,194)
$knowledgeGitPanel.Size = New-Object System.Drawing.Size(830,178)
$knowledgeGitPanel.BackColor = [System.Drawing.Color]::White
$knowledgeGitPanel.BorderStyle = 'FixedSingle'
$knowledgeTab.Controls.Add($knowledgeGitPanel)

$knowledgeGitTitle = New-Object System.Windows.Forms.Label
$knowledgeGitTitle.Text = 'Git repository'
$knowledgeGitTitle.Font = New-Font 11 ([System.Drawing.FontStyle]::Bold)
$knowledgeGitTitle.AutoSize = $true
$knowledgeGitTitle.Location = New-Object System.Drawing.Point(16,14)
$knowledgeGitPanel.Controls.Add($knowledgeGitTitle)

$knowledgeGitStatus = New-Object System.Windows.Forms.Label
$knowledgeGitStatus.Text = '● Проверка Git…'
$knowledgeGitStatus.Font = New-Font 9 ([System.Drawing.FontStyle]::Bold)
$knowledgeGitStatus.AutoSize = $true
$knowledgeGitStatus.Location = New-Object System.Drawing.Point(16,45)
$knowledgeGitPanel.Controls.Add($knowledgeGitStatus)

$branchCaption = New-Object System.Windows.Forms.Label
$branchCaption.Text = 'Branch:'
$branchCaption.Font = New-Font 8 ([System.Drawing.FontStyle]::Bold)
$branchCaption.AutoSize = $true
$branchCaption.Location = New-Object System.Drawing.Point(16,75)
$knowledgeGitPanel.Controls.Add($branchCaption)
$knowledgeBranchValue = New-Object System.Windows.Forms.Label
$knowledgeBranchValue.Text = '—'
$knowledgeBranchValue.AutoSize = $true
$knowledgeBranchValue.Location = New-Object System.Drawing.Point(72,75)
$knowledgeGitPanel.Controls.Add($knowledgeBranchValue)

$remoteCaption = New-Object System.Windows.Forms.Label
$remoteCaption.Text = 'Origin:'
$remoteCaption.Font = New-Font 8 ([System.Drawing.FontStyle]::Bold)
$remoteCaption.AutoSize = $true
$remoteCaption.Location = New-Object System.Drawing.Point(16,100)
$knowledgeGitPanel.Controls.Add($remoteCaption)
$knowledgeRemoteValue = New-Object System.Windows.Forms.Label
$knowledgeRemoteValue.Text = '—'
$knowledgeRemoteValue.AutoEllipsis = $true
$knowledgeRemoteValue.Location = New-Object System.Drawing.Point(72,99)
$knowledgeRemoteValue.Size = New-Object System.Drawing.Size(500,20)
$knowledgeGitPanel.Controls.Add($knowledgeRemoteValue)

$commitCaption = New-Object System.Windows.Forms.Label
$commitCaption.Text = 'Last commit:'
$commitCaption.Font = New-Font 8 ([System.Drawing.FontStyle]::Bold)
$commitCaption.AutoSize = $true
$commitCaption.Location = New-Object System.Drawing.Point(16,125)
$knowledgeGitPanel.Controls.Add($commitCaption)
$knowledgeCommitValue = New-Object System.Windows.Forms.Label
$knowledgeCommitValue.Text = '—'
$knowledgeCommitValue.AutoEllipsis = $true
$knowledgeCommitValue.Location = New-Object System.Drawing.Point(88,124)
$knowledgeCommitValue.Size = New-Object System.Drawing.Size(480,20)
$knowledgeGitPanel.Controls.Add($knowledgeCommitValue)

$knowledgeSetupButton = New-Object System.Windows.Forms.Button
$knowledgeSetupButton.Text = '⚙ Проверить GitHub SSH'
$knowledgeSetupButton.Size = New-Object System.Drawing.Size(175,36)
$knowledgeSetupButton.Location = New-Object System.Drawing.Point(625,18)
$knowledgeSetupButton.Add_Click({ Test-KnowledgeGitHubConnection })
$knowledgeGitPanel.Controls.Add($knowledgeSetupButton)

$knowledgeSshCreateButton = New-Object System.Windows.Forms.Button
$knowledgeSshCreateButton.Text = '🔑 Создать SSH key'
$knowledgeSshCreateButton.Font = New-Font 8
$knowledgeSshCreateButton.Size = New-Object System.Drawing.Size(210, 34)
$knowledgeSshCreateButton.Location = New-Object System.Drawing.Point(790, 76)
$knowledgeSshCreateButton.Add_Click({ [void](Configure-KnowledgeGitHubSsh) })
$knowledgeGitPanel.Controls.Add($knowledgeSshCreateButton)

$knowledgeSshCopyButton = New-Object System.Windows.Forms.Button
$knowledgeSshCopyButton.Text = '📋 Скопировать public key'
$knowledgeSshCopyButton.Font = New-Font 8
$knowledgeSshCopyButton.Size = New-Object System.Drawing.Size(210, 34)
$knowledgeSshCopyButton.Location = New-Object System.Drawing.Point(790, 114)
$knowledgeSshCopyButton.Add_Click({ [void](Copy-GitHubSshPublicKey) })
$knowledgeGitPanel.Controls.Add($knowledgeSshCopyButton)

$knowledgeSyncButton = New-Object System.Windows.Forms.Button
$knowledgeSyncButton.Text = '↻ Synchronize'
$knowledgeSyncButton.Font = New-Font 9 ([System.Drawing.FontStyle]::Bold)
$knowledgeSyncButton.Size = New-Object System.Drawing.Size(175,36)
$knowledgeSyncButton.Location = New-Object System.Drawing.Point(625,62)
$knowledgeSyncButton.BackColor = [System.Drawing.Color]::FromArgb(37,99,235)
$knowledgeSyncButton.ForeColor = [System.Drawing.Color]::White
$knowledgeSyncButton.FlatStyle = 'Flat'
$knowledgeSyncButton.Add_Click({ Sync-KnowledgeRepository })
$knowledgeGitPanel.Controls.Add($knowledgeSyncButton)

$knowledgeRefreshButton = New-Object System.Windows.Forms.Button
$knowledgeRefreshButton.Text = 'Обновить статус'
$knowledgeRefreshButton.Size = New-Object System.Drawing.Size(175,32)
$knowledgeRefreshButton.Location = New-Object System.Drawing.Point(625,106)
$knowledgeRefreshButton.Add_Click({ Refresh-KnowledgeStatusInteractive })
$knowledgeGitPanel.Controls.Add($knowledgeRefreshButton)

$knowledgeCommitLabel = New-Object System.Windows.Forms.Label
$knowledgeCommitLabel.Text = 'Commit message'
$knowledgeCommitLabel.Font = New-Font 9 ([System.Drawing.FontStyle]::Bold)
$knowledgeCommitLabel.AutoSize = $true
$knowledgeCommitLabel.Location = New-Object System.Drawing.Point(20,394)
$knowledgeTab.Controls.Add($knowledgeCommitLabel)

$knowledgeCommitMessage = New-Object System.Windows.Forms.TextBox
$knowledgeCommitMessage.Font = New-Font 10
$knowledgeCommitMessage.Location = New-Object System.Drawing.Point(20,420)
$knowledgeCommitMessage.Size = New-Object System.Drawing.Size(565,30)
$knowledgeCommitMessage.Text = ''
$knowledgeTab.Controls.Add($knowledgeCommitMessage)

$knowledgeCommitButton = New-Object System.Windows.Forms.Button
$knowledgeCommitButton.Text = '💾 Commit'
$knowledgeCommitButton.Font = New-Font 9 ([System.Drawing.FontStyle]::Bold)
$knowledgeCommitButton.Size = New-Object System.Drawing.Size(245,34)
$knowledgeCommitButton.Location = New-Object System.Drawing.Point(605,418)
$knowledgeCommitButton.Add_Click({ Commit-KnowledgeChanges })
$knowledgeTab.Controls.Add($knowledgeCommitButton)

$knowledgeSyncInfo = New-Object System.Windows.Forms.Label
$knowledgeSyncInfo.Text = 'GitHub по умолчанию: Gamazzz/rx2go-ai-qa. При старте выполняется безопасная синхронизация, если нет локальных изменений.'
$knowledgeSyncInfo.Font = New-Font 8
$knowledgeSyncInfo.ForeColor = [System.Drawing.Color]::DimGray
$knowledgeSyncInfo.AutoSize = $true
$knowledgeSyncInfo.Location = New-Object System.Drawing.Point(20,462)
$knowledgeTab.Controls.Add($knowledgeSyncInfo)

$knowledgeRecentTitle = New-Object System.Windows.Forms.Label
$knowledgeRecentTitle.Text = 'Последние изменения Knowledge Base'
$knowledgeRecentTitle.Font = New-Font 10 ([System.Drawing.FontStyle]::Bold)
$knowledgeRecentTitle.AutoSize = $true
$knowledgeRecentTitle.Location = New-Object System.Drawing.Point(20,502)
$knowledgeTab.Controls.Add($knowledgeRecentTitle)

$knowledgeRecentList = New-Object System.Windows.Forms.ListBox
$knowledgeRecentList.Font = New-Object System.Drawing.Font('Consolas',9)
$knowledgeRecentList.Location = New-Object System.Drawing.Point(20,530)
$knowledgeRecentList.Size = New-Object System.Drawing.Size(830,155)
$knowledgeTab.Controls.Add($knowledgeRecentList)

$knowledgePolicy = New-Object System.Windows.Forms.Label
$knowledgePolicy.Text = 'В Git: knowledge / jira-cases / scenarios / tests / pages / api / agents / scripts / docs. Не в Git: .secrets, .env, reports, jira-runs, screenshots, videos, traces.'
$knowledgePolicy.Font = New-Font 8
$knowledgePolicy.ForeColor = [System.Drawing.Color]::DimGray
$knowledgePolicy.AutoSize = $true
$knowledgePolicy.Location = New-Object System.Drawing.Point(20,700)
$knowledgeTab.Controls.Add($knowledgePolicy)



function Move-ControlToParent {
    param(
        [System.Windows.Forms.Control]$Control,
        [System.Windows.Forms.Control]$Parent
    )

    if ($null -eq $Control -or $null -eq $Parent) { return }
    if ($Control.Parent -ne $null -and $Control.Parent -ne $Parent) {
        $Control.Parent.Controls.Remove($Control)
    }
    if ($Control.Parent -ne $Parent) {
        $Parent.Controls.Add($Control) | Out-Null
    }
}

function Add-ColumnStylePercent {
    param([System.Windows.Forms.TableLayoutPanel]$Table, [single]$Width)
    $style = New-Object System.Windows.Forms.ColumnStyle
    $style.SizeType = [System.Windows.Forms.SizeType]::Percent
    $style.Width = $Width
    $Table.ColumnStyles.Add($style) | Out-Null
}


function Add-ColumnStyleAbsolute {
    param([System.Windows.Forms.TableLayoutPanel]$Table, [single]$Width)
    $style = New-Object System.Windows.Forms.ColumnStyle
    $style.SizeType = [System.Windows.Forms.SizeType]::Absolute
    $style.Width = $Width
    $Table.ColumnStyles.Add($style) | Out-Null
}

function Add-RowStylePercent {
    param([System.Windows.Forms.TableLayoutPanel]$Table, [single]$Height)
    $style = New-Object System.Windows.Forms.RowStyle
    $style.SizeType = [System.Windows.Forms.SizeType]::Percent
    $style.Height = $Height
    $Table.RowStyles.Add($style) | Out-Null
}

function Add-RowStyleAbsolute {
    param([System.Windows.Forms.TableLayoutPanel]$Table, [single]$Height)
    $style = New-Object System.Windows.Forms.RowStyle
    $style.SizeType = [System.Windows.Forms.SizeType]::Absolute
    $style.Height = $Height
    $Table.RowStyles.Add($style) | Out-Null
}

function Apply-ResponsiveLayout {
    if ($script:ResponsiveLayoutApplied) { return }
    $script:ResponsiveLayoutApplied = $true

    $form.SuspendLayout()
    $tabs.SuspendLayout()
    $quickTab.SuspendLayout()
    $jiraTab.SuspendLayout()
    $knowledgeTab.SuspendLayout()

    # Hide obsolete captions replaced by structured containers.
    foreach ($oldCtrl in @($resultsTitle, $failedTitle, $logTitle, $jiraPlanTitle, $jiraRuleLabel, $jiraEnvLabel, $jiraQaCommentLabel, $knowledgeTitle, $knowledgeHint, $knowledgeCommitLabel, $knowledgeRecentTitle)) {
        if ($oldCtrl) { $oldCtrl.Visible = $false }
    }

    # ------------------------------------------------------------------
    # QUICK RUN TAB
    # ------------------------------------------------------------------
    $quickRoot = New-Object System.Windows.Forms.Panel
    $quickRoot.Dock = 'Fill'
    $quickRoot.Padding = New-Object System.Windows.Forms.Padding(12)
    $quickRoot.BackColor = [System.Drawing.Color]::FromArgb(246,248,251)
    $quickTab.AutoScroll = $true
    $quickTab.Controls.Add($quickRoot) | Out-Null
    $quickRoot.BringToFront()

    # The old configPanel used absolute coordinates. Keep it detached so changing
    # BRANCH/HOT/ADM can never shift or overflow the Quick Run page.
    if ($configPanel.Parent) {
        $configPanel.Parent.Controls.Remove($configPanel)
    }
    $configPanel.Visible = $false

    $quickGrid = New-Object System.Windows.Forms.TableLayoutPanel
    $quickGrid.Dock = 'Fill'
    $quickGrid.ColumnCount = 1
    $quickGrid.RowCount = 5
    $quickGrid.Padding = New-Object System.Windows.Forms.Padding(0)
    $quickGrid.Margin = New-Object System.Windows.Forms.Padding(0)
    Add-ColumnStylePercent $quickGrid 100
    Add-RowStyleAbsolute $quickGrid 236
    Add-RowStyleAbsolute $quickGrid 104
    Add-RowStyleAbsolute $quickGrid 76
    Add-RowStyleAbsolute $quickGrid 170
    Add-RowStylePercent $quickGrid 100
    $quickRoot.Controls.Add($quickGrid) | Out-Null

    # --------------------------------------------------------------
    # 1. AUTH + CONNECTIONS — all credentials on one page
    # --------------------------------------------------------------
    $quickConfigGroup = New-Object System.Windows.Forms.GroupBox
    $quickConfigGroup.Text = '1. Доступ и подключения'
    $quickConfigGroup.Dock = 'Fill'
    $quickConfigGroup.Padding = New-Object System.Windows.Forms.Padding(12,8,12,10)
    $quickConfigGroup.Margin = New-Object System.Windows.Forms.Padding(0,0,0,6)
    $quickGrid.Controls.Add($quickConfigGroup, 0, 0)

    $quickAccessGrid = New-Object System.Windows.Forms.TableLayoutPanel
    $quickAccessGrid.Dock = 'Fill'
    $quickAccessGrid.ColumnCount = 4
    $quickAccessGrid.RowCount = 5
    $quickAccessGrid.Margin = New-Object System.Windows.Forms.Padding(0)
    Add-ColumnStylePercent $quickAccessGrid 17
    Add-ColumnStylePercent $quickAccessGrid 33
    Add-ColumnStylePercent $quickAccessGrid 17
    Add-ColumnStylePercent $quickAccessGrid 33
    for ($i = 0; $i -lt 5; $i++) { Add-RowStylePercent $quickAccessGrid 20 }
    $quickConfigGroup.Controls.Add($quickAccessGrid) | Out-Null

    $envLabel.Text = 'Окружение'
    $envLabel.Dock = 'Fill'
    $envLabel.TextAlign = 'MiddleLeft'
    $envLabel.Margin = New-Object System.Windows.Forms.Padding(4,4,8,4)
    Move-ControlToParent $envLabel $quickAccessGrid
    $quickAccessGrid.SetCellPosition($envLabel, (New-Object System.Windows.Forms.TableLayoutPanelCellPosition(0,0)))

    $environmentCombo.Dock = 'Fill'
    $environmentCombo.Margin = New-Object System.Windows.Forms.Padding(0,4,12,4)
    Move-ControlToParent $environmentCombo $quickAccessGrid
    $quickAccessGrid.SetCellPosition($environmentCombo, (New-Object System.Windows.Forms.TableLayoutPanelCellPosition(1,0)))

    $urlCaption.Text = 'URL'
    $urlCaption.Dock = 'Fill'
    $urlCaption.TextAlign = 'MiddleLeft'
    $urlCaption.Margin = New-Object System.Windows.Forms.Padding(4,4,8,4)
    Move-ControlToParent $urlCaption $quickAccessGrid
    $quickAccessGrid.SetCellPosition($urlCaption, (New-Object System.Windows.Forms.TableLayoutPanelCellPosition(2,0)))

    $urlValue.AutoSize = $false
    $urlValue.Dock = 'Fill'
    $urlValue.TextAlign = 'MiddleLeft'
    $urlValue.AutoEllipsis = $true
    $urlValue.Margin = New-Object System.Windows.Forms.Padding(0,4,4,4)
    Move-ControlToParent $urlValue $quickAccessGrid
    $quickAccessGrid.SetCellPosition($urlValue, (New-Object System.Windows.Forms.TableLayoutPanelCellPosition(3,0)))

    $gatewayLoginLabel = New-Object System.Windows.Forms.Label
    $gatewayLoginLabel.Text = 'ADM — логин 1-го фактора'
    $gatewayLoginLabel.Font = New-Font 9 ([System.Drawing.FontStyle]::Bold)
    $gatewayLoginLabel.Dock = 'Fill'
    $gatewayLoginLabel.TextAlign = 'MiddleLeft'
    $gatewayLoginLabel.Margin = New-Object System.Windows.Forms.Padding(4,4,8,4)
    $quickAccessGrid.Controls.Add($gatewayLoginLabel, 0, 1)

    $gatewayLoginBox = New-Object System.Windows.Forms.TextBox
    $gatewayLoginBox.Text = 'admin'
    $gatewayLoginBox.ReadOnly = $true
    $gatewayLoginBox.Font = New-Font 10
    $gatewayLoginBox.Dock = 'Fill'
    $gatewayLoginBox.Margin = New-Object System.Windows.Forms.Padding(0,4,12,4)
    $quickAccessGrid.Controls.Add($gatewayLoginBox, 1, 1)
    $script:GatewayLoginBox = $gatewayLoginBox

    $dailyLabel.Text = 'ADM — суточный пароль'
    $dailyLabel.Dock = 'Fill'
    $dailyLabel.TextAlign = 'MiddleLeft'
    $dailyLabel.Margin = New-Object System.Windows.Forms.Padding(4,4,8,4)
    Move-ControlToParent $dailyLabel $quickAccessGrid
    $quickAccessGrid.SetCellPosition($dailyLabel, (New-Object System.Windows.Forms.TableLayoutPanelCellPosition(2,1)))

    $dailyPassword.Dock = 'Fill'
    $dailyPassword.Margin = New-Object System.Windows.Forms.Padding(0,4,4,4)
    Move-ControlToParent $dailyPassword $quickAccessGrid
    $quickAccessGrid.SetCellPosition($dailyPassword, (New-Object System.Windows.Forms.TableLayoutPanelCellPosition(3,1)))

    $appLoginLabel = New-Object System.Windows.Forms.Label
    $appLoginLabel.Text = 'Rx2GO — логин'
    $appLoginLabel.Font = New-Font 9 ([System.Drawing.FontStyle]::Bold)
    $appLoginLabel.Dock = 'Fill'
    $appLoginLabel.TextAlign = 'MiddleLeft'
    $appLoginLabel.Margin = New-Object System.Windows.Forms.Padding(4,4,8,4)
    $quickAccessGrid.Controls.Add($appLoginLabel, 0, 2)

    $appLoginBox = New-Object System.Windows.Forms.TextBox
    $appLoginBox.Text = 'sergeyqa'
    $appLoginBox.ReadOnly = $true
    $appLoginBox.Font = New-Font 10
    $appLoginBox.Dock = 'Fill'
    $appLoginBox.Margin = New-Object System.Windows.Forms.Padding(0,4,12,4)
    $quickAccessGrid.Controls.Add($appLoginBox, 1, 2)
    $script:InlineAppLoginBox = $appLoginBox

    $appPasswordLabel = New-Object System.Windows.Forms.Label
    $appPasswordLabel.Text = 'Rx2GO — пароль'
    $appPasswordLabel.Font = New-Font 9 ([System.Drawing.FontStyle]::Bold)
    $appPasswordLabel.Dock = 'Fill'
    $appPasswordLabel.TextAlign = 'MiddleLeft'
    $appPasswordLabel.Margin = New-Object System.Windows.Forms.Padding(4,4,8,4)
    $quickAccessGrid.Controls.Add($appPasswordLabel, 2, 2)

    $appPasswordPanel = New-Object System.Windows.Forms.TableLayoutPanel
    $appPasswordPanel.Dock = 'Fill'
    $appPasswordPanel.ColumnCount = 2
    $appPasswordPanel.RowCount = 1
    $appPasswordPanel.Margin = New-Object System.Windows.Forms.Padding(0,2,4,2)
    Add-ColumnStylePercent $appPasswordPanel 57
    Add-ColumnStylePercent $appPasswordPanel 43
    Add-RowStylePercent $appPasswordPanel 100
    $quickAccessGrid.Controls.Add($appPasswordPanel, 3, 2)

    $appPasswordBox = New-Object System.Windows.Forms.TextBox
    $appPasswordBox.UseSystemPasswordChar = $true
    $appPasswordBox.Font = New-Font 10
    $appPasswordBox.Dock = 'Fill'
    $appPasswordBox.Margin = New-Object System.Windows.Forms.Padding(0,2,6,2)
    $appPasswordPanel.Controls.Add($appPasswordBox, 0, 0)
    $script:InlineAppPasswordBox = $appPasswordBox

    $credentialButton.Text = 'Сохранить пароль'
    $credentialButton.Dock = 'Fill'
    $credentialButton.Margin = New-Object System.Windows.Forms.Padding(0,1,0,1)
    Move-ControlToParent $credentialButton $appPasswordPanel
    $appPasswordPanel.SetCellPosition($credentialButton, (New-Object System.Windows.Forms.TableLayoutPanelCellPosition(1,0)))

    $quickCodexStatus = New-Object System.Windows.Forms.Label
    $quickCodexStatus.Text = '● Codex CLI: проверка…'
    $quickCodexStatus.Font = New-Font 9 ([System.Drawing.FontStyle]::Bold)
    $quickCodexStatus.Dock = 'Fill'
    $quickCodexStatus.TextAlign = 'MiddleLeft'
    $quickCodexStatus.Margin = New-Object System.Windows.Forms.Padding(4,4,8,4)
    $quickAccessGrid.Controls.Add($quickCodexStatus, 0, 3)
    $quickAccessGrid.SetColumnSpan($quickCodexStatus, 2)
    $script:QuickCodexStatus = $quickCodexStatus

    $quickGptStatus = New-Object System.Windows.Forms.Label
    $quickGptStatus.Text = '● ChatGPT: проверка…'
    $quickGptStatus.Font = New-Font 9 ([System.Drawing.FontStyle]::Bold)
    $quickGptStatus.Dock = 'Fill'
    $quickGptStatus.TextAlign = 'MiddleLeft'
    $quickGptStatus.Margin = New-Object System.Windows.Forms.Padding(4,4,8,4)
    $quickAccessGrid.Controls.Add($quickGptStatus, 2, 3)
    $script:QuickGptStatus = $quickGptStatus

    $quickConnectionsPanel = New-Object System.Windows.Forms.FlowLayoutPanel
    $quickConnectionsPanel.Dock = 'Fill'
    $quickConnectionsPanel.FlowDirection = 'LeftToRight'
    $quickConnectionsPanel.WrapContents = $false
    $quickConnectionsPanel.Margin = New-Object System.Windows.Forms.Padding(0,2,4,2)
    $quickAccessGrid.Controls.Add($quickConnectionsPanel, 3, 3)

    $quickRecheckConnectionsButton = New-Object System.Windows.Forms.Button
    $quickRecheckConnectionsButton.Text = 'Проверить'
    $quickRecheckConnectionsButton.Font = New-Font 9
    $quickRecheckConnectionsButton.Size = New-Object System.Drawing.Size(95,30)
    $quickRecheckConnectionsButton.Margin = New-Object System.Windows.Forms.Padding(0,2,6,2)
    $quickRecheckConnectionsButton.Add_Click({ Update-ChatGPTOAuthUI })
    $quickConnectionsPanel.Controls.Add($quickRecheckConnectionsButton) | Out-Null
    $script:QuickRecheckConnectionsButton = $quickRecheckConnectionsButton

    $quickChatGptButton = New-Object System.Windows.Forms.Button
    $quickChatGptButton.Text = 'Подключить ChatGPT'
    $quickChatGptButton.Font = New-Font 9
    $quickChatGptButton.Size = New-Object System.Drawing.Size(180,30)
    $quickChatGptButton.Margin = New-Object System.Windows.Forms.Padding(0,2,0,2)
    $quickChatGptButton.Add_Click({ Connect-ChatGPTOAuth })
    $quickConnectionsPanel.Controls.Add($quickChatGptButton) | Out-Null
    $script:QuickChatGptButton = $quickChatGptButton

    $authCaption.Text = 'Схема'
    $authCaption.Dock = 'Fill'
    $authCaption.TextAlign = 'MiddleLeft'
    $authCaption.Margin = New-Object System.Windows.Forms.Padding(4,4,8,4)
    Move-ControlToParent $authCaption $quickAccessGrid
    $quickAccessGrid.SetCellPosition($authCaption, (New-Object System.Windows.Forms.TableLayoutPanelCellPosition(0,4)))

    $authValue.AutoSize = $false
    $authValue.Dock = 'Fill'
    $authValue.TextAlign = 'MiddleLeft'
    $authValue.AutoEllipsis = $true
    $authValue.Margin = New-Object System.Windows.Forms.Padding(0,4,12,4)
    Move-ControlToParent $authValue $quickAccessGrid
    $quickAccessGrid.SetCellPosition($authValue, (New-Object System.Windows.Forms.TableLayoutPanelCellPosition(1,4)))
    $quickAccessGrid.SetColumnSpan($authValue, 2)

    $quickCredentialStatus = New-Object System.Windows.Forms.Label
    $quickCredentialStatus.Text = '● пароль Rx2GO не сохранён'
    $quickCredentialStatus.Font = New-Font 8.5
    $quickCredentialStatus.Dock = 'Fill'
    $quickCredentialStatus.TextAlign = 'MiddleLeft'
    $quickCredentialStatus.ForeColor = [System.Drawing.Color]::DimGray
    $quickCredentialStatus.Margin = New-Object System.Windows.Forms.Padding(0,4,4,4)
    $quickAccessGrid.Controls.Add($quickCredentialStatus, 3, 4)
    $script:QuickCredentialStatus = $quickCredentialStatus

    # Load the encrypted Rx2GO credential into the same page.
    $savedInlineApp = Get-AppCredentialPlain
    if ($savedInlineApp) {
        $appLoginBox.Text = [string]$savedInlineApp.Login
        $appPasswordBox.Text = [string]$savedInlineApp.Password
        $quickCredentialStatus.Text = '● пароль Rx2GO загружен из Windows DPAPI'
        $quickCredentialStatus.ForeColor = [System.Drawing.Color]::FromArgb(32,120,72)
        $savedInlineApp.Password = $null
    }

    # The old hint remains as a compact stable line below the auth block.
    $dailyHint.Visible = $false

    # --------------------------------------------------------------
    # 2. TEST SETTINGS
    # --------------------------------------------------------------
    $quickTestGroup = New-Object System.Windows.Forms.GroupBox
    $quickTestGroup.Text = '2. Параметры теста'
    $quickTestGroup.Dock = 'Fill'
    $quickTestGroup.Padding = New-Object System.Windows.Forms.Padding(12,8,12,8)
    $quickTestGroup.Margin = New-Object System.Windows.Forms.Padding(0,0,0,6)
    $quickGrid.Controls.Add($quickTestGroup, 0, 1)

    $quickTestGrid = New-Object System.Windows.Forms.TableLayoutPanel
    $quickTestGrid.Dock = 'Fill'
    $quickTestGrid.ColumnCount = 4
    $quickTestGrid.RowCount = 2
    Add-ColumnStylePercent $quickTestGrid 18
    Add-ColumnStylePercent $quickTestGrid 27
    Add-ColumnStylePercent $quickTestGrid 27
    Add-ColumnStylePercent $quickTestGrid 28
    Add-RowStylePercent $quickTestGrid 50
    Add-RowStylePercent $quickTestGrid 50
    $quickTestGroup.Controls.Add($quickTestGrid) | Out-Null

    $suiteLabel.Text = 'Что проверить'
    $suiteLabel.Dock = 'Fill'
    $suiteLabel.TextAlign = 'MiddleLeft'
    $suiteLabel.Margin = New-Object System.Windows.Forms.Padding(4,3,8,3)
    Move-ControlToParent $suiteLabel $quickTestGrid
    $quickTestGrid.SetCellPosition($suiteLabel, (New-Object System.Windows.Forms.TableLayoutPanelCellPosition(0,0)))

    $suiteCombo.Dock = 'Fill'
    $suiteCombo.Margin = New-Object System.Windows.Forms.Padding(0,3,12,3)
    Move-ControlToParent $suiteCombo $quickTestGrid
    $quickTestGrid.SetCellPosition($suiteCombo, (New-Object System.Windows.Forms.TableLayoutPanelCellPosition(1,0)))

    $headedCheck.Dock = 'Fill'
    $headedCheck.Margin = New-Object System.Windows.Forms.Padding(4,3,8,3)
    Move-ControlToParent $headedCheck $quickTestGrid
    $quickTestGrid.SetCellPosition($headedCheck, (New-Object System.Windows.Forms.TableLayoutPanelCellPosition(2,0)))

    $keepBrowserOpenCheck.Dock = 'Fill'
    $keepBrowserOpenCheck.Margin = New-Object System.Windows.Forms.Padding(4,3,4,3)
    Move-ControlToParent $keepBrowserOpenCheck $quickTestGrid
    $quickTestGrid.SetCellPosition($keepBrowserOpenCheck, (New-Object System.Windows.Forms.TableLayoutPanelCellPosition(3,0)))

    $browserModeLabel.Dock = 'Fill'
    $browserModeLabel.TextAlign = 'MiddleLeft'
    $browserModeLabel.Margin = New-Object System.Windows.Forms.Padding(4,3,8,3)
    Move-ControlToParent $browserModeLabel $quickTestGrid
    $quickTestGrid.SetCellPosition($browserModeLabel, (New-Object System.Windows.Forms.TableLayoutPanelCellPosition(0,1)))
    $quickTestGrid.SetColumnSpan($browserModeLabel, 2)

    $mutatingCheck.Dock = 'Fill'
    $mutatingCheck.Margin = New-Object System.Windows.Forms.Padding(4,3,4,3)
    Move-ControlToParent $mutatingCheck $quickTestGrid
    $quickTestGrid.SetCellPosition($mutatingCheck, (New-Object System.Windows.Forms.TableLayoutPanelCellPosition(2,1)))
    $quickTestGrid.SetColumnSpan($mutatingCheck, 2)

    # --------------------------------------------------------------
    # 3. ACTION
    # --------------------------------------------------------------
    $actionPanel = New-Object System.Windows.Forms.Panel
    $actionPanel.Dock = 'Fill'
    $actionPanel.Margin = New-Object System.Windows.Forms.Padding(0,0,0,6)
    $quickGrid.Controls.Add($actionPanel, 0, 2)

    $actionGrid = New-Object System.Windows.Forms.TableLayoutPanel
    $actionGrid.Dock = 'Fill'
    $actionGrid.ColumnCount = 3
    $actionGrid.RowCount = 1
    Add-ColumnStylePercent $actionGrid 24
    Add-ColumnStylePercent $actionGrid 12
    Add-ColumnStylePercent $actionGrid 64
    Add-RowStylePercent $actionGrid 100
    $actionPanel.Controls.Add($actionGrid) | Out-Null

    $runButton.Dock = 'Fill'
    $runButton.Margin = New-Object System.Windows.Forms.Padding(0,8,8,8)
    Move-ControlToParent $runButton $actionGrid
    $actionGrid.SetCellPosition($runButton, (New-Object System.Windows.Forms.TableLayoutPanelCellPosition(0,0)))

    $cancelButton.Dock = 'Fill'
    $cancelButton.Margin = New-Object System.Windows.Forms.Padding(0,8,12,8)
    Move-ControlToParent $cancelButton $actionGrid
    $actionGrid.SetCellPosition($cancelButton, (New-Object System.Windows.Forms.TableLayoutPanelCellPosition(1,0)))

    $actionStatusPanel = New-Object System.Windows.Forms.TableLayoutPanel
    $actionStatusPanel.Dock = 'Fill'
    $actionStatusPanel.ColumnCount = 1
    $actionStatusPanel.RowCount = 2
    Add-ColumnStylePercent $actionStatusPanel 100
    Add-RowStylePercent $actionStatusPanel 55
    Add-RowStylePercent $actionStatusPanel 45
    $actionStatusPanel.Margin = New-Object System.Windows.Forms.Padding(0,2,0,2)
    $actionGrid.Controls.Add($actionStatusPanel, 2, 0)

    $statusLabel.Dock = 'Fill'
    $statusLabel.TextAlign = 'BottomLeft'
    $statusLabel.Margin = New-Object System.Windows.Forms.Padding(0,0,0,2)
    Move-ControlToParent $statusLabel $actionStatusPanel
    $actionStatusPanel.SetCellPosition($statusLabel, (New-Object System.Windows.Forms.TableLayoutPanelCellPosition(0,0)))

    $progress.Dock = 'Fill'
    $progress.Margin = New-Object System.Windows.Forms.Padding(0,4,8,10)
    Move-ControlToParent $progress $actionStatusPanel
    $actionStatusPanel.SetCellPosition($progress, (New-Object System.Windows.Forms.TableLayoutPanelCellPosition(0,1)))

    # --------------------------------------------------------------
    # 4. RESULTS
    # --------------------------------------------------------------
    $metricsGrid = New-Object System.Windows.Forms.TableLayoutPanel
    $metricsGrid.Dock = 'Fill'
    $metricsGrid.ColumnCount = 2
    $metricsGrid.RowCount = 1
    $metricsGrid.Margin = New-Object System.Windows.Forms.Padding(0,0,0,6)
    Add-ColumnStylePercent $metricsGrid 45
    Add-ColumnStylePercent $metricsGrid 55
    Add-RowStylePercent $metricsGrid 100
    $quickGrid.Controls.Add($metricsGrid, 0, 3)

    $summaryGroup = New-Object System.Windows.Forms.GroupBox
    $summaryGroup.Text = 'Результаты'
    $summaryGroup.Dock = 'Fill'
    $summaryGroup.Padding = New-Object System.Windows.Forms.Padding(10)
    $summaryGroup.Margin = New-Object System.Windows.Forms.Padding(0,0,6,0)
    $metricsGrid.Controls.Add($summaryGroup, 0, 0)

    $summaryPanel = New-Object System.Windows.Forms.Panel
    $summaryPanel.Dock = 'Fill'
    $summaryGroup.Controls.Add($summaryPanel) | Out-Null

    $passValue.Parent.Size = New-Object System.Drawing.Size(116, 78)
    $passValue.Parent.Location = New-Object System.Drawing.Point(8, 14)
    Move-ControlToParent $passValue.Parent $summaryPanel

    $failValue.Parent.Size = New-Object System.Drawing.Size(116, 78)
    $failValue.Parent.Location = New-Object System.Drawing.Point(132, 14)
    Move-ControlToParent $failValue.Parent $summaryPanel

    $skipValue.Parent.Size = New-Object System.Drawing.Size(116, 78)
    $skipValue.Parent.Location = New-Object System.Drawing.Point(256, 14)
    Move-ControlToParent $skipValue.Parent $summaryPanel

    $jiraButton.Size = New-Object System.Drawing.Size(210, 34)
    $jiraButton.Location = New-Object System.Drawing.Point(8, 104)
    Move-ControlToParent $jiraButton $summaryPanel

    $htmlButton.Size = New-Object System.Drawing.Size(170, 34)
    $htmlButton.Location = New-Object System.Drawing.Point(228, 104)
    Move-ControlToParent $htmlButton $summaryPanel

    $failedGroup = New-Object System.Windows.Forms.GroupBox
    $failedGroup.Text = 'Упавшие сценарии'
    $failedGroup.Dock = 'Fill'
    $failedGroup.Padding = New-Object System.Windows.Forms.Padding(10)
    $failedGroup.Margin = New-Object System.Windows.Forms.Padding(6,0,0,0)
    $metricsGrid.Controls.Add($failedGroup, 1, 0)

    $failedList.Dock = 'Fill'
    $failedList.IntegralHeight = $false
    Move-ControlToParent $failedList $failedGroup

    # --------------------------------------------------------------
    # 5. LOG
    # --------------------------------------------------------------
    $logGroup = New-Object System.Windows.Forms.GroupBox
    $logGroup.Text = 'Ход тестирования'
    $logGroup.Dock = 'Fill'
    $logGroup.Padding = New-Object System.Windows.Forms.Padding(10)
    $quickGrid.Controls.Add($logGroup, 0, 4)

    $logBox.Dock = 'Fill'
    Move-ControlToParent $logBox $logGroup

    # ------------------------------------------------------------------
    # JIRA TAB
    # ------------------------------------------------------------------
    $jiraRoot = New-Object System.Windows.Forms.Panel
    $jiraRoot.Dock = 'Fill'
    $jiraRoot.Padding = New-Object System.Windows.Forms.Padding(12)
    $jiraRoot.BackColor = [System.Drawing.Color]::FromArgb(246,248,251)
    $jiraTab.Controls.Add($jiraRoot) | Out-Null
    $jiraRoot.BringToFront()

    $jiraGrid = New-Object System.Windows.Forms.TableLayoutPanel
    $jiraGrid.Dock = 'Fill'
    $jiraGrid.ColumnCount = 2
    $jiraGrid.RowCount = 7
    Add-ColumnStylePercent $jiraGrid 66
    Add-ColumnStylePercent $jiraGrid 34
    Add-RowStyleAbsolute $jiraGrid 74
    Add-RowStyleAbsolute $jiraGrid 170
    Add-RowStyleAbsolute $jiraGrid 170
    Add-RowStyleAbsolute $jiraGrid 104
    Add-RowStyleAbsolute $jiraGrid 170
    Add-RowStylePercent $jiraGrid 100
    Add-RowStyleAbsolute $jiraGrid 50
    $jiraRoot.Controls.Add($jiraGrid) | Out-Null

    $jiraHeaderPanel = New-Object System.Windows.Forms.Panel
    $jiraHeaderPanel.Dock = 'Fill'
    $jiraGrid.Controls.Add($jiraHeaderPanel, 0, 0)

    $jiraSourceLabel.Font = New-Font 14 ([System.Drawing.FontStyle]::Bold)
    $jiraSourceLabel.AutoSize = $true
    $jiraSourceLabel.Location = New-Object System.Drawing.Point(0, 4)
    Move-ControlToParent $jiraSourceLabel $jiraHeaderPanel

    $jiraSourceHint.Font = New-Font 9
    $jiraSourceHint.ForeColor = [System.Drawing.Color]::DimGray
    $jiraSourceHint.AutoSize = $false
    $jiraSourceHint.Size = New-Object System.Drawing.Size(700, 42)
    $jiraSourceHint.Location = New-Object System.Drawing.Point(0, 34)
    Move-ControlToParent $jiraSourceHint $jiraHeaderPanel

    $jiraIntegrationGroup = New-Object System.Windows.Forms.GroupBox
    $jiraIntegrationGroup.Text = 'Интеграции'
    $jiraIntegrationGroup.Dock = 'Fill'
    $jiraIntegrationGroup.Padding = New-Object System.Windows.Forms.Padding(10)
    $jiraGrid.Controls.Add($jiraIntegrationGroup, 1, 0)

    $jiraIntegrationPanel = New-Object System.Windows.Forms.Panel
    $jiraIntegrationPanel.Dock = 'Fill'
    $jiraIntegrationGroup.Controls.Add($jiraIntegrationPanel) | Out-Null

    $chatGptStatus.AutoSize = $true
    $chatGptStatus.Location = New-Object System.Drawing.Point(8, 10)
    Move-ControlToParent $chatGptStatus $jiraIntegrationPanel

    $jiraConnectionStatus.AutoSize = $true
    $jiraConnectionStatus.Location = New-Object System.Drawing.Point(8, 34)
    Move-ControlToParent $jiraConnectionStatus $jiraIntegrationPanel

    $jiraAiCheck.AutoSize = $true
    $jiraAiCheck.Location = New-Object System.Drawing.Point(8, 58)
    Move-ControlToParent $jiraAiCheck $jiraIntegrationPanel


    $agentCountLabel = New-Object System.Windows.Forms.Label
    $agentCountLabel.Text = '5 специализированных агентов'
    $agentCountLabel.Font = New-Font 8 ([System.Drawing.FontStyle]::Bold)
    $agentCountLabel.ForeColor = [System.Drawing.Color]::FromArgb(37,99,235)
    $agentCountLabel.AutoSize = $true
    $agentCountLabel.Location = New-Object System.Drawing.Point(190, 67)
    $jiraIntegrationPanel.Controls.Add($agentCountLabel) | Out-Null

    $chatGptConnectButton.Size = New-Object System.Drawing.Size(160, 30)
    $chatGptConnectButton.Location = New-Object System.Drawing.Point(190, 8)
    Move-ControlToParent $chatGptConnectButton $jiraIntegrationPanel

    $jiraConnectButton.Size = New-Object System.Drawing.Size(160, 30)
    $jiraConnectButton.Location = New-Object System.Drawing.Point(190, 40)
    Move-ControlToParent $jiraConnectButton $jiraIntegrationPanel

    $jiraSourceGroup = New-Object System.Windows.Forms.GroupBox
    $jiraSourceGroup.Text = 'Ссылка / ключ / описание Jira'
    $jiraSourceGroup.Dock = 'Fill'
    $jiraSourceGroup.Padding = New-Object System.Windows.Forms.Padding(10)
    $jiraGrid.Controls.Add($jiraSourceGroup, 0, 1)

    $jiraSourceLayout = New-Object System.Windows.Forms.TableLayoutPanel
    $jiraSourceLayout.Dock = 'Fill'
    $jiraSourceLayout.ColumnCount = 1
    $jiraSourceLayout.RowCount = 2
    Add-ColumnStylePercent $jiraSourceLayout 100
    Add-RowStylePercent $jiraSourceLayout 100
    Add-RowStyleAbsolute $jiraSourceLayout 42
    $jiraSourceGroup.Controls.Add($jiraSourceLayout) | Out-Null

    $jiraTaskBox.Dock = 'Fill'
    Move-ControlToParent $jiraTaskBox $jiraSourceLayout
    $jiraSourceLayout.Controls.Add($jiraTaskBox, 0, 0)

    $jiraLoadPanel = New-Object System.Windows.Forms.Panel
    $jiraLoadPanel.Dock = 'Fill'
    $jiraSourceLayout.Controls.Add($jiraLoadPanel, 0, 1)

    $jiraLoadButton.Size = New-Object System.Drawing.Size(140, 32)
    $jiraLoadButton.Location = New-Object System.Drawing.Point(0, 5)
    Move-ControlToParent $jiraLoadButton $jiraLoadPanel

    $jiraImportedInfo.AutoSize = $true
    $jiraImportedInfo.Location = New-Object System.Drawing.Point(152, 11)
    Move-ControlToParent $jiraImportedInfo $jiraLoadPanel

    $jiraCommentGroup = New-Object System.Windows.Forms.GroupBox
    $jiraCommentGroup.Text = 'Комментарий QA + скриншоты задачи'
    $jiraCommentGroup.Dock = 'Fill'
    $jiraCommentGroup.Padding = New-Object System.Windows.Forms.Padding(10)
    $jiraGrid.Controls.Add($jiraCommentGroup, 1, 1)

    $jiraCommentLayout = New-Object System.Windows.Forms.TableLayoutPanel
    $jiraCommentLayout.Dock = 'Fill'
    $jiraCommentLayout.ColumnCount = 1
    $jiraCommentLayout.RowCount = 2
    Add-ColumnStylePercent $jiraCommentLayout 100
    Add-RowStylePercent $jiraCommentLayout 100
    Add-RowStyleAbsolute $jiraCommentLayout 42
    $jiraCommentGroup.Controls.Add($jiraCommentLayout) | Out-Null

    $jiraQaCommentBox.Dock = 'Fill'
    $jiraQaCommentBox.Margin = New-Object System.Windows.Forms.Padding(0,0,0,4)
    Move-ControlToParent $jiraQaCommentBox $jiraCommentLayout
    $jiraCommentLayout.Controls.Add($jiraQaCommentBox, 0, 0)

    $jiraScreenshotPanel = New-Object System.Windows.Forms.FlowLayoutPanel
    $jiraScreenshotPanel.Dock = 'Fill'
    $jiraScreenshotPanel.FlowDirection = 'LeftToRight'
    $jiraScreenshotPanel.WrapContents = $false
    $jiraScreenshotPanel.AutoScroll = $true
    $jiraScreenshotPanel.Margin = New-Object System.Windows.Forms.Padding(0)
    $jiraCommentLayout.Controls.Add($jiraScreenshotPanel, 0, 1)

    $jiraScreenshotPasteButton.Size = New-Object System.Drawing.Size(132, 30)
    $jiraScreenshotPasteButton.Margin = New-Object System.Windows.Forms.Padding(0,3,4,3)
    Move-ControlToParent $jiraScreenshotPasteButton $jiraScreenshotPanel

    $jiraScreenshotFilesButton.Size = New-Object System.Drawing.Size(82, 30)
    $jiraScreenshotFilesButton.Margin = New-Object System.Windows.Forms.Padding(0,3,4,3)
    Move-ControlToParent $jiraScreenshotFilesButton $jiraScreenshotPanel

    $jiraScreenshotClearButton.Size = New-Object System.Drawing.Size(82, 30)
    $jiraScreenshotClearButton.Margin = New-Object System.Windows.Forms.Padding(0,3,4,3)
    Move-ControlToParent $jiraScreenshotClearButton $jiraScreenshotPanel

    $jiraScreenshotInfo.AutoSize = $false
    $jiraScreenshotInfo.Size = New-Object System.Drawing.Size(220, 30)
    $jiraScreenshotInfo.TextAlign = 'MiddleLeft'
    $jiraScreenshotInfo.Margin = New-Object System.Windows.Forms.Padding(4,3,0,3)
    Move-ControlToParent $jiraScreenshotInfo $jiraScreenshotPanel

    $jiraImportedGroup = New-Object System.Windows.Forms.GroupBox
    $jiraImportedGroup.Text = 'Импортированное описание и комментарии Jira'
    $jiraImportedGroup.Dock = 'Fill'
    $jiraImportedGroup.Padding = New-Object System.Windows.Forms.Padding(10)
    $jiraGrid.Controls.Add($jiraImportedGroup, 0, 2)
    $jiraGrid.SetColumnSpan($jiraImportedGroup, 2)

    $jiraImportedBox.Dock = 'Fill'
    Move-ControlToParent $jiraImportedBox $jiraImportedGroup

    $jiraRuleGroup = New-Object System.Windows.Forms.GroupBox
    $jiraRuleGroup.Text = 'Постоянные правила Rx2GO'
    $jiraRuleGroup.Dock = 'Fill'
    $jiraRuleGroup.Padding = New-Object System.Windows.Forms.Padding(10)
    $jiraGrid.Controls.Add($jiraRuleGroup, 0, 3)
    $jiraGrid.SetColumnSpan($jiraRuleGroup, 2)

    $jiraRulePanel = New-Object System.Windows.Forms.Panel
    $jiraRulePanel.Dock = 'Fill'
    $jiraRuleGroup.Controls.Add($jiraRulePanel) | Out-Null

    $jiraRulesCountLabel.AutoSize = $true
    $jiraRulesCountLabel.Location = New-Object System.Drawing.Point(0, 4)
    Move-ControlToParent $jiraRulesCountLabel $jiraRulePanel

    $jiraPersistentRuleBox.Location = New-Object System.Drawing.Point(0, 28)
    $jiraPersistentRuleBox.Size = New-Object System.Drawing.Size(820, 52)
    $jiraPersistentRuleBox.Anchor = 'Top,Left,Right'
    Move-ControlToParent $jiraPersistentRuleBox $jiraRulePanel

    $jiraSaveRuleButton.Size = New-Object System.Drawing.Size(210, 34)
    $jiraSaveRuleButton.Anchor = 'Top,Right'
    $jiraSaveRuleButton.Location = New-Object System.Drawing.Point(835, 28)
    Move-ControlToParent $jiraSaveRuleButton $jiraRulePanel

    $jiraSettingsGroup = New-Object System.Windows.Forms.GroupBox
    $jiraSettingsGroup.Text = 'Окружение и проверки'
    $jiraSettingsGroup.Dock = 'Fill'
    $jiraSettingsGroup.Padding = New-Object System.Windows.Forms.Padding(10)
    $jiraGrid.Controls.Add($jiraSettingsGroup, 0, 4)

    $jiraSettingsPanel = New-Object System.Windows.Forms.FlowLayoutPanel
    $jiraSettingsPanel.Dock = 'Fill'
    $jiraSettingsPanel.FlowDirection = 'LeftToRight'
    $jiraSettingsPanel.WrapContents = $true
    $jiraSettingsPanel.AutoScroll = $true
    $jiraSettingsPanel.Padding = New-Object System.Windows.Forms.Padding(2,6,2,2)
    $jiraSettingsGroup.Controls.Add($jiraSettingsPanel) | Out-Null

    $jiraEnvironmentCombo.Size = New-Object System.Drawing.Size(140, 28)
    $jiraEnvironmentCombo.Margin = New-Object System.Windows.Forms.Padding(4,3,14,6)
    Move-ControlToParent $jiraEnvironmentCombo $jiraSettingsPanel

    foreach ($check in @($jiraUiCheck,$jiraApiCheck,$jiraRegressionCheck,$jiraNetworkCheck,$jiraHeadedCheck,$jiraMutatingCheck)) {
        $check.AutoSize = $true
        $check.Margin = New-Object System.Windows.Forms.Padding(5,7,14,6)
        Move-ControlToParent $check $jiraSettingsPanel
    }

    $jiraDailyLabel.AutoSize = $true
    $jiraDailyLabel.Margin = New-Object System.Windows.Forms.Padding(5,8,8,6)
    Move-ControlToParent $jiraDailyLabel $jiraSettingsPanel

    $jiraDailyPassword.Size = New-Object System.Drawing.Size(190, 28)
    $jiraDailyPassword.Margin = New-Object System.Windows.Forms.Padding(0,4,10,6)
    Move-ControlToParent $jiraDailyPassword $jiraSettingsPanel

    $jiraExecutionGroup = New-Object System.Windows.Forms.GroupBox
    $jiraExecutionGroup.Text = 'Проверка и статус'
    $jiraExecutionGroup.Dock = 'Fill'
    $jiraExecutionGroup.Padding = New-Object System.Windows.Forms.Padding(10)
    $jiraGrid.Controls.Add($jiraExecutionGroup, 1, 4)

    $jiraExecutionGrid = New-Object System.Windows.Forms.TableLayoutPanel
    $jiraExecutionGrid.Dock = 'Fill'
    $jiraExecutionGrid.ColumnCount = 2
    $jiraExecutionGrid.RowCount = 1
    Add-ColumnStylePercent $jiraExecutionGrid 44
    Add-ColumnStylePercent $jiraExecutionGrid 56
    Add-RowStylePercent $jiraExecutionGrid 100
    $jiraExecutionGroup.Controls.Add($jiraExecutionGrid) | Out-Null

    $jiraExecutionLeft = New-Object System.Windows.Forms.TableLayoutPanel
    $jiraExecutionLeft.Dock = 'Fill'
    $jiraExecutionLeft.ColumnCount = 1
    $jiraExecutionLeft.RowCount = 4
    Add-ColumnStylePercent $jiraExecutionLeft 100
    Add-RowStyleAbsolute $jiraExecutionLeft 52
    Add-RowStyleAbsolute $jiraExecutionLeft 24
    Add-RowStyleAbsolute $jiraExecutionLeft 24
    Add-RowStylePercent $jiraExecutionLeft 100
    $jiraExecutionGrid.Controls.Add($jiraExecutionLeft, 0, 0)

    $jiraRunButton.Dock = 'Fill'
    $jiraRunButton.Margin = New-Object System.Windows.Forms.Padding(0,2,8,6)
    Move-ControlToParent $jiraRunButton $jiraExecutionLeft
    $jiraExecutionLeft.Controls.Add($jiraRunButton, 0, 0)

    $modulePanel = New-Object System.Windows.Forms.FlowLayoutPanel
    $modulePanel.Dock = 'Fill'
    $modulePanel.FlowDirection = 'LeftToRight'
    $modulePanel.WrapContents = $false
    $jiraExecutionLeft.Controls.Add($modulePanel, 0, 1)
    $jiraModuleCaption.AutoSize = $true
    $jiraModuleCaption.Margin = New-Object System.Windows.Forms.Padding(0,4,6,0)
    Move-ControlToParent $jiraModuleCaption $modulePanel
    $jiraModuleValue.AutoSize = $true
    $jiraModuleValue.Margin = New-Object System.Windows.Forms.Padding(0,4,0,0)
    Move-ControlToParent $jiraModuleValue $modulePanel

    $automationPanel = New-Object System.Windows.Forms.FlowLayoutPanel
    $automationPanel.Dock = 'Fill'
    $automationPanel.FlowDirection = 'LeftToRight'
    $automationPanel.WrapContents = $false
    $jiraExecutionLeft.Controls.Add($automationPanel, 0, 2)
    $jiraAutomationCaption.AutoSize = $true
    $jiraAutomationCaption.Margin = New-Object System.Windows.Forms.Padding(0,4,6,0)
    Move-ControlToParent $jiraAutomationCaption $automationPanel
    $jiraAutomationValue.AutoSize = $true
    $jiraAutomationValue.Margin = New-Object System.Windows.Forms.Padding(0,4,0,0)
    Move-ControlToParent $jiraAutomationValue $automationPanel

    $jiraTaskStatus.AutoSize = $false
    $jiraTaskStatus.Dock = 'Fill'
    $jiraTaskStatus.AutoEllipsis = $true
    $jiraTaskStatus.Margin = New-Object System.Windows.Forms.Padding(0,6,8,0)
    Move-ControlToParent $jiraTaskStatus $jiraExecutionLeft
    $jiraExecutionLeft.Controls.Add($jiraTaskStatus, 0, 3)

    $script:AgentStatusPanel = New-Object System.Windows.Forms.GroupBox
    $script:AgentStatusPanel.Text = 'Smart QA pipeline'
    $script:AgentStatusPanel.Dock = 'Fill'
    $script:AgentStatusPanel.Margin = New-Object System.Windows.Forms.Padding(6,0,0,0)
    $jiraExecutionGrid.Controls.Add($script:AgentStatusPanel, 1, 0)

    $agentStatusGrid = New-Object System.Windows.Forms.TableLayoutPanel
    $agentStatusGrid.Dock = 'Fill'
    $agentStatusGrid.ColumnCount = 1
    $agentStatusGrid.RowCount = 4
    Add-ColumnStylePercent $agentStatusGrid 100
    Add-RowStylePercent $agentStatusGrid 25
    Add-RowStylePercent $agentStatusGrid 25
    Add-RowStylePercent $agentStatusGrid 25
    Add-RowStylePercent $agentStatusGrid 25
    $script:AgentStatusPanel.Controls.Add($agentStatusGrid) | Out-Null

    $script:AgentJiraAnalystLabel = New-Object System.Windows.Forms.Label
    $script:AgentJiraAnalystLabel.Text = '1. Requirements Analyst — ожидает'
    $script:AgentJiraAnalystLabel.Dock = 'Fill'
    $script:AgentJiraAnalystLabel.AutoEllipsis = $true
    $script:AgentJiraAnalystLabel.TextAlign = 'MiddleLeft'
    $agentStatusGrid.Controls.Add($script:AgentJiraAnalystLabel, 0, 0)

    $script:AgentTestDesignerLabel = New-Object System.Windows.Forms.Label
    $script:AgentTestDesignerLabel.Text = '2. Playwright MCP QA — ожидает'
    $script:AgentTestDesignerLabel.Dock = 'Fill'
    $script:AgentTestDesignerLabel.AutoEllipsis = $true
    $script:AgentTestDesignerLabel.TextAlign = 'MiddleLeft'
    $agentStatusGrid.Controls.Add($script:AgentTestDesignerLabel, 0, 1)

    # Legacy label is kept as an object for compatibility but is not part of the visible pipeline.
    $script:AgentUiLabel = New-Object System.Windows.Forms.Label
    $script:AgentUiLabel.Visible = $false

    $script:AgentReviewerLabel = New-Object System.Windows.Forms.Label
    $script:AgentReviewerLabel.Text = '3. QA Reviewer — ожидает'
    $script:AgentReviewerLabel.Dock = 'Fill'
    $script:AgentReviewerLabel.AutoEllipsis = $true
    $script:AgentReviewerLabel.TextAlign = 'MiddleLeft'
    $agentStatusGrid.Controls.Add($script:AgentReviewerLabel, 0, 2)

    $script:AgentApiLabel = New-Object System.Windows.Forms.Label
    $script:AgentApiLabel.Text = 'RCA. Failure Triage — ожидает'
    $script:AgentApiLabel.Dock = 'Fill'
    $script:AgentApiLabel.AutoEllipsis = $true
    $script:AgentApiLabel.TextAlign = 'MiddleLeft'
    $agentStatusGrid.Controls.Add($script:AgentApiLabel, 0, 3)

    $jiraPlanGroup = New-Object System.Windows.Forms.GroupBox
    $jiraPlanGroup.Text = 'Smart QA: план, MCP и Playwright'
    $jiraPlanGroup.Dock = 'Fill'
    $jiraPlanGroup.Padding = New-Object System.Windows.Forms.Padding(10)
    $jiraGrid.Controls.Add($jiraPlanGroup, 0, 5)
    $jiraGrid.SetColumnSpan($jiraPlanGroup, 2)

    $jiraPlanLogGrid = New-Object System.Windows.Forms.TableLayoutPanel
    $jiraPlanLogGrid.Dock = 'Fill'
    $jiraPlanLogGrid.ColumnCount = 2
    $jiraPlanLogGrid.RowCount = 1
    Add-ColumnStylePercent $jiraPlanLogGrid 58
    Add-ColumnStylePercent $jiraPlanLogGrid 42
    Add-RowStylePercent $jiraPlanLogGrid 100
    $jiraPlanGroup.Controls.Add($jiraPlanLogGrid) | Out-Null

    $planInnerGroup = New-Object System.Windows.Forms.GroupBox
    $planInnerGroup.Text = 'Тест-план'
    $planInnerGroup.Dock = 'Fill'
    $planInnerGroup.Margin = New-Object System.Windows.Forms.Padding(0,0,6,0)
    $jiraPlanLogGrid.Controls.Add($planInnerGroup, 0, 0)
    $jiraPlanBox.Dock = 'Fill'
    Move-ControlToParent $jiraPlanBox $planInnerGroup

    $agentLogGroup = New-Object System.Windows.Forms.GroupBox
    $agentLogGroup.Text = 'Лог Smart QA / Playwright MCP / Playwright'
    $agentLogGroup.Dock = 'Fill'
    $agentLogGroup.Margin = New-Object System.Windows.Forms.Padding(6,0,0,0)
    $jiraPlanLogGrid.Controls.Add($agentLogGroup, 1, 0)

    $agentLogLayout = New-Object System.Windows.Forms.TableLayoutPanel
    $agentLogLayout.Dock = 'Fill'
    $agentLogLayout.ColumnCount = 1
    $agentLogLayout.RowCount = 2
    Add-ColumnStylePercent $agentLogLayout 100
    Add-RowStylePercent $agentLogLayout 100
    Add-RowStyleAbsolute $agentLogLayout 38
    $agentLogGroup.Controls.Add($agentLogLayout) | Out-Null

    $script:AgentLogBox = New-Object System.Windows.Forms.RichTextBox
    $script:AgentLogBox.Dock = 'Fill'
    $script:AgentLogBox.ReadOnly = $true
    $script:AgentLogBox.BackColor = [System.Drawing.Color]::FromArgb(17,24,39)
    $script:AgentLogBox.ForeColor = [System.Drawing.Color]::FromArgb(229,231,235)
    $script:AgentLogBox.Font = New-Object System.Drawing.Font('Consolas', 8.5)
    $script:AgentLogBox.Text = "Smart QA pipeline ready.`r`n"
    $agentLogLayout.Controls.Add($script:AgentLogBox, 0, 0)

    $agentLogButtons = New-Object System.Windows.Forms.FlowLayoutPanel
    $agentLogButtons.Dock = 'Fill'
    $agentLogButtons.FlowDirection = 'LeftToRight'
    $agentLogButtons.WrapContents = $false
    $agentLogLayout.Controls.Add($agentLogButtons, 0, 1)

    $openAgentLogsButton = New-Object System.Windows.Forms.Button
    $openAgentLogsButton.Text = 'Открыть папку логов'
    $openAgentLogsButton.Size = New-Object System.Drawing.Size(160, 30)
    $openAgentLogsButton.Margin = New-Object System.Windows.Forms.Padding(0,4,8,0)
    $openAgentLogsButton.Add_Click({ Open-AgentLogFolder })
    $agentLogButtons.Controls.Add($openAgentLogsButton) | Out-Null

    $clearAgentLogsButton = New-Object System.Windows.Forms.Button
    $clearAgentLogsButton.Text = 'Очистить окно'
    $clearAgentLogsButton.Size = New-Object System.Drawing.Size(120, 30)
    $clearAgentLogsButton.Margin = New-Object System.Windows.Forms.Padding(0,4,0,0)
    $clearAgentLogsButton.Add_Click({ if ($script:AgentLogBox) { $script:AgentLogBox.Clear() } })
    $agentLogButtons.Controls.Add($clearAgentLogsButton) | Out-Null

    $jiraFooterPanel = New-Object System.Windows.Forms.Panel
    $jiraFooterPanel.Dock = 'Fill'
    $jiraGrid.Controls.Add($jiraFooterPanel, 0, 6)
    $jiraGrid.SetColumnSpan($jiraFooterPanel, 2)

    $jiraCopyReportButton.Size = New-Object System.Drawing.Size(205, 34)
    $jiraCopyReportButton.Location = New-Object System.Drawing.Point(0, 8)
    Move-ControlToParent $jiraCopyReportButton $jiraFooterPanel

    $jiraRegressionButton.Size = New-Object System.Drawing.Size(185, 34)
    $jiraRegressionButton.Location = New-Object System.Drawing.Point(216, 8)
    Move-ControlToParent $jiraRegressionButton $jiraFooterPanel

    $jiraNote.AutoSize = $false
    $jiraNote.Size = New-Object System.Drawing.Size(620, 36)
    $jiraNote.Location = New-Object System.Drawing.Point(420, 8)
    $jiraNote.ForeColor = [System.Drawing.Color]::DimGray
    Move-ControlToParent $jiraNote $jiraFooterPanel

    # ------------------------------------------------------------------
    # KNOWLEDGE TAB
    # ------------------------------------------------------------------
    $knowledgeRoot = New-Object System.Windows.Forms.Panel
    $knowledgeRoot.Dock = 'Fill'
    $knowledgeRoot.Padding = New-Object System.Windows.Forms.Padding(12)
    $knowledgeRoot.BackColor = [System.Drawing.Color]::FromArgb(246,248,251)
    $knowledgeTab.Controls.Add($knowledgeRoot) | Out-Null
    $knowledgeRoot.BringToFront()

    $knowledgeGrid = New-Object System.Windows.Forms.TableLayoutPanel
    $knowledgeGrid.Dock = 'Fill'
    $knowledgeGrid.ColumnCount = 1
    $knowledgeGrid.RowCount = 5
    Add-ColumnStylePercent $knowledgeGrid 100
    Add-RowStyleAbsolute $knowledgeGrid 72
    Add-RowStyleAbsolute $knowledgeGrid 108
    Add-RowStyleAbsolute $knowledgeGrid 245
    Add-RowStyleAbsolute $knowledgeGrid 118
    Add-RowStylePercent $knowledgeGrid 100
    $knowledgeRoot.Controls.Add($knowledgeGrid) | Out-Null

    $knowledgeHeaderGroup = New-Object System.Windows.Forms.GroupBox
    $knowledgeHeaderGroup.Text = 'Общая память Rx2GO QA'
    $knowledgeHeaderGroup.Dock = 'Fill'
    $knowledgeHeaderGroup.Padding = New-Object System.Windows.Forms.Padding(10)
    $knowledgeGrid.Controls.Add($knowledgeHeaderGroup, 0, 0)

    $knowledgeHeaderPanel = New-Object System.Windows.Forms.Panel
    $knowledgeHeaderPanel.Dock = 'Fill'
    $knowledgeHeaderGroup.Controls.Add($knowledgeHeaderPanel) | Out-Null

    $knowledgeHint.Visible = $true
    $knowledgeHint.AutoSize = $false
    $knowledgeHint.Size = New-Object System.Drawing.Size(980, 36)
    $knowledgeHint.Location = New-Object System.Drawing.Point(0, 4)
    Move-ControlToParent $knowledgeHint $knowledgeHeaderPanel

    $knowledgeStatsGroup = New-Object System.Windows.Forms.GroupBox
    $knowledgeStatsGroup.Text = 'Содержимое базы знаний'
    $knowledgeStatsGroup.Dock = 'Fill'
    $knowledgeStatsGroup.Padding = New-Object System.Windows.Forms.Padding(10)
    $knowledgeGrid.Controls.Add($knowledgeStatsGroup, 0, 1)

    $knowledgeStatsFlow = New-Object System.Windows.Forms.FlowLayoutPanel
    $knowledgeStatsFlow.Dock = 'Fill'
    $knowledgeStatsFlow.WrapContents = $false
    $knowledgeStatsFlow.AutoScroll = $true
    $knowledgeStatsGroup.Controls.Add($knowledgeStatsFlow) | Out-Null

    foreach ($card in @($knowledgeRulesValue.Parent, $knowledgeJiraValue.Parent, $knowledgeRegressionValue.Parent, $knowledgeTestsValue.Parent)) {
        $card.Size = New-Object System.Drawing.Size(210, 82)
        Move-ControlToParent $card $knowledgeStatsFlow
    }

    $knowledgeGitGroup = New-Object System.Windows.Forms.GroupBox
    $knowledgeGitGroup.Text = 'Git repository'
    $knowledgeGitGroup.Dock = 'Fill'
    $knowledgeGitGroup.Padding = New-Object System.Windows.Forms.Padding(10)
    $knowledgeGrid.Controls.Add($knowledgeGitGroup, 0, 2)

    # Replace the old fixed-coordinate Git panel with a responsive two-column grid.
    $knowledgeGitPanel.BorderStyle = 'None'
    $knowledgeGitPanel.Dock = 'Fill'
    Move-ControlToParent $knowledgeGitPanel $knowledgeGitGroup
    $knowledgeGitPanel.Controls.Clear()

    $knowledgeGitGrid = New-Object System.Windows.Forms.TableLayoutPanel
    $knowledgeGitGrid.Dock = 'Fill'
    $knowledgeGitGrid.ColumnCount = 2
    $knowledgeGitGrid.RowCount = 1
    Add-ColumnStylePercent $knowledgeGitGrid 72
    Add-ColumnStylePercent $knowledgeGitGrid 28
    Add-RowStylePercent $knowledgeGitGrid 100
    $knowledgeGitPanel.Controls.Add($knowledgeGitGrid) | Out-Null

    $knowledgeGitInfoPanel = New-Object System.Windows.Forms.TableLayoutPanel
    $knowledgeGitInfoPanel.Dock = 'Fill'
    $knowledgeGitInfoPanel.ColumnCount = 2
    $knowledgeGitInfoPanel.RowCount = 5
    Add-ColumnStyleAbsolute $knowledgeGitInfoPanel 92
    Add-ColumnStylePercent $knowledgeGitInfoPanel 100
    Add-RowStyleAbsolute $knowledgeGitInfoPanel 34
    Add-RowStyleAbsolute $knowledgeGitInfoPanel 28
    Add-RowStyleAbsolute $knowledgeGitInfoPanel 28
    Add-RowStyleAbsolute $knowledgeGitInfoPanel 28
    Add-RowStylePercent $knowledgeGitInfoPanel 100
    $knowledgeGitGrid.Controls.Add($knowledgeGitInfoPanel, 0, 0)

    $knowledgeGitTitle.Text = 'Git repository'
    $knowledgeGitTitle.Dock = 'Fill'
    $knowledgeGitTitle.TextAlign = 'MiddleLeft'
    $knowledgeGitTitle.Margin = New-Object System.Windows.Forms.Padding(2,0,2,0)
    Move-ControlToParent $knowledgeGitTitle $knowledgeGitInfoPanel
    $knowledgeGitInfoPanel.Controls.Add($knowledgeGitTitle, 0, 0)
    $knowledgeGitInfoPanel.SetColumnSpan($knowledgeGitTitle, 2)

    $knowledgeGitStatus.Dock = 'Fill'
    $knowledgeGitStatus.TextAlign = 'MiddleLeft'
    $knowledgeGitStatus.Margin = New-Object System.Windows.Forms.Padding(2,0,2,0)
    Move-ControlToParent $knowledgeGitStatus $knowledgeGitInfoPanel
    $knowledgeGitInfoPanel.Controls.Add($knowledgeGitStatus, 0, 1)
    $knowledgeGitInfoPanel.SetColumnSpan($knowledgeGitStatus, 2)

    foreach ($pair in @(
        @($branchCaption,$knowledgeBranchValue,2),
        @($remoteCaption,$knowledgeRemoteValue,3),
        @($commitCaption,$knowledgeCommitValue,4)
    )) {
        $caption = $pair[0]
        $value = $pair[1]
        $row = [int]$pair[2]

        $caption.Dock = 'Fill'
        $caption.TextAlign = 'MiddleLeft'
        $caption.Margin = New-Object System.Windows.Forms.Padding(2,0,4,0)
        Move-ControlToParent $caption $knowledgeGitInfoPanel
        $knowledgeGitInfoPanel.Controls.Add($caption, 0, $row)

        $value.AutoSize = $false
        $value.Dock = 'Fill'
        $value.TextAlign = 'MiddleLeft'
        $value.Margin = New-Object System.Windows.Forms.Padding(0)
        Move-ControlToParent $value $knowledgeGitInfoPanel
        $knowledgeGitInfoPanel.Controls.Add($value, 1, $row)
    }

    $knowledgeGitActions = New-Object System.Windows.Forms.TableLayoutPanel
    $knowledgeGitActions.Dock = 'Fill'
    $knowledgeGitActions.ColumnCount = 1
    $knowledgeGitActions.RowCount = 5
    Add-ColumnStylePercent $knowledgeGitActions 100
    Add-RowStylePercent $knowledgeGitActions 20
    Add-RowStylePercent $knowledgeGitActions 20
    Add-RowStylePercent $knowledgeGitActions 20
    Add-RowStylePercent $knowledgeGitActions 20
    Add-RowStylePercent $knowledgeGitActions 20
    $knowledgeGitActions.Padding = New-Object System.Windows.Forms.Padding(8,2,2,2)
    $knowledgeGitGrid.Controls.Add($knowledgeGitActions, 1, 0)

    foreach ($action in @(
        @($knowledgeSetupButton,0),
        @($knowledgeSshCreateButton,1),
        @($knowledgeSshCopyButton,2),
        @($knowledgeRefreshButton,3),
        @($knowledgeSyncButton,4)
    )) {
        $button = $action[0]
        $row = [int]$action[1]
        $button.Dock = 'Fill'
        $button.Margin = New-Object System.Windows.Forms.Padding(0,3,0,3)
        Move-ControlToParent $button $knowledgeGitActions
        $knowledgeGitActions.Controls.Add($button, 0, $row)
    }

    $knowledgeCommitGroup = New-Object System.Windows.Forms.GroupBox
    $knowledgeCommitGroup.Text = 'Commit knowledge'
    $knowledgeCommitGroup.Dock = 'Fill'
    $knowledgeCommitGroup.Padding = New-Object System.Windows.Forms.Padding(10)
    $knowledgeGrid.Controls.Add($knowledgeCommitGroup, 0, 3)

    $knowledgeCommitPanel = New-Object System.Windows.Forms.TableLayoutPanel
    $knowledgeCommitPanel.Dock = 'Fill'
    $knowledgeCommitPanel.ColumnCount = 2
    $knowledgeCommitPanel.RowCount = 2
    Add-ColumnStylePercent $knowledgeCommitPanel 82
    Add-ColumnStylePercent $knowledgeCommitPanel 18
    Add-RowStyleAbsolute $knowledgeCommitPanel 40
    Add-RowStylePercent $knowledgeCommitPanel 100
    $knowledgeCommitGroup.Controls.Add($knowledgeCommitPanel) | Out-Null

    # The old free-floating label caused layout-health noise and is redundant
    # because the GroupBox already says "Commit knowledge".
    $knowledgeCommitLabel.Visible = $false

    $knowledgeCommitMessage.Dock = 'Fill'
    $knowledgeCommitMessage.Margin = New-Object System.Windows.Forms.Padding(0,4,8,4)
    Move-ControlToParent $knowledgeCommitMessage $knowledgeCommitPanel
    $knowledgeCommitPanel.Controls.Add($knowledgeCommitMessage, 0, 0)

    $knowledgeCommitButton.Dock = 'Fill'
    $knowledgeCommitButton.Visible = $true
    $knowledgeCommitButton.Margin = New-Object System.Windows.Forms.Padding(0,3,0,3)
    Move-ControlToParent $knowledgeCommitButton $knowledgeCommitPanel
    $knowledgeCommitPanel.Controls.Add($knowledgeCommitButton, 1, 0)

    $knowledgeSyncInfo.AutoSize = $false
    $knowledgeSyncInfo.Dock = 'Fill'
    $knowledgeSyncInfo.TextAlign = 'MiddleLeft'
    $knowledgeSyncInfo.Margin = New-Object System.Windows.Forms.Padding(0,2,0,0)
    Move-ControlToParent $knowledgeSyncInfo $knowledgeCommitPanel
    $knowledgeCommitPanel.Controls.Add($knowledgeSyncInfo, 0, 1)
    $knowledgeCommitPanel.SetColumnSpan($knowledgeSyncInfo, 2)

    $knowledgeRecentGroup = New-Object System.Windows.Forms.GroupBox
    $knowledgeRecentGroup.Text = 'Последние изменения Knowledge Base'
    $knowledgeRecentGroup.Dock = 'Fill'
    $knowledgeRecentGroup.Padding = New-Object System.Windows.Forms.Padding(10)
    $knowledgeGrid.Controls.Add($knowledgeRecentGroup, 0, 4)

    $knowledgeRecentList.Dock = 'Fill'
    Move-ControlToParent $knowledgeRecentList $knowledgeRecentGroup

    $knowledgePolicy.AutoSize = $false
    $knowledgePolicy.Dock = 'Bottom'
    $knowledgePolicy.Height = 40
    $knowledgePolicy.ForeColor = [System.Drawing.Color]::DimGray
    Move-ControlToParent $knowledgePolicy $knowledgeRoot

    $quickTab.ResumeLayout($true)
    $jiraTab.ResumeLayout($true)
    $knowledgeTab.ResumeLayout($true)
    $tabs.ResumeLayout($true)
    $form.ResumeLayout($true)
}


function Style-PrimaryButton([System.Windows.Forms.Button]$Button) {
    if (-not $Button) { return }
    $Button.FlatStyle = 'Flat'
    $Button.FlatAppearance.BorderSize = 0
    $Button.BackColor = [System.Drawing.Color]::FromArgb(37,99,235)
    $Button.ForeColor = [System.Drawing.Color]::White
    $Button.Cursor = [System.Windows.Forms.Cursors]::Hand
}

function Style-SecondaryButton([System.Windows.Forms.Button]$Button) {
    if (-not $Button) { return }
    $Button.FlatStyle = 'Flat'
    $Button.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(203,213,225)
    $Button.BackColor = [System.Drawing.Color]::White
    $Button.ForeColor = [System.Drawing.Color]::FromArgb(31,41,55)
    $Button.Cursor = [System.Windows.Forms.Cursors]::Hand
}

function Apply-VisualPolish {
    $form.BackColor = [System.Drawing.Color]::FromArgb(241,245,249)
    $tabs.Font = New-Font 9 ([System.Drawing.FontStyle]::Bold)
    $tabs.Padding = New-Object System.Drawing.Point(18,8)
    $tabs.ItemSize = New-Object System.Drawing.Size(150,32)
    $tabs.SizeMode = 'Fixed'

    foreach ($tab in @($quickTab,$jiraTab,$knowledgeTab)) {
        $tab.BackColor = [System.Drawing.Color]::FromArgb(248,250,252)
    }

    Style-PrimaryButton $runButton
    Style-PrimaryButton $jiraRunButton
    Style-PrimaryButton $knowledgeSyncButton

    foreach ($button in @(
        $cancelButton,$jiraButton,$htmlButton,$credentialButton,$quickChatGptButton,$quickRecheckConnectionsButton,
        $chatGptConnectButton,$jiraConnectButton,$jiraLoadButton,
        $jiraSaveRuleButton,$jiraCopyReportButton,$jiraRegressionButton,
        $knowledgeSetupButton,$knowledgeRefreshButton,$knowledgeCommitButton,
        $openAgentLogsButton,$clearAgentLogsButton
    )) {
        Style-SecondaryButton $button
    }

    foreach ($box in @($logBox,$jiraImportedBox,$jiraPlanBox)) {
        if ($box) {
            $box.BorderStyle = 'FixedSingle'
        }
    }

    foreach ($group in @(
        $quickConfigGroup,$quickTestGroup,$summaryGroup,$failedGroup,$logGroup,
        $jiraIntegrationGroup,$jiraSourceGroup,$jiraCommentGroup,$jiraImportedGroup,
        $jiraRuleGroup,$jiraSettingsGroup,$jiraExecutionGroup,$jiraPlanGroup,
        $knowledgeHeaderGroup,$knowledgeStatsGroup,$knowledgeGitGroup,
        $knowledgeCommitGroup,$knowledgeRecentGroup
    )) {
        if ($group) {
            $group.ForeColor = [System.Drawing.Color]::FromArgb(51,65,85)
            $group.BackColor = [System.Drawing.Color]::White
        }
    }
}


function Resize-LauncherChrome {
    if (-not $form -or -not $tabs) { return }

    $usableWidth = [Math]::Max(900, $form.ClientSize.Width - 24)
    $usableHeight = [Math]::Max(650, $form.ClientSize.Height - 108)

    $tabs.Location = New-Object System.Drawing.Point(12,96)
    $tabs.Size = New-Object System.Drawing.Size($usableWidth,$usableHeight)

    if ($layoutHealthLabel) {
        $layoutHealthLabel.Left = [Math]::Max(720, $header.ClientSize.Width - $layoutHealthLabel.Width - 28)
    }
}


function Find-LayoutOverflow {
    param([System.Windows.Forms.Control]$Parent)
    $issues = @()
    if (-not $Parent -or -not $Parent.Visible) { return @() }
    foreach ($child in @($Parent.Controls)) {
        if (-not $child.Visible) { continue }
        if ($child.Width -le 0 -or $child.Height -le 0) { continue }
        $managed = ($Parent -is [System.Windows.Forms.TableLayoutPanel] -or $Parent -is [System.Windows.Forms.FlowLayoutPanel] -or $Parent -is [System.Windows.Forms.SplitContainer])
        if (-not $managed -and $child.Dock -eq [System.Windows.Forms.DockStyle]::None) {
            $name = if ($child.Name) { $child.Name } else { $child.GetType().Name }
            if ($child.Left -lt -2 -or $child.Top -lt -2) { $issues += "${name}: negative position" }
            if ($Parent.ClientSize.Width -gt 20 -and $child.Right -gt ($Parent.ClientSize.Width + 8)) { $issues += "${name}: right overflow ($($child.Right) > $($Parent.ClientSize.Width))" }
            if ($Parent.ClientSize.Height -gt 20 -and $child.Bottom -gt ($Parent.ClientSize.Height + 8)) { $issues += "${name}: bottom overflow ($($child.Bottom) > $($Parent.ClientSize.Height))" }
        }
        foreach ($nested in (Find-LayoutOverflow $child)) { if ($nested) { $issues += [string]$nested } }
    }
    return $issues
}

function Update-LayoutHealth {
    if (-not $layoutHealthLabel) { return }

    $issues = @()
    foreach ($tab in @($quickTab,$jiraTab,$knowledgeTab)) {
        foreach ($issue in (Find-LayoutOverflow $tab)) {
            if ($issue) { $issues += [string]$issue }
        }
    }

    if ($issues.Count -eq 0) {
        $layoutHealthLabel.Text = '● UI layout OK'
        $layoutHealthLabel.ForeColor = [System.Drawing.Color]::FromArgb(74,222,128)
        $layoutHealthLabel.Tag = ''
    }
    else {
        $layoutHealthLabel.Text = "● UI: $($issues.Count) layout issue(s)"
        $layoutHealthLabel.ForeColor = [System.Drawing.Color]::FromArgb(251,191,36)
        $layoutHealthLabel.Tag = ($issues -join "`r`n")
    }
}

function Invoke-StartupKnowledgePull {
    if (Test-GitInstalled) {
        Initialize-KnowledgeGit -Silent
    }
    $git = Get-GitState
    if (-not $git.Repository -or $git.Remote -eq 'не настроен' -or $git.Dirty) {
        Refresh-KnowledgeUI
        return
    }
    $remoteBranch = Invoke-Git @('ls-remote','--exit-code','--heads','origin',$git.Branch) 10000
    if ($remoteBranch.ExitCode -ne 0) {
        if ($knowledgeSyncInfo) {
            $knowledgeSyncInfo.Text = 'Startup sync: remote-ветка ещё не создана; после первого commit нажми Synchronize.'
            $knowledgeSyncInfo.ForeColor = [System.Drawing.Color]::DimGray
        }
        Refresh-KnowledgeUI
        return
    }
    $pull = Invoke-Git @('pull','--ff-only','origin',$git.Branch) 20000
    if ($knowledgeSyncInfo) {
        if ($pull.ExitCode -eq 0) {
            $knowledgeSyncInfo.Text = 'Startup sync: последние knowledge-изменения получены.'
            $knowledgeSyncInfo.ForeColor = [System.Drawing.Color]::FromArgb(32,120,72)
        } else {
            $knowledgeSyncInfo.Text = 'Startup sync пропущен/не выполнен. Нажми Synchronize для повторной попытки.'
            $knowledgeSyncInfo.ForeColor = [System.Drawing.Color]::FromArgb(161,98,7)
        }
    }
    Refresh-KnowledgeUI
}

$script:ChatGPTAuthTimer = New-Object System.Windows.Forms.Timer
$script:ChatGPTAuthTimer.Interval = 2000
$script:ChatGPTAuthTimer.Add_Tick({
    if ($script:ChatGPTAuthProcess -and $script:ChatGPTAuthProcess.HasExited) {
        $script:ChatGPTAuthTimer.Stop()
        $chatGptConnectButton.Enabled = $true
        if ($script:QuickChatGptButton) { $script:QuickChatGptButton.Enabled = $true }
        Update-ChatGPTOAuthUI
        if ($script:ChatGPTConnected) {
            $jiraTaskStatus.Text = 'ChatGPT подключён — AI-анализ готов'
            $jiraTaskStatus.ForeColor = [System.Drawing.Color]::FromArgb(32,120,72)
        }
    }
})

Apply-ResponsiveLayout
Apply-VisualPolish
Resize-LauncherChrome
Set-EnvironmentUI
Update-ChatGPTOAuthUI
Refresh-KnowledgeUI

$script:CodexStartupTimer = New-Object System.Windows.Forms.Timer
$script:CodexStartupTimer.Interval = 350
$script:CodexStartupTimer.Add_Tick({
    $script:CodexStartupTimer.Stop()
    Initialize-CodexOnLauncherStart
})

$script:KnowledgeStartupTimer = New-Object System.Windows.Forms.Timer
$script:KnowledgeStartupTimer.Interval = 700
$script:KnowledgeStartupTimer.Add_Tick({
    $script:KnowledgeStartupTimer.Stop()
    if ($knowledgeSyncInfo) {
        $knowledgeSyncInfo.Text = 'Startup sync: проверяю общий Knowledge Repository…'
        $knowledgeSyncInfo.ForeColor = [System.Drawing.Color]::DimGray
        [System.Windows.Forms.Application]::DoEvents()
    }
    Invoke-StartupKnowledgePull
})

$tabs.Add_SelectedIndexChanged({
    [System.Windows.Forms.Application]::DoEvents()
    Update-LayoutHealth
})

$form.Add_Shown({
    Resize-LauncherChrome
    Update-LayoutHealth
    $script:CodexStartupTimer.Start()
    $script:KnowledgeStartupTimer.Start()
})

if (-not (Test-Path $script:CredentialFile)) {
    $logBox.Text = "Первый запуск: введи пароль Rx2GO в блоке «Доступ и подключения».`r`nДля ADM также введи суточный пароль из Telegram. Все данные находятся на одной странице.`r`n"
}

$jiraStartupTimer = New-Object System.Windows.Forms.Timer
$jiraStartupTimer.Interval = 1200
$jiraStartupTimer.Add_Tick({
    $jiraStartupTimer.Stop()
    Update-JiraConnectionUI
})
$jiraStartupTimer.Start()

[void]$form.ShowDialog()
