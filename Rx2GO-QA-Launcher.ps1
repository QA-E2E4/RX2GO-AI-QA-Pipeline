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

    if ($env:RX2GO_QUEUE_WORKER -eq '1') {
        try {
            $statusPath = [string]$env:RX2GO_QUEUE_STATUS_FILE
            if ($statusPath) {
                $dir = Split-Path $statusPath -Parent
                if ($dir) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
                $payload = [ordered]@{
                    schemaVersion = 1; jobId = [string]$env:RX2GO_QUEUE_JOB_ID; taskKey = [string]$env:RX2GO_QUEUE_TASK_KEY;
                    environment = [string]$env:RX2GO_QUEUE_ENV; pid = $PID; status = 'FINISHED'; phase = 'ERROR';
                    detail = [string]$eventArgs.Exception.Message; final = $true; result = 'ERROR'; updatedAt = (Get-Date).ToString('o')
                }
                [System.IO.File]::WriteAllText($statusPath, ($payload | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($false)))
            }
        } catch {}
        return
    }

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

# Queue Worker mode is an isolated child Launcher process started by the Jira Queue.
# Each worker gets its own copied project root, reports, browser/CDP session and agent state.
$script:QueueWorkerMode = ($env:RX2GO_QUEUE_WORKER -eq '1')
$script:QueueWorkerJobId = [string]$env:RX2GO_QUEUE_JOB_ID
$script:QueueWorkerTaskKey = [string]$env:RX2GO_QUEUE_TASK_KEY
$script:QueueWorkerEnvironment = [string]$env:RX2GO_QUEUE_ENV
$script:QueueWorkerStatusFile = [string]$env:RX2GO_QUEUE_STATUS_FILE
$script:QueueWorkerParentRoot = [string]$env:RX2GO_QUEUE_PARENT_ROOT
$script:QueueWorkerSlot = [string]$env:RX2GO_QUEUE_WORKER_SLOT
$script:QueueWorkerFinalWritten = $false
$script:QueueWorkerFinalResult = $null
$script:QueueWorkerStarted = $false
$script:QueueWorkerStartedAt = $null

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
    'fixtures','utils','.github',
    'Rx2GO-QA-Launcher.ps1','LauncherBootstrap.ps1','run.ps1','setup.ps1',
    'START QA.bat','START QA DEBUG.bat',
    'CHECK CODEX.bat','CHECK PLAYWRIGHT CONFIG.bat','CHECK RX2GO LOGIN.bat','CHECK TEST ENVIRONMENT.bat',
    'INSTALL CODEX.bat','INSTALL CODEX.ps1','CONFIGURE BROWSERSTACK MCP.bat',
    'README.md','JIRA-WORKFLOW.md','LAUNCHER.md',
    'playwright.config.ts','package.json','package-lock.json','tsconfig.json','.gitignore','.env.example','VERSION'
)
$script:DefaultGitRemote = 'git@github.com:QA-E2E4/rx2go-ai-qa.git'
$script:GitBusy = $false

$script:JiraFetchedSource = $null
$script:JiraGeneratedSpec = $null
$script:LoadedJiraIssue = $null
$script:LoadedJiraIssueKey = $null
$script:JiraImportedEdited = $false
$script:SuppressJiraImportedEditEvent = $false
$script:IntegrityGuardVerified = $false
$script:JiraGenerationError = $null
$script:JiraGenerationLog = $null

$script:LastAgentError = $null
$script:LastAgentFailureKind = $null
$script:LastFixtureRecoveryInterruption = $null
$script:AgentRunDir = $null
$script:AgentJiraAnalysis = $null
$script:AgentTestDesign = $null
$script:AgentUiDesign = $null
$script:AgentApiDesign = $null
$script:AgentReviewerSpec = $null
$script:AgentMcpExecution = $null
$script:AgentMcpExecutionRaw = $null
$script:FailureTriage = $null
$script:LastKnowledgeRetrieval = $null
$script:LastKnowledgeContext = ''
$script:KnowledgeRemoteRef = $null
$script:LastKnowledgeLearning = $null
$script:LastKnowledgeLearningFile = $null
$script:LastAutoGitSync = $null
$script:AutoGitAfterJiraRun = (-not $script:QueueWorkerMode)
$script:TestDataMutationAlwaysAllowed = $true
$script:SmartCoverageDesign = $null
$script:TaskUnderstandingContract = $null
$script:TaskUnderstandingGate = $null
$script:KnowledgeReadWarningShown = $false
$script:LastKnowledgeReadStatus = $null
$script:LastKnowledgeWriteWarning = $null
$script:KnowledgeExplorerRunning = $false
$script:KnowledgeExplorerStopRequested = $false
$script:KnowledgeExplorerRunDir = $null
$script:KnowledgeExplorerLastResult = $null
$script:KnowledgeExplorerStaleDays = 14
$script:KnowledgeSaveState = 'UNKNOWN'
$script:KnowledgeSaveDetails = 'Статус GitHub ещё не проверен.'
$script:KnowledgeSaveLastSuccess = $null
$script:KnowledgeExplorerProjectMap = $null
$script:KnowledgeExplorerProjectMapEnvironment = ''

# Jira Queue manager state (parent Launcher only).
$script:QueueRoot = Join-Path $script:LocalDataRoot 'queue'
$script:QueueWorkersRoot = Join-Path $script:QueueRoot 'workers'
$script:QueueJobsRoot = Join-Path $script:QueueRoot 'jobs'
$script:QueueStateFile = Join-Path $script:QueueRoot 'queue-state.json'
$script:QueueItems = New-Object System.Collections.ArrayList
$script:QueueRunning = $false
$script:QueuePaused = $false
$script:QueueMaxParallel = 3
$script:QueueTimer = $null
$script:QueueLastEvent = ''
$script:QueueUsageLimitWarningShown = $false
$script:JiraScreenshotPaths = @()
$script:JiraScreenshotMaxCount = 8
$script:PlaywrightMcpReady = $false
$script:BrowserStackCredentialFile = Join-Path $script:LocalDataRoot 'secrets\browserstack.credential.xml'
$script:BrowserStackMcpConfigured = $false


$script:TestPathOverride = $null



function Test-GitInstalled {
    return $null -ne (Get-Command git -ErrorAction SilentlyContinue)
}


function Invoke-Git([string[]]$Arguments, [int]$TimeoutMs = 60000) {
    if (-not (Test-GitInstalled)) {
        return [pscustomobject]@{
            ExitCode = 127
            Output = 'Git не установлен'
            Error = 'Git не установлен'
        }
    }

    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = 'git.exe'
        $psi.Arguments = ($Arguments | ForEach-Object {
            if ($_ -match '[\s"]') {
                '"' + ($_ -replace '"','\\"') + '"'
            }
            else {
                $_
            }
        }) -join ' '

        $psi.WorkingDirectory = $script:ProjectRoot
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true

        $p = New-Object System.Diagnostics.Process
        $p.StartInfo = $psi

        [void]$p.Start()

        # Critical: begin asynchronous reads BEFORE waiting for process exit.
        # Waiting first can deadlock if git fills stdout/stderr pipe buffers.
        $stdoutTask = $p.StandardOutput.ReadToEndAsync()
        $stderrTask = $p.StandardError.ReadToEndAsync()

        $watch = [System.Diagnostics.Stopwatch]::StartNew()

        while (-not $p.HasExited -and $watch.ElapsedMilliseconds -lt $TimeoutMs) {
            try {
                [System.Windows.Forms.Application]::DoEvents()
            }
            catch {
                # Queue workers / non-UI contexts may not need message pumping.
            }

            Start-Sleep -Milliseconds 50
        }

        if (-not $p.HasExited) {
            try { $p.Kill() } catch {}

            try { [void]$p.WaitForExit(2000) } catch {}

            $partialOut = ''
            $partialErr = ''

            try {
                if ($stdoutTask.Wait(1500)) {
                    $partialOut = ([string]$stdoutTask.Result).Trim()
                }
            } catch {}

            try {
                if ($stderrTask.Wait(1500)) {
                    $partialErr = ([string]$stderrTask.Result).Trim()
                }
            } catch {}

            return [pscustomobject]@{
                ExitCode = 124
                Output = $partialOut
                Error = if ($partialErr) {
                    "Git command timeout after $TimeoutMs ms. $partialErr"
                }
                else {
                    "Git command timeout after $TimeoutMs ms"
                }
            }
        }

        # Required after asynchronous redirection on .NET Framework so all
        # output events/tasks are drained before reading final results.
        try { $p.WaitForExit() } catch {}

        $out = ''
        $err = ''

        try { $out = ([string]$stdoutTask.Result).Trim() } catch {}
        try { $err = ([string]$stderrTask.Result).Trim() } catch {}

        return [pscustomobject]@{
            ExitCode = $p.ExitCode
            Output = $out
            Error = $err
        }
    }
    catch {
        return [pscustomobject]@{
            ExitCode = 1
            Output = ''
            Error = $_.Exception.Message
        }
    }
}


function Get-KnowledgeGitStatusLines {
    $args = New-Object System.Collections.ArrayList
    [void]$args.Add('status')
    [void]$args.Add('--porcelain')
    [void]$args.Add('--')

    foreach ($path in $script:KnowledgePaths) {
        [void]$args.Add([string]$path)
    }

    $result = Invoke-Git @($args)

    if (
        $result.ExitCode -ne 0 -or
        [string]::IsNullOrWhiteSpace($result.Output)
    ) {
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
    $paths = New-Object System.Collections.ArrayList

    foreach ($path in $script:KnowledgePaths) {
        if (-not [string]::IsNullOrWhiteSpace([string]$path)) {
            [void]$paths.Add([string]$path)
        }
    }

    return @($paths)
}



function Set-KnowledgeSaveState {
    param(
        [ValidateSet('UNKNOWN','SAVED','LOCAL_ONLY','SAVING','ERROR')]
        [string]$State,
        [string]$Details = ''
    )

    $script:KnowledgeSaveState = $State
    $script:KnowledgeSaveDetails = [string]$Details

    if ($State -eq 'SAVED') {
        $script:KnowledgeSaveLastSuccess = Get-Date
    }

    if ($knowledgeSaveStatusValue) {
        switch ($State) {
            'SAVED' {
                $knowledgeSaveStatusValue.Text = '✅ ЗНАНИЯ СОХРАНЕНЫ В GITHUB'
                $knowledgeSaveStatusValue.ForeColor = [System.Drawing.Color]::FromArgb(32,120,72)
            }
            'LOCAL_ONLY' {
                $knowledgeSaveStatusValue.Text = '🟡 ЕСТЬ ЛОКАЛЬНЫЕ ЗНАНИЯ — НЕ ОТПРАВЛЕНЫ'
                $knowledgeSaveStatusValue.ForeColor = [System.Drawing.Color]::FromArgb(161,98,7)
            }
            'SAVING' {
                $knowledgeSaveStatusValue.Text = '🔄 СОХРАНЯЮ ЗНАНИЯ В GITHUB…'
                $knowledgeSaveStatusValue.ForeColor = [System.Drawing.Color]::FromArgb(37,99,235)
            }
            'ERROR' {
                $knowledgeSaveStatusValue.Text = '❌ СОХРАНЕНИЕ ЗНАНИЙ НЕ ПОДТВЕРЖДЕНО'
                $knowledgeSaveStatusValue.ForeColor = [System.Drawing.Color]::Firebrick
            }
            default {
                $knowledgeSaveStatusValue.Text = '⚪ СТАТУС ЗНАНИЙ НЕ ПРОВЕРЕН'
                $knowledgeSaveStatusValue.ForeColor = [System.Drawing.Color]::DimGray
            }
        }
    }

    if ($knowledgeSaveDetailsLabel) {
        $detailText = [string]$Details

        if ($State -eq 'SAVED' -and $script:KnowledgeSaveLastSuccess) {
            $detailText += "  •  Проверено: $($script:KnowledgeSaveLastSuccess.ToString('dd.MM.yyyy HH:mm:ss'))"
        }

        $knowledgeSaveDetailsLabel.Text = $detailText
    }

    try {
        [System.Windows.Forms.Application]::DoEvents()
    }
    catch { }
}


function Get-KnowledgeSaveVerification {
    param([switch]$VerifyRemote)

    $git = Get-GitState
    $managedChanges = 0
    $ahead = $null
    $remoteVerified = $false
    $message = ''

    if (-not $git.Repository) {
        return [pscustomobject]@{
            Repository=$false
            ManagedChanges=0
            Ahead=$null
            RemoteVerified=$false
            Saved=$false
            Message='Git repository недоступен.'
        }
    }

    $managedChanges = @(Get-KnowledgeGitStatusLines).Count

    if ($managedChanges -gt 0) {
        return [pscustomobject]@{
            Repository=$true
            ManagedChanges=$managedChanges
            Ahead=$null
            RemoteVerified=$false
            Saved=$false
            Message="Есть $managedChanges локальных управляемых изменений."
        }
    }

    if (-not $VerifyRemote) {
        return [pscustomobject]@{
            Repository=$true
            ManagedChanges=0
            Ahead=$null
            RemoteVerified=$false
            Saved=$false
            Message='Локальных knowledge-изменений нет, но GitHub ещё не проверен.'
        }
    }

    if (-not (Set-KnowledgeOriginToSsh)) {
        return [pscustomobject]@{
            Repository=$true
            ManagedChanges=0
            Ahead=$null
            RemoteVerified=$false
            Saved=$false
            Message='Не удалось проверить GitHub: SSH origin не настроен.'
        }
    }

    $privateKey = Get-GitHubSshPrivateKeyPath

    if (-not (Test-Path $privateKey)) {
        return [pscustomobject]@{
            Repository=$true
            ManagedChanges=0
            Ahead=$null
            RemoteVerified=$false
            Saved=$false
            Message='Не удалось подтвердить сохранение: SSH key не настроен.'
        }
    }

    $auth = Invoke-SshGitHubAuthCheck

    if (-not $auth.Success) {
        return [pscustomobject]@{
            Repository=$true
            ManagedChanges=0
            Ahead=$null
            RemoteVerified=$false
            Saved=$false
            Message="Не удалось подтвердить сохранение: GitHub SSH недоступен. $($auth.Message)"
        }
    }

    $git = Get-GitState
    $branch = [string]$git.Branch

    if ([string]::IsNullOrWhiteSpace($branch) -or $branch -eq 'detached') {
        return [pscustomobject]@{
            Repository=$true
            ManagedChanges=0
            Ahead=$null
            RemoteVerified=$false
            Saved=$false
            Message='Не удалось подтвердить сохранение: Git HEAD detached.'
        }
    }

    $remoteBranch = Invoke-Git @(
        'ls-remote',
        '--exit-code',
        '--heads',
        'origin',
        $branch
    ) 30000

    if ($remoteBranch.ExitCode -ne 0) {
        return [pscustomobject]@{
            Repository=$true
            ManagedChanges=0
            Ahead=1
            RemoteVerified=$true
            Saved=$false
            Message="В GitHub ещё нет origin/$branch или ветка недоступна."
        }
    }

    $fetch = Invoke-Git @(
        'fetch',
        'origin',
        $branch
    ) 60000

    if ($fetch.ExitCode -ne 0) {
        return [pscustomobject]@{
            Repository=$true
            ManagedChanges=0
            Ahead=$null
            RemoteVerified=$false
            Saved=$false
            Message="Не удалось проверить GitHub после fetch: $($fetch.Error) $($fetch.Output)"
        }
    }

    $remoteRef = "origin/$branch"
    $aheadRaw = (Invoke-Git @(
        'rev-list',
        '--count',
        "$remoteRef..HEAD"
    ) 15000).Output

    $behindRaw = (Invoke-Git @(
        'rev-list',
        '--count',
        "HEAD..$remoteRef"
    ) 15000).Output

    $aheadValue = 0
    $behindValue = 0
    [void][int]::TryParse([string]$aheadRaw, [ref]$aheadValue)
    [void][int]::TryParse([string]$behindRaw, [ref]$behindValue)

    $remoteVerified = $true
    $ahead = $aheadValue

    if ($aheadValue -gt 0 -and $behindValue -gt 0) {
        $message = "Локальная база и GitHub разошлись: local +$aheadValue / remote +$behindValue. Нужна синхронизация."
    }
    elseif ($aheadValue -gt 0) {
        $message = "Есть $aheadValue локальный commit(ов), которые ещё не отправлены в GitHub."
    }
    elseif ($behindValue -gt 0) {
        $message = "GitHub содержит $behindValue новый commit(ов). Локальная база требует обновления."
    }
    else {
        $message = 'Все управляемые знания присутствуют в GitHub.'
    }

    return [pscustomobject]@{
        Repository=$true
        ManagedChanges=0
        Ahead=$ahead
        Behind=$behindValue
        RemoteVerified=$remoteVerified
        Saved=($aheadValue -eq 0 -and $behindValue -eq 0)
        Message=$message
    }
}


function Refresh-KnowledgeSaveState {
    param([switch]$VerifyRemote)

    if ($script:KnowledgeSaveState -eq 'SAVING') {
        return
    }

    try {
        $verification = Get-KnowledgeSaveVerification -VerifyRemote:$VerifyRemote

        if ($verification.ManagedChanges -gt 0) {
            Set-KnowledgeSaveState `
                -State LOCAL_ONLY `
                -Details $verification.Message
            return
        }

        if ($VerifyRemote) {
            if ($verification.Saved -and $verification.RemoteVerified) {
                Set-KnowledgeSaveState `
                    -State SAVED `
                    -Details 'GitHub подтверждён: локальных неотправленных знаний нет.'
            }
            elseif ($verification.RemoteVerified -and $verification.Ahead -gt 0) {
                Set-KnowledgeSaveState `
                    -State LOCAL_ONLY `
                    -Details $verification.Message
            }
            else {
                Set-KnowledgeSaveState `
                    -State ERROR `
                    -Details $verification.Message
            }

            return
        }

        # Local-only refresh must never claim SAVED by itself.
        # Keep a previously remote-verified green state until local changes appear.
        if ($script:KnowledgeSaveState -eq 'SAVED') {
            return
        }

        Set-KnowledgeSaveState `
            -State UNKNOWN `
            -Details 'Локально изменений знаний нет. Для зелёного статуса нужна проверка GitHub.'
    }
    catch {
        Set-KnowledgeSaveState `
            -State ERROR `
            -Details "Ошибка проверки Knowledge: $($_.Exception.Message)"
    }
}


function Save-AllKnowledgeToGitHub {
    if ($script:GitBusy) {
        Set-KnowledgeSaveState `
            -State ERROR `
            -Details 'Git сейчас занят другой операцией.'
        return
    }

    try {
        Set-KnowledgeSaveState `
            -State SAVING `
            -Details 'Автоматически: add → commit → safe sync → push → финальная проверка GitHub.'

        Set-KnowledgeActionStatus `
            -Text 'Сохраняю знания в GitHub…' `
            -Kind Info

        $git = Get-GitState

        if (-not $git.Repository) {
            Initialize-KnowledgeGit
            $git = Get-GitState
        }

        if (-not $git.Repository) {
            throw 'Git repository не удалось подготовить.'
        }

        # Step 1: commit managed knowledge/project changes if they exist.
        if ($git.ManagedDirty) {
            Commit-KnowledgeChanges

            $afterCommit = Get-GitState

            if ($afterCommit.ManagedDirty) {
                throw 'Не удалось создать локальный commit управляемых знаний.'
            }
        }

        # Step 2: fetch / safe pull / push using the existing guarded SSH sync.
        Sync-KnowledgeRepository

        # Step 3: never trust the operation label; verify the final GitHub state.
        $verification = Get-KnowledgeSaveVerification -VerifyRemote

        if (
            $verification.Saved -and
            $verification.RemoteVerified -and
            $verification.ManagedChanges -eq 0 -and
            $verification.Ahead -eq 0
        ) {
            Set-KnowledgeSaveState `
                -State SAVED `
                -Details 'Все управляемые знания сохранены и подтверждены в GitHub.'

            Set-KnowledgeActionStatus `
                -Text 'Знания сохранены в GitHub ✓' `
                -Kind Success

            [System.Windows.Forms.MessageBox]::Show(
                "Готово.`r`n`r`nВсе управляемые знания сохранены в GitHub и это подтверждено повторной проверкой.",
                'Rx2GO QA — Knowledge',
                'OK',
                'Information'
            ) | Out-Null
        }
        elseif ($verification.ManagedChanges -gt 0 -or $verification.Ahead -gt 0) {
            Set-KnowledgeSaveState `
                -State LOCAL_ONLY `
                -Details $verification.Message

            Set-KnowledgeActionStatus `
                -Text $verification.Message `
                -Kind Warning
        }
        else {
            Set-KnowledgeSaveState `
                -State ERROR `
                -Details $verification.Message

            Set-KnowledgeActionStatus `
                -Text $verification.Message `
                -Kind Error
        }

        Refresh-KnowledgeUI -PreserveActionText
    }
    catch {
        Set-KnowledgeSaveState `
            -State ERROR `
            -Details $_.Exception.Message

        Set-KnowledgeActionStatus `
            -Text "Не удалось сохранить знания в GitHub: $($_.Exception.Message)" `
            -Kind Error

        [System.Windows.Forms.MessageBox]::Show(
            "Знания НЕ подтверждены как сохранённые в GitHub.`r`n`r`n$($_.Exception.Message)",
            'Rx2GO QA — Knowledge',
            'OK',
            'Warning'
        ) | Out-Null
    }
}

function Test-ManagedGitPath {
    param([string]$Path)

    $normalized = ([string]$Path).Replace('\','/').Trim()

    if ([string]::IsNullOrWhiteSpace($normalized)) {
        return $false
    }

    foreach ($managedPath in @($script:KnowledgePaths)) {
        $managed = ([string]$managedPath).Replace('\','/').TrimEnd('/')

        if (
            [string]::Equals(
                $normalized,
                $managed,
                [System.StringComparison]::OrdinalIgnoreCase
            ) -or
            $normalized.StartsWith(
                $managed + '/',
                [System.StringComparison]::OrdinalIgnoreCase
            )
        ) {
            return $true
        }
    }

    return $false
}


function Get-GitStatusEntryPath {
    param([string]$RawLine)

    if ([string]::IsNullOrWhiteSpace($RawLine)) {
        return ''
    }

    $path = if ($RawLine.Length -gt 3) {
        $RawLine.Substring(3).Trim()
    }
    else {
        ''
    }

    if ($path -match '\s+->\s+') {
        $path = ($path -split '\s+->\s+')[-1].Trim()
    }

    return $path.Trim('"')
}


function Get-OtherGitStatusEntries {
    $entries = New-Object System.Collections.ArrayList

    foreach ($line in @(Get-AllGitStatusLines)) {
        $path = Get-GitStatusEntryPath -RawLine ([string]$line)

        if ([string]::IsNullOrWhiteSpace($path)) {
            continue
        }

        if (Test-ManagedGitPath -Path $path) {
            continue
        }

        $statusCode = if ($line.Length -ge 2) {
            $line.Substring(0,2)
        }
        else {
            ''
        }

        $isUntracked = ($statusCode -eq '??')

        [void]$entries.Add([pscustomobject]@{
            Raw = [string]$line
            StatusCode = $statusCode
            Path = $path
            IsUntracked = $isUntracked
            IsTrackedChange = (-not $isUntracked)
        })
    }

    return @($entries)
}


function Format-GitStatusEntryList {
    param(
        $Entries,
        [int]$MaxItems = 12
    )

    $lines = New-Object System.Collections.ArrayList
    $items = @($Entries)
    $shown = 0

    foreach ($entry in $items) {
        if ($shown -ge $MaxItems) {
            break
        }

        $kind = if ([bool]$entry.IsUntracked) {
            'untracked'
        }
        else {
            "tracked $([string]$entry.StatusCode)"
        }

        [void]$lines.Add("• $([string]$entry.Path)  [$kind]")
        $shown++
    }

    if ($items.Count -gt $shown) {
        [void]$lines.Add("… ещё $($items.Count - $shown)")
    }

    if ($lines.Count -eq 0) {
        return 'Нет.'
    }

    return (@($lines) -join "`r`n")
}


function Show-GitLocalChanges {
    $git = Get-GitState

    if (-not $git.Repository) {
        [System.Windows.Forms.MessageBox]::Show(
            'Git repository не настроен.',
            'Rx2GO QA — Git changes',
            'OK',
            'Information'
        ) | Out-Null
        return
    }

    $managed = @(Get-KnowledgeGitStatusLines)
    $other = @(Get-OtherGitStatusEntries)

    $managedText = if ($managed.Count -gt 0) {
        @(
            $managed |
                Select-Object -First 12 |
                ForEach-Object { "• $_" }
        ) -join "`r`n"
    }
    else {
        'Нет.'
    }

    if ($managed.Count -gt 12) {
        $managedText += "`r`n… ещё $($managed.Count - 12)"
    }

    $otherText = Format-GitStatusEntryList -Entries $other -MaxItems 16

    $message = @"
Управляемые Launcher изменения: $($managed.Count)

$managedText

Вне управляемого списка: $($other.Count)

$otherText

Untracked-файлы сами по себе больше не блокируют безопасный Pull.
Tracked-изменения вне управляемого списка блокируют Pull, чтобы их не потерять.
"@

    [System.Windows.Forms.MessageBox]::Show(
        $message,
        'Rx2GO QA — локальные Git изменения',
        'OK',
        'Information'
    ) | Out-Null
}


function Set-KnowledgeSshStatus {
    param(
        [string]$Text,
        [ValidateSet('Info','Success','Warning','Error')]
        [string]$Kind = 'Info'
    )

    if (-not $knowledgeSshStatusValue) {
        return
    }

    $knowledgeSshStatusValue.Text = $Text

    switch ($Kind) {
        'Success' {
            $knowledgeSshStatusValue.ForeColor = [System.Drawing.Color]::FromArgb(32,120,72)
        }
        'Warning' {
            $knowledgeSshStatusValue.ForeColor = [System.Drawing.Color]::FromArgb(161,98,7)
        }
        'Error' {
            $knowledgeSshStatusValue.ForeColor = [System.Drawing.Color]::Firebrick
        }
        default {
            $knowledgeSshStatusValue.ForeColor = [System.Drawing.Color]::FromArgb(37,99,235)
        }
    }

    try {
        [System.Windows.Forms.Application]::DoEvents()
    }
    catch { }
}


function Get-GitHubSshUserFromMessage {
    param([string]$Message)

    if ([string]::IsNullOrWhiteSpace($Message)) {
        return ''
    }

    $match = [regex]::Match(
        $Message,
        '(?i)\bHi\s+([^!\s]+)!'
    )

    if ($match.Success) {
        return [string]$match.Groups[1].Value
    }

    return ''
}


function Get-GitState {
    if (-not (Test-GitInstalled)) {
        return [pscustomobject]@{
            Installed=$false
            Repository=$false
            Branch='—'
            Remote='—'
            Dirty=$false
            Changes=0
            ManagedDirty=$false
            ManagedChanges=0
            OtherChanges=0
            OtherTrackedChanges=0
            OtherUntrackedChanges=0
            LastCommit='—'
            Status='Git не установлен'
        }
    }

    $inside = Invoke-Git @('rev-parse','--is-inside-work-tree')

    if ($inside.ExitCode -ne 0 -or $inside.Output -ne 'true') {
        return [pscustomobject]@{
            Installed=$true
            Repository=$false
            Branch='—'
            Remote='—'
            Dirty=$false
            Changes=0
            ManagedDirty=$false
            ManagedChanges=0
            OtherChanges=0
            OtherTrackedChanges=0
            OtherUntrackedChanges=0
            LastCommit='—'
            Status='Репозиторий не инициализирован'
        }
    }

    $branch = (Invoke-Git @('branch','--show-current')).Output
    if (-not $branch) {
        $branch = 'detached'
    }

    $remote = (Invoke-Git @('remote','get-url','origin')).Output
    if (-not $remote) {
        $remote = 'не настроен'
    }

    $allLines = @(Get-AllGitStatusLines)
    $managedLines = @(Get-KnowledgeGitStatusLines)
    $otherEntries = @(Get-OtherGitStatusEntries)

    $allCount = $allLines.Count
    $managedCount = $managedLines.Count
    $otherCount = $otherEntries.Count

    $otherTracked = @(
        $otherEntries |
            Where-Object { [bool]$_.IsTrackedChange }
    ).Count

    $otherUntracked = @(
        $otherEntries |
            Where-Object { [bool]$_.IsUntracked }
    ).Count

    $lastCommit = (Invoke-Git @('log','-1','--pretty=format:%h %s')).Output
    if (-not $lastCommit) {
        $lastCommit = 'коммитов пока нет'
    }

    $status = if ($managedCount -gt 0) {
        "Изменения проекта: $managedCount"
    }
    elseif ($otherTracked -gt 0) {
        "Вне управляемых файлов: tracked $otherTracked"
    }
    elseif ($otherUntracked -gt 0) {
        "Вне управляемых файлов: untracked $otherUntracked"
    }
    else {
        'Synced locally'
    }

    return [pscustomobject]@{
        Installed=$true
        Repository=$true
        Branch=$branch
        Remote=$remote
        Dirty=($allCount -gt 0)
        Changes=$allCount
        ManagedDirty=($managedCount -gt 0)
        ManagedChanges=$managedCount
        OtherChanges=$otherCount
        OtherTrackedChanges=$otherTracked
        OtherUntrackedChanges=$otherUntracked
        LastCommit=$lastCommit
        Status=$status
    }
}

function Get-KnowledgeExplorerModuleDefinitions {
    return @(
        [pscustomobject]@{ Name='Orders'; Slug='orders'; Hint='Orders / Order Detail / batch / Activity History' },
        [pscustomobject]@{ Name='Scanner'; Slug='scanner'; Hint='Scanner / Order Editor / order creation / delivery method' },
        [pscustomobject]@{ Name='Tickets Queue'; Slug='tickets-queue'; Hint='Tickets Queue / Ticket Dashboard / Workout / Related tickets' },
        [pscustomobject]@{ Name='Dispatcher'; Slug='dispatcher'; Hint='Dispatcher Queue / Delivery Details' },
        [pscustomobject]@{ Name='QAQC'; Slug='qaqc'; Hint='QAQC Queue / Delivery method / order review' },
        [pscustomobject]@{ Name='Routes / Gigs'; Slug='routes-gigs'; Hint='Routes / Gigs / Activity History / order-route relationship' },
        [pscustomobject]@{ Name='Copays'; Slug='copays'; Hint='Copays / order copay / payment-related UI' },
        [pscustomobject]@{ Name='Chat'; Slug='chat'; Hint='Route chat / Show Chat / message history' }
    )
}


function Get-KnowledgeExplorerModeKey {
    param([string]$DisplayName)

    switch -Regex ($DisplayName) {
        '^Быстрый' { return 'quick' }
        '^Глубокий' { return 'deep' }
        '^Полный проект' { return 'full-project' }
        '^Изучить модуль' { return 'module' }
        '^Изучить workflow' { return 'workflow' }
        '^Обновить' { return 'refresh' }
        default { return 'quick' }
    }
}



function ConvertTo-KnowledgeExplorerSafeSlug {
    param([string]$Text)

    $value = ([string]$Text).Trim().ToLowerInvariant()

    $translit = @{
        'а'='a'; 'б'='b'; 'в'='v'; 'г'='g'; 'д'='d'; 'е'='e'; 'ё'='e'
        'ж'='zh'; 'з'='z'; 'и'='i'; 'й'='y'; 'к'='k'; 'л'='l'; 'м'='m'
        'н'='n'; 'о'='o'; 'п'='p'; 'р'='r'; 'с'='s'; 'т'='t'; 'у'='u'
        'ф'='f'; 'х'='h'; 'ц'='c'; 'ч'='ch'; 'ш'='sh'; 'щ'='sch'; 'ъ'=''
        'ы'='y'; 'ь'=''; 'э'='e'; 'ю'='yu'; 'я'='ya'
    }

    $builder = New-Object System.Text.StringBuilder

    foreach ($char in $value.ToCharArray()) {
        $s = [string]$char

        if ($translit.ContainsKey($s)) {
            [void]$builder.Append([string]$translit[$s])
        }
        else {
            [void]$builder.Append($s)
        }
    }

    $slug = $builder.ToString()
    $slug = $slug -replace '[^a-z0-9]+','-'
    $slug = $slug.Trim('-')

    if ([string]::IsNullOrWhiteSpace($slug)) {
        $sha = [System.Security.Cryptography.SHA256]::Create()

        try {
            $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]$Text)
            $hash = $sha.ComputeHash($bytes)
            $hex = -join ($hash | ForEach-Object { $_.ToString('x2') })
            $slug = "module-$($hex.Substring(0,8))"
        }
        finally {
            $sha.Dispose()
        }
    }

    if ($slug.Length -gt 64) {
        $slug = $slug.Substring(0,64).Trim('-')
    }

    return $slug
}


function Get-KnowledgeExplorerProjectMapFile {
    param([string]$Environment)

    $envFolder = Get-KnowledgeExplorerEnvironmentFolder -Environment $Environment
    $dir = Join-Path $script:ProjectRoot "knowledge\explorer\$envFolder"

    New-Item `
        -ItemType Directory `
        -Path $dir `
        -Force | Out-Null

    return (Join-Path $dir 'project-map.json')
}


function Save-KnowledgeExplorerProjectMap {
    param(
        [string]$Environment,
        $Parsed
    )

    $path = Get-KnowledgeExplorerProjectMapFile -Environment $Environment

    $record = [ordered]@{
        schemaVersion = 1
        sourceClass = 'LIVE_PROJECT_MAP'
        source = "Playwright MCP / Rx2GO $Environment"
        environment = ([string]$Environment).ToUpperInvariant()
        observedAt = (Get-Date).ToString('o')
        deploymentHierarchy = 'BRANCH -> HOT -> ADM'
        requirementAuthority = $false
        result = $Parsed
    }

    Write-Utf8NoBomFile `
        -Path $path `
        -Content ($record | ConvertTo-Json -Depth 16)

    return $path
}


function Get-KnowledgeExplorerProjectMapPrompt {
    param([string]$Environment)

    $environment = ([string]$Environment).ToUpperInvariant()
    $layer = Get-KnowledgeExplorerLayerType -Environment $environment
    $baseline = Get-KnowledgeExplorerBaselineEnvironment -Environment $environment

    return @"
You are Rx2GO Project Mapper.

GOAL:
Before Knowledge Explorer studies modules, discover the ACTUAL accessible Rx2GO application structure for the current authenticated user.

ENVIRONMENT:
$environment

KNOWLEDGE LAYER:
$layer

BASELINE:
$(if ($baseline) { $baseline } else { 'NONE — ADM is primary baseline' })

STRICT TOOL RULES:
- Use ONLY `playwright/browser_*` MCP tools.
- Work in the EXISTING authenticated Rx2GO Chrome session.
- Do NOT close the browser or current tab.
- Do NOT navigate outside rx2go.ai.
- Read-only discovery only. Never create/update/delete/transition business data.
- Start with browser_tabs + browser_snapshot.
- Discover navigation from the LIVE UI. Do not rely on a predefined module list.
- Expand/click safe navigation groups as needed.
- You may open pages, tabs, filters, accordions, and non-mutating menus.
- Return to navigation and continue until all accessible first-level product sections are mapped.
- If a menu item opens a detail/list page representing a distinct business capability, include it as a module.
- Exclude logout, profile/account-only controls, documentation links, external links, browser controls, pure separators, and duplicate aliases to the same capability.
- If two menu labels clearly open the same route/capability, return one canonical module and list aliases.
- Do not record secrets, tokens, cookies, auth headers, personal customer/patient data.

IMPORTANT:
- This is a PROJECT MAP, not a product requirement document.
- Existing observed behavior is not automatically expected behavior.
- Suspicious UI behavior does not become a confirmed bug.

RETURN ONLY valid JSON:
{
  "mcpUsed": true,
  "environment": "$environment",
  "status": "COMPLETE|PARTIAL|BLOCKED",
  "startUrl": "actual URL",
  "endUrl": "actual URL",
  "navigationModel": "sidebar|topbar|mixed|other",
  "modules": [
    {
      "name": "canonical visible module name",
      "group": "navigation group/section or Main",
      "entryUrl": "actual observed URL",
      "howToOpen": "observed navigation action",
      "aliases": ["alternate visible names if any"],
      "purposeHint": "short observed purpose",
      "safeToExploreReadOnly": true,
      "requiresSpecificContext": false,
      "contextHint": "facility/client/service/order/ticket context if visibly required",
      "confidence": "HIGH|MEDIUM|LOW"
    }
  ],
  "navigationGroups": [
    {
      "name": "group name",
      "items": ["visible module names"]
    }
  ],
  "excludedItems": [
    {
      "name": "visible item",
      "reason": "logout/profile/external/duplicate/non-product/etc"
    }
  ],
  "uncertainties": ["what could not be proven safely"],
  "summary": "short project map summary"
}

FINAL SELF-CHECK:
- mcpUsed must be true.
- environment must be $environment.
- modules must be deduplicated by capability, not just label.
- COMPLETE only if all currently accessible main navigation groups were inspected.
- Do not include invented routes or hidden modules that were not observed live.
"@
}


function Test-KnowledgeExplorerProjectMap {
    param(
        $Parsed,
        [string]$Environment
    )

    if (-not $Parsed) {
        return [pscustomobject]@{
            Success=$false
            Error='Project Mapper returned no JSON.'
        }
    }

    if (-not [bool]$Parsed.mcpUsed) {
        return [pscustomobject]@{
            Success=$false
            Error='Project Mapper did not confirm Playwright MCP usage.'
        }
    }

    $environment = ([string]$Environment).ToUpperInvariant()

    if ([string]$Parsed.environment -ne $environment) {
        return [pscustomobject]@{
            Success=$false
            Error="Project Mapper environment mismatch: expected $environment, received $([string]$Parsed.environment)."
        }
    }

    $status = ([string]$Parsed.status).ToUpperInvariant()

    if ($status -notin @('COMPLETE','PARTIAL','BLOCKED')) {
        return [pscustomobject]@{
            Success=$false
            Error="Project Mapper returned unknown status '$status'."
        }
    }

    $modules = @($Parsed.modules | Where-Object { $_ })

    if ($status -ne 'BLOCKED' -and $modules.Count -eq 0) {
        return [pscustomobject]@{
            Success=$false
            Error='Project Mapper found no modules.'
        }
    }

    $seen = @{}

    foreach ($module in $modules) {
        $name = ([string]$module.name).Trim()

        if ([string]::IsNullOrWhiteSpace($name)) {
            return [pscustomobject]@{
                Success=$false
                Error='Project Mapper returned a module without name.'
            }
        }

        $key = $name.ToLowerInvariant()

        if ($seen.ContainsKey($key)) {
            return [pscustomobject]@{
                Success=$false
                Error="Project Mapper returned duplicate module '$name'."
            }
        }

        $seen[$key] = $true
    }

    return [pscustomobject]@{
        Success=$true
        Error=''
    }
}


function Convert-ProjectMapToExplorerModules {
    param($ProjectMap)

    $result = New-Object System.Collections.ArrayList
    $usedSlugs = @{}

    foreach ($module in @($ProjectMap.modules | Where-Object { $_ })) {
        $name = ([string]$module.name).Trim()
        $slug = ConvertTo-KnowledgeExplorerSafeSlug -Text $name

        $baseSlug = $slug
        $suffix = 2

        while ($usedSlugs.ContainsKey($slug)) {
            $slug = "$baseSlug-$suffix"
            $suffix++
        }

        $usedSlugs[$slug] = $true

        $hintParts = New-Object System.Collections.ArrayList

        if ($module.group) {
            [void]$hintParts.Add("Group: $([string]$module.group)")
        }

        if ($module.entryUrl) {
            [void]$hintParts.Add("Observed entry URL: $([string]$module.entryUrl)")
        }

        if ($module.purposeHint) {
            [void]$hintParts.Add("Purpose: $([string]$module.purposeHint)")
        }

        if ($module.contextHint) {
            [void]$hintParts.Add("Context: $([string]$module.contextHint)")
        }

        [void]$result.Add([pscustomobject]@{
            Name = $name
            Slug = $slug
            Hint = (@($hintParts) -join ' | ')
            EntryUrl = [string]$module.entryUrl
            Group = [string]$module.group
            RequiresSpecificContext = [bool]$module.requiresSpecificContext
            ContextHint = [string]$module.contextHint
            Discovered = $true
        })
    }

    return @($result)
}


function Invoke-KnowledgeExplorerProjectMapper {
    param([string]$Environment)

    Set-KnowledgeExplorerStatus `
        -Text "Этап 1/2: строю карту всего проекта $Environment…" `
        -Kind Info

    $prompt = Get-KnowledgeExplorerProjectMapPrompt -Environment $Environment

    $raw = Invoke-CodexAgent `
        -AgentSlug "knowledge-project-mapper-$($Environment.ToLowerInvariant())" `
        -Prompt $prompt `
        -TimeoutSec 600 `
        -ReasoningEffort 'medium'

    if (-not $raw) {
        return [pscustomobject]@{
            Success=$false
            StopAll=(
                [string]$script:LastAgentFailureKind -eq 'CODEX_USAGE_LIMIT' -or
                (Test-CodexUsageLimitText -Text ([string]$script:LastAgentError))
            )
            Error=[string]$script:LastAgentError
        }
    }

    if (-not (Test-LastAgentUsedPlaywrightMcpSuccessfully -MinimumCompletedCalls 3)) {
        return [pscustomobject]@{
            Success=$false
            StopAll=$false
            Error=[string]$script:LastAgentError
        }
    }

    $parsed = Convert-AgentJson $raw

    if (-not $parsed) {
        return [pscustomobject]@{
            Success=$false
            StopAll=$false
            Error=[string]$script:LastAgentError
        }
    }

    $validation = Test-KnowledgeExplorerProjectMap `
        -Parsed $parsed `
        -Environment $Environment

    if (-not $validation.Success) {
        return [pscustomobject]@{
            Success=$false
            StopAll=$false
            Error=[string]$validation.Error
        }
    }

    $mapFile = Save-KnowledgeExplorerProjectMap `
        -Environment $Environment `
        -Parsed $parsed

    $script:KnowledgeExplorerProjectMap = $parsed
    $script:KnowledgeExplorerProjectMapEnvironment = ([string]$Environment).ToUpperInvariant()

    $modules = @(Convert-ProjectMapToExplorerModules -ProjectMap $parsed)

    Write-KnowledgeExplorerLog "Project Map → $($modules.Count) модулей"
    Write-KnowledgeExplorerLog "Карта сохранена → $mapFile"

    foreach ($module in $modules) {
        Write-KnowledgeExplorerLog "  • $($module.Name) | $($module.EntryUrl)"
    }

    return [pscustomobject]@{
        Success=$true
        StopAll=$false
        Error=''
        Parsed=$parsed
        Modules=$modules
        File=$mapFile
    }
}

function Get-KnowledgeExplorerBaselineEnvironment {
    param([string]$Environment)

    switch (([string]$Environment).ToUpperInvariant()) {
        'HOT' { return 'ADM' }
        'BRANCH' { return 'HOT' }
        default { return '' }
    }
}


function Get-KnowledgeExplorerLayerType {
    param([string]$Environment)

    switch (([string]$Environment).ToUpperInvariant()) {
        'ADM' { return 'ADM_BASELINE' }
        'HOT' { return 'HOT_DELTA' }
        'BRANCH' { return 'BRANCH_TEMPORARY_DELTA' }
        default { return 'UNKNOWN' }
    }
}


function Get-KnowledgeExplorerEnvironmentFolder {
    param([string]$Environment)

    switch (([string]$Environment).ToUpperInvariant()) {
        'ADM' { return 'adm' }
        'HOT' { return 'hot' }
        'BRANCH' { return 'branch' }
        default { return 'unknown' }
    }
}


function Get-KnowledgeExplorerModuleFile {
    param(
        [string]$Environment,
        [string]$Slug
    )

    $envFolder = Get-KnowledgeExplorerEnvironmentFolder -Environment $Environment
    $dir = Join-Path $script:ProjectRoot "knowledge\explorer\$envFolder\modules"
    New-Item -ItemType Directory -Path $dir -Force | Out-Null

    return (Join-Path $dir "$Slug.json")
}


function Get-KnowledgeExplorerWorkflowFile {
    param(
        [string]$Environment,
        [string]$ModuleSlug,
        [string]$Target
    )

    $safeTarget = ([string]$Target).Trim().ToLowerInvariant()
    $safeTarget = $safeTarget -replace '[^a-z0-9а-яё]+','-'
    $safeTarget = $safeTarget.Trim('-')

    if ([string]::IsNullOrWhiteSpace($safeTarget)) {
        $safeTarget = 'primary-workflow'
    }

    if ($safeTarget.Length -gt 50) {
        $safeTarget = $safeTarget.Substring(0,50).Trim('-')
    }

    $envFolder = Get-KnowledgeExplorerEnvironmentFolder -Environment $Environment
    $dir = Join-Path $script:ProjectRoot "knowledge\explorer\$envFolder\workflows"
    New-Item -ItemType Directory -Path $dir -Force | Out-Null

    return (Join-Path $dir "$ModuleSlug-$safeTarget.json")
}


function Initialize-KnowledgeExplorerStorage {
    foreach ($environment in @('ADM','HOT','BRANCH')) {
        $envFolder = Get-KnowledgeExplorerEnvironmentFolder -Environment $environment

        foreach ($suffix in @('modules','workflows')) {
            New-Item `
                -ItemType Directory `
                -Path (Join-Path $script:ProjectRoot "knowledge\explorer\$envFolder\$suffix") `
                -Force | Out-Null
        }
    }

    # v0.12.34 stored HOT observations directly under explorer/modules + workflows.
    # Migrate them once into the HOT delta layer without deleting legacy files.
    foreach ($kind in @('modules','workflows')) {
        $legacy = Join-Path $script:ProjectRoot "knowledge\explorer\$kind"
        $target = Join-Path $script:ProjectRoot "knowledge\explorer\hot\$kind"

        if (Test-Path $legacy) {
            foreach ($file in @(
                Get-ChildItem `
                    -Path $legacy `
                    -File `
                    -Filter '*.json' `
                    -ErrorAction SilentlyContinue
            )) {
                $dest = Join-Path $target $file.Name

                if (-not (Test-Path $dest)) {
                    try {
                        Copy-Item `
                            -Path $file.FullName `
                            -Destination $dest `
                            -Force
                    }
                    catch { }
                }
            }
        }
    }
}


function Write-KnowledgeExplorerLog {
    param([string]$Text)

    $stamp = Get-Date -Format 'HH:mm:ss'
    $line = "$stamp  $Text"

    if ($knowledgeExplorerLogBox) {
        $knowledgeExplorerLogBox.AppendText($line + "`r`n")
        $knowledgeExplorerLogBox.SelectionStart = $knowledgeExplorerLogBox.TextLength
        $knowledgeExplorerLogBox.ScrollToCaret()
    }

    if ($script:KnowledgeExplorerRunDir) {
        try {
            Add-Content `
                -Path (Join-Path $script:KnowledgeExplorerRunDir 'knowledge-explorer.log') `
                -Value $line `
                -Encoding UTF8
        }
        catch { }
    }

    try {
        Append-AgentLog "KNOWLEDGE EXPLORER → $Text"
    }
    catch { }

    try {
        [System.Windows.Forms.Application]::DoEvents()
    }
    catch { }
}


function Set-KnowledgeExplorerStatus {
    param(
        [string]$Text,
        [ValidateSet('Info','Success','Warning','Error')]
        [string]$Kind = 'Info'
    )

    if ($knowledgeExplorerStatusLabel) {
        $knowledgeExplorerStatusLabel.Text = $Text

        switch ($Kind) {
            'Success' { $knowledgeExplorerStatusLabel.ForeColor = [System.Drawing.Color]::FromArgb(32,120,72) }
            'Warning' { $knowledgeExplorerStatusLabel.ForeColor = [System.Drawing.Color]::FromArgb(161,98,7) }
            'Error' { $knowledgeExplorerStatusLabel.ForeColor = [System.Drawing.Color]::Firebrick }
            default { $knowledgeExplorerStatusLabel.ForeColor = [System.Drawing.Color]::FromArgb(37,99,235) }
        }
    }

    Write-KnowledgeExplorerLog $Text
}


function Update-KnowledgeExplorerEnvironmentUi {
    if (-not $knowledgeExplorerEnvironmentCombo) {
        return
    }

    $environment = ([string]$knowledgeExplorerEnvironmentCombo.SelectedItem).ToUpperInvariant()

    if ([string]::IsNullOrWhiteSpace($environment)) {
        $environment = 'ADM'
    }

    $baseline = Get-KnowledgeExplorerBaselineEnvironment -Environment $environment
    $layer = Get-KnowledgeExplorerLayerType -Environment $environment

    if ($knowledgeExplorerBaselineValueLabel) {
        $knowledgeExplorerBaselineValueLabel.Text = if ($baseline) {
            "$baseline  → сравнение"
        }
        else {
            '—  основная база'
        }
    }

    if ($knowledgeExplorerStartButton) {
        $knowledgeExplorerStartButton.Text = "▶ ИЗУЧИТЬ $environment"
    }

    $needAdmCode = ($environment -eq 'ADM')

    if ($knowledgeAdmDailyPasswordBox) {
        $knowledgeAdmDailyPasswordBox.Enabled = $needAdmCode
        $knowledgeAdmDailyPasswordBox.BackColor = if ($needAdmCode) {
            [System.Drawing.Color]::White
        }
        else {
            [System.Drawing.Color]::FromArgb(241,245,249)
        }
    }

    if ($knowledgeAdmDailyPasswordLabel) {
        $knowledgeAdmDailyPasswordLabel.Enabled = $needAdmCode
    }

    if ($knowledgeExplorerStatusLabel -and -not $script:KnowledgeExplorerRunning) {
        $knowledgeExplorerStatusLabel.Text = switch ($environment) {
            'ADM' { 'ADM = основная база знаний / baseline.' }
            'HOT' { 'HOT = delta относительно ADM.' }
            'BRANCH' { 'BRANCH = временная delta относительно HOT; auto-push отключён.' }
            default { "$layer" }
        }
    }
}



function Update-KnowledgeExplorerModeUi {
    if (-not $knowledgeExplorerModeCombo) {
        return
    }

    $mode = Get-KnowledgeExplorerModeKey `
        -DisplayName ([string]$knowledgeExplorerModeCombo.SelectedItem)

    if ($knowledgeExplorerModuleCombo) {
        $knowledgeExplorerModuleCombo.Enabled = ($mode -in @('module','workflow'))
    }

    if ($knowledgeExplorerTargetBox) {
        $knowledgeExplorerTargetBox.Enabled = ($mode -eq 'workflow')
    }

    if ($knowledgeExplorerModuleLabel) {
        $knowledgeExplorerModuleLabel.Text = if ($mode -in @('module','workflow')) {
            'Модуль'
        }
        elseif ($mode -eq 'full-project') {
            'Модуль'
        }
        else {
            'Модуль'
        }
    }

    if ($knowledgeExplorerStatusLabel -and -not $script:KnowledgeExplorerRunning) {
        $environment = if ($knowledgeExplorerEnvironmentCombo) {
            ([string]$knowledgeExplorerEnvironmentCombo.SelectedItem).ToUpperInvariant()
        }
        else {
            'ADM'
        }

        if ($mode -eq 'full-project') {
            $knowledgeExplorerStatusLabel.Text = "Полный проект: сначала карта всего доступного меню $environment, затем глубокое изучение каждого найденного модуля."
        }
        elseif ($mode -eq 'deep') {
            $knowledgeExplorerStatusLabel.Text = 'Глубокий crawl: изучаются 8 приоритетных модулей; выбор «Модуль» не используется.'
        }
        elseif ($mode -eq 'quick') {
            $knowledgeExplorerStatusLabel.Text = 'Быстрый crawl: изучаются 8 приоритетных модулей; выбор «Модуль» не используется.'
        }
        elseif ($mode -eq 'module') {
            $knowledgeExplorerStatusLabel.Text = 'Будет подробно изучен только выбранный модуль.'
        }
        elseif ($mode -eq 'workflow') {
            $knowledgeExplorerStatusLabel.Text = 'Будет изучен выбранный workflow внутри выбранного модуля.'
        }
    }
}

function Get-KnowledgeExplorerExistingContext {
    param(
        [string]$Environment,
        [string]$ModuleSlug
    )

    $path = Get-KnowledgeExplorerModuleFile `
        -Environment $Environment `
        -Slug $ModuleSlug

    if (-not (Test-Path $path)) {
        return 'NO PREVIOUS KNOWLEDGE FOR THIS ENVIRONMENT.'
    }

    try {
        $raw = Get-Content -Raw -Path $path -ErrorAction Stop

        if ($raw.Length -gt 18000) {
            return $raw.Substring(0,18000) + "`n[TRUNCATED]"
        }

        return $raw
    }
    catch {
        return 'PREVIOUS KNOWLEDGE COULD NOT BE READ.'
    }
}


function Get-KnowledgeExplorerBaselineContext {
    param(
        [string]$Environment,
        [string]$ModuleSlug
    )

    $baseline = Get-KnowledgeExplorerBaselineEnvironment -Environment $Environment

    if ([string]::IsNullOrWhiteSpace($baseline)) {
        return [pscustomobject]@{
            Environment=''
            Available=$false
            Context='NO BASELINE — CURRENT ENVIRONMENT IS ADM BASELINE.'
        }
    }

    $path = Get-KnowledgeExplorerModuleFile `
        -Environment $baseline `
        -Slug $ModuleSlug

    if (-not (Test-Path $path)) {
        return [pscustomobject]@{
            Environment=$baseline
            Available=$false
            Context="BASELINE $baseline HAS NOT BEEN EXPLORED FOR THIS MODULE YET."
        }
    }

    try {
        $raw = Get-Content -Raw -Path $path -ErrorAction Stop

        if ($raw.Length -gt 22000) {
            $raw = $raw.Substring(0,22000) + "`n[TRUNCATED]"
        }

        return [pscustomobject]@{
            Environment=$baseline
            Available=$true
            Context=$raw
        }
    }
    catch {
        return [pscustomobject]@{
            Environment=$baseline
            Available=$false
            Context="BASELINE $baseline COULD NOT BE READ."
        }
    }
}


function Get-KnowledgeExplorerModulesForRun {
    param(
        [string]$Mode,
        [string]$SelectedModuleName,
        [string]$Environment
    )

    $all = @(Get-KnowledgeExplorerModuleDefinitions)

    if ($Mode -in @('module','workflow')) {
        return @(
            $all |
                Where-Object { [string]$_.Name -eq [string]$SelectedModuleName } |
                Select-Object -First 1
        )
    }

    if ($Mode -eq 'refresh') {
        $cutoff = (Get-Date).AddDays(-1 * [int]$script:KnowledgeExplorerStaleDays)
        $stale = New-Object System.Collections.ArrayList

        foreach ($module in $all) {
            $path = Get-KnowledgeExplorerModuleFile `
                -Environment $Environment `
                -Slug ([string]$module.Slug)

            $baseline = Get-KnowledgeExplorerBaselineEnvironment -Environment $Environment
            $baselineMissing = $false

            if ($baseline) {
                $baselinePath = Get-KnowledgeExplorerModuleFile `
                    -Environment $baseline `
                    -Slug ([string]$module.Slug)

                $baselineMissing = -not (Test-Path $baselinePath)
            }

            if (-not (Test-Path $path)) {
                [void]$stale.Add($module)
                continue
            }

            if ($baselineMissing) {
                [void]$stale.Add($module)
                continue
            }

            try {
                $doc = Get-Content -Raw -Path $path | ConvertFrom-Json -ErrorAction Stop
                $observedAt = [datetime]$doc.observedAt

                if ($observedAt -lt $cutoff) {
                    [void]$stale.Add($module)
                }
            }
            catch {
                [void]$stale.Add($module)
            }
        }

        return @($stale)
    }

    return $all
}


function Get-KnowledgeExplorerPrompt {
    param(
        [string]$Mode,
        $Module,
        [string]$WorkflowTarget,
        [string]$Environment
    )

    $environment = ([string]$Environment).ToUpperInvariant()
    $baselineInfo = Get-KnowledgeExplorerBaselineContext `
        -Environment $environment `
        -ModuleSlug ([string]$Module.Slug)

    $baseline = [string]$baselineInfo.Environment
    $baselineAvailable = [bool]$baselineInfo.Available
    $layer = Get-KnowledgeExplorerLayerType -Environment $environment

    $existing = if ($Mode -eq 'refresh') {
        Get-KnowledgeExplorerExistingContext `
            -Environment $environment `
            -ModuleSlug ([string]$Module.Slug)
    }
    else {
        'NOT REQUESTED FOR THIS MODE.'
    }

    $modeRules = switch ($Mode) {
        'quick' {
@"
MODE: QUICK STRUCTURE CRAWL
- Aim for 6-12 meaningful Playwright MCP calls for this module.
- Map navigation, current URL/routes, purpose, visible controls, tables/filters and stable locator hints.
- Do not mutate Rx2GO data.
- Do not open every record; sample only what is required to understand the module.
"@
        }
        'deep' {
@"
MODE: DEEP READ-ONLY CRAWL
- Aim for 15-30 meaningful Playwright MCP calls for this module.
- Map UI + navigation + non-mutating Network/API behavior + data relationships.
- You may change filters, tabs, pagination and open/close cards/modals.
- Do not create/update/delete/transition business or test entities.
"@
        }
        'full-project' {
@"
MODE: FULL PROJECT MODULE CRAWL
- This module was discovered by the live Project Mapper.
- Aim for 12-25 meaningful Playwright MCP calls for this module.
- Explore the complete safe read-only surface of THIS discovered capability:
  navigation, child pages/tabs, controls, filters, tables, non-mutating Network/API, relationships, validation hints and stable semantic selectors.
- Follow internal child links only while they remain part of this business capability.
- Do not recursively start studying unrelated modules; Project Mapper controls project-level coverage.
- Do not create/update/delete/transition business data.
"@
        }
        'module' {
@"
MODE: SELECTED MODULE DEEP CRAWL
- Explore only the selected module in detail.
- Map its normal user flow, controls, filters, child pages, UI state, stable selectors and safe Network/API observations.
- Do not mutate entities.
"@
        }
        'workflow' {
@"
MODE: WORKFLOW EXPLORATION
WORKFLOW TARGET: $WorkflowTarget
- Understand the requested workflow end-to-end.
- Prefer read-only observation first.
- Fresh isolated QA test data MAY be created/updated/deleted only when the workflow cannot be understood read-only.
- Mark any fresh data clearly with `KNOWLEDGE EXPLORER` where the UI provides a safe field.
- Never modify an unmarked pre-existing business/customer entity.
- Cleanup current-run QA fixtures when safe and when evidence is already captured.
"@
        }
        'refresh' {
@"
MODE: REFRESH STALE KNOWLEDGE
- Re-check previous knowledge for $environment against the current live UI.
- Do not trust old selectors/routes blindly.
- Mark changed/removed/new facts explicitly.
- Read-only: do not mutate entities.

PREVIOUS $environment KNOWLEDGE:
$existing
"@
        }
        default {
            'MODE: QUICK STRUCTURE CRAWL'
        }
    }

    $comparisonRules = if ($environment -eq 'ADM') {
@"
KNOWLEDGE ROLE:
- ADM is the PRIMARY / STABLE KNOWLEDGE BASELINE.
- Do not compare ADM against HOT or BRANCH.
- Store what is currently verified on ADM.
- A feature seen only on HOT or BRANCH must NOT be added to ADM baseline until it is actually observed on ADM.
"@
    }
    else {
@"
KNOWLEDGE ROLE:
- $environment is NOT the primary baseline.
- Compare current $environment against BASELINE $baseline.
- BASELINE AVAILABLE: $baselineAvailable
- If baseline is unavailable, still explore current $environment but return status PARTIAL and baselineAvailable=false.
- Do not silently treat a $environment-only behavior as a common/project rule.
- Record SAME / NEW / CHANGED / REMOVED differences explicitly.

BASELINE $baseline KNOWLEDGE:
$($baselineInfo.Context)
"@
    }

    $branchRules = if ($environment -eq 'BRANCH') {
@"
BRANCH TEMPORARY RULE:
- This is temporary development-branch knowledge.
- It may help current branch testing but must never replace HOT or ADM baseline.
- Mark temporary=true.
"@
    }
    else {
        ''
    }

    return @"
You are Rx2GO Knowledge Explorer.

GOAL:
Build reliable structured QA knowledge for Rx2GO while preserving the deployment hierarchy:

BRANCH -> HOT -> ADM

KNOWLEDGE AUTHORITY:
- ADM = primary/stable baseline.
- HOT = delta compared with ADM.
- BRANCH = temporary delta compared with HOT.
- A HOT PASS does NOT automatically change ADM baseline.
- ADM baseline changes only after the behavior is actually observed/verified on ADM.

ENVIRONMENT:
$environment

KNOWLEDGE LAYER:
$layer

BASELINE ENVIRONMENT:
$(if ($baseline) { $baseline } else { 'NONE' })

MODULE:
$($Module.Name)

MODULE HINT:
$($Module.Hint)

DISCOVERED ENTRY URL:
$(if ($Module.PSObject.Properties.Name -contains 'EntryUrl') { [string]$Module.EntryUrl } else { '' })

DISCOVERED NAVIGATION GROUP:
$(if ($Module.PSObject.Properties.Name -contains 'Group') { [string]$Module.Group } else { '' })

DISCOVERED CONTEXT REQUIREMENT:
$(if ($Module.PSObject.Properties.Name -contains 'ContextHint') { [string]$Module.ContextHint } else { '' })

FULL-PROJECT DISCOVERY RULE:
- If this module came from Project Mapper, use its observed entry URL/navigation as a starting hint, but verify it live.
- Do not substitute a predefined module with a similarly named page.
- If the discovered module requires facility/client/service/business context, verify the current context before storing observations.

$comparisonRules

$branchRules

STRICT TOOL RULES:
- Use ONLY `playwright/browser_*` MCP tools.
- Do NOT use bundled Browser, Chrome, Computer Use, node_repl or shell tools.
- Work in the EXISTING authenticated Rx2GO Chrome session.
- Do NOT close the browser or tab.
- Do NOT navigate outside rx2go.ai.
- Start with browser_tabs + browser_snapshot.
- Use live UI evidence; do not invent routes, fields, selectors or API endpoints.

KNOWLEDGE SAFETY:
- You are OBSERVING the product, not defining product requirements.
- An observed current behavior is an OBSERVED_FACT, never automatically an expected requirement.
- Jira requirements are NOT part of this exploration.
- If you notice suspicious behavior, record it only as OBSERVED_ANOMALY_NOT_REQUIREMENT.
- Do not call something a confirmed bug merely because it looks odd.
- Store uncertainty instead of guessing.
- Prefer stable semantic locator hints (role/name/label/text/test-id) over brittle CSS/XPath.
- Never record secrets, passwords, tokens, auth headers, cookies or personal customer data.
- Do not copy large response bodies. Record endpoint purpose/shape and relevant fields only.
- Avoid storing actual patient/customer names, phones, addresses or prescriptions.

$modeRules

RETURN ONLY valid JSON:
{
  "mcpUsed": true,
  "environment": "$environment",
  "knowledgeLayer": "$layer",
  "baselineEnvironment": "$(if ($baseline) { $baseline } else { 'NONE' })",
  "baselineAvailable": $(if ($environment -eq 'ADM') { '$false' } elseif ($baselineAvailable) { '$true' } else { '$false' }),
  "temporary": $(if ($environment -eq 'BRANCH') { '$true' } else { '$false' }),
  "module": "$($Module.Name)",
  "status": "COMPLETE|PARTIAL|BLOCKED",
  "startUrl": "actual URL",
  "endUrl": "actual URL",
  "pagePurpose": "what this module/page is for based on live observation",

  "routes": [
    {
      "name": "human route/page name",
      "url": "actual observed URL",
      "howToOpen": "observed navigation",
      "confidence": "HIGH|MEDIUM|LOW"
    }
  ],

  "controls": [
    {
      "name": "visible control",
      "type": "button|input|select|table|tab|link|modal|other",
      "purpose": "observed purpose",
      "locatorHints": ["role/name/label/text/test-id only"],
      "notes": "observed behavior"
    }
  ],

  "navigation": [
    {
      "from": "page/state",
      "action": "actual action",
      "to": "page/state",
      "evidence": "what was observed"
    }
  ],

  "apiObservations": [
    {
      "method": "GET|POST|PUT|PATCH|DELETE|UNKNOWN",
      "path": "/observed/path",
      "trigger": "UI action that caused it",
      "statusCodesObserved": [200],
      "purpose": "what it appears to do from evidence",
      "importantFields": ["field names only"],
      "confidence": "HIGH|MEDIUM|LOW"
    }
  ],

  "relationships": [
    {
      "entities": ["entity A","entity B"],
      "relationship": "observed relationship",
      "evidence": "UI/API evidence"
    }
  ],

  "workflows": [
    {
      "name": "observed workflow",
      "steps": ["step 1","step 2"],
      "preconditionsObserved": ["observed precondition"],
      "resultObserved": "observed final state",
      "mutationUsed": false
    }
  ],

  "validationRulesObserved": [
    {
      "fieldOrAction": "control/action",
      "observedRule": "only what was actually observed",
      "evidence": "live evidence"
    }
  ],

  "selectorHints": [
    {
      "element": "semantic element",
      "preferred": ["getByRole(...)", "getByLabel(...)", "data-testid if present"],
      "avoid": ["brittle hint if relevant"]
    }
  ],

  "observedFacts": [
    {
      "factType": "OBSERVED_FACT",
      "fact": "current live fact",
      "evidence": "URL/control/API/snapshot evidence",
      "confidence": "HIGH|MEDIUM|LOW"
    }
  ],

  "baselineComparison": [
    {
      "type": "SAME|NEW|CHANGED|REMOVED|UNKNOWN",
      "area": "route|control|api|workflow|validation|relationship|other",
      "baselineFact": "what baseline says or N/A",
      "currentFact": "what current environment shows",
      "evidence": "current live evidence"
    }
  ],

  "anomalies": [
    {
      "classification": "OBSERVED_ANOMALY_NOT_REQUIREMENT",
      "description": "what looked inconsistent",
      "evidence": "live evidence",
      "impact": "possible QA impact"
    }
  ],

  "changesFromPrevious": [
    {
      "type": "NEW|CHANGED|REMOVED|UNCHANGED",
      "fact": "fact",
      "evidence": "current evidence"
    }
  ],

  "uncertainties": ["what could not be proven safely"],
  "mutationsCreated": ["fresh QA-only entity id/name if workflow mode created one"],
  "summary": "short useful module summary"
}

FINAL SELF-CHECK:
- environment must be $environment.
- knowledgeLayer must be $layer.
- module must be `$($Module.Name)`.
- mcpUsed must be true.
- status COMPLETE only if the module was actually reached and observed.
- For HOT/BRANCH, COMPLETE requires baseline comparison when baselineAvailable=true.
- For HOT/BRANCH with missing baseline, status must be PARTIAL.
- Never convert observed behavior into expected requirements.
"@
}


function Test-KnowledgeExplorerResult {
    param(
        $Parsed,
        $Module,
        [string]$Environment
    )

    if (-not $Parsed) {
        return [pscustomobject]@{ Success=$false; Error='Explorer returned no JSON.' }
    }

    $environment = ([string]$Environment).ToUpperInvariant()
    $layer = Get-KnowledgeExplorerLayerType -Environment $environment
    $baseline = Get-KnowledgeExplorerBaselineEnvironment -Environment $environment

    if (-not [bool]$Parsed.mcpUsed) {
        return [pscustomobject]@{ Success=$false; Error='Explorer did not confirm Playwright MCP usage.' }
    }

    if ([string]$Parsed.environment -ne $environment) {
        return [pscustomobject]@{
            Success=$false
            Error="Wrong environment in Explorer output: expected $environment, received $([string]$Parsed.environment)"
        }
    }

    if ([string]$Parsed.knowledgeLayer -ne $layer) {
        return [pscustomobject]@{
            Success=$false
            Error="Wrong knowledge layer: expected $layer, received $([string]$Parsed.knowledgeLayer)"
        }
    }

    if ([string]$Parsed.module -ne [string]$Module.Name) {
        return [pscustomobject]@{
            Success=$false
            Error="Explorer module mismatch: expected '$($Module.Name)', received '$([string]$Parsed.module)'."
        }
    }

    $status = ([string]$Parsed.status).ToUpperInvariant()

    if ($status -notin @('COMPLETE','PARTIAL','BLOCKED')) {
        return [pscustomobject]@{ Success=$false; Error="Unknown Explorer status '$status'." }
    }

    if ($environment -eq 'ADM') {
        if ([string]$Parsed.baselineEnvironment -ne 'NONE') {
            return [pscustomobject]@{
                Success=$false
                Error='ADM is the baseline and must not declare HOT/BRANCH as its baseline.'
            }
        }

        if ([bool]$Parsed.temporary) {
            return [pscustomobject]@{
                Success=$false
                Error='ADM baseline cannot be marked temporary.'
            }
        }
    }
    else {
        if ([string]$Parsed.baselineEnvironment -ne $baseline) {
            return [pscustomobject]@{
                Success=$false
                Error="Wrong baseline: $environment must compare with $baseline."
            }
        }

        $baselinePath = Get-KnowledgeExplorerModuleFile `
            -Environment $baseline `
            -Slug ([string]$Module.Slug)

        $baselineExists = Test-Path $baselinePath

        if ($baselineExists -and -not [bool]$Parsed.baselineAvailable) {
            return [pscustomobject]@{
                Success=$false
                Error="Baseline $baseline exists but Explorer did not use it."
            }
        }

        if (-not $baselineExists -and $status -eq 'COMPLETE') {
            return [pscustomobject]@{
                Success=$false
                Error="Cannot mark $environment COMPLETE without baseline $baseline. Use PARTIAL."
            }
        }

        if (
            [bool]$Parsed.baselineAvailable -and
            @($Parsed.baselineComparison | Where-Object { $_ }).Count -eq 0
        ) {
            return [pscustomobject]@{
                Success=$false
                Error="$environment baseline comparison is empty."
            }
        }
    }

    if ($environment -eq 'BRANCH' -and -not [bool]$Parsed.temporary) {
        return [pscustomobject]@{
            Success=$false
            Error='BRANCH observations must be marked temporary=true.'
        }
    }

    return [pscustomobject]@{ Success=$true; Error='' }
}


function Save-KnowledgeExplorerResult {
    param(
        [string]$Mode,
        $Module,
        [string]$WorkflowTarget,
        [string]$Environment,
        $Parsed
    )

    Initialize-KnowledgeExplorerStorage

    $targetPath = if ($Mode -eq 'workflow') {
        Get-KnowledgeExplorerWorkflowFile `
            -Environment $Environment `
            -ModuleSlug ([string]$Module.Slug) `
            -Target $WorkflowTarget
    }
    else {
        Get-KnowledgeExplorerModuleFile `
            -Environment $Environment `
            -Slug ([string]$Module.Slug)
    }

    $baseline = Get-KnowledgeExplorerBaselineEnvironment -Environment $Environment
    $layer = Get-KnowledgeExplorerLayerType -Environment $Environment

    $record = [ordered]@{
        schemaVersion = 2
        sourceClass = 'LIVE_OBSERVATION'
        source = "Playwright MCP / Rx2GO $Environment"
        environment = ([string]$Environment).ToUpperInvariant()
        knowledgeLayer = $layer
        baselineEnvironment = if ($baseline) { $baseline } else { 'NONE' }
        primaryBaseline = (([string]$Environment).ToUpperInvariant() -eq 'ADM')
        temporary = (([string]$Environment).ToUpperInvariant() -eq 'BRANCH')
        module = [string]$Module.Name
        moduleSlug = [string]$Module.Slug
        mode = $Mode
        workflowTarget = if ($Mode -eq 'workflow') { [string]$WorkflowTarget } else { '' }
        observedAt = (Get-Date).ToString('o')
        freshnessDays = [int]$script:KnowledgeExplorerStaleDays
        requirementAuthority = $false
        warning = 'Observed behavior is context/technical knowledge. Jira remains authoritative for expected behavior.'
        deploymentHierarchy = 'BRANCH -> HOT -> ADM'
        promotionRule = 'HOT knowledge does not become ADM baseline until re-observed on ADM.'
        result = $Parsed
    }

    Write-Utf8NoBomFile `
        -Path $targetPath `
        -Content ($record | ConvertTo-Json -Depth 18)

    $relative = $targetPath.Substring($script:ProjectRoot.Length) -replace '^[\\/]+',''
    Write-KnowledgeExplorerLog "Сохранено → $relative"

    return $targetPath
}



function Update-KnowledgeExplorerIndex {
    Initialize-KnowledgeExplorerStorage

    $environmentSummaries = New-Object System.Collections.ArrayList
    $persistentTotal = 0

    foreach ($environment in @('ADM','HOT')) {
        $entriesBySlug = @{}

        # Start with predefined priority modules so they remain visible before a full crawl.
        foreach ($definition in @(Get-KnowledgeExplorerModuleDefinitions)) {
            $entriesBySlug[[string]$definition.Slug] = [ordered]@{
                name = [string]$definition.Name
                slug = [string]$definition.Slug
                status = 'NOT_EXPLORED'
                lastObservedAt = ''
                mode = ''
                summary = ''
                differenceCount = 0
                discoveredByProjectMap = $false
                file = "knowledge/explorer/$($environment.ToLowerInvariant())/modules/$($definition.Slug).json"
            }
        }

        $mapPath = Get-KnowledgeExplorerProjectMapFile -Environment $environment
        $mappedModuleCount = 0
        $mapObservedAt = ''

        if (Test-Path $mapPath) {
            try {
                $mapDoc = Get-Content -Raw -Path $mapPath | ConvertFrom-Json -ErrorAction Stop
                $mapObservedAt = [string]$mapDoc.observedAt

                foreach ($mapped in @($mapDoc.result.modules | Where-Object { $_ })) {
                    $slug = ConvertTo-KnowledgeExplorerSafeSlug -Text ([string]$mapped.name)

                    if (-not $entriesBySlug.ContainsKey($slug)) {
                        $entriesBySlug[$slug] = [ordered]@{
                            name = [string]$mapped.name
                            slug = $slug
                            status = 'DISCOVERED'
                            lastObservedAt = ''
                            mode = ''
                            summary = [string]$mapped.purposeHint
                            differenceCount = 0
                            discoveredByProjectMap = $true
                            file = "knowledge/explorer/$($environment.ToLowerInvariant())/modules/$slug.json"
                        }
                    }
                    else {
                        $entriesBySlug[$slug].discoveredByProjectMap = $true
                    }

                    $mappedModuleCount++
                }
            }
            catch { }
        }

        $moduleDir = Join-Path `
            $script:ProjectRoot `
            "knowledge\explorer\$($environment.ToLowerInvariant())\modules"

        foreach ($file in @(
            Get-ChildItem `
                -Path $moduleDir `
                -File `
                -Filter '*.json' `
                -ErrorAction SilentlyContinue
        )) {
            try {
                $doc = Get-Content -Raw -Path $file.FullName | ConvertFrom-Json -ErrorAction Stop
                $slug = [string]$doc.moduleSlug

                if ([string]::IsNullOrWhiteSpace($slug)) {
                    $slug = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
                }

                if (-not $entriesBySlug.ContainsKey($slug)) {
                    $entriesBySlug[$slug] = [ordered]@{
                        name = [string]$doc.module
                        slug = $slug
                        status = 'NOT_EXPLORED'
                        lastObservedAt = ''
                        mode = ''
                        summary = ''
                        differenceCount = 0
                        discoveredByProjectMap = $true
                        file = "knowledge/explorer/$($environment.ToLowerInvariant())/modules/$slug.json"
                    }
                }

                $entriesBySlug[$slug].name = [string]$doc.module
                $entriesBySlug[$slug].status = [string]$doc.result.status
                $entriesBySlug[$slug].lastObservedAt = [string]$doc.observedAt
                $entriesBySlug[$slug].mode = [string]$doc.mode
                $entriesBySlug[$slug].summary = [string]$doc.result.summary
                $entriesBySlug[$slug].differenceCount = @(
                    $doc.result.baselineComparison |
                        Where-Object {
                            ([string]$_.type).ToUpperInvariant() -in @('NEW','CHANGED','REMOVED')
                        }
                ).Count
            }
            catch {
                $slug = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)

                if ($entriesBySlug.ContainsKey($slug)) {
                    $entriesBySlug[$slug].status = 'INVALID'
                }
            }
        }

        $entries = @(
            $entriesBySlug.Values |
                ForEach-Object { [pscustomobject]$_ } |
                Sort-Object name
        )

        $explored = @(
            $entries |
                Where-Object {
                    $_.status -in @('COMPLETE','PARTIAL','BLOCKED')
                }
        ).Count

        $persistentTotal += $explored

        [void]$environmentSummaries.Add([pscustomobject]@{
            environment = $environment
            role = if ($environment -eq 'ADM') { 'PRIMARY_BASELINE' } else { 'DELTA_VS_ADM' }
            baseline = if ($environment -eq 'ADM') { 'NONE' } else { 'ADM' }
            projectMapAvailable = (Test-Path $mapPath)
            projectMapObservedAt = $mapObservedAt
            mappedModules = $mappedModuleCount
            exploredModules = $explored
            totalKnownModules = $entries.Count
            modules = $entries
        })
    }

    $index = [ordered]@{
        schemaVersion = 3
        deploymentHierarchy = 'BRANCH -> HOT -> ADM'
        primaryBaseline = 'ADM'
        generatedAt = (Get-Date).ToString('o')
        staleAfterDays = [int]$script:KnowledgeExplorerStaleDays
        exploredModules = $persistentTotal
        environments = @($environmentSummaries)
        note = 'Project Mapper can dynamically extend the module catalog beyond the predefined priority modules. BRANCH remains excluded from the persistent global index.'
    }

    $indexPath = Join-Path $script:ProjectRoot 'knowledge\explorer\index.json'

    Write-Utf8NoBomFile `
        -Path $indexPath `
        -Content ($index | ConvertTo-Json -Depth 14)

    # Local-only BRANCH index — dynamic modules included.
    $branchEntries = New-Object System.Collections.ArrayList
    $branchDir = Join-Path $script:ProjectRoot 'knowledge\explorer\branch\modules'

    foreach ($file in @(
        Get-ChildItem `
            -Path $branchDir `
            -File `
            -Filter '*.json' `
            -ErrorAction SilentlyContinue
    )) {
        try {
            $doc = Get-Content -Raw -Path $file.FullName | ConvertFrom-Json -ErrorAction Stop

            [void]$branchEntries.Add([pscustomobject]@{
                name = [string]$doc.module
                slug = [string]$doc.moduleSlug
                status = [string]$doc.result.status
                lastObservedAt = [string]$doc.observedAt
                differenceCount = @(
                    $doc.result.baselineComparison |
                        Where-Object {
                            ([string]$_.type).ToUpperInvariant() -in @('NEW','CHANGED','REMOVED')
                        }
                ).Count
            })
        }
        catch { }
    }

    $branchMapPath = Get-KnowledgeExplorerProjectMapFile -Environment 'BRANCH'
    $branchIndexPath = Join-Path $script:ProjectRoot 'knowledge\explorer\branch\index.json'

    Write-Utf8NoBomFile `
        -Path $branchIndexPath `
        -Content (([ordered]@{
            schemaVersion = 2
            environment = 'BRANCH'
            baseline = 'HOT'
            temporary = $true
            generatedAt = (Get-Date).ToString('o')
            projectMapAvailable = (Test-Path $branchMapPath)
            exploredModules = @($branchEntries).Count
            modules = @($branchEntries)
        }) | ConvertTo-Json -Depth 12)

    return [pscustomobject]$index
}

function Invoke-KnowledgeExplorerModule {
    param(
        [string]$Mode,
        $Module,
        [string]$WorkflowTarget,
        [string]$Environment
    )

    Set-KnowledgeExplorerStatus `
        -Text "Изучаю $Environment → $($Module.Name)…" `
        -Kind Info

    $prompt = Get-KnowledgeExplorerPrompt `
        -Mode $Mode `
        -Module $Module `
        -WorkflowTarget $WorkflowTarget `
        -Environment $Environment

    $reasoning = if ($Mode -eq 'workflow') { 'medium' } else { 'low' }

    $timeout = switch ($Mode) {
        'quick' { 300 }
        'deep' { 480 }
        'full-project' { 480 }
        'module' { 420 }
        'workflow' { 600 }
        'refresh' { 360 }
        default { 360 }
    }

    $raw = Invoke-CodexAgent `
        -AgentSlug "knowledge-explorer-$($Environment.ToLowerInvariant())-$($Module.Slug)-$Mode" `
        -Prompt $prompt `
        -TimeoutSec $timeout `
        -ReasoningEffort $reasoning

    if (-not $raw) {
        if (
            [string]$script:LastAgentFailureKind -eq 'CODEX_USAGE_LIMIT' -or
            (Test-CodexUsageLimitText -Text ([string]$script:LastAgentError))
        ) {
            return [pscustomobject]@{
                Success=$false
                StopAll=$true
                Error=(Get-CodexFailureUserMessage `
                    -FailureKind 'CODEX_USAGE_LIMIT' `
                    -ErrorText ([string]$script:LastAgentError))
            }
        }

        return [pscustomobject]@{
            Success=$false
            StopAll=$false
            Error=[string]$script:LastAgentError
        }
    }

    if (-not (Test-LastAgentUsedPlaywrightMcpSuccessfully -MinimumCompletedCalls 2)) {
        return [pscustomobject]@{
            Success=$false
            StopAll=$false
            Error=[string]$script:LastAgentError
        }
    }

    $parsed = Convert-AgentJson $raw

    if (-not $parsed) {
        return [pscustomobject]@{
            Success=$false
            StopAll=$false
            Error=[string]$script:LastAgentError
        }
    }

    $validation = Test-KnowledgeExplorerResult `
        -Parsed $parsed `
        -Module $Module `
        -Environment $Environment

    if (-not $validation.Success) {
        return [pscustomobject]@{
            Success=$false
            StopAll=$false
            Error=[string]$validation.Error
        }
    }

    $saved = Save-KnowledgeExplorerResult `
        -Mode $Mode `
        -Module $Module `
        -WorkflowTarget $WorkflowTarget `
        -Environment $Environment `
        -Parsed $parsed

    return [pscustomobject]@{
        Success=$true
        StopAll=$false
        Error=''
        Parsed=$parsed
        File=$saved
    }
}


function Invoke-KnowledgeExplorerGitSync {
    param([string]$Environment)

    $environment = ([string]$Environment).ToUpperInvariant()

    if ($environment -eq 'BRANCH') {
        return [pscustomobject]@{
            Success=$true
            Message='BRANCH knowledge сохранён локально как temporary delta. Auto commit/push отключён.'
        }
    }

    if ($script:GitBusy) {
        return [pscustomobject]@{
            Success=$false
            Message='Git занят. Explorer knowledge сохранён локально.'
        }
    }

    $script:GitBusy = $true

    try {
        if (-not (Test-GitInstalled)) {
            return [pscustomobject]@{
                Success=$false
                Message='Git не установлен. Explorer knowledge сохранён локально.'
            }
        }

        Initialize-KnowledgeGit -Silent
        $git = Get-GitState

        if (-not $git.Repository) {
            return [pscustomobject]@{
                Success=$false
                Message='Git repository недоступен. Explorer knowledge сохранён локально.'
            }
        }

        if (-not (Set-KnowledgeOriginToSsh)) {
            return [pscustomobject]@{
                Success=$false
                Message='SSH origin не настроен. Explorer knowledge сохранён локально.'
            }
        }

        $preStaged = Invoke-Git @('diff','--cached','--name-only') 15000

        if (
            $preStaged.ExitCode -eq 0 -and
            -not [string]::IsNullOrWhiteSpace([string]$preStaged.Output)
        ) {
            $foreignStaged = @(
                $preStaged.Output -split "`r?`n" |
                    Where-Object {
                        $_ -and
                        $_ -notmatch '^(knowledge/explorer/|knowledge\\explorer\\)'
                    }
            )

            if ($foreignStaged.Count -gt 0) {
                return [pscustomobject]@{
                    Success=$false
                    Message='Есть уже staged-файлы вне Knowledge Explorer. Auto commit пропущен, чтобы не смешивать изменения.'
                }
            }
        }

        $envFolder = Get-KnowledgeExplorerEnvironmentFolder -Environment $environment

        $add = Invoke-Git @(
            'add','-A','--',
            "knowledge/explorer/$envFolder",
            'knowledge/explorer/index.json'
        ) 120000

        if ($add.ExitCode -ne 0) {
            return [pscustomobject]@{
                Success=$false
                Message=("git add Explorer failed: $($add.Error) $($add.Output)").Trim()
            }
        }

        $staged = Invoke-Git @(
            'diff','--cached','--name-only','--',
            "knowledge/explorer/$envFolder",
            'knowledge/explorer/index.json'
        ) 15000

        if (
            $staged.ExitCode -ne 0 -or
            [string]::IsNullOrWhiteSpace([string]$staged.Output)
        ) {
            return [pscustomobject]@{
                Success=$true
                Message="Knowledge Explorer ${environment}: новых изменений для Git нет."
            }
        }

        $role = if ($environment -eq 'ADM') { 'baseline' } else { 'delta-vs-ADM' }
        $message = "Knowledge Explorer $environment $role " + (Get-Date -Format 'yyyy-MM-dd HH:mm')

        $commit = Invoke-Git @('commit','-m',$message) 60000

        if ($commit.ExitCode -ne 0) {
            $combined = (([string]$commit.Error) + "`n" + ([string]$commit.Output)).Trim()

            if ($combined -notmatch '(?i)nothing to commit') {
                return [pscustomobject]@{
                    Success=$false
                    Message="Explorer git commit failed: $combined"
                }
            }
        }

        $privateKey = Get-GitHubSshPrivateKeyPath

        if (-not (Test-Path $privateKey)) {
            return [pscustomobject]@{
                Success=$false
                Message='Explorer knowledge закоммичен локально; SSH key для push не настроен.'
            }
        }

        $auth = Invoke-SshGitHubAuthCheck

        if (-not $auth.Success) {
            return [pscustomobject]@{
                Success=$false
                Message="Explorer knowledge закоммичен локально; GitHub SSH не готов: $($auth.Message)"
            }
        }

        $git = Get-GitState
        $branch = [string]$git.Branch

        if ([string]::IsNullOrWhiteSpace($branch) -or $branch -eq 'detached') {
            return [pscustomobject]@{
                Success=$false
                Message='Explorer knowledge закоммичен локально; HEAD detached, push пропущен.'
            }
        }

        $push = Invoke-Git @('push','origin',$branch) 90000

        if ($push.ExitCode -ne 0) {
            $combined = (([string]$push.Error) + "`n" + ([string]$push.Output)).Trim()

            return [pscustomobject]@{
                Success=$false
                Message="Explorer knowledge закоммичен локально; push failed: $combined"
            }
        }

        return [pscustomobject]@{
            Success=$true
            Message="Knowledge Explorer $environment → GitHub push PASS ($branch)."
        }
    }
    catch {
        return [pscustomobject]@{
            Success=$false
            Message="Explorer Git exception: $($_.Exception.Message)"
        }
    }
    finally {
        $script:GitBusy = $false
    }
}


function Stop-KnowledgeExplorer {
    if (-not $script:KnowledgeExplorerRunning) {
        return
    }

    $script:KnowledgeExplorerStopRequested = $true

    Set-KnowledgeExplorerStatus `
        -Text 'Остановка запрошена. Explorer завершит текущий модуль и остановится.' `
        -Kind Warning

    if ($knowledgeExplorerStopButton) {
        $knowledgeExplorerStopButton.Enabled = $false
    }
}


function Open-KnowledgeExplorerFolder {
    Initialize-KnowledgeExplorerStorage

    $environment = if ($knowledgeExplorerEnvironmentCombo) {
        ([string]$knowledgeExplorerEnvironmentCombo.SelectedItem).ToUpperInvariant()
    }
    else {
        'ADM'
    }

    if ([string]::IsNullOrWhiteSpace($environment)) {
        $environment = 'ADM'
    }

    $envFolder = Get-KnowledgeExplorerEnvironmentFolder -Environment $environment
    $path = Join-Path $script:ProjectRoot "knowledge\explorer\$envFolder"

    try {
        Start-Process explorer.exe -ArgumentList "`"$path`""
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            "Не удалось открыть папку:`r`n$path`r`n`r`n$($_.Exception.Message)",
            'Rx2GO QA — Knowledge Explorer',
            'OK',
            'Warning'
        ) | Out-Null
    }
}


function Start-KnowledgeExplorer {
    if ($script:KnowledgeExplorerRunning) {
        return
    }

    if ($script:JiraRunActive) {
        [System.Windows.Forms.MessageBox]::Show(
            'Сейчас выполняется Jira Smart QA. Дождись завершения перед запуском Knowledge Explorer.',
            'Rx2GO QA — Knowledge Explorer',
            'OK',
            'Warning'
        ) | Out-Null
        return
    }

    if ($script:QueueRunning) {
        [System.Windows.Forms.MessageBox]::Show(
            'Сейчас работает Jira Queue. Останови/поставь очередь на паузу перед Knowledge Explorer, чтобы не смешивать браузерные сессии.',
            'Rx2GO QA — Knowledge Explorer',
            'OK',
            'Warning'
        ) | Out-Null
        return
    }

    $environment = ([string]$knowledgeExplorerEnvironmentCombo.SelectedItem).ToUpperInvariant()

    if ($environment -notin @('ADM','HOT','BRANCH')) {
        $environment = 'ADM'
    }

    $mode = Get-KnowledgeExplorerModeKey `
        -DisplayName ([string]$knowledgeExplorerModeCombo.SelectedItem)

    $selectedModule = [string]$knowledgeExplorerModuleCombo.SelectedItem
    $workflowTarget = ([string]$knowledgeExplorerTargetBox.Text).Trim()

    if ($mode -in @('module','workflow')) {
        if ([string]::IsNullOrWhiteSpace($selectedModule)) {
            [System.Windows.Forms.MessageBox]::Show(
                'Выбери модуль для Knowledge Explorer.',
                'Rx2GO QA — Knowledge Explorer',
                'OK',
                'Warning'
            ) | Out-Null
            return
        }
    }

    if (
        $environment -eq 'ADM' -and
        [string]::IsNullOrWhiteSpace([string](Get-SharedAdmDailyPassword))
    ) {
        Set-KnowledgeExplorerStatus `
            -Text 'ADM: введи суточный пароль из Telegram в поле «ADM код Telegram».' `
            -Kind Warning

        if ($knowledgeAdmDailyPasswordBox) {
            $knowledgeAdmDailyPasswordBox.Focus()
        }

        [System.Windows.Forms.MessageBox]::Show(
            "Для изучения ADM нужен первый фактор авторизации.`r`n`r`nЛогин: admin`r`nПароль: сегодняшний суточный код из Telegram.`r`n`r`nВведи код прямо в поле «ADM код Telegram» на этой странице и снова нажми «ИЗУЧИТЬ ADM».",
            'Rx2GO QA — ADM авторизация',
            'OK',
            'Warning'
        ) | Out-Null

        return
    }

    Initialize-KnowledgeExplorerStorage

    $modules = @()

    if ($mode -ne 'full-project') {
        $modules = @(
            Get-KnowledgeExplorerModulesForRun `
                -Mode $mode `
                -SelectedModuleName $selectedModule `
                -Environment $environment
        )

        if ($modules.Count -eq 0) {
            Set-KnowledgeExplorerStatus `
                -Text "Для $environment устаревших модулей старше $($script:KnowledgeExplorerStaleDays) дней нет." `
                -Kind Success
            return
        }
    }

    if (-not (Ensure-PlaywrightDependencies)) {
        Set-KnowledgeExplorerStatus `
            -Text "Playwright dependencies недоступны: $($script:LastAgentError)" `
            -Kind Error
        return
    }

    $script:KnowledgeExplorerRunning = $true
    $script:KnowledgeExplorerStopRequested = $false

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $script:KnowledgeExplorerRunDir = Join-Path `
        $script:ProjectRoot `
        "reports\knowledge-explorer\$($environment.ToLowerInvariant())\$stamp"

    New-Item `
        -ItemType Directory `
        -Path $script:KnowledgeExplorerRunDir `
        -Force | Out-Null

    if ($knowledgeExplorerStartButton) {
        $knowledgeExplorerStartButton.Enabled = $false
    }

    if ($knowledgeExplorerStopButton) {
        $knowledgeExplorerStopButton.Enabled = $true
    }

    if ($knowledgeExplorerEnvironmentCombo) {
        $knowledgeExplorerEnvironmentCombo.Enabled = $false
    }

    if ($knowledgeAdmDailyPasswordBox) {
        $knowledgeAdmDailyPasswordBox.Enabled = $false
    }

    if ($knowledgeExplorerProgress) {
        $knowledgeExplorerProgress.Minimum = 0

        if ($mode -eq 'full-project') {
            $knowledgeExplorerProgress.Maximum = 1
        }
        else {
            $knowledgeExplorerProgress.Maximum = [Math]::Max(1,$modules.Count)
        }

        $knowledgeExplorerProgress.Value = 0
    }

    if ($knowledgeExplorerLogBox) {
        $knowledgeExplorerLogBox.Clear()
    }

    $oldTask = $script:CurrentJiraTask
    $oldIssueKey = $script:LoadedJiraIssueKey

    $script:CurrentJiraTask = [pscustomobject]@{
        Key="KNOWLEDGE-EXPLORER-$environment"
    }
    $script:LoadedJiraIssueKey = "KNOWLEDGE-EXPLORER-$environment"

    try {
        $baseline = Get-KnowledgeExplorerBaselineEnvironment -Environment $environment
        $roleText = if ($environment -eq 'ADM') {
            'PRIMARY BASELINE'
        }
        elseif ($environment -eq 'HOT') {
            'DELTA VS ADM'
        }
        else {
            'TEMP DELTA VS HOT'
        }

        $launchText = if ($mode -eq 'full-project') {
            "Запускаю $environment ($roleText). Сначала Project Mapper построит карту доступных модулей."
        }
        else {
            "Запускаю $environment ($roleText). Модулей: $($modules.Count)."
        }

        Set-KnowledgeExplorerStatus `
            -Text $launchText `
            -Kind Info

        if ($baseline) {
            Write-KnowledgeExplorerLog "Baseline: $baseline"
        }
        else {
            Write-KnowledgeExplorerLog 'Baseline: ADM itself'
        }

        if (-not (Bootstrap-PersistentBrowserSession -Environment $environment)) {
            Set-KnowledgeExplorerStatus `
                -Text "Не удалось открыть/авторизовать ${environment}: $($script:LastAgentError)" `
                -Kind Error
            return
        }

        if (-not (Invoke-PlaywrightMcpSessionPreflight -Environment $environment)) {
            Set-KnowledgeExplorerStatus `
                -Text "Playwright MCP не подключился к ${environment}: $($script:LastAgentError)" `
                -Kind Error
            return
        }

        if ($mode -eq 'full-project') {
            $mapResult = Invoke-KnowledgeExplorerProjectMapper `
                -Environment $environment

            if (-not $mapResult.Success) {
                Set-KnowledgeExplorerStatus `
                    -Text "Не удалось построить карту проекта: $($mapResult.Error)" `
                    -Kind Error

                if ($mapResult.StopAll) {
                    $script:KnowledgeExplorerStopRequested = $true
                }

                return
            }

            $modules = @($mapResult.Modules)

            if ($modules.Count -eq 0) {
                Set-KnowledgeExplorerStatus `
                    -Text 'Project Mapper не нашёл доступных продуктовых модулей.' `
                    -Kind Warning
                return
            }

            if ($knowledgeExplorerProgress) {
                $knowledgeExplorerProgress.Maximum = $modules.Count + 1
                $knowledgeExplorerProgress.Value = 1
            }

            Set-KnowledgeExplorerStatus `
                -Text "Этап 2/2: карта готова — найдено $($modules.Count) модулей. Начинаю полный crawl." `
                -Kind Info
        }

        $completed = 0
        $partial = 0
        $blocked = 0
        $failed = 0

        foreach ($module in $modules) {
            if ($script:KnowledgeExplorerStopRequested) {
                break
            }

            $result = Invoke-KnowledgeExplorerModule `
                -Mode $mode `
                -Module $module `
                -WorkflowTarget $workflowTarget `
                -Environment $environment

            if ($result.Success) {
                $status = ([string]$result.Parsed.status).ToUpperInvariant()

                switch ($status) {
                    'COMPLETE' { $completed++ }
                    'PARTIAL' { $partial++ }
                    'BLOCKED' { $blocked++ }
                }

                $differenceCount = @(
                    $result.Parsed.baselineComparison |
                        Where-Object {
                            ([string]$_.type).ToUpperInvariant() -in @('NEW','CHANGED','REMOVED')
                        }
                ).Count

                if ($baseline) {
                    Write-KnowledgeExplorerLog "$($module.Name) → $status • differences vs ${baseline}: $differenceCount"
                }
                else {
                    Write-KnowledgeExplorerLog "$($module.Name) → $status • ADM baseline updated"
                }
            }
            else {
                $failed++
                Write-KnowledgeExplorerLog "$($module.Name) → ERROR | $($result.Error)"

                if ($result.StopAll) {
                    Set-KnowledgeExplorerStatus `
                        -Text $result.Error `
                        -Kind Warning

                    $script:KnowledgeExplorerStopRequested = $true
                }
            }

            if ($knowledgeExplorerProgress) {
                $next = [Math]::Min(
                    $knowledgeExplorerProgress.Maximum,
                    $knowledgeExplorerProgress.Value + 1
                )

                $knowledgeExplorerProgress.Value = $next
            }

            [void](Update-KnowledgeExplorerIndex)
            Refresh-KnowledgeUI -PreserveActionText

            try {
                [System.Windows.Forms.Application]::DoEvents()
            }
            catch { }
        }

        $index = Update-KnowledgeExplorerIndex
        $script:KnowledgeExplorerLastResult = $index

        if ($script:KnowledgeExplorerStopRequested) {
            Set-KnowledgeExplorerStatus `
                -Text "Explorer $environment остановлен. COMPLETE $completed • PARTIAL $partial • BLOCKED $blocked • ERROR $failed." `
                -Kind Warning
        }
        else {
            $finishPrefix = if ($mode -eq 'full-project') {
                "Полный проект $environment завершён"
            }
            else {
                "Explorer $environment завершён"
            }

            Set-KnowledgeExplorerStatus `
                -Text "${finishPrefix}: COMPLETE $completed • PARTIAL $partial • BLOCKED $blocked • ERROR $failed." `
                -Kind Success
        }

        $gitResult = Invoke-KnowledgeExplorerGitSync -Environment $environment
        Write-KnowledgeExplorerLog $gitResult.Message

        if (-not $gitResult.Success) {
            Set-KnowledgeActionStatus `
                -Text $gitResult.Message `
                -Kind Warning

            Set-KnowledgeSaveState `
                -State LOCAL_ONLY `
                -Details $gitResult.Message
        }
        else {
            Set-KnowledgeActionStatus `
                -Text $gitResult.Message `
                -Kind Success

            if ($environment -eq 'BRANCH') {
                if ($knowledgeSaveDetailsLabel) {
                    $knowledgeSaveDetailsLabel.Text = 'BRANCH Explorer knowledge временное и остаётся локально; ADM/HOT GitHub knowledge не меняется.'
                }
            }
            else {
                try {
                    Refresh-KnowledgeSaveState -VerifyRemote
                }
                catch { }
            }
        }

        Refresh-KnowledgeUI -PreserveActionText
    }
    catch {
        Set-KnowledgeExplorerStatus `
            -Text "Knowledge Explorer exception: $($_.Exception.Message)" `
            -Kind Error
    }
    finally {
        $script:CurrentJiraTask = $oldTask
        $script:LoadedJiraIssueKey = $oldIssueKey
        $script:KnowledgeExplorerRunning = $false

        if ($knowledgeExplorerStartButton) {
            $knowledgeExplorerStartButton.Enabled = $true
        }

        if ($knowledgeExplorerStopButton) {
            $knowledgeExplorerStopButton.Enabled = $false
        }

        if ($knowledgeExplorerEnvironmentCombo) {
            $knowledgeExplorerEnvironmentCombo.Enabled = $true
        }

        if ($knowledgeAdmDailyPasswordBox) {
            $knowledgeAdmDailyPasswordBox.Enabled = $true
        }

        Update-KnowledgeExplorerEnvironmentUi
        Write-KnowledgeExplorerLog 'Chrome оставлен открытым.'
    }
}

function Get-KnowledgeStats {
    $rules = @(Get-Rx2GOProjectRules).Count
    $jiraDir = Join-Path $script:ProjectRoot 'jira-cases'
    $scenarioDir = Join-Path $script:ProjectRoot 'scenarios'
    $testsDir = Join-Path $script:ProjectRoot 'tests'
    $learnedDir = Join-Path $script:ProjectRoot 'knowledge\learned'
    $jira = if (Test-Path $jiraDir) { @(Get-ChildItem $jiraDir -File -Filter '*.md' -ErrorAction SilentlyContinue).Count } else { 0 }
    $scenarios = if (Test-Path $scenarioDir) { @(Get-ChildItem $scenarioDir -File -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in @('.yaml','.yml','.json') }).Count } else { 0 }
    $tests = if (Test-Path $testsDir) { @(Get-ChildItem $testsDir -File -Recurse -Filter '*.spec.ts' -ErrorAction SilentlyContinue).Count } else { 0 }
    $learned = if (Test-Path $learnedDir) { @(Get-ChildItem $learnedDir -File -Recurse -Filter '*.json' -ErrorAction SilentlyContinue).Count } else { 0 }

    $explorerIndex = Join-Path $script:ProjectRoot 'knowledge\explorer\index.json'
    $exploredModules = 0

    if (Test-Path $explorerIndex) {
        try {
            $explorerDoc = Get-Content -Raw -Path $explorerIndex | ConvertFrom-Json -ErrorAction Stop
            $exploredModules = [int]$explorerDoc.exploredModules
        }
        catch {
            $exploredModules = 0
        }
    }

    return [pscustomobject]@{
        Rules=$rules
        JiraCases=$jira
        Scenarios=$scenarios
        Tests=$tests
        Learned=$learned
        ExploredModules=$exploredModules
    }
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
    return 'git@github.com:QA-E2E4/rx2go-ai-qa.git'
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

        Set-KnowledgeSshStatus `
            -Text 'SSH: CHECKING…' `
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
            $sshUser = Get-GitHubSshUserFromMessage -Message ([string]$check.Message)

            Set-KnowledgeActionStatus `
                -Text 'GitHub SSH подключён ✓  Браузер не используется.' `
                -Kind Success

            $sshStatusText = if ($sshUser) {
                "SSH: ✓ CONNECTED • $sshUser"
            }
            else {
                'SSH: ✓ CONNECTED'
            }

            Set-KnowledgeSshStatus `
                -Text $sshStatusText `
                -Kind Success

            return $true
        }

        if ($check.NeedsKeyRegistration) {
            Set-KnowledgeActionStatus `
                -Text 'SSH key создан. Добавь public key в GitHub один раз.' `
                -Kind Warning

            Set-KnowledgeSshStatus `
                -Text 'SSH: ⚠ KEY NOT REGISTERED' `
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

        Set-KnowledgeSshStatus `
            -Text 'SSH: ✕ ERROR' `
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
    if ($script:GitBusy) {
        return
    }

    $script:GitBusy = $true
    $needsSetup = $false

    try {
        Set-KnowledgeActionStatus `
            -Text 'Проверяю GitHub через SSH…' `
            -Kind Info

        Set-KnowledgeSshStatus `
            -Text 'SSH: CHECKING…' `
            -Kind Info

        if (-not (Test-GitInstalled)) {
            Set-KnowledgeActionStatus `
                -Text 'Git не установлен.' `
                -Kind Error

            Set-KnowledgeSshStatus `
                -Text 'SSH: — Git unavailable' `
                -Kind Error

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

            Set-KnowledgeSshStatus `
                -Text 'SSH: ✕ OpenSSH not found' `
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

            Set-KnowledgeSshStatus `
                -Text 'SSH: ⚠ KEY NOT FOUND' `
                -Kind Warning

            Set-KnowledgeActionStatus `
                -Text 'SSH key ещё не создан.' `
                -Kind Warning

            return
        }

        if (-not (Set-KnowledgeOriginToSsh)) {
            Set-KnowledgeActionStatus `
                -Text 'Не удалось переключить origin на SSH.' `
                -Kind Error

            Set-KnowledgeSshStatus `
                -Text 'SSH: ✕ origin setup failed' `
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

                Set-KnowledgeSshStatus `
                    -Text 'SSH: ⚠ KEY NOT REGISTERED' `
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

            Set-KnowledgeSshStatus `
                -Text 'SSH: ✕ AUTH FAILED' `
                -Kind Error

            return
        }

        $sshUser = Get-GitHubSshUserFromMessage -Message ([string]$auth.Message)

        $remoteCheck = Invoke-Git @(
            'ls-remote','--heads','origin'
        ) 30000

        if ($remoteCheck.ExitCode -eq 0) {
            $timestamp = Get-Date -Format 'HH:mm:ss'

            $sshStatusText = if ($sshUser) {
                "SSH: ✓ CONNECTED • $sshUser • repo OK • $timestamp"
            }
            else {
                "SSH: ✓ CONNECTED • repo OK • $timestamp"
            }

            Set-KnowledgeSshStatus `
                -Text $sshStatusText `
                -Kind Success

            Set-KnowledgeActionStatus `
                -Text "GitHub SSH доступен ✓  origin: $(Get-KnowledgeSshOrigin)  |  ${timestamp}" `
                -Kind Success

            return
        }

        $reason = if ($remoteCheck.Error) {
            [string]$remoteCheck.Error
        }
        else {
            [string]$remoteCheck.Output
        }

        if ($reason.Length -gt 300) {
            $reason = $reason.Substring(0,297) + '...'
        }

        Set-KnowledgeSshStatus `
            -Text 'SSH: ⚠ CONNECTED • repository unavailable' `
            -Kind Warning

        Set-KnowledgeActionStatus `
            -Text "SSH авторизация есть, но repository недоступен: $reason" `
            -Kind Error
    }
    catch {
        Set-KnowledgeSshStatus `
            -Text 'SSH: ✕ CHECK ERROR' `
            -Kind Error

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

        if ($knowledgeExplorerValue) {
            $knowledgeExplorerValue.Text = [string]$stats.ExploredModules
        }

        if ($knowledgeIntroLabel) {
            $knowledgeIntroLabel.Text = "GitHub SSH • Auto-Learning: $($stats.Learned) • Auto Commit + Push после Jira-теста: ON. Секреты, runtime, reports, screenshots и traces не отправляются."
        }

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

        if ($git.ManagedDirty -and $script:KnowledgeSaveState -ne 'SAVING') {
            Set-KnowledgeSaveState `
                -State LOCAL_ONLY `
                -Details "Есть $($git.ManagedChanges) локальных управляемых изменений, которые ещё не подтверждены в GitHub."
        }

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
                    -Text "$($git.ManagedChanges) изменений проекта. Нажми «СОХРАНИТЬ ЗНАНИЯ В GITHUB»." `
                    -Kind Warning
            }
            elseif ($git.OtherChanges -gt 0) {
                Set-KnowledgeActionStatus `
                    -Text "Управляемые файлы проекта чистые. $($git.OtherChanges) изменение(й) вне безопасного списка не блокируют Commit." `
                    -Kind Warning
            }
            else {
                Set-KnowledgeActionStatus `
                    -Text 'Локально чисто. Зелёный статус Knowledge появляется только после проверки GitHub.' `
                    -Kind Info
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
            [System.Windows.Forms.MessageBox]::Show(
                'Git не установлен. Установи Git for Windows, затем снова открой Launcher.',
                'Rx2GO QA',
                'OK',
                'Warning'
            ) | Out-Null
        }
        return
    }

    $git = Get-GitState

    if (-not $git.Repository) {
        $r = Invoke-Git @('init','-b','main')

        if ($r.ExitCode -ne 0) {
            if (-not $Silent) {
                [System.Windows.Forms.MessageBox]::Show(
                    "Не удалось инициализировать Git: $($r.Error)",
                    'Rx2GO QA',
                    'OK',
                    'Error'
                ) | Out-Null
            }
            return
        }
    }

    $current = Get-GitState

    if ($current.Remote -eq 'не настроен') {
        $add = Invoke-Git @(
            'remote','add','origin',$script:DefaultGitRemote
        )

        if ($add.ExitCode -ne 0) {
            if (-not $Silent) {
                [System.Windows.Forms.MessageBox]::Show(
                    "Не удалось привязать GitHub автоматически:`r`n$($add.Error)",
                    'Rx2GO QA',
                    'OK',
                    'Error'
                ) | Out-Null
            }
            return
        }
    }
    elseif (
        ([string]$current.Remote) -match '^https?://github\.com/(?:Gamazzz|QA-E2E4)/rx2go-ai-qa(?:\.git)?/?$'
    ) {
        # Old launcher versions initialized this repo with HTTPS.
        # That can invoke Git Credential Manager and open browser OAuth.
        [void](Invoke-Git @(
            'remote','set-url','origin',$script:DefaultGitRemote
        ) 10000)
    }

    if ($knowledgeSyncInfo) {
        $knowledgeSyncInfo.Text = "GitHub origin: $script:DefaultGitRemote (SSH)"
        $knowledgeSyncInfo.ForeColor = [System.Drawing.Color]::DimGray
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

        $addArgs = New-Object System.Collections.ArrayList
        [void]$addArgs.Add('add')
        [void]$addArgs.Add('-A')
        [void]$addArgs.Add('--')

        foreach ($path in $pathArgs) {
            [void]$addArgs.Add([string]$path)
        }

        $addResult = Invoke-Git @($addArgs) 120000

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
            -Text "Локальный Commit создан ✓  Файлов: $($stagedFiles.Count). В GitHub ещё не подтверждено." `
            -Kind Warning

        Set-KnowledgeSaveState `
            -State LOCAL_ONLY `
            -Details 'Создан только локальный commit. Для сохранения знаний нажми «СОХРАНИТЬ ЗНАНИЯ В GITHUB».'
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
            "Есть $($git.ManagedChanges) несохранённых изменений проекта.`r`n`r`nИспользуй основную кнопку «СОХРАНИТЬ ЗНАНИЯ В GITHUB».",
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
        if ($git.OtherTrackedChanges -gt 0) {
            Set-KnowledgeActionStatus `
                -Text "Synchronize: tracked вне Launcher — $($git.OtherTrackedChanges); проверяю remote…" `
                -Kind Warning
        }
        elseif ($git.OtherUntrackedChanges -gt 0) {
            Set-KnowledgeActionStatus `
                -Text "Synchronize: untracked вне Launcher — $($git.OtherUntrackedChanges); они не блокируют safe pull." `
                -Kind Info
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
            $otherEntries = @(Get-OtherGitStatusEntries)
            $trackedOutside = @(
                $otherEntries |
                    Where-Object { [bool]$_.IsTrackedChange }
            )
            $untrackedOutside = @(
                $otherEntries |
                    Where-Object { [bool]$_.IsUntracked }
            )

            if ($trackedOutside.Count -gt 0) {
                $trackedList = Format-GitStatusEntryList `
                    -Entries $trackedOutside `
                    -MaxItems 12

                Set-KnowledgeActionStatus `
                    -Text "GitHub +$behind; tracked локальных файлов вне Launcher — $($trackedOutside.Count). Синхронизация приостановлена." `
                    -Kind Warning

                [System.Windows.Forms.MessageBox]::Show(
                    "Сохранение знаний приостановлено.`r`n`r`nВ GitHub есть $behind новый commit(ов), а локально изменены TRACKED-файлы вне управляемого Launcher списка:`r`n`r`n$trackedList`r`n`r`nНичего не удалено и не перезаписано.`r`nНажми «Показать изменения», чтобы проверить эти файлы.",
                    'Rx2GO QA — безопасная синхронизация',
                    'OK',
                    'Warning'
                ) | Out-Null

                return
            }

            if ($ahead -gt 0) {
                # Both sides contain commits: a fast-forward is impossible.
                # Rebase only committed Launcher knowledge onto the latest remote.
                # If a real conflict occurs, abort immediately to restore the exact
                # pre-rebase local state. Never force-push.
                Set-KnowledgeActionStatus `
                    -Text "Локальная база и GitHub изменились одновременно. Безопасно объединяю историю…" `
                    -Kind Info

                $rebase = Invoke-Git @(
                    'rebase',
                    $remoteRef
                ) 120000

                if ($rebase.ExitCode -ne 0) {
                    $conflicts = Invoke-Git @(
                        'diff',
                        '--name-only',
                        '--diff-filter=U'
                    ) 15000

                    $conflictFiles = @(
                        ([string]$conflicts.Output) -split "`r?`n" |
                            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
                    )

                    # Always return repository to its original state.
                    [void](Invoke-Git @(
                        'rebase',
                        '--abort'
                    ) 30000)

                    $reason = (
                        ([string]$rebase.Error) + "`n" +
                        ([string]$rebase.Output)
                    ).Trim()

                    $conflictText = if ($conflictFiles.Count -gt 0) {
                        @(
                            $conflictFiles |
                                Select-Object -First 12 |
                                ForEach-Object { "• $_" }
                        ) -join "`r`n"
                    }
                    else {
                        'Git не вернул список конфликтующих файлов.'
                    }

                    Set-KnowledgeSaveState `
                        -State LOCAL_ONLY `
                        -Details 'Локальные знания сохранены, но автоматическое объединение с GitHub не завершено.'

                    Set-KnowledgeActionStatus `
                        -Text 'Истории Git разошлись, автоматическое объединение остановлено. Локальные данные сохранены.' `
                        -Kind Warning

                    [System.Windows.Forms.MessageBox]::Show(
                        "Знания НЕ потеряны.`r`n`r`nЛокальная база и GitHub изменялись одновременно, и автоматическое объединение встретило конфликт.`r`n`r`nКонфликтующие файлы:`r`n$conflictText`r`n`r`nRebase автоматически отменён — локальная история восстановлена.`r`n`r`nТехническая причина:`r`n$reason",
                        'Rx2GO QA — нужен ручной разбор Git',
                        'OK',
                        'Warning'
                    ) | Out-Null

                    return
                }

                Set-KnowledgeActionStatus `
                    -Text "Истории безопасно объединены ✓  Локальные knowledge commit перенесены поверх origin/$($git.Branch)." `
                    -Kind Success
            }
            else {
                if ($untrackedOutside.Count -gt 0) {
                    Set-KnowledgeActionStatus `
                        -Text "GitHub +$behind; локально $($untrackedOutside.Count) untracked файл(ов). Выполняю безопасный fast-forward." `
                        -Kind Info
                }

                $pull = Invoke-Git @(
                    'pull',
                    '--ff-only',
                    'origin',
                    $git.Branch
                ) 60000

                if ($pull.ExitCode -ne 0) {
                    $reason = (
                        ([string]$pull.Error) + "`n" +
                        ([string]$pull.Output)
                    ).Trim()

                    Set-KnowledgeActionStatus `
                        -Text 'Не удалось получить изменения GitHub. Локальные данные не изменены.' `
                        -Kind Error

                    [System.Windows.Forms.MessageBox]::Show(
                        "Синхронизация не выполнена, но локальные знания не потеряны.`r`n`r`n$reason",
                        'Rx2GO QA — GitHub',
                        'OK',
                        'Warning'
                    ) | Out-Null

                    return
                }
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

        try {
            Refresh-KnowledgeSaveState -VerifyRemote
        }
        catch { }
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

    $script:SuppressJiraImportedEditEvent = $true
    try {
        $jiraImportedBox.Text = Format-JiraIssueForPreview $issue
        $jiraImportedBox.SelectionStart = 0
        $jiraImportedBox.ScrollToCaret()
    }
    finally {
        $script:SuppressJiraImportedEditEvent = $false
    }
    $script:JiraImportedEdited = $false

    $jiraImportedInfo.Text = "$issueKey загружена • Jira comments: $(@($issue.comments).Count) • поле редактируемое"
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



function Write-QueueWorkerStatus {
    param(
        [string]$Status,
        [string]$Phase = '',
        [string]$Detail = '',
        [bool]$Final = $false,
        [string]$Result = ''
    )

    if (-not $script:QueueWorkerMode) { return }
    if ([string]::IsNullOrWhiteSpace($script:QueueWorkerStatusFile)) { return }

    try {
        $dir = Split-Path $script:QueueWorkerStatusFile -Parent
        if ($dir) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

        $payload = [ordered]@{
            schemaVersion = 1
            jobId = $script:QueueWorkerJobId
            taskKey = $script:QueueWorkerTaskKey
            environment = $script:QueueWorkerEnvironment
            workerSlot = $script:QueueWorkerSlot
            pid = $PID
            status = $Status
            phase = $Phase
            detail = $Detail
            final = $Final
            result = $Result
            startedAt = if ($script:QueueWorkerStartedAt) { $script:QueueWorkerStartedAt.ToString('o') } else { $null }
            updatedAt = (Get-Date).ToString('o')
            workerRoot = $script:ProjectRoot
            generatedSpec = if ($script:JiraGeneratedSpec) { [string]$script:JiraGeneratedSpec } else { '' }
            jiraReport = if ($script:LastJiraReportPath) { [string]$script:LastJiraReportPath } else { '' }
            jiraRunDir = if ($script:LastJiraRunDir) { [string]$script:LastJiraRunDir } else { '' }
            agentRunDir = if ($script:AgentRunDir) { [string]$script:AgentRunDir } else { '' }
            learnedFile = if ($script:LastKnowledgeLearningFile) { [string]$script:LastKnowledgeLearningFile } else { '' }
        }

        $json = $payload | ConvertTo-Json -Depth 8
        $tmp = $script:QueueWorkerStatusFile + '.tmp'
        [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false)))
        Move-Item -Path $tmp -Destination $script:QueueWorkerStatusFile -Force
    }
    catch {}
}

function Update-QueueWorkerPhaseFromAgent {
    param(
        [string]$Agent,
        [string]$State,
        [string]$Details = ''
    )

    if (-not $script:QueueWorkerMode -or $script:QueueWorkerFinalWritten) { return }

    $phase = switch ($Agent) {
        'JiraAnalyst' { 'ANALYZING' }
        'McpQaAgent' { 'TESTING' }
        'QAReviewer' { 'REVIEWING' }
        'FailureTriage' { 'RCA' }
        default { 'RUNNING' }
    }

    $stateDetail = if ($Details) { "$State — $Details" } else { $State }
    Write-QueueWorkerStatus -Status 'RUNNING' -Phase $phase -Detail $stateDetail
}

function Complete-QueueWorkerResult {
    param(
        [ValidateSet('PASS','FAIL','BLOCKED','ERROR','STOPPED')]
        [string]$Result,
        [string]$Details = ''
    )

    if (-not $script:QueueWorkerMode) { return }
    if ($script:QueueWorkerFinalWritten) { return }

    $script:QueueWorkerFinalWritten = $true
    $script:QueueWorkerFinalResult = $Result

    Write-QueueWorkerStatus `
        -Status 'FINISHED' `
        -Phase $Result `
        -Detail $Details `
        -Final $true `
        -Result $Result
}

function Write-QueueLog {
    param([string]$Text)

    $line = "$(Get-Date -Format 'HH:mm:ss')  $Text"
    $script:QueueLastEvent = $line

    if ($queueLogBox) {
        $queueLogBox.AppendText($line + "`r`n")
        $queueLogBox.SelectionStart = $queueLogBox.TextLength
        $queueLogBox.ScrollToCaret()
    }
}

function New-QueueItem {
    param(
        [string]$Key,
        [string]$Environment
    )

    return [pscustomobject]@{
        Id = ([guid]::NewGuid().ToString('N').Substring(0,12))
        Key = $Key.ToUpperInvariant()
        Environment = $Environment
        Status = 'WAITING'
        Result = ''
        Details = ''
        WorkerSlot = 0
        Pid = 0
        Process = $null
        WorkerDir = ''
        StatusFile = ''
        AddedAt = (Get-Date)
        StartedAt = $null
        FinishedAt = $null
        RetryCount = 0
        Merged = $false
        GitSynced = $false
        ReportPath = ''
    }
}

function Save-QueueState {
    if ($script:QueueWorkerMode) { return }

    try {
        New-Item -ItemType Directory -Path $script:QueueRoot -Force | Out-Null
        $items = @(
            $script:QueueItems |
                ForEach-Object {
                    [ordered]@{
                        id = $_.Id
                        key = $_.Key
                        environment = $_.Environment
                        status = $_.Status
                        result = $_.Result
                        details = $_.Details
                        workerSlot = $_.WorkerSlot
                        pid = $_.Pid
                        workerDir = $_.WorkerDir
                        statusFile = $_.StatusFile
                        addedAt = if ($_.AddedAt) { ([datetime]$_.AddedAt).ToString('o') } else { $null }
                        startedAt = if ($_.StartedAt) { ([datetime]$_.StartedAt).ToString('o') } else { $null }
                        finishedAt = if ($_.FinishedAt) { ([datetime]$_.FinishedAt).ToString('o') } else { $null }
                        retryCount = $_.RetryCount
                        merged = $_.Merged
                        gitSynced = $_.GitSynced
                        reportPath = $_.ReportPath
                    }
                }
        )

        $obj = [ordered]@{
            schemaVersion = 1
            maxParallel = $script:QueueMaxParallel
            paused = $script:QueuePaused
            savedAt = (Get-Date).ToString('o')
            items = $items
        }
        Write-Utf8NoBomFile -Path $script:QueueStateFile -Content ($obj | ConvertTo-Json -Depth 8)
    }
    catch {
        Write-QueueLog "Queue state save warning: $($_.Exception.Message)"
    }
}

function Load-QueueState {
    if ($script:QueueWorkerMode) { return }
    if (-not (Test-Path $script:QueueStateFile)) { return }

    try {
        $raw = Get-Content -Raw -Path $script:QueueStateFile
        if ([string]::IsNullOrWhiteSpace($raw)) { return }
        $state = $raw | ConvertFrom-Json -ErrorAction Stop

        if ($state.maxParallel) {
            $script:QueueMaxParallel = [Math]::Max(1,[Math]::Min(3,[int]$state.maxParallel))
        }

        foreach ($old in @($state.items)) {
            if (-not $old.key) { continue }
            $item = New-QueueItem -Key ([string]$old.key) -Environment ([string]$old.environment)
            $item.Id = if ($old.id) { [string]$old.id } else { $item.Id }
            $item.Result = [string]$old.result
            $item.Details = [string]$old.details
            $item.WorkerDir = [string]$old.workerDir
            $item.StatusFile = [string]$old.statusFile
            $item.RetryCount = [int]$old.retryCount
            $item.Merged = [bool]$old.merged
            $item.GitSynced = [bool]$old.gitSynced
            $item.ReportPath = [string]$old.reportPath

            if ($old.addedAt) { try { $item.AddedAt = [datetime]$old.addedAt } catch {} }
            if ($old.startedAt) { try { $item.StartedAt = [datetime]$old.startedAt } catch {} }
            if ($old.finishedAt) { try { $item.FinishedAt = [datetime]$old.finishedAt } catch {} }

            $previousStatus = ([string]$old.status).ToUpperInvariant()
            if ($previousStatus -in @('STARTING','ANALYZING','TESTING','REVIEWING','PLAYWRIGHT','RCA','SYNCING','RUNNING')) {
                $item.Status = 'INTERRUPTED'
                $item.Details = 'Предыдущий Launcher был закрыт во время выполнения. Нажми Retry.'
                $item.Result = ''
            }
            else {
                $item.Status = if ($previousStatus) { $previousStatus } else { 'WAITING' }
            }

            [void]$script:QueueItems.Add($item)
        }
    }
    catch {
        Write-QueueLog "Queue state load warning: $($_.Exception.Message)"
    }
}

function Get-SelectedQueueItem {
    if (-not $queueGrid -or $queueGrid.SelectedRows.Count -eq 0) { return $null }
    $id = [string]$queueGrid.SelectedRows[0].Tag
    if ([string]::IsNullOrWhiteSpace($id)) { return $null }
    return @($script:QueueItems | Where-Object { $_.Id -eq $id } | Select-Object -First 1)[0]
}

function Get-QueueStatusColor {
    param([string]$Status)

    $normalizedStatus = ([string]$Status).ToUpperInvariant()

    switch ($normalizedStatus) {
        'PASS' { return [System.Drawing.Color]::FromArgb(32,120,72) }
        'FAIL' { return [System.Drawing.Color]::Firebrick }
        'BLOCKED' { return [System.Drawing.Color]::FromArgb(197,119,0) }
        'ERROR' { return [System.Drawing.Color]::Firebrick }
        'STOPPED' { return [System.Drawing.Color]::DimGray }
        'INTERRUPTED' { return [System.Drawing.Color]::FromArgb(161,98,7) }
        'WAITING' { return [System.Drawing.Color]::DimGray }
        default { return [System.Drawing.Color]::FromArgb(37,99,235) }
    }
}


function Refresh-QueueGrid {
    if (-not $queueGrid) { return }

    try {
        $selectedId = $null
        if ($queueGrid.SelectedRows.Count -gt 0) {
            $selectedId = [string]$queueGrid.SelectedRows[0].Tag
        }

        $queueGrid.Rows.Clear()
        $n = 1

        # PowerShell 5.1-safe queue snapshot.
        $itemsSnapshot = @($script:QueueItems)

        foreach ($item in $itemsSnapshot) {
            if ($null -eq $item) { continue }

            $started = if ($item.StartedAt) {
                ([datetime]$item.StartedAt).ToString('HH:mm:ss')
            } else { '' }

            $worker = if ([int]$item.WorkerSlot -gt 0) {
                "W$($item.WorkerSlot)"
            } else { '' }

            $rowIndex = $queueGrid.Rows.Add(
                $n,
                [string]$item.Key,
                [string]$item.Environment,
                [string]$item.Status,
                $worker,
                $started,
                [string]$item.Result,
                [string]$item.Details
            )

            $row = $queueGrid.Rows[$rowIndex]
            $row.Tag = [string]$item.Id
            $row.Cells[3].Style.ForeColor = Get-QueueStatusColor -Status ([string]$item.Status)
            $row.Cells[3].Style.Font = New-Object System.Drawing.Font('Segoe UI',8.5,[System.Drawing.FontStyle]::Bold)

            if (-not [string]::IsNullOrWhiteSpace([string]$item.Result)) {
                $row.Cells[6].Style.ForeColor = Get-QueueStatusColor -Status ([string]$item.Result)
                $row.Cells[6].Style.Font = New-Object System.Drawing.Font('Segoe UI',8.5,[System.Drawing.FontStyle]::Bold)
            }

            if (
                -not [string]::IsNullOrWhiteSpace($selectedId) -and
                ([string]$item.Id) -eq $selectedId
            ) {
                $row.Selected = $true
            }

            $n++
        }

        if ($queueSummaryLabel) {
            $waiting = @($itemsSnapshot | Where-Object { ([string]$_.Status).ToUpperInvariant() -eq 'WAITING' }).Count
            $running = @($itemsSnapshot | Where-Object {
                ([string]$_.Status).ToUpperInvariant() -in @('STARTING','ANALYZING','TESTING','REVIEWING','PLAYWRIGHT','RCA','SYNCING')
            }).Count
            $pass = @($itemsSnapshot | Where-Object { ([string]$_.Result).ToUpperInvariant() -eq 'PASS' }).Count
            $fail = @($itemsSnapshot | Where-Object { ([string]$_.Result).ToUpperInvariant() -eq 'FAIL' }).Count
            $blocked = @($itemsSnapshot | Where-Object { ([string]$_.Result).ToUpperInvariant() -eq 'BLOCKED' }).Count

            $queueSummaryLabel.Text = "WAITING $waiting  •  RUNNING $running/$($script:QueueMaxParallel)  •  PASS $pass  •  FAIL $fail  •  BLOCKED $blocked"
        }
    }
    catch {
        $message = "Jira Queue UI недоступна: $($_.Exception.Message)"
        Write-QueueLog "QUEUE UI FAIL-SAFE → $message"

        if ($queueStatusLabel) {
            $queueStatusLabel.Text = "$message • основной Launcher продолжает работу."
            $queueStatusLabel.ForeColor = [System.Drawing.Color]::FromArgb(197,119,0)
        }

        if ($queueStartButton) {
            $queueStartButton.Enabled = $false
        }

        # Queue must never terminate the main Launcher.
        return
    }
}

function Get-QueueTaskKeysFromText {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }
    return @(
        [regex]::Matches($Text, '(?i)\bSCRUM-\d+\b') |
            ForEach-Object { $_.Value.ToUpperInvariant() } |
            Select-Object -Unique
    )
}

function Add-QueueTasksFromInput {
    $keys = @(Get-QueueTaskKeysFromText -Text ([string]$queueInputBox.Text))
    if ($keys.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show(
            'Вставь один или несколько Jira key/URL, например SCRUM-3403, SCRUM-4069.',
            'Rx2GO QA — Jira Queue','OK','Warning'
        ) | Out-Null
        return
    }

    $environment = [string]$queueEnvironmentCombo.SelectedItem
    if ([string]::IsNullOrWhiteSpace($environment)) { $environment = 'HOT' }

    foreach ($key in $keys) {
        $activeDuplicate = @(
            $script:QueueItems |
                Where-Object { $_.Key -eq $key -and $_.Status -in @('WAITING','STARTING','ANALYZING','TESTING','REVIEWING','PLAYWRIGHT','RCA','SYNCING') }
        ).Count -gt 0

        if ($activeDuplicate) {
            Write-QueueLog "$key уже есть в активной очереди — пропущен."
            continue
        }

        [void]$script:QueueItems.Add((New-QueueItem -Key $key -Environment $environment))
        Write-QueueLog "Добавлено: $key [$environment]"
    }

    $queueInputBox.Clear()
    Refresh-QueueGrid
    Save-QueueState
}

function Remove-SelectedQueueItem {
    $item = Get-SelectedQueueItem
    if (-not $item) { return }

    if ($item.Status -in @('STARTING','ANALYZING','TESTING','REVIEWING','PLAYWRIGHT','RCA','SYNCING')) {
        [System.Windows.Forms.MessageBox]::Show(
            'Сначала останови выполняющийся Worker.',
            'Rx2GO QA — Jira Queue','OK','Warning'
        ) | Out-Null
        return
    }

    [void]$script:QueueItems.Remove($item)
    Write-QueueLog "Удалено из очереди: $($item.Key)"
    Refresh-QueueGrid
    Save-QueueState
}

function Move-SelectedQueueItem {
    param([int]$Direction)
    $item = Get-SelectedQueueItem
    if (-not $item -or $item.Status -ne 'WAITING') { return }

    $index = $script:QueueItems.IndexOf($item)
    $target = $index + $Direction
    if ($target -lt 0 -or $target -ge $script:QueueItems.Count) { return }

    $script:QueueItems.RemoveAt($index)
    $script:QueueItems.Insert($target,$item)
    Refresh-QueueGrid
    Save-QueueState
}

function Retry-SelectedQueueItem {
    $item = Get-SelectedQueueItem
    if (-not $item) { return }
    if ($item.Status -in @('STARTING','ANALYZING','TESTING','REVIEWING','PLAYWRIGHT','RCA','SYNCING')) { return }

    $item.RetryCount++
    $item.Status = 'WAITING'
    $item.Result = ''
    $item.Details = "Retry #$($item.RetryCount)"
    $item.WorkerSlot = 0
    $item.Pid = 0
    $item.Process = $null
    $item.WorkerDir = ''
    $item.StatusFile = ''
    $item.StartedAt = $null
    $item.FinishedAt = $null
    $item.Merged = $false
    $item.GitSynced = $false
    $item.ReportPath = ''

    Write-QueueLog "Retry поставлен в очередь: $($item.Key)"
    Refresh-QueueGrid
    Save-QueueState
    if ($script:QueueRunning -and -not $script:QueuePaused) { Process-QueueTick }
}

function Get-FreeQueueWorkerSlot {
    for ($slot=1; $slot -le $script:QueueMaxParallel; $slot++) {
        $used = @(
            $script:QueueItems |
                Where-Object {
                    $_.WorkerSlot -eq $slot -and
                    $_.Status -in @('STARTING','ANALYZING','TESTING','REVIEWING','PLAYWRIGHT','RCA')
                }
        ).Count -gt 0
        if (-not $used) { return $slot }
    }
    return 0
}

function Prepare-QueueWorkerDirectory {
    param($Item)

    $retrySuffix = if ($Item.RetryCount -gt 0) { "-r$($Item.RetryCount)" } else { '' }
    $workerDir = Join-Path $script:QueueWorkersRoot "$($Item.Id)-$($Item.Key)$retrySuffix"

    if (Test-Path $workerDir) {
        Remove-Item -Path $workerDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    New-Item -ItemType Directory -Path $workerDir -Force | Out-Null

    $excludeDirs = @('.git','node_modules','reports','jira-runs','.qa-state','.secrets')
    $excludeFiles = @('.env','startup-error.log')

    foreach ($source in @(Get-ChildItem -Path $script:ProjectRoot -Force -ErrorAction Stop)) {
        if ($source.PSIsContainer -and $excludeDirs -contains $source.Name) { continue }
        if (-not $source.PSIsContainer -and $excludeFiles -contains $source.Name) { continue }
        if (-not $source.PSIsContainer -and $source.Name -match '(?i)credential|secret') { continue }

        $dest = Join-Path $workerDir $source.Name
        Copy-Item -Path $source.FullName -Destination $dest -Recurse -Force
    }

    $mainNodeModules = Join-Path $script:ProjectRoot 'node_modules'
    $workerNodeModules = Join-Path $workerDir 'node_modules'

    if (Test-Path $mainNodeModules) {
        try {
            New-Item -ItemType Junction -Path $workerNodeModules -Target $mainNodeModules -Force -ErrorAction Stop | Out-Null
        }
        catch {
            $cmd = "mklink /J `"$workerNodeModules`" `"$mainNodeModules`""
            $junction = Start-Process -FilePath 'cmd.exe' -ArgumentList '/d','/c',$cmd -Wait -PassThru -WindowStyle Hidden
            if ($junction.ExitCode -ne 0 -or -not (Test-Path $workerNodeModules)) {
                throw 'Не удалось создать worker junction к node_modules.'
            }
        }
    }
    else {
        throw 'node_modules отсутствует в основном Launcher. Сначала выполни Playwright precheck/setup.'
    }

    return $workerDir
}

function Start-QueueWorker {
    param($Item,[int]$Slot)

    try {
        $workerDir = Prepare-QueueWorkerDirectory -Item $Item
        $jobDir = Join-Path $script:QueueJobsRoot "$($Item.Id)-r$($Item.RetryCount)"
        New-Item -ItemType Directory -Path $jobDir -Force | Out-Null
        $statusFile = Join-Path $jobDir 'status.json'
        if (Test-Path $statusFile) { Remove-Item $statusFile -Force -ErrorAction SilentlyContinue }

        $launcherPath = Join-Path $workerDir 'Rx2GO-QA-Launcher.ps1'
        if (-not (Test-Path $launcherPath)) { throw "Worker Launcher not found: $launcherPath" }

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = (Join-Path $PSHOME 'powershell.exe')
        $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$launcherPath`""
        $psi.WorkingDirectory = $workerDir
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true

        $psi.EnvironmentVariables['RX2GO_QUEUE_WORKER'] = '1'
        $psi.EnvironmentVariables['RX2GO_QUEUE_JOB_ID'] = [string]$Item.Id
        $psi.EnvironmentVariables['RX2GO_QUEUE_TASK_KEY'] = [string]$Item.Key
        $psi.EnvironmentVariables['RX2GO_QUEUE_ENV'] = [string]$Item.Environment
        $psi.EnvironmentVariables['RX2GO_QUEUE_STATUS_FILE'] = $statusFile
        $psi.EnvironmentVariables['RX2GO_QUEUE_PARENT_ROOT'] = $script:ProjectRoot
        $psi.EnvironmentVariables['RX2GO_QUEUE_WORKER_SLOT'] = [string]$Slot
        if ([string]$Item.Environment -eq 'ADM' -and $dailyPassword) {
            $psi.EnvironmentVariables['RX2GO_QUEUE_DAILY_PASSWORD'] = [string]$dailyPassword.Text
        }

        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $psi
        [void]$process.Start()

        $Item.Process = $process
        $Item.Pid = $process.Id
        $Item.WorkerSlot = $Slot
        $Item.WorkerDir = $workerDir
        $Item.StatusFile = $statusFile
        $Item.StartedAt = Get-Date
        $Item.FinishedAt = $null
        $Item.Status = 'STARTING'
        $Item.Result = ''
        $Item.Details = "Worker $Slot запускается"
        $Item.Merged = $false
        $Item.GitSynced = $false

        Write-QueueLog "START $($Item.Key) → Worker $Slot / PID $($process.Id) / $($Item.Environment)"
        Save-QueueState
        return $true
    }
    catch {
        $Item.Status = 'ERROR'
        $Item.Result = 'ERROR'
        $Item.Details = $_.Exception.Message
        $Item.FinishedAt = Get-Date
        Write-QueueLog "ERROR $($Item.Key): $($_.Exception.Message)"
        Save-QueueState
        return $false
    }
}

function Read-QueueWorkerStatus {
    param($Item)
    if (-not $Item.StatusFile -or -not (Test-Path $Item.StatusFile)) { return $null }
    try {
        $raw = Get-Content -Raw -Path $Item.StatusFile -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        return ($raw | ConvertFrom-Json -ErrorAction Stop)
    }
    catch { return $null }
}


function Merge-UniqueQueueStrings {
    param($A,$B)

    $result = New-Object System.Collections.ArrayList

    foreach ($value in @($A) + @($B)) {
        if ($null -eq $value) { continue }

        $s = ([string]$value).Trim()
        if (-not $s) { continue }

        $exists = @(
            @($result) |
                Where-Object {
                    [string]::Equals(
                        [string]$_,
                        $s,
                        [System.StringComparison]::OrdinalIgnoreCase
                    )
                }
        ).Count -gt 0

        if (-not $exists) {
            [void]$result.Add($s)
        }
    }

    return @($result)
}

function Merge-QueueLearnedKnowledgeJson {
    param([string]$Source,[string]$Destination)

    if (-not (Test-Path $Destination)) {
        New-Item -ItemType Directory -Path (Split-Path $Destination -Parent) -Force | Out-Null
        Copy-Item $Source $Destination -Force
        return
    }

    try {
        $src = Get-Content -Raw $Source | ConvertFrom-Json -ErrorAction Stop
        $dst = Get-Content -Raw $Destination | ConvertFrom-Json -ErrorAction Stop
        $fields = @('stableProductFacts','navigationFacts','apiNetworkFacts','testDataRules','automationLessons','regressionCandidates','projectRuleCandidates')

        foreach ($field in $fields) {
            $merged = Merge-UniqueQueueStrings -A $dst.$field -B $src.$field
            if ($src.PSObject.Properties.Name -contains $field) { $src.$field = @($merged) }
            else { Add-Member -InputObject $src -NotePropertyName $field -NotePropertyValue @($merged) }
        }

        $src | ConvertTo-Json -Depth 14 | Set-Content -Path $Destination -Encoding UTF8
    }
    catch {
        Copy-Item $Source $Destination -Force
    }
}

function Invoke-QueueMergeWorkerOutputs {
    param($Item)

    if (-not $Item.WorkerDir -or -not (Test-Path $Item.WorkerDir)) {
        return [pscustomobject]@{ Success=$false; Count=0; Message='Worker directory missing.' }
    }

    $roots = @('knowledge','jira-cases','scenarios','tests\\generated')
    $changed = 0

    foreach ($relRoot in $roots) {
        $srcRoot = Join-Path $Item.WorkerDir $relRoot
        if (-not (Test-Path $srcRoot)) { continue }

        foreach ($file in @(Get-ChildItem -Path $srcRoot -File -Recurse -ErrorAction SilentlyContinue)) {
            $relative = $file.FullName.Substring($Item.WorkerDir.Length).TrimStart('\\','/')
            $dest = Join-Path $script:ProjectRoot $relative

            $same = $false
            if (Test-Path $dest) {
                try {
                    $same = ((Get-FileHash $file.FullName -Algorithm SHA256).Hash -eq (Get-FileHash $dest -Algorithm SHA256).Hash)
                } catch {}
            }
            if ($same) { continue }

            New-Item -ItemType Directory -Path (Split-Path $dest -Parent) -Force | Out-Null

            if ($relative -match '(?i)^knowledge[\\/]learned[\\/].+\\.json$') {
                Merge-QueueLearnedKnowledgeJson -Source $file.FullName -Destination $dest
            }
            else {
                Copy-Item -Path $file.FullName -Destination $dest -Force
            }
            $changed++
        }
    }

    return [pscustomobject]@{ Success=$true; Count=$changed; Message="Merged $changed managed file(s)." }
}

function Invoke-QueueGitSyncForItem {
    param($Item)

    $oldSummary = $script:LastSummary
    $oldMcp = $script:AgentMcpExecution
    try {
        $fakeSummary = [pscustomobject]@{
            Pass = if ($Item.Result -eq 'PASS') { 1 } else { 0 }
            Fail = if ($Item.Result -eq 'FAIL') { 1 } else { 0 }
            Skip = if ($Item.Result -eq 'BLOCKED') { 1 } else { 0 }
            Total = 1
            Failed = @()
        }
        $script:LastSummary = $fakeSummary
        $script:AgentMcpExecution = $null
        $fakeTask = [pscustomobject]@{ Key=$Item.Key; Title='Jira Queue worker result'; Module='Queue' }
        return (Invoke-AutoGitCommitPushAfterJiraRun -Task $fakeTask -Summary $fakeSummary)
    }
    finally {
        $script:LastSummary = $oldSummary
        $script:AgentMcpExecution = $oldMcp
    }
}


function Test-QueueItemHasCodexUsageLimit {
    param($Item,$WorkerStatus)

    $parts = @(
        [string]$Item.Details
        [string]$Item.Result
        if ($WorkerStatus) { [string]$WorkerStatus.detail } else { '' }
        if ($WorkerStatus) { [string]$WorkerStatus.result } else { '' }
    ) -join "`n"

    return (Test-CodexUsageLimitText -Text $parts)
}

function Pause-QueueForCodexUsageLimit {
    param([string]$Details)

    $script:QueuePaused = $true

    if ($queueStatusLabel) {
        $queueStatusLabel.Text = 'Очередь на паузе: достигнут лимит Codex. Новые Worker не запускаются.'
        $queueStatusLabel.ForeColor = [System.Drawing.Color]::FromArgb(197,119,0)
    }

    Write-QueueLog "QUEUE PAUSED → Codex usage limit | $Details"
    Save-QueueState

    if (-not $script:QueueUsageLimitWarningShown) {
        $script:QueueUsageLimitWarningShown = $true

        [System.Windows.Forms.MessageBox]::Show(
            "Очередь автоматически поставлена на паузу: достигнут лимит Codex.`r`n`r`nУже запущенные Worker могут завершить текущий шаг, но новые задачи не будут стартовать.`r`n`r`n$Details`r`n`r`nПосле восстановления лимита нажми Resume.",
            'Rx2GO QA — Jira Queue',
            'OK',
            'Warning'
        ) | Out-Null
    }
}

function Finalize-QueueWorkerItem {
    param($Item,$WorkerStatus)

    if ($Item.Merged) { return }

    $Item.Status = 'SYNCING'
    $Item.Details = 'Объединяю знания/тесты и синхронизирую GitHub…'
    Refresh-QueueGrid
    [System.Windows.Forms.Application]::DoEvents()

    $merge = Invoke-QueueMergeWorkerOutputs -Item $Item
    if (-not $merge.Success) {
        $Item.Status = 'ERROR'
        $Item.Result = 'ERROR'
        $Item.Details = "Merge failed: $($merge.Message)"
        $Item.Merged = $true
        $Item.FinishedAt = Get-Date
        Write-QueueLog "$($Item.Key) → merge ERROR: $($merge.Message)"
        Save-QueueState
        return
    }

    $Item.Merged = $true
    if ($WorkerStatus.jiraReport) { $Item.ReportPath = [string]$WorkerStatus.jiraReport }
    $Item.Result = if ($WorkerStatus.result) { ([string]$WorkerStatus.result).ToUpperInvariant() } else { 'ERROR' }

    Write-QueueLog "$($Item.Key) → $($merge.Message)"

    $gitResult = Invoke-QueueGitSyncForItem -Item $Item
    if ($gitResult -and $gitResult.Success -and ($gitResult.Pushed -or $gitResult.Message -match 'synchronized')) {
        $Item.GitSynced = $true
        Write-QueueLog "$($Item.Key) → GitHub sync PASS"
    }
    elseif ($gitResult -and $gitResult.Warning) {
        Write-QueueLog "$($Item.Key) → Git warning: $($gitResult.Warning)"
    }

    $Item.Status = switch ($Item.Result) {
        'PASS' { 'PASS' }
        'FAIL' { 'FAIL' }
        'BLOCKED' { 'BLOCKED' }
        'STOPPED' { 'STOPPED' }
        default { 'ERROR' }
    }
    $Item.Details = if ($WorkerStatus.detail) { [string]$WorkerStatus.detail } else { $Item.Result }
    if (-not $Item.GitSynced -and $gitResult -and $gitResult.Warning) {
        $Item.Details += " | Git: $($gitResult.Warning)"
    }
    $Item.FinishedAt = Get-Date
    $Item.Process = $null
    $Item.Pid = 0
    $Item.WorkerSlot = 0

    if (Test-QueueItemHasCodexUsageLimit -Item $Item -WorkerStatus $WorkerStatus) {
        $codexLimitDetails = [string]$Item.Details

        if ([string]::IsNullOrWhiteSpace($codexLimitDetails)) {
            $codexLimitDetails = 'Codex usage limit reached.'
        }

        Pause-QueueForCodexUsageLimit -Details $codexLimitDetails
    }

    Write-QueueLog "DONE $($Item.Key) → $($Item.Result)"
    Save-QueueState
}

function Stop-QueueWorkerItem {
    param($Item,[string]$Reason='Остановлено пользователем')
    if (-not $Item) { return }

    if ($Item.Process -and -not $Item.Process.HasExited) {
        try { & taskkill /PID $Item.Process.Id /T /F | Out-Null } catch {}
    }

    $Item.Status = 'STOPPED'
    $Item.Result = 'STOPPED'
    $Item.Details = $Reason
    $Item.FinishedAt = Get-Date
    $Item.Process = $null
    $Item.Pid = 0
    $Item.WorkerSlot = 0
    Write-QueueLog "STOP $($Item.Key)"
    Refresh-QueueGrid
    Save-QueueState
}

function Stop-SelectedQueueWorker {
    $item = Get-SelectedQueueItem
    if ($item) { Stop-QueueWorkerItem -Item $item }
}

function Stop-AllQueueWorkers {
    foreach ($item in @($script:QueueItems)) {
        if ($item.Status -in @('STARTING','ANALYZING','TESTING','REVIEWING','PLAYWRIGHT','RCA','SYNCING')) {
            Stop-QueueWorkerItem -Item $item -Reason 'Остановлено при закрытии/остановке очереди'
        }
    }
    $script:QueueRunning = $false
    $script:QueuePaused = $false
    if ($script:QueueTimer) { $script:QueueTimer.Stop() }
    Refresh-QueueGrid
    Save-QueueState
}

function Test-QueuePreflight {
    if ($script:QueueWorkerMode) { return $false }

    if (@($script:QueueItems | Where-Object { $_.Status -eq 'WAITING' }).Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show('В очереди нет задач со статусом WAITING.','Rx2GO QA — Jira Queue','OK','Information') | Out-Null
        return $false
    }

    if ($script:RunningProcess -and -not $script:RunningProcess.HasExited) {
        [System.Windows.Forms.MessageBox]::Show('Сначала дождись завершения одиночного теста. Очередь использует отдельные Workers, но Git sync выполняется основным Launcher.','Rx2GO QA — Jira Queue','OK','Warning') | Out-Null
        return $false
    }

    if (-not $script:ChatGPTConnected) {
        [System.Windows.Forms.MessageBox]::Show('ChatGPT/Codex не подключён. Подключи его на вкладке Jira Task/Быстрый запуск.','Rx2GO QA — Jira Queue','OK','Warning') | Out-Null
        return $false
    }

    $app = Get-AppCredentialPlain
    if (-not $app -or [string]::IsNullOrWhiteSpace([string]$app.Password)) {
        [System.Windows.Forms.MessageBox]::Show('Не сохранён пароль Rx2GO. Настрой учетку на вкладке «Быстрый запуск».','Rx2GO QA — Jira Queue','OK','Warning') | Out-Null
        return $false
    }
    $app.Password = $null

    $jiraCredential = Get-JiraApiCredentialPlain
    if (-not $jiraCredential) {
        [System.Windows.Forms.MessageBox]::Show('Не настроен Jira API credential. Нажми «Настроить Jira» на вкладке Jira Task.','Rx2GO QA — Jira Queue','OK','Warning') | Out-Null
        return $false
    }
    $jiraCredential.Token = $null

    $admWaiting = @($script:QueueItems | Where-Object { $_.Status -eq 'WAITING' -and $_.Environment -eq 'ADM' }).Count -gt 0
    if ($admWaiting -and [string]::IsNullOrWhiteSpace([string]$dailyPassword.Text)) {
        [System.Windows.Forms.MessageBox]::Show('В очереди есть ADM-задачи. Введи суточный пароль ADM на вкладке «Быстрый запуск».','Rx2GO QA — Jira Queue','OK','Warning') | Out-Null
        return $false
    }

    $queueStatusLabel.Text = 'Preflight: проверяю Playwright dependencies…'
    [System.Windows.Forms.Application]::DoEvents()
    if (-not (Ensure-PlaywrightDependencies)) {
        [System.Windows.Forms.MessageBox]::Show("Playwright precheck не прошёл:`r`n$($script:LastAgentError)",'Rx2GO QA — Jira Queue','OK','Error') | Out-Null
        return $false
    }

    if (-not (Ensure-PlaywrightMcpForCodex)) {
        [System.Windows.Forms.MessageBox]::Show("Playwright MCP не готов:`r`n$($script:LastAgentError)",'Rx2GO QA — Jira Queue','OK','Error') | Out-Null
        return $false
    }

    Update-LayoutHealth
    if ($layoutHealthLabel -and $layoutHealthLabel.Tag) {
        Write-QueueLog 'UI layout health warning detected before queue start. Queue tab uses managed Dock/TableLayout controls; see header UI status for details.'
    }

    return $true
}

function Start-JiraQueue {
    if ($script:QueueRunning -and -not $script:QueuePaused) { return }
    if (-not (Test-QueuePreflight)) { return }

    $script:QueueMaxParallel = [Math]::Max(1,[Math]::Min(3,[int]$queueParallelNumeric.Value))
    $script:QueueRunning = $true
    $script:QueuePaused = $false
    $queueStatusLabel.Text = "Очередь запущена • максимум $($script:QueueMaxParallel) Worker(s)"
    $queueStatusLabel.ForeColor = [System.Drawing.Color]::FromArgb(32,120,72)
    $runButton.Enabled = $false
    $jiraRunButton.Enabled = $false
    Write-QueueLog "QUEUE START → parallel=$($script:QueueMaxParallel)"
    Save-QueueState
    $script:QueueTimer.Start()
    Process-QueueTick
}

function Pause-JiraQueue {
    if (-not $script:QueueRunning) { return }
    $script:QueuePaused = $true
    $queueStatusLabel.Text = 'PAUSED — выполняющиеся Workers продолжат работу; новые не запускаются.'
    $queueStatusLabel.ForeColor = [System.Drawing.Color]::FromArgb(161,98,7)
    Write-QueueLog 'QUEUE PAUSE'
    Save-QueueState
}

function Resume-JiraQueue {
    if (-not $script:QueueRunning) {
        Start-JiraQueue
        return
    }
    $script:QueuePaused = $false
    $script:QueueUsageLimitWarningShown = $false
    $queueStatusLabel.Text = "RUNNING — максимум $($script:QueueMaxParallel) Worker(s)"
    $queueStatusLabel.ForeColor = [System.Drawing.Color]::FromArgb(32,120,72)
    Write-QueueLog 'QUEUE RESUME'
    Process-QueueTick
    Save-QueueState
}

function Process-QueueTick {
    if ($script:QueueWorkerMode -or -not $script:QueueRunning) { return }

    # 1) Poll running workers and finalize only after the worker process exits.
    foreach ($item in @($script:QueueItems)) {
        if ($item.Status -notin @('STARTING','ANALYZING','TESTING','REVIEWING','PLAYWRIGHT','RCA')) { continue }

        $workerStatus = Read-QueueWorkerStatus -Item $item
        if ($workerStatus) {
            if (-not [bool]$workerStatus.final) {
                $phase = ([string]$workerStatus.phase).ToUpperInvariant()
                if ($phase -in @('STARTING','ANALYZING','TESTING','REVIEWING','PLAYWRIGHT','RCA')) {
                    $item.Status = $phase
                }
                if ($workerStatus.detail) { $item.Details = [string]$workerStatus.detail }
            }
        }

        $processExited = $false
        if ($item.Process) {
            try { $processExited = $item.Process.HasExited } catch { $processExited = $true }
        }
        elseif ($item.Pid -gt 0) {
            try { $null = Get-Process -Id $item.Pid -ErrorAction Stop; $processExited = $false } catch { $processExited = $true }
        }

        if ($workerStatus -and [bool]$workerStatus.final -and $processExited) {
            Finalize-QueueWorkerItem -Item $item -WorkerStatus $workerStatus
        }
        elseif ($processExited -and (-not $workerStatus -or -not [bool]$workerStatus.final)) {
            $item.Status = 'ERROR'
            $item.Result = 'ERROR'
            $item.Details = 'Worker process завершился без финального status.json. Открой логи Worker.'
            $item.FinishedAt = Get-Date
            $item.Process = $null
            $item.Pid = 0
            $item.WorkerSlot = 0
            Write-QueueLog "ERROR $($item.Key) → worker exited without final status"
            Save-QueueState
        }
    }

    # 2) Start new workers up to the configured cap.
    if (-not $script:QueuePaused) {
        while ($true) {
            $active = @($script:QueueItems | Where-Object { $_.Status -in @('STARTING','ANALYZING','TESTING','REVIEWING','PLAYWRIGHT','RCA') }).Count
            if ($active -ge $script:QueueMaxParallel) { break }

            $next = @($script:QueueItems | Where-Object { $_.Status -eq 'WAITING' } | Select-Object -First 1)[0]
            if (-not $next) { break }

            $slot = Get-FreeQueueWorkerSlot
            if ($slot -le 0) { break }
            [void](Start-QueueWorker -Item $next -Slot $slot)
        }
    }

    Refresh-QueueGrid

    $waitingCount = @($script:QueueItems | Where-Object { $_.Status -eq 'WAITING' }).Count
    $activeCount = @($script:QueueItems | Where-Object { $_.Status -in @('STARTING','ANALYZING','TESTING','REVIEWING','PLAYWRIGHT','RCA','SYNCING') }).Count

    if ($waitingCount -eq 0 -and $activeCount -eq 0) {
        $script:QueueRunning = $false
        $script:QueuePaused = $false
        $script:QueueTimer.Stop()
        $queueStatusLabel.Text = 'Очередь завершена.'
        $queueStatusLabel.ForeColor = [System.Drawing.Color]::FromArgb(32,120,72)
        $runButton.Enabled = $true
        $jiraRunButton.Enabled = $true
        Write-QueueLog 'QUEUE COMPLETE'
        Save-QueueState
    }
}

function Open-SelectedQueueLogs {
    $item = Get-SelectedQueueItem
    if (-not $item) { return }

    $path = if ($item.WorkerDir -and (Test-Path $item.WorkerDir)) { $item.WorkerDir }
            elseif ($item.StatusFile -and (Test-Path (Split-Path $item.StatusFile -Parent))) { Split-Path $item.StatusFile -Parent }
            else { $script:QueueRoot }

    if (Test-Path $path) { Start-Process explorer.exe $path }
}


function Test-QueueEngineSelfTest {
    try {
        $keys = @(Get-QueueTaskKeysFromText 'SCRUM-1, https://x/browse/SCRUM-2 SCRUM-1')

        if ($keys.Count -ne 2) { return $false }
        if ($keys[0] -ne 'SCRUM-1' -or $keys[1] -ne 'SCRUM-2') { return $false }
        if ([Math]::Max(1,[Math]::Min(3,5)) -ne 3) { return $false }

        # Regression guard for v0.12.26 / Windows PowerShell 5.1.
        if ($script:QueueItems -isnot [System.Collections.ArrayList]) {
            return $false
        }

        $snapshot = @($script:QueueItems)
        if ($null -eq $snapshot) { return $false }

        $probe = New-Object System.Collections.ArrayList
        [void]$probe.Add([pscustomobject]@{ Status='WAITING'; Result='' })

        $probeSnapshot = @($probe)
        if ($probeSnapshot.Count -ne 1) { return $false }

        $waiting = @(
            $probeSnapshot |
                Where-Object { ([string]$_.Status).ToUpperInvariant() -eq 'WAITING' }
        ).Count

        if ($waiting -ne 1) { return $false }

        return $true
    }
    catch {
        Write-QueueLog "Queue engine self-test exception: $($_.Exception.Message)"
        return $false
    }
}

function Set-AgentStatus {
    param(
        [ValidateSet('JiraAnalyst','McpQaAgent','QAReviewer','FailureTriage','TestDesigner','UIAgent','ApiNetworkAgent')]
        [string]$Agent,
        [ValidateSet('WAIT','RUNNING','PASS','FAIL','BLOCKED')]
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
        'BLOCKED' { 'недостаточно данных' }
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
        'BLOCKED' { $label.ForeColor = [System.Drawing.Color]::FromArgb(197,119,0) }
    }

    if ($State -ne 'WAIT') {
        $detailText = if ($Details) { " — $Details" } else { '' }
        Append-AgentLog "$caption → $State$detailText"
    }

    Update-QueueWorkerPhaseFromAgent -Agent $Agent -State $State -Details $Details
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
    $script:LastKnowledgeRetrieval = $null
    $script:LastKnowledgeContext = ''
    $script:KnowledgeRemoteRef = $null
    $script:LastKnowledgeLearning = $null
    $script:LastKnowledgeLearningFile = $null
    $script:LastAutoGitSync = $null
    $script:SmartCoverageDesign = $null
    $script:TaskUnderstandingContract = $null
    $script:TaskUnderstandingGate = $null
    $script:KnowledgeReadWarningShown = $false
    $script:LastKnowledgeReadStatus = $null
    $script:LastKnowledgeWriteWarning = $null
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


function Test-CodexUsageLimitText {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }

    return (
        $Text -match '(?i)CODEX_USAGE_LIMIT' -or
        $Text -match '(?i)лимит\s+Codex' -or
        $Text -match "(?i)you'?ve hit your usage limit" -or
        $Text -match '(?i)usage limit' -or
        $Text -match '(?i)rate limit' -or
        $Text -match '(?i)quota.*(exceeded|reached|limit)' -or
        $Text -match '(?i)credits?.*(exhausted|depleted|limit|remaining\s*0)' -or
        $Text -match '(?i)too many requests' -or
        $Text -match '(?i)try again at\s+\d' -or
        $Text -match '(?i)limit.*reset'
    )
}

function Get-CodexUsageLimitRetryHint {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }

    $m = [regex]::Match(
        $Text,
        '(?i)(try again at[^\r\n\.]{1,80})'
    )

    if ($m.Success) {
        return $m.Groups[1].Value.Trim()
    }

    return ''
}

function Get-CodexFailureUserMessage {
    param(
        [string]$FailureKind,
        [string]$ErrorText
    )

    if ($FailureKind -eq 'CODEX_USAGE_LIMIT') {
        $retry = Get-CodexUsageLimitRetryHint -Text $ErrorText

        if ($retry) {
            return "Достигнут лимит Codex ($retry). Исходный результат проверки сохранён."
        }

        return 'Достигнут лимит Codex. Исходный результат проверки сохранён.'
    }

    if ($FailureKind -eq 'CODEX_TIMEOUT') {
        return 'Fixture Recovery не завершён: превышено время ожидания Codex. Исходный результат проверки сохранён.'
    }

    if ($FailureKind -eq 'CODEX_AUTH') {
        return 'Fixture Recovery не завершён: Codex требует повторной авторизации. Исходный результат проверки сохранён.'
    }

    if (-not [string]::IsNullOrWhiteSpace($ErrorText)) {
        return "Fixture Recovery технически прерван: $ErrorText"
    }

    return 'Fixture Recovery технически прерван. Исходный результат проверки сохранён.'
}

function Show-CodexUsageLimitWarning {
    param([string]$Message)

    if ([string]::IsNullOrWhiteSpace($Message)) { return }

    # Queue workers are hidden processes. Never show a modal dialog there,
    # otherwise a hidden worker could block forever. Parent queue shows it.
    if ($script:QueueWorkerMode) {
        return
    }

    [System.Windows.Forms.MessageBox]::Show(
        "$Message`r`n`r`nЭто не FAIL продукта. Проверку можно повторить после восстановления лимита.",
        'Rx2GO QA — Codex',
        'OK',
        'Warning'
    ) | Out-Null
}

function Get-CompactFixtureRecoveryContext {
    param(
        $Task,
        $InitialExecution,
        [string]$JiraText,
        [string]$QaComment,
        [string[]]$ProjectRules,
        [string]$KnowledgeContext,
        $CoverageDesign
    )

    $blockedAcceptance = @(
        @($InitialExecution.acceptanceResults) |
            Where-Object { ([string]$_.status).ToUpperInvariant() -eq 'BLOCKED' } |
            Select-Object -First 8
    )

    $blockedAdditional = @(
        @($InitialExecution.additionalResults) |
            Where-Object { ([string]$_.status).ToUpperInvariant() -in @('BLOCKED','SKIP') } |
            Select-Object -First 6
    )

    $compactInitial = [ordered]@{
        status = [string]$InitialExecution.status
        startUrl = [string]$InitialExecution.startUrl
        endUrl = [string]$InitialExecution.endUrl
        testData = $InitialExecution.testData
        blockers = @($InitialExecution.blockers | Select-Object -First 8)
        blockedAcceptance = $blockedAcceptance
        blockedAdditional = $blockedAdditional
    } | ConvertTo-Json -Depth 10 -Compress

    if ($compactInitial.Length -gt 8000) {
        $compactInitial = $compactInitial.Substring(0,8000) + '[TRUNCATED]'
    }

    $scope = Get-CurrentIterationScopeFromComments -JiraText $JiraText
    if ([string]::IsNullOrWhiteSpace($scope)) {
        $scope = @(
            "CURRENT: " + (@($Task.CurrentBehavior) -join ' | ')
            "EXPECTED: " + (@($Task.ExpectedBehavior) -join ' | ')
            "ACCEPTANCE: " + (@($Task.Criteria) -join ' | ')
        ) -join "`n"
    }

    if ($scope.Length -gt 5000) {
        $scope = $scope.Substring(0,5000) + '[TRUNCATED]'
    }

    $qa = [string]$QaComment
    if ($qa.Length -gt 1800) { $qa = $qa.Substring(0,1800) + '[TRUNCATED]' }

    $rules = (@($ProjectRules) | Select-Object -First 14) -join "`n- "
    if ($rules.Length -gt 3500) { $rules = $rules.Substring(0,3500) + '[TRUNCATED]' }

    $knowledge = [string]$KnowledgeContext
    if ($knowledge.Length -gt 4500) {
        $knowledge = $knowledge.Substring(0,4500) + '[TRUNCATED]'
    }

    $coverage = if ($CoverageDesign) {
        $highValue = @(
            @($CoverageDesign.checks) |
                Where-Object { ([string]$_.priority).ToUpperInvariant() -in @('P0','P1') } |
                Select-Object -First 8
        )

        [ordered]@{
            strategy = [string]$CoverageDesign.strategy
            checks = $highValue
            skippedIdeas = @($CoverageDesign.skippedIdeas | Select-Object -First 3)
        } | ConvertTo-Json -Depth 8 -Compress
    }
    else {
        '{"strategy":"live risk-based recovery","checks":[]}'
    }

    if ($coverage.Length -gt 3500) {
        $coverage = $coverage.Substring(0,3500) + '[TRUNCATED]'
    }

    return [pscustomobject]@{
        Scope = $scope
        QaComment = $qa
        ProjectRules = $rules
        Knowledge = $knowledge
        Coverage = $coverage
        InitialBlocked = $compactInitial
    }
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
    $script:LastAgentFailureKind = $null

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

            # Important v0.12.30 recovery pass:
            # `codex exec -o <file>` can flush the final answer only while the
            # wrapper/MCP process is terminating. Therefore a valid final JSON
            # may appear AFTER the pre-kill timeout recovery window.
            if (
                -not $recoveredRaw -and
                $AgentSlug -eq '02-playwright-mcp-qa'
            ) {
                $postKillDeadline = [DateTime]::UtcNow.AddSeconds(8)

                while (
                    [DateTime]::UtcNow -lt $postKillDeadline -and
                    -not $recoveredRaw
                ) {
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
                    try {
                        [System.Windows.Forms.Application]::DoEvents()
                    }
                    catch { }
                }
            }

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

                Append-AgentLog "RECOVERED $AgentSlug → $recoveredStatus | valid final JSON accepted after wrapper timeout"
                return $recoveredRaw
            }

            $script:LastAgentFailureKind = 'CODEX_TIMEOUT'
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
            $combinedFailureText = (
                ([string]$stderr) + "`n" +
                ([string]$stdout)
            )

            if (Test-CodexUsageLimitText -Text $combinedFailureText) {
                $script:LastAgentFailureKind = 'CODEX_USAGE_LIMIT'
                $retryHint = Get-CodexUsageLimitRetryHint -Text $combinedFailureText

                $script:LastAgentError = if ($retryHint) {
                    "${AgentSlug}: Codex usage limit reached; $retryHint"
                }
                else {
                    "${AgentSlug}: Codex usage limit reached"
                }
            }
            elseif ($stderr -match 'input is not valid UTF-8') {
                $script:LastAgentFailureKind = 'CODEX_INPUT'
                $script:LastAgentError = "${AgentSlug}: Codex rejected UTF-8 input"
            }
            elseif ($stderr -match '(?i)not logged in|authentication|login required') {
                $script:LastAgentFailureKind = 'CODEX_AUTH'
                $script:LastAgentError = "${AgentSlug}: Codex authentication is required"
            }
            else {
                $script:LastAgentFailureKind = 'CODEX_EXIT'
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
        $script:LastAgentFailureKind = 'CODEX_EXCEPTION'
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




function Get-SharedAdmDailyPassword {
    if (
        $knowledgeAdmDailyPasswordBox -and
        -not [string]::IsNullOrWhiteSpace([string]$knowledgeAdmDailyPasswordBox.Text)
    ) {
        return [string]$knowledgeAdmDailyPasswordBox.Text
    }

    if (
        $dailyPassword -and
        -not [string]::IsNullOrWhiteSpace([string]$dailyPassword.Text)
    ) {
        return [string]$dailyPassword.Text
    }

    return ''
}


function Sync-AdmDailyPasswordFields {
    param(
        [string]$Source,
        [string]$Value
    )

    $value = [string]$Value

    if (
        $Source -ne 'Knowledge' -and
        $knowledgeAdmDailyPasswordBox -and
        [string]$knowledgeAdmDailyPasswordBox.Text -ne $value
    ) {
        $knowledgeAdmDailyPasswordBox.Text = $value
    }

    if (
        $Source -ne 'QuickRun' -and
        $dailyPassword -and
        [string]$dailyPassword.Text -ne $value
    ) {
        $dailyPassword.Text = $value
    }
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

    $admDailyPassword = Get-SharedAdmDailyPassword

    if ((Test-GatewayRequired $Environment) -and
        [string]::IsNullOrWhiteSpace([string]$admDailyPassword)) {

        $credential.Password = $null
        $script:LastAgentError = 'ADM: не указан суточный пароль из Telegram. Введи его прямо в Knowledge Explorer или на Quick Run.'
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
        $psi.EnvironmentVariables['RX2GO_DAILY_PASSWORD'] = [string]$admDailyPassword
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

    $admDailyPassword = Get-SharedAdmDailyPassword

    if ((Test-GatewayRequired $environment) -and
        [string]::IsNullOrWhiteSpace([string]$admDailyPassword)) {

        $script:LastAgentError = 'ADM: не указан суточный пароль из Telegram. Введи его прямо в Knowledge Explorer или на Quick Run.'
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
        $psi.EnvironmentVariables['RX2GO_DAILY_PASSWORD'] = [string]$admDailyPassword
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


function Get-KnowledgeRetrievalCategory {
    param([string]$Path)

    $normalized = ([string]$Path).Replace('\','/').ToLowerInvariant()

    if ($normalized.StartsWith('jira-cases/')) { return 'JiraCase' }
    if ($normalized.StartsWith('scenarios/')) { return 'Scenario' }
    if ($normalized.StartsWith('tests/')) { return 'Test' }
    if ($normalized.StartsWith('knowledge/')) { return 'Knowledge' }
    if ($normalized.StartsWith('pages/') -or $normalized.StartsWith('api/')) { return 'Helper' }

    return 'Other'
}

function Test-KnowledgeRetrievalPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }

    $normalized = $Path.Replace('\','/').ToLowerInvariant()

    if (
        $normalized.StartsWith('.git/') -or
        $normalized.StartsWith('node_modules/') -or
        $normalized.StartsWith('reports/') -or
        $normalized.StartsWith('jira-runs/') -or
        $normalized.StartsWith('.qa-state/') -or
        $normalized.StartsWith('.secrets/') -or
        $normalized -match '(^|/)(secrets?|credentials?|cookies?|tokens?)(/|$)'
    ) {
        return $false
    }

    $category = Get-KnowledgeRetrievalCategory -Path $normalized
    if ($category -eq 'Other') { return $false }

    $ext = [System.IO.Path]::GetExtension($normalized)
    return ($ext -in @('.md','.yaml','.yml','.json','.ts','.tsx'))
}

function Get-KnowledgeSearchTerms {
    param([string[]]$Texts)

    $stopWords = @(
        'this','that','with','from','into','when','then','than','will','should','must',
        'have','has','had','the','and','for','are','was','were','not','but','can',
        'page','task','test','testing','check','expected','actual','current',
        'это','как','для','при','что','или','если','после','перед','нужно','должен',
        'должна','должно','проверить','тест','тестирование','задача','страница',
        'сейчас','ожидаемо','описание','текущее','поведение','кнопка','данные'
    )

    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($textValue in @($Texts)) {
        if ([string]::IsNullOrWhiteSpace([string]$textValue)) { continue }

        $matches = [regex]::Matches(
            ([string]$textValue).ToLowerInvariant(),
            '[a-zа-яё0-9][a-zа-яё0-9_-]{2,}'
        )

        foreach ($match in $matches) {
            $token = [string]$match.Value

            if ($token.Length -lt 3) { continue }
            if ($stopWords -contains $token) { continue }
            if ($token -match '^\d{7,}$') { continue }

            [void]$set.Add($token)

            # Add lightweight normalized domain variants to improve cross-case recall.
            if ($token -match '^tickets?$') { [void]$set.Add('ticket') }
            if ($token -match '^orders?$') { [void]$set.Add('order') }
            if ($token -match '^related') { [void]$set.Add('related') }
            if ($token -match '^refresh') { [void]$set.Add('refresh') }
            if ($token -match '^scanner') { [void]$set.Add('scanner') }
            if ($token -match '^dispatcher') { [void]$set.Add('dispatcher') }
        }
    }

    return @($set | Select-Object -First 90)
}


function Update-KnowledgeRemoteSnapshot {
    $result = [ordered]@{
        Success = $false
        RemoteRef = $null
        Message = 'LOCAL ONLY'
    }

    if ($script:QueueWorkerMode) {
        $result.Message = 'QUEUE WORKER LOCAL SNAPSHOT'
        return [pscustomobject]$result
    }

    if (-not (Test-GitInstalled)) {
        return [pscustomobject]$result
    }

    Initialize-KnowledgeGit -Silent

    $git = Get-GitState
    if (-not $git.Repository -or $git.Remote -eq 'не настроен') {
        return [pscustomobject]$result
    }

    if (([string]$git.Remote) -match '^https?://') {
        [void](Set-KnowledgeOriginToSsh)
        $git = Get-GitState
    }

    if (([string]$git.Remote) -notmatch '^git@github\.com:') {
        $result.Message = 'REMOTE MEMORY SKIPPED: origin is not SSH'
        return [pscustomobject]$result
    }

    $privateKey = Get-GitHubSshPrivateKeyPath

    if (-not (Test-Path $privateKey)) {
        $result.Message = 'REMOTE MEMORY SKIPPED: SSH key is not configured'
        return [pscustomobject]$result
    }

    # Invoke-SshGitHubAuthCheck uses BatchMode=yes, so no browser/password UI.
    $sshCheck = Invoke-SshGitHubAuthCheck

    if (-not $sshCheck.Success) {
        $result.Message = 'REMOTE MEMORY SKIPPED: SSH authentication is not ready'
        return [pscustomobject]$result
    }

    $branch = [string]$git.Branch
    if ([string]::IsNullOrWhiteSpace($branch) -or $branch -eq 'detached') {
        $branch = 'main'
    }

    $remoteBranch = Invoke-Git `
        @('ls-remote','--exit-code','--heads','origin',$branch) `
        15000

    if ($remoteBranch.ExitCode -ne 0) {
        $result.Message = "REMOTE BRANCH NOT AVAILABLE: origin/$branch"
        return [pscustomobject]$result
    }

    $fetch = Invoke-Git @(
        'fetch','--quiet','origin',$branch
    ) 45000

    if ($fetch.ExitCode -ne 0) {
        $result.Message = "REMOTE FETCH FAILED: $($fetch.Error)"
        return [pscustomobject]$result
    }

    $remoteRef = "origin/$branch"
    $verify = Invoke-Git @(
        'rev-parse','--verify',$remoteRef
    ) 10000

    if ($verify.ExitCode -ne 0) {
        $verifyFetchHead = Invoke-Git @(
            'rev-parse','--verify','FETCH_HEAD'
        ) 10000

        if ($verifyFetchHead.ExitCode -eq 0) {
            $remoteRef = 'FETCH_HEAD'
        }
        else {
            $result.Message = 'REMOTE FETCHED BUT REF NOT RESOLVED'
            return [pscustomobject]$result
        }
    }

    $script:KnowledgeRemoteRef = $remoteRef
    $result.Success = $true
    $result.RemoteRef = $remoteRef
    $result.Message = "REMOTE SNAPSHOT READY: $remoteRef"

    return [pscustomobject]$result
}


function Get-RemoteKnowledgePaths {
    param([string]$RemoteRef)

    if ([string]::IsNullOrWhiteSpace($RemoteRef)) { return @() }

    $tree = Invoke-Git @('ls-tree','-r','--name-only',$RemoteRef) 20000
    if ($tree.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($tree.Output)) {
        return @()
    }

    return @(
        $tree.Output -split "`r?`n" |
            Where-Object { Test-KnowledgeRetrievalPath -Path $_ } |
            Select-Object -Unique
    )
}

function Get-LocalKnowledgePaths {
    $roots = @('jira-cases','scenarios','tests','knowledge','pages','api')
    $paths = New-Object System.Collections.Generic.List[string]

    foreach ($rootName in $roots) {
        $fullRoot = Join-Path $script:ProjectRoot $rootName
        if (-not (Test-Path $fullRoot)) { continue }

        foreach ($file in @(Get-ChildItem -Path $fullRoot -File -Recurse -ErrorAction SilentlyContinue)) {
            $relative = $file.FullName.Substring($script:ProjectRoot.Length).TrimStart('\','/')
            $relative = $relative.Replace('\','/')

            if (Test-KnowledgeRetrievalPath -Path $relative) {
                $paths.Add($relative)
            }
        }
    }

    return @($paths | Select-Object -Unique)
}

function Read-KnowledgeRetrievalContent {
    param(
        [string]$Path,
        [string]$Source,
        [string]$RemoteRef
    )

    try {
        if ($Source -eq 'REMOTE' -and -not [string]::IsNullOrWhiteSpace($RemoteRef)) {
            $gitObject = $RemoteRef + ':' + $Path
            $show = Invoke-Git @('show',$gitObject) 15000

            if ($show.ExitCode -eq 0) {
                return [string]$show.Output
            }

            return ''
        }

        $full = Join-Path $script:ProjectRoot ($Path -replace '/', '\')
        if (-not (Test-Path $full)) { return '' }

        $file = Get-Item $full -ErrorAction Stop
        if ($file.Length -gt 250KB) { return '' }

        return [System.IO.File]::ReadAllText($full, [System.Text.Encoding]::UTF8)
    }
    catch {
        return ''
    }
}

function Get-KnowledgeSnippet {
    param(
        [string]$Content,
        [string[]]$Terms,
        [int]$MaxChars = 1800
    )

    if ([string]::IsNullOrWhiteSpace($Content)) { return '' }

    $clean = $Content.Trim()
    if ($clean.Length -le $MaxChars) { return $clean }

    $lower = $clean.ToLowerInvariant()
    $bestIndex = -1

    foreach ($term in @($Terms)) {
        if ([string]::IsNullOrWhiteSpace([string]$term)) { continue }

        $idx = $lower.IndexOf(([string]$term).ToLowerInvariant())
        if ($idx -ge 0 -and ($bestIndex -lt 0 -or $idx -lt $bestIndex)) {
            $bestIndex = $idx
        }
    }

    if ($bestIndex -lt 0) {
        return ($clean.Substring(0,$MaxChars) + "`n[TRUNCATED]")
    }

    $start = [Math]::Max(0, $bestIndex - 320)
    $length = [Math]::Min($MaxChars, $clean.Length - $start)

    return (
        $clean.Substring($start,$length) +
        $(if (($start + $length) -lt $clean.Length) { "`n[TRUNCATED]" } else { '' })
    )
}

function Get-KnowledgeCandidateScore {
    param(
        [string]$Path,
        [string]$Content,
        [string[]]$Terms,
        [string]$IssueKey,
        [string]$Module
    )

    $category = Get-KnowledgeRetrievalCategory -Path $Path
    $score = switch ($category) {
        'JiraCase'  { 14 }
        'Scenario'  { 12 }
        'Test'      { 10 }
        'Knowledge' { 8 }
        'Helper'    { 7 }
        default     { 0 }
    }

    $pathLower = ([string]$Path).ToLowerInvariant()
    $contentLower = ([string]$Content).ToLowerInvariant()

    $matched = 0
    foreach ($term in @($Terms)) {
        if ([string]::IsNullOrWhiteSpace([string]$term)) { continue }

        $needle = ([string]$term).ToLowerInvariant()

        if ($pathLower.Contains($needle)) {
            $score += 6
            $matched++
            continue
        }

        if ($contentLower.Contains($needle)) {
            $score += 2
            $matched++
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($IssueKey) -and $pathLower.Contains($IssueKey.ToLowerInvariant())) {
        $score += 20
    }

    if (-not [string]::IsNullOrWhiteSpace($Module)) {
        $moduleLower = $Module.ToLowerInvariant()

        if ($pathLower.Contains($moduleLower)) { $score += 12 }
        elseif ($contentLower.Contains($moduleLower)) { $score += 8 }
    }

    if ($matched -eq 0 -and $category -notin @('Knowledge','Helper')) {
        return 0
    }

    return $score
}


function Get-CurrentKnowledgeEnvironment {
    if (
        $script:QueueWorkerMode -and
        -not [string]::IsNullOrWhiteSpace([string]$script:QueueWorkerEnvironment)
    ) {
        return ([string]$script:QueueWorkerEnvironment).ToUpperInvariant()
    }

    if (
        $jiraEnvironmentCombo -and
        -not [string]::IsNullOrWhiteSpace([string]$jiraEnvironmentCombo.SelectedItem)
    ) {
        return ([string]$jiraEnvironmentCombo.SelectedItem).ToUpperInvariant()
    }

    return 'ADM'
}


function Test-KnowledgeExplorerPathAllowedForEnvironment {
    param(
        [string]$Path,
        [string]$Environment
    )

    $normalized = ([string]$Path).Replace('\','/').ToLowerInvariant()

    if ($normalized -notmatch '(^|/)knowledge/explorer/') {
        return $true
    }

    # Explorer policies/readme/index are neutral metadata.
    if (
        $normalized -match '/knowledge/explorer/(readme\.md|index\.json)$' -or
        $normalized -match '/knowledge/knowledge-explorer-policy\.yaml$'
    ) {
        return $true
    }

    $environment = ([string]$Environment).ToUpperInvariant()

    switch ($environment) {
        'ADM' {
            return (
                $normalized -match '/knowledge/explorer/adm/' -and
                $normalized -notmatch '/knowledge/explorer/(hot|branch)/'
            )
        }
        'HOT' {
            return (
                $normalized -match '/knowledge/explorer/(adm|hot)/' -or
                # v0.12.34 legacy files were HOT observations.
                $normalized -match '/knowledge/explorer/(modules|workflows)/'
            )
        }
        'BRANCH' {
            return (
                $normalized -match '/knowledge/explorer/(adm|hot|branch)/' -or
                $normalized -match '/knowledge/explorer/(modules|workflows)/'
            )
        }
        default {
            return $false
        }
    }
}


function Get-KnowledgeExplorerEnvironmentScoreBoost {
    param(
        [string]$Path,
        [string]$Environment
    )

    $normalized = ([string]$Path).Replace('\','/').ToLowerInvariant()
    $environment = ([string]$Environment).ToUpperInvariant()

    if ($environment -eq 'ADM') {
        if ($normalized -match '/knowledge/explorer/adm/') { return 18 }
        return 0
    }

    if ($environment -eq 'HOT') {
        if ($normalized -match '/knowledge/explorer/hot/') { return 24 }
        if ($normalized -match '/knowledge/explorer/(modules|workflows)/') { return 20 }
        if ($normalized -match '/knowledge/explorer/adm/') { return 12 }
        return 0
    }

    if ($environment -eq 'BRANCH') {
        if ($normalized -match '/knowledge/explorer/branch/') { return 30 }
        if ($normalized -match '/knowledge/explorer/hot/') { return 20 }
        if ($normalized -match '/knowledge/explorer/(modules|workflows)/') { return 18 }
        if ($normalized -match '/knowledge/explorer/adm/') { return 10 }
        return 0
    }

    return 0
}

function Get-RelevantKnowledgeContext {
    param(
        [string]$JiraText,
        [string]$QaComment,
        [string]$IssueKey,
        [string]$Module = '',
        [string]$Stage = 'task'
    )

    $terms = @(Get-KnowledgeSearchTerms -Texts @($JiraText,$QaComment,$IssueKey,$Module))
    $knowledgeEnvironment = Get-CurrentKnowledgeEnvironment
    $remote = Update-KnowledgeRemoteSnapshot
    $remoteRef = if ($remote.Success) { [string]$remote.RemoteRef } else { '' }

    $localPaths = @(Get-LocalKnowledgePaths)
    $remotePaths = if ($remote.Success) {
        @(Get-RemoteKnowledgePaths -RemoteRef $remoteRef)
    } else {
        @()
    }

    # Build one candidate per path.
    # Historical memory prefers the fetched GitHub copy; executable helpers/tests
    # prefer the current local workspace because it matches the running Launcher.
    $pathSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($path in @($remotePaths + $localPaths)) {
        if ($path) { [void]$pathSet.Add([string]$path) }
    }

    $items = New-Object System.Collections.Generic.List[object]

    foreach ($path in @($pathSet)) {
        if (
            -not (Test-KnowledgeExplorerPathAllowedForEnvironment `
                -Path ([string]$path) `
                -Environment $knowledgeEnvironment)
        ) {
            continue
        }

        $category = Get-KnowledgeRetrievalCategory -Path $path

        $hasRemote = $remotePaths -contains $path
        $hasLocal = $localPaths -contains $path

        $source = if (
            $hasRemote -and
            $category -in @('JiraCase','Scenario','Knowledge')
        ) {
            'REMOTE'
        }
        elseif ($hasLocal) {
            'LOCAL'
        }
        elseif ($hasRemote) {
            'REMOTE'
        }
        else {
            continue
        }

        $content = Read-KnowledgeRetrievalContent `
            -Path $path `
            -Source $source `
            -RemoteRef $remoteRef

        if ([string]::IsNullOrWhiteSpace($content)) { continue }

        $score = Get-KnowledgeCandidateScore `
            -Path $path `
            -Content $content `
            -Terms $terms `
            -IssueKey $IssueKey `
            -Module $Module

        $score += Get-KnowledgeExplorerEnvironmentScoreBoost `
            -Path ([string]$path) `
            -Environment $knowledgeEnvironment

        if ($score -le 0) { continue }

        $snippet = Get-KnowledgeSnippet `
            -Content $content `
            -Terms $terms `
            -MaxChars 1800

        $items.Add([pscustomobject]@{
            Path = [string]$path
            Category = [string]$category
            Source = [string]$source
            Score = [int]$score
            Snippet = [string]$snippet
        })
    }

    $limits = @{
        JiraCase = 5
        Scenario = 4
        Test = 6
        Knowledge = 6
        Helper = 6
    }

    $selected = New-Object System.Collections.Generic.List[object]

    foreach ($categoryName in @('JiraCase','Scenario','Test','Knowledge','Helper')) {
        $limit = [int]$limits[$categoryName]

        foreach ($item in @(
            $items |
                Where-Object { $_.Category -eq $categoryName } |
                Sort-Object Score -Descending |
                Select-Object -First $limit
        )) {
            $selected.Add($item)
        }
    }

    # Keep the final prompt bounded while preserving category diversity.
    $selected = @(
        $selected |
            Sort-Object Score -Descending |
            Select-Object -First 22
    )

    $contextLines = New-Object System.Collections.Generic.List[string]
    $contextLines.Add("KNOWLEDGE RETRIEVAL STAGE: $Stage")
    $contextLines.Add("CURRENT ENVIRONMENT: $knowledgeEnvironment")
    $contextLines.Add(
        "ENVIRONMENT KNOWLEDGE HIERARCHY: ADM=primary baseline; HOT=ADM+HOT delta; BRANCH=ADM+HOT+temporary BRANCH delta."
    )
    $contextLines.Add("REMOTE SNAPSHOT: $($remote.Message)")
    $contextLines.Add("MATCHED FILES: $($selected.Count)")
    $contextLines.Add('')

    if ($selected.Count -eq 0) {
        $contextLines.Add('No relevant previous knowledge was found. Do not invent memory.')
    }
    else {
        foreach ($item in $selected) {
            $contextLines.Add(
                "### [$($item.Category)] $($item.Path) | source=$($item.Source) | score=$($item.Score)"
            )
            $contextLines.Add([string]$item.Snippet)
            $contextLines.Add('')
        }
    }

    $context = ($contextLines -join "`n")

    $safeKey = if ([string]::IsNullOrWhiteSpace($IssueKey)) {
        'ADHOC'
    } else {
        ($IssueKey -replace '[^A-Za-z0-9_-]','_')
    }

    $dir = Join-Path $script:ProjectRoot "reports\knowledge-retrieval\$safeKey"
    New-Item -ItemType Directory -Path $dir -Force | Out-Null

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmssfff'
    $txtPath = Join-Path $dir "$stamp-$Stage.txt"
    $jsonPath = Join-Path $dir "$stamp-$Stage.json"

    Write-Utf8NoBomFile -Path $txtPath -Content $context

    $artifact = [pscustomobject]@{
        Stage = $Stage
        IssueKey = $IssueKey
        Module = $Module
        RemoteSnapshot = [string]$remote.Message
        RemoteRef = $remoteRef
        SearchTerms = @($terms)
        Count = $selected.Count
        Items = @($selected | ForEach-Object {
            [pscustomobject]@{
                Path = $_.Path
                Category = $_.Category
                Source = $_.Source
                Score = $_.Score
            }
        })
        Context = $context
        TextArtifact = $txtPath
        JsonArtifact = $jsonPath
    }

    $json = $artifact | ConvertTo-Json -Depth 8
    Write-Utf8NoBomFile -Path $jsonPath -Content $json

    return $artifact
}

function Get-KnowledgeMemoryPrompt {
    if (
        $script:LastKnowledgeRetrieval -and
        -not [string]::IsNullOrWhiteSpace([string]$script:LastKnowledgeRetrieval.Context)
    ) {
        return [string]$script:LastKnowledgeRetrieval.Context
    }

    return 'No relevant retrieved memory available.'
}

function Get-KnowledgeMemorySummary {
    if (-not $script:LastKnowledgeRetrieval) {
        return 'Knowledge retrieval: not available'
    }

    $count = [int]$script:LastKnowledgeRetrieval.Count
    $remote = [string]$script:LastKnowledgeRetrieval.RemoteSnapshot

    return "Knowledge retrieval: $count relevant file(s) | $remote"
}


function Test-TaskRequiresUsDateLocale {
    param([string]$JiraText, [string]$QaComment = '')

    $combined = "$JiraText`n$QaComment"

    return (
        $combined -match '(?i)MM/DD/YYYY' -or
        $combined -match '(?i)американск.{0,16}формат.{0,16}дат' -or
        $combined -match '(?i)american.{0,16}date.{0,16}format' -or
        $combined -match '(?i)american locale'
    )
}

function Get-CurrentIterationScopeFromComments {
    param([string]$JiraText)

    if ([string]::IsNullOrWhiteSpace($JiraText)) { return '' }

    $markers = @(
        'пока тестируем это',
        'пока проверяем это',
        'сейчас тестируем это',
        'работать над задачей будем частями',
        'test only these for now',
        'for now test'
    )

    $lower = $JiraText.ToLowerInvariant()
    $bestIndex = -1

    foreach ($marker in $markers) {
        $idx = $lower.LastIndexOf($marker)
        if ($idx -gt $bestIndex) { $bestIndex = $idx }
    }

    if ($bestIndex -lt 0) { return '' }

    $tail = $JiraText.Substring($bestIndex)
    if ($tail.Length -gt 5000) { $tail = $tail.Substring(0,5000) }

    return $tail
}

function Test-CrossJiraMarker {
    param([string]$Text, [string]$CurrentIssueKey)

    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }

    foreach ($match in [regex]::Matches($Text, '(?i)\bSCRUM-\d+\b')) {
        $key = ([string]$match.Value).ToUpperInvariant()

        if (
            -not [string]::IsNullOrWhiteSpace($CurrentIssueKey) -and
            $key -ne $CurrentIssueKey.ToUpperInvariant()
        ) {
            return $true
        }
    }

    return $false
}

function Test-McpCrossTaskDataSafety {
    param($Task, $McpExecution)

    if (-not $Task -or -not $McpExecution) {
        return [pscustomobject]@{ Success=$true; Error='' }
    }

    $parts = New-Object System.Collections.Generic.List[string]

    if ($McpExecution.testData) {
        $parts.Add(($McpExecution.testData | ConvertTo-Json -Compress -Depth 8))
    }

    foreach ($line in @(
        @($McpExecution.executedSteps) +
        @($McpExecution.acceptanceResults | ForEach-Object { $_.evidence })
    )) {
        if ([string]::IsNullOrWhiteSpace([string]$line)) { continue }

        $lineText = [string]$line

        if (
            $lineText -match '(?i)\bSCRUM-\d+\b' -and
            $lineText -notmatch '(?i)(не использ|did not use|not used|abandon|отклон|discard|ignored|не подходит)'
        ) {
            $parts.Add($lineText)
        }
    }

    $combined = $parts -join "`n"

    if (Test-CrossJiraMarker -Text $combined -CurrentIssueKey ([string]$Task.Key)) {
        return [pscustomobject]@{
            Success=$false
            Error="Smart QA used test data/evidence marked for another Jira task. Current task is $($Task.Key)."
        }
    }

    return [pscustomobject]@{ Success=$true; Error='' }
}


function Test-McpResultIntegrity {
    param(
        $Task,
        $McpExecution
    )

    $errors = New-Object System.Collections.Generic.List[string]

    if (-not $Task) {
        $errors.Add('Current Jira task is missing.')
    }

    if (-not $McpExecution) {
        $errors.Add('Smart QA execution result is missing.')
        return [pscustomobject]@{
            Success = $false
            Error = ($errors -join ' | ')
        }
    }

    $status = ([string]$McpExecution.status).ToUpperInvariant()
    $results = @($McpExecution.acceptanceResults)
    $additionalResults = @($McpExecution.additionalResults | Where-Object { $_ })
    $impactingAdditional = @(
        $additionalResults |
            Where-Object { [bool]$_.affectsOverallResult }
    )
    $blockers = @($McpExecution.blockers | Where-Object { $_ })

    # Task-understanding contract verification is mandatory for analyzed Jira tasks.
    if ($Task -and -not [string]::IsNullOrWhiteSpace([string]$Task.ContractId)) {
        if (-not $McpExecution.understanding) { $errors.Add('Missing task-understanding confirmation.') }
        else {
            if ([string]$McpExecution.understanding.contractId -ne [string]$Task.ContractId) { $errors.Add('Smart QA used a different Task Understanding Contract.') }
            if (-not [bool]$McpExecution.understanding.contractAccepted) { $errors.Add('Smart QA did not accept the locked task contract.') }
            if (-not [bool]$McpExecution.understanding.outOfScopeRespected) { $errors.Add('Smart QA allowed out-of-scope behavior to affect this run.') }
            if (-not [bool]$McpExecution.understanding.qaCommentKeptAsGuidance) { $errors.Add('QA comment was treated as a product requirement.') }
            if (-not [bool]$McpExecution.understanding.memoryKeptAdvisory) { $errors.Add('Knowledge memory was treated as a current requirement.') }
        }
        if (-not $McpExecution.contextVerification) { $errors.Add('Missing live context verification.') }
        else {
            if (-not [bool]$McpExecution.contextVerification.contextReady) { $errors.Add('Live browser context was not ready before testing.') }
            if (-not [bool]$McpExecution.contextVerification.environmentVerified) { $errors.Add('Environment was not verified live.') }
            if (-not [bool]$McpExecution.contextVerification.moduleVerified) { $errors.Add('Task module was not verified live.') }
            if (-not [bool]$McpExecution.contextVerification.requiredBusinessContextVerified) { $errors.Add('Required facility/client/service/business context was not verified live.') }
            if (@($McpExecution.contextVerification.unverifiedAssumptions | Where-Object { $_ }).Count -gt 0) { $errors.Add('Smart QA returned a verdict with unverified context assumptions.') }
        }
        $expectedIds = @(@($Task.AcceptanceMatrix | Where-Object { $_ }) | ForEach-Object { ([string]$_.id).ToUpperInvariant() })
        if ($expectedIds.Count -gt 0) {
            $returnedIds = @($results | ForEach-Object { ([string]$_.criterionId).ToUpperInvariant() })
            foreach ($expectedId in $expectedIds) { $count=@($returnedIds | Where-Object { $_ -eq $expectedId }).Count; if($count -ne 1){$errors.Add("Acceptance $expectedId must be returned exactly once; received $count.")} }
            foreach ($returnedId in $returnedIds) { if([string]::IsNullOrWhiteSpace($returnedId)){$errors.Add('Acceptance result is missing criterionId.')} elseif($expectedIds -notcontains $returnedId){$errors.Add("Unknown acceptance criterionId returned: $returnedId.")} }
            $understandingIds=@(@($McpExecution.understanding.acceptanceIds | Where-Object { $_ }) | ForEach-Object { ([string]$_).ToUpperInvariant() })
            foreach($expectedId in $expectedIds){if($understandingIds -notcontains $expectedId){$errors.Add("Understanding self-check omitted $expectedId.")}}
        }
    }

    # A machine-readable self-audit is mandatory for every live Smart QA result.
    if (-not $McpExecution.integrity) {
        $errors.Add('Missing integrity self-audit.')
    }
    else {
        if (-not [bool]$McpExecution.integrity.liveCurrentRunEvidence) {
            $errors.Add('Result is not based exclusively on current live-run evidence.')
        }

        if (-not [bool]$McpExecution.integrity.currentScopeOnly) {
            $errors.Add('Result includes checks outside the current Jira execution scope.')
        }

        if (-not [bool]$McpExecution.integrity.testDataIsolated) {
            $errors.Add('Test data isolation was not confirmed.')
        }

        if ([bool]$McpExecution.integrity.historicalEvidenceUsedAsVerdict) {
            $errors.Add('Historical Jira/memory evidence was used as the current verdict.')
        }

        if (-not [bool]$McpExecution.integrity.environmentAssumptionsVerified) {
            $errors.Add('Environment/browser/native-control assumptions were not verified.')
        }
    }

    if ($McpExecution.testData) {
        $hasEntities = (@($McpExecution.testData.entities).Count -gt 0)
        $created = [bool]$McpExecution.testData.created

        if (($hasEntities -or $created) -and -not [bool]$McpExecution.testData.currentTaskVerified) {
            $errors.Add('Used test data was not verified for the current Jira task.')
        }
    }

    if ($status -in @('PASS','FAIL')) {
        if ($results.Count -eq 0) {
            $errors.Add("$status has no acceptanceResults.")
        }

        foreach ($result in $results) {
            $criterionStatus = ([string]$result.status).ToUpperInvariant()
            $evidence = [string]$result.evidence

            if ($criterionStatus -in @('PASS','FAIL')) {
                if ([string]::IsNullOrWhiteSpace($evidence) -or $evidence.Trim().Length -lt 8) {
                    $errors.Add("Acceptance '$($result.criterion)' has insufficient current-run evidence.")
                }
            }
        }
    }

    foreach ($extra in $additionalResults) {
        $extraStatus = ([string]$extra.status).ToUpperInvariant()
        $extraEvidence = [string]$extra.evidence

        if ($extraStatus -in @('PASS','FAIL','BLOCKED','SKIP')) {
            if ([string]::IsNullOrWhiteSpace($extraEvidence)) {
                $errors.Add("Additional check '$($extra.case)' has no evidence/skip reason.")
            }
        }
        else {
            $errors.Add("Additional check '$($extra.case)' has invalid status '$extraStatus'.")
        }
    }

    $failedImpactingAdditional = @(
        $impactingAdditional |
            Where-Object { ([string]$_.status).ToUpperInvariant() -eq 'FAIL' }
    )

    $blockedImpactingAdditional = @(
        $impactingAdditional |
            Where-Object { ([string]$_.status).ToUpperInvariant() -eq 'BLOCKED' }
    )

    $failedCriteria = @(
        $results |
            Where-Object { ([string]$_.status).ToUpperInvariant() -eq 'FAIL' }
    )

    $blockedCriteria = @(
        $results |
            Where-Object { ([string]$_.status).ToUpperInvariant() -eq 'BLOCKED' }
    )

    if ($status -eq 'PASS') {
        if (
            $failedCriteria.Count -gt 0 -or
            $blockedCriteria.Count -gt 0 -or
            $failedImpactingAdditional.Count -gt 0 -or
            $blockedImpactingAdditional.Count -gt 0
        ) {
            $errors.Add('Overall PASS conflicts with failing/blocking acceptance or impacting additional result.')
        }

        if ($results.Count -gt 0) {
            $notPass = @(
                $results |
                    Where-Object { ([string]$_.status).ToUpperInvariant() -ne 'PASS' }
            )

            if ($notPass.Count -gt 0) {
                $errors.Add('Overall PASS requires every executed acceptance criterion to PASS.')
            }
        }
    }

    if ($status -eq 'FAIL') {
        if ($failedCriteria.Count -eq 0 -and $failedImpactingAdditional.Count -eq 0) {
            $errors.Add('Overall FAIL has no failed acceptance criterion or impacting additional regression/negative check.')
        }

        foreach ($failed in $failedCriteria) {
            if ([string]::IsNullOrWhiteSpace([string]$failed.evidence)) {
                $errors.Add("Failed acceptance '$($failed.criterion)' has no live evidence.")
            }
        }

        foreach ($failedExtra in $failedImpactingAdditional) {
            if ([string]::IsNullOrWhiteSpace([string]$failedExtra.evidence)) {
                $errors.Add("Failed additional check '$($failedExtra.case)' has no live evidence.")
            }
        }
    }

    if ($status -eq 'BLOCKED') {
        if ($blockers.Count -eq 0 -and $blockedCriteria.Count -eq 0) {
            $errors.Add('Overall BLOCKED has no blocker evidence.')
        }
    }

    # Historical words inside current evidence are not automatically wrong,
    # but using history AS the verdict is forbidden and already machine-checked above.
    # Ambiguous language is not strong enough for a product FAIL.
    if ($status -eq 'FAIL') {
        foreach ($failed in $failedCriteria) {
            $evidence = ([string]$failed.evidence).ToLowerInvariant()

            if (
                $evidence -match '(вероятно|возможно|похоже|предполож|probably|possibly|seems|appears to)' -and
                $evidence -notmatch '(фактически|наблюдал|observed|actual|screenshot|network|console|dom|value=)'
            ) {
                $errors.Add("Failed acceptance '$($failed.criterion)' is based on ambiguous/inferred evidence.")
            }
        }
    }

    return [pscustomobject]@{
        Success = ($errors.Count -eq 0)
        Error = ($errors -join ' | ')
    }
}

function Test-SmartQaIntegrityGuardSelfTest {
    $task = [pscustomobject]@{
        Key = 'SCRUM-SELFTEST'
    }

    $good = [pscustomobject]@{
        status = 'PASS'
        acceptanceResults = @(
            [pscustomobject]@{
                criterion = 'current criterion'
                status = 'PASS'
                evidence = 'Observed live browser state in current run.'
            }
        )
        blockers = @()
        testData = [pscustomobject]@{
            created = $false
            currentTaskVerified = $true
            entities = @()
        }
        integrity = [pscustomobject]@{
            liveCurrentRunEvidence = $true
            currentScopeOnly = $true
            testDataIsolated = $true
            historicalEvidenceUsedAsVerdict = $false
            environmentAssumptionsVerified = $true
        }
    }

    $badStatus = [pscustomobject]@{
        status = 'PASS'
        acceptanceResults = @(
            [pscustomobject]@{
                criterion = 'failed criterion'
                status = 'FAIL'
                evidence = 'Observed current failure.'
            }
        )
        blockers = @()
        testData = [pscustomobject]@{
            created = $false
            currentTaskVerified = $true
            entities = @()
        }
        integrity = $good.integrity
    }

    $badHistory = [pscustomobject]@{
        status = 'FAIL'
        acceptanceResults = @(
            [pscustomobject]@{
                criterion = 'criterion'
                status = 'FAIL'
                evidence = 'Historical Jira screenshot only.'
            }
        )
        blockers = @()
        testData = [pscustomobject]@{
            created = $false
            currentTaskVerified = $true
            entities = @()
        }
        integrity = [pscustomobject]@{
            liveCurrentRunEvidence = $false
            currentScopeOnly = $true
            testDataIsolated = $true
            historicalEvidenceUsedAsVerdict = $true
            environmentAssumptionsVerified = $true
        }
    }

    $goodResult = Test-McpResultIntegrity -Task $task -McpExecution $good
    $badStatusResult = Test-McpResultIntegrity -Task $task -McpExecution $badStatus
    $badHistoryResult = Test-McpResultIntegrity -Task $task -McpExecution $badHistory

    return (
        $goodResult.Success -and
        -not $badStatusResult.Success -and
        -not $badHistoryResult.Success
    )
}


function Convert-KnowledgeRemoteStatusToUserMessage {
    param([string]$Status)

    if ([string]::IsNullOrWhiteSpace($Status)) {
        return 'Причина не определена.'
    }

    if ($Status -match '^REMOTE SNAPSHOT READY') {
        return 'Актуальная Knowledge Base успешно получена из GitHub.'
    }

    if ($Status -match 'SSH key is not configured') {
        return 'SSH-ключ GitHub не настроен.'
    }

    if ($Status -match 'SSH authentication is not ready') {
        return 'GitHub SSH недоступен или публичный ключ ещё не добавлен в GitHub.'
    }

    if ($Status -match 'origin is not SSH') {
        return 'Git origin настроен не через SSH.'
    }

    if ($Status -match 'REMOTE BRANCH NOT AVAILABLE') {
        return 'Удалённая ветка Knowledge Base пока недоступна.'
    }

    if ($Status -match 'REMOTE FETCH FAILED') {
        return 'Не удалось получить свежие изменения Knowledge Base из GitHub.'
    }

    if ($Status -eq 'LOCAL ONLY') {
        return 'Удалённая Knowledge Base недоступна.'
    }

    return $Status
}

function Show-KnowledgeReadWarningOnce {
    param([string]$RemoteStatus)

    $script:LastKnowledgeReadStatus = $RemoteStatus

    if (
        [string]::IsNullOrWhiteSpace($RemoteStatus) -or
        $RemoteStatus -match '^REMOTE SNAPSHOT READY'
    ) {
        return
    }

    if ($script:KnowledgeReadWarningShown) {
        return
    }

    $script:KnowledgeReadWarningShown = $true
    $reason = Convert-KnowledgeRemoteStatusToUserMessage -Status $RemoteStatus

    Append-AgentLog "KNOWLEDGE READ → LOCAL FALLBACK | $reason"

    if ($script:QueueWorkerMode) {
        Write-QueueWorkerStatus -Status 'RUNNING' -Phase 'KNOWLEDGE' -Detail "Local Knowledge fallback: $reason"
        return
    }

    [System.Windows.Forms.MessageBox]::Show(
        "Не удалось получить актуальную базу знаний из GitHub.`r`n`r`nПричина: $reason`r`n`r`nТестирование продолжится с локальной Knowledge Base. Результат теста не будет подменён или остановлен из-за этой проблемы.",
        'Rx2GO QA — Knowledge Base',
        'OK',
        'Warning'
    ) | Out-Null
}

function Show-KnowledgeWriteWarningAfterRun {
    $messages = New-Object System.Collections.Generic.List[string]

    if (-not [string]::IsNullOrWhiteSpace([string]$script:LastKnowledgeWriteWarning)) {
        $messages.Add([string]$script:LastKnowledgeWriteWarning)
    }

    if (
        $script:LastAutoGitSync -and
        -not [string]::IsNullOrWhiteSpace([string]$script:LastAutoGitSync.Warning)
    ) {
        $messages.Add("GitHub sync: $($script:LastAutoGitSync.Warning)")
    }

    if ($messages.Count -eq 0) {
        return
    }

    $details = ($messages | Select-Object -Unique) -join "`r`n"

    Append-AgentLog "KNOWLEDGE WRITE → WARNING | $details"

    if ($script:QueueWorkerMode) {
        Write-QueueWorkerStatus -Status 'RUNNING' -Phase 'KNOWLEDGE' -Detail "Knowledge write warning: $details"
        return
    }

    [System.Windows.Forms.MessageBox]::Show(
        "Тест завершён, но база знаний обновлена не полностью.`r`n`r`n$details`r`n`r`nPASS/FAIL продукта не изменён. Локальные данные и commit, если он был создан, сохранены.",
        'Rx2GO QA — Knowledge Base',
        'OK',
        'Warning'
    ) | Out-Null
}

function Invoke-AgentJiraAnalyst {
    param(
        [string]$JiraText,
        [string]$QaComment,
        [string[]]$ProjectRules,
        [string]$KnowledgeContext = ''
    )

    Set-AgentStatus -Agent JiraAnalyst -State RUNNING -Details 'строю Task Understanding Contract'

    $prompt = @"
You are Agent 1 of the Rx2GO QA pipeline: SENIOR REQUIREMENTS ANALYST.

Your most important responsibility is to UNDERSTAND THE TASK CORRECTLY before any browser testing begins.
Do not design Playwright code and do not execute the product.

You receive sources with DIFFERENT authority:
1. Jira Description / Expected / Acceptance — product requirements.
2. Jira comments — may clarify or narrow the CURRENT iteration.
3. QA COMMENT — execution guidance, NOT automatically a product requirement.
4. Task screenshots — visual context, NOT automatically a requirement.
5. Project rules — execution constraints, NOT product requirements.
6. Knowledge memory — historical QA experience, NEVER a current requirement.

SOURCE PRECEDENCE:
- Current explicit Jira requirement > older Jira text > QA guidance > memory.
- A later Jira comment can narrow the scope of THIS run.
- QA COMMENT may define facility/test-data/workflow guidance but must not silently create acceptance criteria.
- Knowledge may suggest risks/workflows but must not change expected behavior.

Return ONLY valid JSON with this exact top-level shape:
{
  "title": "short task title",
  "module": "Tickets Queue|Chat|Scanner|Dispatcher|QAQC|Orders|Unknown",
  "taskGoal": "one precise sentence describing what product behavior is being changed or fixed",
  "primaryBusinessObject": "order|ticket|route|chat|scanner|other",
  "trigger": "what action/event starts the behavior being tested",
  "preconditions": ["business precondition"],
  "inScope": ["what THIS run must verify"],
  "outOfScope": ["explicitly excluded/umbrella areas not deciding THIS run"],
  "currentBehavior": ["current bug/actual behavior only"],
  "expectedBehavior": ["expected behavior only"],
  "expectedStateChanges": ["state/data changes that MUST happen"],
  "forbiddenStateChanges": ["state/data changes that MUST NOT happen"],
  "reproductionSteps": ["reproduction step"],
  "acceptanceCriteria": ["testable requirement"],
  "acceptanceMatrix": [
    {
      "id": "AC1",
      "requirement": "testable requirement",
      "sourceType": "DESCRIPTION|JIRA_COMMENT",
      "sourceQuote": "short source fragment that justifies this criterion",
      "precondition": "required starting state or N/A",
      "action": "user/system action",
      "expected": "observable expected result",
      "evidenceNeeded": ["UI|API|NETWORK|CONSOLE|DATA"]
    }
  ],
  "executionGuidance": ["QA-comment instruction that affects HOW to test but is not acceptance"],
  "constraints": ["project/environment/test-data constraint"],
  "riskAreas": ["directly related risk area"],
  "negativeRiskIdeas": ["direct negative case"],
  "boundaryRiskIdeas": ["boundary case"],
  "regressionRiskIdeas": ["direct adjacent regression"],
  "ambiguities": [
    {"severity": "LOW|MEDIUM|HIGH", "text": "what is ambiguous", "impact": "how it could change the verdict"}
  ],
  "contradictions": [
    {"text": "contradicting statements", "resolved": true, "resolution": "which source wins and why"}
  ],
  "clarificationsFromComments": ["meaningful Jira-comment clarification"],
  "scopeDecision": "how the latest Jira comments changed or did not change the current run scope",
  "confidence": 0,
  "selfAudit": {
    "currentBehaviorNotUsedAsAcceptance": true,
    "qaCommentNotUsedAsRequirement": true,
    "memoryNotUsedAsRequirement": true,
    "screenshotNotUsedAsRequirement": true,
    "latestScopeApplied": true,
    "noInventedRequirements": true
  }
}

TASK SCREENSHOTS:
$(Get-JiraScreenshotPromptSummary)

CURRENT ITERATION SCOPE EXTRACT FROM LATEST JIRA COMMENTS:
$(Get-CurrentIterationScopeFromComments -JiraText $JiraText)

JIRA SOURCE:
$JiraText

QA COMMENT:
$QaComment

RX2GO PROJECT RULES:
$($ProjectRules -join "`n- ")

RETRIEVED KNOWLEDGE MEMORY:
$KnowledgeContext

MANDATORY ANALYSIS RULES:
- "Сейчас", "Current", "Actual", "Текущее поведение" = CURRENT BUG/ACTUAL behavior, never Expected.
- "Ожидаемо", "Expected", "Критерий приёмки", "Acceptance Criteria", "Необходимо" = requirement.
- "Как воспроизвести" = reproduction, not requirement by itself.
- If a later Jira comment explicitly narrows testing, acceptanceCriteria and inScope must reflect THIS narrowed iteration.
- Keep umbrella functionality in outOfScope/risk only when it does not decide the current run.
- Every acceptanceMatrix item MUST trace to DESCRIPTION or JIRA_COMMENT through sourceType + short sourceQuote.
- QA COMMENT, PROJECT RULE, SCREENSHOT and MEMORY are forbidden as acceptanceMatrix sourceType.
- Split compound requirements into separately testable AC items when needed.
- acceptanceMatrix IDs must be AC1, AC2, AC3... with no gaps.
- For each AC clearly state precondition -> action -> expected -> evidenceNeeded.
- Identify both required state changes and forbidden side effects when relevant.
- Do not invent endpoint names, exact controls, values or rules absent from current Jira sources.
- If missing information could change PASS/FAIL, record an ambiguity. Use HIGH only when safe testing cannot determine the intended result.
- Resolve contradictions by source precedence when possible; otherwise leave resolved=false and reduce confidence.
- confidence is your confidence that another QA engineer can execute the intended CURRENT scope without guessing.
- Before returning JSON, perform selfAudit honestly.
"@

    $raw = Invoke-CodexAgent `
        -AgentSlug '01-jira-analyst' `
        -Prompt $prompt `
        -TimeoutSec 300 `
        -ReasoningEffort 'medium' `
        -ImagePaths (Get-JiraScreenshotPaths)

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
    $script:TaskUnderstandingContract = $parsed

    if ($script:AgentRunDir) {
        try {
            $contractArtifact = Join-Path $script:AgentRunDir 'task-understanding.json'
            Write-Utf8NoBomFile -Path $contractArtifact -Content ($parsed | ConvertTo-Json -Depth 14)
            Append-AgentLog "TASK UNDERSTANDING ARTIFACT -> $contractArtifact"
        }
        catch {
            Append-AgentLog "TASK UNDERSTANDING ARTIFACT warning -> $($_.Exception.Message)"
        }
    }

    Set-AgentStatus -Agent JiraAnalyst -State PASS -Details "confidence $([int]$parsed.confidence)%"
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
DATA MUTATION ALLOWED: YES — ALL QA TEST-DATA ACTIONS AUTHORIZED

TEST DATA MUTATION POLICY — GLOBAL RX2GO QA RULE:
- Mutation of TEST DATA is ALWAYS AUTHORIZED.
- For current-run or clearly identified QA/test entities you may create, edit, update, modify, save, submit, transition status, assign/unassign, link/unlink, remoderate, resolve/reopen, attach/detach, delete, recreate and clean up data whenever needed to complete the test.
- This applies to QA orders, tickets, routes/gigs and other fixtures created for testing, explicitly marked as test data, or explicitly identified by the current Jira task as test fixtures.
- Prefer fresh isolated current-Jira fixtures whenever provenance of an existing entity is unclear.
- NEVER mutate an unmarked pre-existing business/customer entity merely because it is visible in the environment.
- Historical IDs from Knowledge Retrieval are reference-only and are not mutation targets.
- If a required state can be produced safely by changing current-run QA data, do that before returning BLOCKED.
- Cleanup/deletion of current-run QA data is allowed when safe and when it does not destroy evidence required for the report.


RULES:
- Build checks that prove the acceptance criteria, not generic smoke.
- Honor the QA comment.
- All necessary actions on clearly identified QA/test data are authorized; never mutate unmarked business/customer data.
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
DATA MUTATION ALLOWED: YES — ALL QA TEST-DATA ACTIONS AUTHORIZED

TEST DATA MUTATION POLICY — GLOBAL RX2GO QA RULE:
- Mutation of TEST DATA is ALWAYS AUTHORIZED.
- For current-run or clearly identified QA/test entities you may create, edit, update, modify, save, submit, transition status, assign/unassign, link/unlink, remoderate, resolve/reopen, attach/detach, delete, recreate and clean up data whenever needed to complete the test.
- This applies to QA orders, tickets, routes/gigs and other fixtures created for testing, explicitly marked as test data, or explicitly identified by the current Jira task as test fixtures.
- Prefer fresh isolated current-Jira fixtures whenever provenance of an existing entity is unclear.
- NEVER mutate an unmarked pre-existing business/customer entity merely because it is visible in the environment.
- Historical IDs from Knowledge Retrieval are reference-only and are not mutation targets.
- If a required state can be produced safely by changing current-run QA data, do that before returning BLOCKED.
- Cleanup/deletion of current-run QA data is allowed when safe and when it does not destroy evidence required for the report.


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




function Get-SmartCoverageDesignJson {
    if (-not $script:SmartCoverageDesign) {
        return '{"strategy":"live risk-based coverage","checks":[],"skippedIdeas":[]}'
    }

    try {
        return ($script:SmartCoverageDesign | ConvertTo-Json -Depth 10 -Compress)
    }
    catch {
        return '{"strategy":"live risk-based coverage","checks":[],"skippedIdeas":[]}'
    }
}

function New-SmartCoveragePlanSummary {
    param($Coverage)

    if (-not $Coverage) {
        return "SMART RISK-BASED COVERAGE:`r`n- Coverage Designer недоступен; дополнительные проверки будут определены live MCP по текущему UI и рискам."
    }

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('SMART RISK-BASED COVERAGE:')

    if ($Coverage.strategy) {
        $lines.Add("Strategy: $($Coverage.strategy)")
    }

    $checks = @($Coverage.checks | Where-Object { $_ })

    if ($checks.Count -eq 0) {
        $lines.Add('- Нет заранее выделенных дополнительных кейсов; MCP обязан выполнить live risk assessment.')
    }
    else {
        $i = 1
        foreach ($check in @($checks | Select-Object -First 18)) {
            $type = if ($check.type) { [string]$check.type } else { 'CHECK' }
            $priority = if ($check.priority) { [string]$check.priority } else { 'P1' }
            $caseText = if ($check.case) { [string]$check.case } else { [string]$check }
            $lines.Add("$i. [$type/$priority] $caseText")
            $i++
        }
    }

    $skipped = @($Coverage.skippedIdeas | Where-Object { $_ })
    if ($skipped.Count -gt 0) {
        $lines.Add('DEFERRED / NOT SAFE:')
        foreach ($item in @($skipped | Select-Object -First 6)) {
            $lines.Add("- $([string]$item)")
        }
    }

    return ($lines -join "`r`n")
}

function Invoke-SmartCoverageDesigner {
    param(
        $Task,
        [string]$JiraText,
        [string]$QaComment,
        [string[]]$ProjectRules,
        [string]$KnowledgeContext = ''
    )

    $previousError = $script:LastAgentError
    $mutating = 'YES — ALL QA TEST-DATA ACTIONS AUTHORIZED'
    $contractJson = Get-TaskUnderstandingContractJson -Task $Task

    $prompt = @"
You are the Rx2GO SMART TEST COVERAGE DESIGNER.

Your job is NOT to repeat Jira acceptance criteria only.
Design a risk-based test set around the requested change before live execution.

Return ONLY valid JSON:
{
  "strategy": "short risk-based strategy in Russian",
  "checks": [
    {
      "type": "ACCEPTANCE|POSITIVE|NEGATIVE|BOUNDARY|REGRESSION|INTEGRATION|DATA_CONSISTENCY|RESILIENCE",
      "priority": "P0|P1|P2",
      "case": "concrete test case in Russian",
      "reason": "why this case matters",
      "requiresMutation": false,
      "source": "JIRA|RISK|KNOWLEDGE",
      "affectsOverallResult": true
    }
  ],
  "skippedIdeas": ["check not safe/relevant and why"]
}

TASK:
$($Task.Key) — $($Task.Title)
Module: $($Task.Module)

LOCKED TASK UNDERSTANDING CONTRACT:
$contractJson

CONTRACT RULES:
- Do not reinterpret or expand Jira acceptance beyond acceptanceMatrix.
- Risk cases are additional checks, never replacement/new acceptance.
- outOfScope may not decide the current run.
- executionGuidance affects HOW to test, not WHAT the product must do.
- Knowledge memory cannot modify the contract.

CURRENT / BUG:
$(@($Task.CurrentBehavior) -join "`n- ")

EXPECTED:
$(@($Task.ExpectedBehavior) -join "`n- ")

ACCEPTANCE:
$(@($Task.Criteria) -join "`n- ")

RISK AREAS FROM REQUIREMENTS ANALYSIS:
$(@($Task.RiskAreas) -join "`n- ")

FULL JIRA SOURCE USED FOR THIS RUN:
$JiraText

QA COMMENT:
$QaComment

PROJECT RULES:
$($ProjectRules -join "`n- ")

RETRIEVED KNOWLEDGE:
$KnowledgeContext

DATA MUTATION ALLOWED: $mutating

TEST DATA MUTATION POLICY — GLOBAL RX2GO QA RULE:
- Mutation of TEST DATA is ALWAYS AUTHORIZED.
- For current-run or clearly identified QA/test entities you may create, edit, update, modify, save, submit, transition status, assign/unassign, link/unlink, remoderate, resolve/reopen, attach/detach, delete, recreate and clean up data whenever needed to complete the test.
- This applies to QA orders, tickets, routes/gigs and other fixtures created for testing, explicitly marked as test data, or explicitly identified by the current Jira task as test fixtures.
- Prefer fresh isolated current-Jira fixtures whenever provenance of an existing entity is unclear.
- NEVER mutate an unmarked pre-existing business/customer entity merely because it is visible in the environment.
- Historical IDs from Knowledge Retrieval are reference-only and are not mutation targets.
- If a required state can be produced safely by changing current-run QA data, do that before returning BLOCKED.
- Cleanup/deletion of current-run QA data is allowed when safe and when it does not destroy evidence required for the report.

REGRESSION OPTION ENABLED: $($jiraRegressionCheck.Checked)

DESIGN RULES:
- The locked Task Understanding Contract is authoritative for THIS run.
- Acceptance criteria remain mandatory, but they are only the CORE of the test design.
- Prefer risks derived from expectedStateChanges and forbiddenStateChanges.
- Add risk-based checks beyond the literal Jira text when they are logically connected to the changed behavior.
- Consider, where relevant:
  1) positive/happy path;
  2) negative validation / forbidden action / invalid state;
  3) boundary and edge values;
  4) regression of directly adjacent or historically fragile behavior;
  5) integration/data consistency between UI and backend;
  6) reload/refresh/repeat-action/idempotency/state-persistence behavior;
  7) role/permission differences only when the current feature has such a risk.
- Use Knowledge Retrieval to recover previously known regressions, automation lessons and module behavior.
- Do NOT add random broad smoke tests from unrelated modules.
- If Jira comments narrow the current iteration scope, additional checks must remain inside that changed area or its immediate dependencies.
- P0/P1 checks in the impacted area may affect the overall result when they reveal a real regression caused by or directly adjacent to the change.
- P2 advisory exploration should normally not fail the Jira task unless it proves a critical impacted regression.
- Use any necessary QA test-data mutation to make relevant checks executable. Skip only when no safe current-run test-data path exists.
- Do not invent exact UI controls/endpoints absent from Jira/knowledge; describe the behavior to verify.
- Prefer a small number of high-value additional cases over a huge checklist.
- Unless genuinely not applicable, include at least one NEGATIVE and one REGRESSION idea.
"@

    $raw = Invoke-CodexAgent `
        -AgentSlug 'risk-coverage-designer' `
        -Prompt $prompt `
        -TimeoutSec 220 `
        -ReasoningEffort 'low'

    if (-not $raw) {
        Append-AgentLog 'SMART COVERAGE → Designer unavailable; MCP will derive additional negative/regression cases live.'
        $script:LastAgentError = $previousError

        return [pscustomobject]@{
            strategy = 'Live risk-based fallback'
            checks = @()
            skippedIdeas = @('Coverage Designer недоступен; дополнительные кейсы обязан определить live MCP.')
        }
    }

    $parsed = Convert-AgentJson $raw

    if (-not $parsed) {
        Append-AgentLog 'SMART COVERAGE → invalid Designer JSON; MCP will derive additional cases live.'
        $script:LastAgentError = $previousError

        return [pscustomobject]@{
            strategy = 'Live risk-based fallback'
            checks = @()
            skippedIdeas = @('Coverage Designer вернул некорректный JSON; дополнительные кейсы обязан определить live MCP.')
        }
    }

    $script:LastAgentError = $previousError
    $script:SmartCoverageDesign = $parsed

    $count = @($parsed.checks | Where-Object { $_ }).Count
    Append-AgentLog "SMART COVERAGE → designed $count risk-based check(s)."

    return $parsed
}


function Test-McpBlockedByInsufficientFixture {
    param($McpExecution)

    if (-not $McpExecution) { return $false }

    $status = ([string]$McpExecution.status).ToUpperInvariant()
    if ($status -ne 'BLOCKED') { return $false }

    $parts = New-Object System.Collections.Generic.List[string]

    foreach ($value in @($McpExecution.blockers)) {
        if ($value) { $parts.Add([string]$value) }
    }

    foreach ($item in @($McpExecution.acceptanceResults)) {
        if ($item) {
            if ($item.criterion) { $parts.Add([string]$item.criterion) }
            if ($item.evidence) { $parts.Add([string]$item.evidence) }
        }
    }

    foreach ($item in @($McpExecution.additionalResults)) {
        if ($item) {
            if ($item.case) { $parts.Add([string]$item.case) }
            if ($item.evidence) { $parts.Add([string]$item.evidence) }
        }
    }

    $combined = ($parts -join "`n").ToLowerInvariant()

    # Strong data/fixture signals. This intentionally does NOT match generic
    # infrastructure/auth/MCP failures.
    $patterns = @(
        'all\s*\(\s*0\s*\)',
        'list\s*=\s*\[\s*\]',
        'found\s*=\s*0',
        'no rows',
        'zero rows',
        'empty history',
        'empty fixture',
        'fixture.*(empty|invalid|unsuitable|непригод)',
        'test data.*(missing|insufficient|required|недостат|отсутств)',
        'нет строк',
        'не содержит строк',
        'строки не отрис',
        'отсутств.*строк',
        'нет данных',
        'отсутств.*данн',
        'пуст.*истори',
        'activity history.*(loading|empty|all \(0\)|нет|отсутств)',
        'history.*(loading|empty|no rows|zero rows)',
        'не удалось.*провер.*из-за отсутств',
        'невозможно.*провер.*из-за отсутств',
        'нуж.*созда.*(order|route|ticket|заказ|раут|тикет)'
    )

    foreach ($pattern in $patterns) {
        if ($combined -match $pattern) {
            return $true
        }
    }

    return $false
}

function Invoke-McpQaFixtureRecovery {
    param(
        $Task,
        $InitialExecution,
        [string]$JiraText,
        [string]$QaComment,
        [string[]]$ProjectRules,
        [string]$KnowledgeContext = '',
        $CoverageDesign = $null
    )

    if (-not $InitialExecution) { return $null }
    if (-not (Test-McpBlockedByInsufficientFixture -McpExecution $InitialExecution)) {
        return $null
    }

    $environment = [string]$jiraEnvironmentCombo.SelectedItem

    $compact = Get-CompactFixtureRecoveryContext `
        -Task $Task `
        -InitialExecution $InitialExecution `
        -JiraText $JiraText `
        -QaComment $QaComment `
        -ProjectRules $ProjectRules `
        -KnowledgeContext $KnowledgeContext `
        -CoverageDesign $CoverageDesign

    Set-AgentStatus `
        -Agent McpQaAgent `
        -State RUNNING `
        -Details 'создаю свежие тестовые данные для заблокированных кейсов'

    $jiraTaskStatus.Text = '2/3 Playwright MCP QA: данных недостаточно → создаю свежий fixture и повторяю проверку…'
    $jiraTaskStatus.ForeColor = [System.Drawing.Color]::FromArgb(197,119,0)
    [System.Windows.Forms.Application]::DoEvents()

    Append-AgentLog 'FIXTURE RECOVERY → initial run BLOCKED because current fixture/data was insufficient.'
    Append-AgentLog 'FIXTURE RECOVERY → mutation is allowed; fresh isolated data is mandatory before final BLOCKED.'

    $prompt = @"
You are the Rx2GO SMART QA FIXTURE RECOVERY AGENT.

You have Microsoft Playwright MCP connected to the SAME already-authenticated Chrome session.
The first live QA pass returned BLOCKED because the selected existing fixture did not contain enough data to verify one or more acceptance criteria.

THIS IS NOT A PLANNING TURN.
You must actively use playwright/browser_* tools and attempt to remove the data blocker.

STRICT TOOL BUDGET:
- Use ONLY `playwright/browser_*` MCP tools for all browser work.
- Do NOT use bundled Browser/Chrome/Computer Use tools.
- Do NOT use node_repl.
- Do NOT inspect Browser extension/native-host/registry/plugin installation.
- Do NOT diagnose unrelated MCP plugins.
- Do NOT use BrowserStack for this recovery.
- Stay inside the existing authenticated Rx2GO Chrome session.
- Spend tokens on the blocked acceptance criteria and fixture creation only.

ENVIRONMENT: $environment
DATA MUTATION ALLOWED: YES

LOCKED TASK UNDERSTANDING CONTRACT:
$(Get-TaskUnderstandingContractJson -Task $Task)

RECOVERY CONTRACT RULES:
- Recovery changes only test fixtures, never task meaning.
- Preserve the same contractId and acceptance criterion IDs.
- Re-run blocked AC IDs; do not invent new acceptance requirements.
- Keep outOfScope excluded from the verdict.

TASK:
$($Task.Key) — $($Task.Title)
Module: $($Task.Module)

CURRENT ITERATION SCOPE ONLY:
$($compact.Scope)

QA COMMENT:
$($compact.QaComment)

RELEVANT PROJECT RULES:
$($compact.ProjectRules)

RELEVANT KNOWLEDGE ONLY:
$($compact.Knowledge)

HIGH-VALUE COVERAGE ONLY:
$($compact.Coverage)

COMPACT INITIAL BLOCKED RESULT:
$($compact.InitialBlocked)

MANDATORY FIXTURE RECOVERY RULES:
1. Do NOT return BLOCKED merely because a previously selected existing order/route/ticket has no rows, no history or unsuitable state.
2. Create, update, modify, transition, link, assign, delete or recreate isolated TEST DATA for THIS Jira key whenever that can remove the blocker.
3. Never modify an unmarked pre-existing business/customer entity to manufacture the missing state.
4. Mark fresh/current-run QA entities with a clear QA / $($Task.Key) marker where the UI provides a safe field for it.
5. Respect facility/environment requirements from Jira and QA comment.
6. If the acceptance criterion requires Activity History / audit/history rows, creating the parent entity alone is not enough:
   - perform the minimum SAFE, reversible/QA-only workflow action needed to generate at least one history entry;
   - confirm the history/API actually contains at least one row;
   - only then verify the target field/date/format.
7. If a route/gig is required, inspect the live UI for the real create/assign flow and create a fresh QA route when safe.
8. If an order is required, use the established Rx2GO test-data rules and a fresh QA order.
9. Reuse proven live controls/endpoints discovered in this session; do not invent selectors or APIs.
10. You may return BLOCKED only AFTER at least one concrete fresh-fixture creation path was attempted and either:
    - creation failed for a specific observed reason;
    - required business preconditions cannot be safely produced;
    - the product/API prevents generation of the needed state.
11. If you still return BLOCKED, blockers must explicitly state:
    - what fresh data you attempted to create;
    - what exact step failed/prevented completion;
    - why no other safe path was available.
12. AUTOCOMPLETE / REQUIRED FIELD RULE:
    - If Recipient, Address, Facility, Client, Pharmacy or another field uses autocomplete/combobox suggestions, typing text is NOT enough.
    - Fill the field, wait for the suggestion list, choose the actual matching suggestion through Playwright, then verify the model/field is accepted.
    - If `Is required`, invalid-state styling, or equivalent validation remains after typing, the value was NOT accepted. Do not submit yet.
    - For Street Address specifically, select the real address suggestion and confirm dependent address data is populated/accepted before Add/Save.
    - For Recipient/Customer fields, select the actual dropdown option and confirm validation disappears.
13. Re-run all previously BLOCKED acceptance criteria after fixture recovery. Preserve already valid PASS evidence only if it is still relevant to the same current run.
14. Do not close the browser.

Return ONLY valid JSON with the SAME structure as the original Smart QA result:
{
  "status": "PASS|FAIL|BLOCKED",
  "mcpUsed": true,
  "environment": "$environment",
  "startUrl": "actual URL",
  "endUrl": "actual URL",
  "understanding": {
    "contractId": "$($Task.ContractId)",
    "contractAccepted": true,
    "acceptanceIds": ["AC1"],
    "outOfScopeRespected": true,
    "qaCommentKeptAsGuidance": true,
    "memoryKeptAdvisory": true,
    "notes": ["fixture recovery preserved task contract"]
  },
  "contextVerification": {
    "contextReady": true,
    "environmentVerified": true,
    "moduleVerified": true,
    "requiredBusinessContextVerified": true,
    "verifiedFacts": ["current live context"],
    "unverifiedAssumptions": []
  },
  "testData": {
    "created": true,
    "currentTaskVerified": true,
    "selectionReason": "created-this-run|exact-jira-entity|unmarked-read-only-entity|not-applicable",
    "sourceTicketId": "",
    "relatedTicketIds": [],
    "entities": [
      {
        "type":"ticket|order|other",
        "id":"actual id",
        "label":"purpose",
        "provenance":"created-this-run|exact-jira-entity|unmarked-read-only-entity",
        "jiraMarker":"$($Task.Key)|none"
      }
    ]
  },
  "integrity": {
    "liveCurrentRunEvidence": true,
    "currentScopeOnly": true,
    "testDataIsolated": true,
    "historicalEvidenceUsedAsVerdict": false,
    "environmentAssumptionsVerified": true,
    "notes": ["self-audit note including fixture recovery"]
  },
  "executedSteps": ["actual browser action"],
  "actualSelectors": ["proven selector/role/text strategy"],
  "acceptanceResults": [
    {"criterionId":"AC1","criterion":"criterion text","status":"PASS|FAIL|BLOCKED","evidence":"current live evidence"}
  ],
  "additionalResults": [
    {
      "type":"NEGATIVE|BOUNDARY|REGRESSION|INTEGRATION|DATA_CONSISTENCY|RESILIENCE",
      "priority":"P0|P1|P2",
      "case":"additional case",
      "status":"PASS|FAIL|SKIP|BLOCKED",
      "evidence":"current live evidence or skip/block reason",
      "affectsOverallResult":true
    }
  ],
  "networkEvidence": ["actual request/status"],
  "consoleEvidence": ["actual console observation"],
  "screenshots": ["artifact path"],
  "blockers": ["blocker only if recovery genuinely could not remove it"],
  "specGuidance": ["deterministic Playwright guidance"]
}
"@

    $raw = Invoke-CodexAgent `
        -AgentSlug '02-playwright-mcp-qa-fixture-recovery' `
        -Prompt $prompt `
        -TimeoutSec 540 `
        -ReasoningEffort 'low'

    if (-not $raw) {
        $failureKind = [string]$script:LastAgentFailureKind
        $failureText = [string]$script:LastAgentError
        $message = Get-CodexFailureUserMessage `
            -FailureKind $failureKind `
            -ErrorText $failureText

        $script:LastFixtureRecoveryInterruption = [pscustomobject]@{
            Kind = $failureKind
            Message = $message
            Error = $failureText
        }

        Set-AgentStatus `
            -Agent McpQaAgent `
            -State BLOCKED `
            -Details 'fixture recovery прерван; исходный BLOCKED сохранён'

        Append-AgentLog "FIXTURE RECOVERY → INTERRUPTED | $failureKind | $message"

        if ($failureKind -eq 'CODEX_USAGE_LIMIT') {
            Show-CodexUsageLimitWarning -Message $message
        }

        return [pscustomobject]@{
            Interrupted = $true
            FailureKind = $failureKind
            Message = $message
            Execution = $null
            Raw = $null
        }
    }

    $parsed = Convert-AgentJson $raw
    if (-not $parsed) {
        Append-AgentLog "FIXTURE RECOVERY → invalid JSON: $($script:LastAgentError)"
        return $null
    }

    if (-not $parsed.status -or -not [bool]$parsed.mcpUsed) {
        Append-AgentLog 'FIXTURE RECOVERY → rejected: missing status or mcpUsed=true.'
        return $null
    }

    if (-not (Test-LastAgentUsedPlaywrightMcpSuccessfully -MinimumCompletedCalls 2)) {
        Append-AgentLog 'FIXTURE RECOVERY → rejected: live Playwright MCP calls were not confirmed.'
        return $null
    }

    $status = ([string]$parsed.status).ToUpperInvariant()
    if (@('PASS','FAIL','BLOCKED') -notcontains $status) {
        Append-AgentLog "FIXTURE RECOVERY → rejected invalid status: $status"
        return $null
    }

    $artifact = Join-Path $script:AgentRunDir 'smart-mcp-fixture-recovery.json'
    Write-Utf8NoBomFile -Path $artifact -Content $raw

    Append-AgentLog "FIXTURE RECOVERY → completed with status $status"
    Append-AgentLog "FIXTURE RECOVERY ARTIFACT → $artifact"

    return [pscustomobject]@{
        Execution = $parsed
        Raw = $raw
    }
}

function Complete-JiraBlockedLiveRun {
    param(
        $Task,
        $McpExecution,
        [string]$Reason
    )

    if (-not $Task -or -not $McpExecution) { return }

    $taskKey = [string]$Task.Key
    $reasonText = if ([string]::IsNullOrWhiteSpace($Reason)) {
        'Не удалось получить достаточно тестовых данных для полного доказательства acceptance criteria.'
    }
    else {
        $Reason
    }

    $pipelineSummary = New-SmartPipelineSummary -McpExecution $McpExecution

    if ([string]::IsNullOrWhiteSpace([string]$script:LastJiraPlan)) {
        $script:LastJiraPlan = New-JiraTestPlan $Task
    }

    $script:LastJiraPlan += "`r`n`r`nFINAL LIVE RESULT:`r`nНЕДОСТАТОЧНО ДАННЫХ`r`n$reasonText"
    $script:LastJiraPlan += $pipelineSummary
    $jiraPlanBox.Text = $script:LastJiraPlan

    [void](Save-JiraRunArtifacts $Task $script:LastJiraPlan)

    # A blocked live run is still a completed QA observation and should teach
    # the Knowledge Base about fixture requirements / automation lessons.
    $blockedSummary = [pscustomobject]@{
        Pass = 0
        Fail = 0
        Skip = 0
        Total = 0
        Failed = @()
    }

    [void](Update-KnowledgeFromCompletedRun `
        -Task $Task `
        -Summary $blockedSummary)

    $script:LastAutoGitSync = Invoke-AutoGitCommitPushAfterJiraRun `
        -Task $Task `
        -Summary $blockedSummary

    Update-AutoGitUiStatus -GitResult $script:LastAutoGitSync
    Show-KnowledgeWriteWarningAfterRun

    [void](Save-JiraReadableReport)

    $jiraCopyReportButton.Enabled = $true
    $jiraRegressionButton.Enabled = $true

    Show-QAResultToast `
        -Result BLOCKED `
        -Title '⚠ НЕДОСТАТОЧНО ДАННЫХ' `
        -Details "$taskKey — $reasonText"

    if ($script:QueueWorkerMode) {
        try { Stop-PersistentBrowserSession } catch {}
        Complete-QueueWorkerResult -Result BLOCKED -Details $reasonText
    }
}

function Invoke-AgentMcpQa {
    param(
        $Task,
        [string]$JiraText,
        [string]$QaComment,
        [string[]]$ProjectRules,
        [string]$KnowledgeContext = '',
        $CoverageDesign = $null
    )

    Set-AgentStatus -Agent McpQaAgent -State RUNNING -Details 'работаю в живом Chrome'
    $script:LastAgentError = $null

    $environment = [string]$jiraEnvironmentCombo.SelectedItem
    $mutating = 'YES — ALL QA TEST-DATA ACTIONS AUTHORIZED'
    $contractJson = Get-TaskUnderstandingContractJson -Task $Task
    $contractId = [string]$Task.ContractId
    $coverageJson = if ($CoverageDesign) {
        $CoverageDesign | ConvertTo-Json -Depth 10 -Compress
    } else {
        '{"strategy":"live risk-based coverage","checks":[],"skippedIdeas":[]}'
    }

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

TASK UNDERSTANDING LOCK:
- The Task Understanding Contract below already passed a deterministic gate.
- Do NOT re-derive acceptance from raw Jira, QA comment, screenshots or memory.
- Execute every acceptanceMatrix ID exactly once and return the same ID in acceptanceResults.
- currentBehavior is bug/actual, NOT expected.
- executionGuidance tells HOW to test; it is NOT a new requirement.
- outOfScope cannot fail this run. Memory cannot create acceptance requirements.
- Verify the live environment/module/required business context before acceptance actions.
- If required context cannot be verified safely, return BLOCKED instead of testing the wrong thing.

LOCKED TASK UNDERSTANDING CONTRACT:
$contractJson

Your job is to behave like a senior QA engineer in the live product:
1. Start by taking a live browser snapshot and confirm the current Rx2GO page.
2. Navigate only as needed to the task module.
3. Read the actual current UI before deciding what controls/selectors exist.
4. Create or modify fresh isolated current-Jira TEST DATA whenever that makes the check deterministic.
5. If a QA/test entity has empty history, zero rows, unsuitable state or otherwise cannot prove a criterion, DO NOT stop at BLOCKED:
   - create a fresh fixture OR modify current-run QA data into the needed state;
   - perform any necessary QA-only update/transition/link/assignment/remoderation;
   - generate the minimum required history/audit/state;
   - retry the check.
6. You are authorized to update, transition, link, unlink, assign, unassign, resolve, reopen, delete, recreate and clean up current-run QA fixtures whenever necessary.
7. Never use Jira example IDs, historical IDs, or unmarked business/customer entities as mutation targets.
8. Return BLOCKED for data reasons only after all safe current-run QA test-data actions that could remove the blocker have been attempted and the blocker is documented.
9. AUTOCOMPLETE / REQUIRED FIELD RULE:
   - For Recipient, Street Address, Facility, Client, Pharmacy and similar autocomplete fields, typing visible text is not proof that the application accepted the value.
   - Select the real suggestion/dropdown option with Playwright and verify required/invalid validation disappears before submitting.
   - If `Is required` remains after fill(), treat the field as NOT selected and fix it before continuing.
10. Execute the acceptance criteria in the live browser now. This is not a planning-only turn.
11. Perform a live risk assessment and execute the highest-value relevant additional cases: negative, boundary, regression, integration/data consistency or resilience checks. Do not stop after the happy path.
12. If the Coverage Designer proposed P0/P1 checks that are feasible and safe, execute them. For each proposed check you do not execute, record a clear SKIP/BLOCKED reason in additionalResults.
13. Inspect browser console and relevant network requests through Playwright MCP when useful.
14. Record the actual IDs/entities you created, the actual controls you used, and actual evidence from the page.
15. Leave the browser open on a useful final state for the generated Playwright test.

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
  "understanding": {
    "contractId": "$contractId",
    "contractAccepted": true,
    "acceptanceIds": ["AC1"],
    "outOfScopeRespected": true,
    "qaCommentKeptAsGuidance": true,
    "memoryKeptAdvisory": true,
    "notes": ["short understanding self-check"]
  },
  "contextVerification": {
    "contextReady": true,
    "environmentVerified": true,
    "moduleVerified": true,
    "requiredBusinessContextVerified": true,
    "verifiedFacts": ["actual current context fact"],
    "unverifiedAssumptions": []
  },
  "testData": {
    "created": true,
    "currentTaskVerified": true,
    "selectionReason": "created-this-run|exact-jira-entity|unmarked-read-only-entity|not-applicable",
    "sourceTicketId": "",
    "relatedTicketIds": [],
    "entities": [
      {
        "type":"ticket|order|other",
        "id":"actual id",
        "label":"purpose",
        "provenance":"created-this-run|exact-jira-entity|unmarked-read-only-entity",
        "jiraMarker":"SCRUM-1234|none"
      }
    ]
  },
  "integrity": {
    "liveCurrentRunEvidence": true,
    "currentScopeOnly": true,
    "testDataIsolated": true,
    "historicalEvidenceUsedAsVerdict": false,
    "environmentAssumptionsVerified": true,
    "notes": ["short self-audit note"]
  },
  "executedSteps": ["actual browser action performed"],
  "actualSelectors": ["selector/role/text strategy proven against the live UI"],
  "acceptanceResults": [
    {"criterionId":"AC1","criterion":"criterion text","status":"PASS|FAIL|BLOCKED","evidence":"actual evidence"}
  ],
  "additionalResults": [
    {
      "type":"NEGATIVE|BOUNDARY|REGRESSION|INTEGRATION|DATA_CONSISTENCY|RESILIENCE",
      "priority":"P0|P1|P2",
      "case":"additional risk-based case",
      "status":"PASS|FAIL|SKIP|BLOCKED",
      "evidence":"actual current-run evidence or skip/block reason",
      "affectsOverallResult":true
    }
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

RETRIEVED KNOWLEDGE MEMORY:
$KnowledgeContext

RISK-BASED COVERAGE DESIGN:
$coverageJson

COVERAGE EXECUTION RULES:
- Jira acceptance criteria are mandatory, but they are not the whole test suite.
- Execute relevant P0/P1 NEGATIVE and REGRESSION checks whenever safe and feasible.
- Also consider BOUNDARY, INTEGRATION, DATA_CONSISTENCY and RESILIENCE checks when the changed behavior exposes such risks.
- Do not run random unrelated smoke tests.
- Additional checks must stay in the impacted module / immediate dependencies, especially when Jira comments narrow the current scope.
- A directly impacted negative/regression failure with live evidence should set affectsOverallResult=true and make overall status FAIL.
- A clearly unrelated/pre-existing advisory issue may be recorded with affectsOverallResult=false and must not distort the Jira result.
- If a valuable additional check cannot be performed safely, return SKIP/BLOCKED for that case with the reason instead of omitting it silently.

MEMORY USE RULES:
- Use prior Jira cases/scenarios to avoid rediscovering known workflow details.
- NEVER reuse an order/ticket/entity visibly marked with another Jira key. Example: while testing SCRUM-3403, an order whose Special Instructions contains SCRUM-4069 is contaminated test data and must be abandoned.
- Historical numeric order/ticket IDs from memory are reference-only. Do not navigate to them as current test data.
- If the live entity contains a QA marker for another SCRUM-* key, leave it and select/create isolated data for the current Jira key.
- Reuse proven repository helpers/test-data patterns when they are still compatible.
- Pay special attention to prior TEST_AUTOMATION_BUG patterns so you do not repeat them.
- Memory is advisory. The live Playwright MCP browser is the source of truth for current UI/runtime behavior.
- Never use historical order/ticket IDs as current test data unless the current task explicitly asks for that exact existing entity.
- Do not mark acceptance PASS/FAIL from memory; execute it live.

ENVIRONMENT: $environment
DATA MUTATION ALLOWED: $mutating

TEST DATA MUTATION POLICY — GLOBAL RX2GO QA RULE:
- Mutation of TEST DATA is ALWAYS AUTHORIZED.
- For current-run or clearly identified QA/test entities you may create, edit, update, modify, save, submit, transition status, assign/unassign, link/unlink, remoderate, resolve/reopen, attach/detach, delete, recreate and clean up data whenever needed to complete the test.
- This applies to QA orders, tickets, routes/gigs and other fixtures created for testing, explicitly marked as test data, or explicitly identified by the current Jira task as test fixtures.
- Prefer fresh isolated current-Jira fixtures whenever provenance of an existing entity is unclear.
- NEVER mutate an unmarked pre-existing business/customer entity merely because it is visible in the environment.
- Historical IDs from Knowledge Retrieval are reference-only and are not mutation targets.
- If a required state can be produced safely by changing current-run QA data, do that before returning BLOCKED.
- Cleanup/deletion of current-run QA data is allowed when safe and when it does not destroy evidence required for the report.

UI CHECK: $($jiraUiCheck.Checked)
API CHECK: $($jiraApiCheck.Checked)
NETWORK/CONSOLE CHECK: $($jiraNetworkCheck.Checked)
REGRESSION CHECK: $($jiraRegressionCheck.Checked)

DATE-FORMAT TESTING RULES:
- For MM/DD/YYYY / American-locale tasks, first classify each target as APP-RENDERED TEXT or NATIVE HTML DATE CONTROL.
- For `<input type="date">`, DOM `value` is normally ISO `YYYY-MM-DD`; Chrome/OS can render the native control differently by locale. Never mark product FAIL solely because a Russian-locale screenshot shows `05.09.2026`.
- Rx2GO QA launches Chrome with en-US locale. Before judging a native date control, record `navigator.language`, document lang where relevant, element type/value, and a current screenshot.
- For app-rendered non-native text dates, the visible text itself must match MM/DD/YYYY.
- Prefer a NON-AMBIGUOUS date such as Jira example `11/30/2028`; do not use ambiguous 05/09/2026 as proof of month/day order.
- Historical Jira screenshots/comments marked FAIL are historical context only. Retest current HOT behavior.
- If the latest Jira comment narrows an umbrella task to a subset, only that subset determines THIS run PASS/FAIL.
- For SCRUM-3403, when the latest comment limits testing to Order Detail Activity History, Gigs Activity History Route, Copays and Scanner, other modules must not affect the current result.

EXECUTION BUDGET:
- Prefer the smallest deterministic fixture that satisfies the task.
- For a Related tickets task, target exactly 1 fresh test order + 3 fresh tickets: 1 source + 2 related.
- Do not create standalone exploratory tickets after one confirmed ticket-creation path is known.
- Once required test data exists, stop setup exploration and execute acceptance criteria immediately.
- Reuse controls/requests already proven in this same live session instead of rediscovering the same flow.
- If a setup attempt fails, inspect the failure before retrying; do not blindly create multiple extra entities.

RESULT INTEGRITY RULES — APPLY TO EVERY JIRA TASK:
- Verify `contextVerification` before acceptance testing: correct environment, module and required business context.
- Echo the exact locked contractId in understanding.contractId.
- understanding.acceptanceIds must contain every contract AC ID.
- Every acceptanceResults row must include the correct criterionId from acceptanceMatrix.
- Never add an unknown criterionId and never omit a contract AC.
- Before returning PASS/FAIL/BLOCKED, perform an explicit evidence self-audit and fill the `integrity` object truthfully.
- PASS/FAIL must be based on evidence observed in THIS live browser run. Jira Description, Jira comments, attached historical screenshots, Knowledge Retrieval and previous test reports are context only.
- Only the CURRENT execution scope may affect the current overall result. Older umbrella requirements outside a later explicitly narrowed Jira-comment scope are background, not current FAILs.
- Every test entity used must be either created this run, the exact entity explicitly required by current Jira, or an unmarked read-only entity that is safe for this check.
- If an entity is visibly tagged/labelled for another Jira key, it is contaminated and cannot be used as current product evidence.
- Before failing on rendering, formatting, timezone, locale, native browser widgets, browser autofill, permissions, downloads or OS-owned UI, determine whether the behavior belongs to Rx2GO or to Chrome/Windows and verify the intended test environment.
- Use non-ambiguous values when the assertion depends on ordering/format (dates, decimal separators, timezone, sorting).
- Overall PASS is allowed only when every executed acceptance result is PASS and no additional result with affectsOverallResult=true has status FAIL/BLOCKED.
- Overall FAIL requires either a failed current acceptance criterion OR a failed directly impacted additional check with affectsOverallResult=true, always with concrete current-run evidence.
- If the observation is ambiguous, environment-dependent, cannot be reproduced safely, or test-data provenance is uncertain, return BLOCKED instead of guessing FAIL.
- Never convert an automation/setup/environment failure into a product FAIL.

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
        if ([string]$script:LastAgentFailureKind -eq 'CODEX_USAGE_LIMIT') {
            $limitMessage = Get-CodexFailureUserMessage `
                -FailureKind 'CODEX_USAGE_LIMIT' `
                -ErrorText ([string]$script:LastAgentError)

            $script:LastAgentError = "[CODEX_USAGE_LIMIT] $limitMessage"

            Set-AgentStatus `
                -Agent McpQaAgent `
                -State BLOCKED `
                -Details 'проверка прервана: лимит Codex'

            Append-AgentLog "MAIN MCP QA → INTERRUPTED / CODEX_USAGE_LIMIT | $limitMessage"

            if (-not $script:QueueWorkerMode) {
                Show-CodexUsageLimitWarning -Message $limitMessage
            }

            return $null
        }

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

    # If the first run is BLOCKED only because the selected fixture/data is empty
    # and mutation is allowed, automatically attempt one fresh-fixture recovery
    # before accepting BLOCKED as the final product-testing state.
    if (
        ([string]$parsed.status).ToUpperInvariant() -eq 'BLOCKED' -and
        (Test-McpBlockedByInsufficientFixture -McpExecution $parsed)
    ) {
        $initialBlockedArtifact = Join-Path $script:AgentRunDir 'smart-mcp-initial-blocked.json'
        Write-Utf8NoBomFile -Path $initialBlockedArtifact -Content $raw
        Append-AgentLog "FIXTURE RECOVERY → initial BLOCKED artifact: $initialBlockedArtifact"

        $recovery = Invoke-McpQaFixtureRecovery `
            -Task $Task `
            -InitialExecution $parsed `
            -JiraText $JiraText `
            -QaComment $QaComment `
            -ProjectRules $ProjectRules `
            -KnowledgeContext $KnowledgeContext `
            -CoverageDesign $CoverageDesign

        if ($recovery -and $recovery.Execution) {
            $parsed = $recovery.Execution
            $raw = [string]$recovery.Raw
        }
        elseif ($recovery -and [bool]$recovery.Interrupted) {
            $interruptionMessage = [string]$recovery.Message

            $newBlockers = @($interruptionMessage) + @($parsed.blockers)

            if ($parsed.PSObject.Properties.Name -contains 'blockers') {
                $parsed.blockers = $newBlockers
            }
            else {
                $parsed | Add-Member `
                    -MemberType NoteProperty `
                    -Name blockers `
                    -Value $newBlockers
            }

            # Restore a BLOCKED product-test state. Recovery infrastructure
            # interruption must not become a red product/QA failure.
            Set-AgentStatus `
                -Agent McpQaAgent `
                -State BLOCKED `
                -Details $interruptionMessage

            Append-AgentLog "FIXTURE RECOVERY → preserved initial BLOCKED | $interruptionMessage"
        }
        else {
            Append-AgentLog 'FIXTURE RECOVERY → could not produce a replacement result; preserving initial BLOCKED evidence.'
        }
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

    $crossTaskSafety = Test-McpCrossTaskDataSafety -Task $Task -McpExecution $parsed
    if (-not $crossTaskSafety.Success) {
        $script:LastAgentError = [string]$crossTaskSafety.Error
        Append-AgentLog "CROSS-JIRA DATA GUARD → FAIL | $($script:LastAgentError)"
        Set-AgentStatus -Agent McpQaAgent -State FAIL -Details 'cross-Jira test data contamination'
        return $null
    }

    $integrityCheck = Test-McpResultIntegrity -Task $Task -McpExecution $parsed
    if (-not $integrityCheck.Success) {
        $script:LastAgentError = "Result Integrity Gate rejected Smart QA verdict: $($integrityCheck.Error)"
        Append-AgentLog "RESULT INTEGRITY GATE → REJECTED | $($integrityCheck.Error)"
        Set-AgentStatus -Agent McpQaAgent -State FAIL -Details 'result integrity rejected'
        return $null
    }

    Append-AgentLog 'RESULT INTEGRITY GATE → PASS'

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
        if (-not $reason) { $reason = 'Не удалось получить достаточно данных для полного выполнения проверки.' }

        $script:LastAgentError = [string]$reason

        Set-AgentStatus `
            -Agent McpQaAgent `
            -State BLOCKED `
            -Details 'недостаточно данных после fixture recovery'

        Append-AgentLog "PRODUCT TEST STATE → BLOCKED / НЕДОСТАТОЧНО ДАННЫХ | $reason"

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
DATA MUTATION ALLOWED: YES — ALL QA TEST-DATA ACTIONS AUTHORIZED

TEST DATA MUTATION POLICY — GLOBAL RX2GO QA RULE:
- Mutation of TEST DATA is ALWAYS AUTHORIZED.
- For current-run or clearly identified QA/test entities you may create, edit, update, modify, save, submit, transition status, assign/unassign, link/unlink, remoderate, resolve/reopen, attach/detach, delete, recreate and clean up data whenever needed to complete the test.
- This applies to QA orders, tickets, routes/gigs and other fixtures created for testing, explicitly marked as test data, or explicitly identified by the current Jira task as test fixtures.
- Prefer fresh isolated current-Jira fixtures whenever provenance of an existing entity is unclear.
- NEVER mutate an unmarked pre-existing business/customer entity merely because it is visible in the environment.
- Historical IDs from Knowledge Retrieval are reference-only and are not mutation targets.
- If a required state can be produced safely by changing current-run QA data, do that before returning BLOCKED.
- Cleanup/deletion of current-run QA data is allowed when safe and when it does not destroy evidence required for the report.


RULES:
- Test the Jira acceptance criteria, not generic page loading.
- Use existing repository fixtures/helpers/page objects where available.
- Never hard-code credentials or secrets.
- All necessary actions on clearly identified QA/test data are authorized; never mutate unmarked business/customer data.
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



function Test-SmartSpecSelectAssertionSafety {
    param(
        [string]$Code,
        $McpExecution
    )

    $result = [ordered]@{
        Success = $true
        Error = ''
    }

    if ([string]::IsNullOrWhiteSpace($Code)) {
        return [pscustomobject]$result
    }

    # Regression guard for SCRUM-4075:
    # visible <select> label can differ from the DOM option value.
    #
    # PowerShell quoting note:
    # a single quote inside a single-quoted PowerShell string is doubled.
    $singleQuotedPattern = '(?is)expect\s*\(\s*([A-Za-z_$][A-Za-z0-9_$\.]*)\s*\)\s*\.\s*toHaveValue\s*\(\s*''([^'']+)'''
    $doubleQuotedPattern = '(?is)expect\s*\(\s*([A-Za-z_$][A-Za-z0-9_$\.]*)\s*\)\s*\.\s*toHaveValue\s*\(\s*"([^"]+)"'

    $matches = New-Object System.Collections.ArrayList

    foreach ($m in [regex]::Matches($Code,$singleQuotedPattern)) {
        [void]$matches.Add([pscustomobject]@{
            LocatorName = [string]$m.Groups[1].Value
            Expected = [string]$m.Groups[2].Value
        })
    }

    foreach ($m in [regex]::Matches($Code,$doubleQuotedPattern)) {
        [void]$matches.Add([pscustomobject]@{
            LocatorName = [string]$m.Groups[1].Value
            Expected = [string]$m.Groups[2].Value
        })
    }

    foreach ($item in @($matches)) {
        $locatorName = [string]$item.LocatorName
        $expected = [string]$item.Expected

        $looksLikeNamedSelect = (
            $locatorName -match '(?i)(facility|service|client|pharmacy|status|select)'
        )

        $looksLikeHumanLabel = (
            $expected -match '[A-Za-z]' -and
            (
                $expected -match '\s' -or
                $expected -match '[A-Z][a-z]+'
            )
        )

        if ($looksLikeNamedSelect -and $looksLikeHumanLabel) {
            $result.Success = $false
            $result.Error = (
                "Generated spec may compare a visible selected option label using toHaveValue(): " +
                "$locatorName -> '$expected'. For HTML select controls, verify option:checked text unless " +
                "the live MCP evidence explicitly proves '$expected' is the underlying option value."
            )

            return [pscustomobject]$result
        }
    }

    return [pscustomobject]$result
}

function Invoke-AgentSmartReviewer {
    param(
        $Task,
        $McpExecution,
        [string]$McpExecutionRaw,
        [string]$QaComment,
        [string[]]$ProjectRules,
        [string]$KnowledgeContext = '',
        $CoverageDesign = $null
    )

    Set-AgentStatus -Agent QAReviewer -State RUNNING -Details 'собираю deterministic spec'
    $script:JiraGenerationError = $null
    $script:JiraGenerationLog = $null

    $environment = [string]$jiraEnvironmentCombo.SelectedItem
    $mcpJson = $McpExecution | ConvertTo-Json -Depth 16
    $contractJson = Get-TaskUnderstandingContractJson -Task $Task
    $coverageJson = if ($CoverageDesign) {
        $CoverageDesign | ConvertTo-Json -Depth 10 -Compress
    } else {
        '{"strategy":"live risk-based coverage","checks":[],"skippedIdeas":[]}'
    }

    $prompt = @"
You are the final Rx2GO QA REVIEWER and Playwright spec owner.

The main Playwright MCP QA Agent has ALREADY worked in the real authenticated browser and produced run-scoped evidence below.
Your job is to turn that REAL execution evidence into one deterministic Playwright TypeScript spec.

You also have Playwright MCP connected to the same Chrome. Use it only when you need to verify a selector/state that is missing from the evidence. Do not redo broad exploration and do not close the browser.

Return ONLY one complete raw TypeScript Playwright spec. No markdown and no prose.

TASK:
$($Task.Key) — $($Task.Title)
Module: $($Task.Module)

LOCKED TASK UNDERSTANDING CONTRACT:
$contractJson

REVIEW CONTRACT RULES:
- Generate assertions for the same acceptanceMatrix only.
- Do not convert QA guidance, screenshot details or Knowledge memory into new acceptance.
- Keep outOfScope out of the deterministic verdict.
- Preserve criterion IDs in test titles/comments where practical.
- The live MCP result must match contractId $($Task.ContractId).

TASK SCREENSHOTS:
$(Get-JiraScreenshotPromptSummary)
Use attached screenshots as secondary visual evidence. The REAL PLAYWRIGHT MCP QA EXECUTION below remains primary runtime evidence.

ACCEPTANCE:
$(@($Task.Criteria) -join "`n- ")

QA COMMENT:
$QaComment

PROJECT RULES:
$($ProjectRules -join "`n- ")

RETRIEVED KNOWLEDGE MEMORY:
$KnowledgeContext

RISK-BASED COVERAGE DESIGN:
$coverageJson

MEMORY USE RULES:
- Reuse compatible existing fixtures/helpers/tests from memory rather than inventing replacements.
- Before generating the spec, verify that MCP's verdict passed Result Integrity principles: current-run evidence, current scope, isolated test data, no historical verdict substitution, verified environment assumptions.
- If MCP evidence is insufficient for a deterministic assertion, do not hard-code the weak inference into the spec.
- Prior automation failures are warnings: avoid repeating their root causes.
- Real MCP execution from THIS run outranks any historical memory for selectors, IDs and current behavior.
- Historical entity IDs must never be used as fallback current test data.
- Reject any spec that navigates to or hard-codes an entity known to belong to another Jira key.
- For MM/DD/YYYY tasks, a native `<input type=date>` has ISO DOM value; do NOT compare that value directly to an MM/DD/YYYY visible string.
- Native date presentation must be evaluated under en-US Chrome locale with UI/screenshot evidence.
- Prefer a non-ambiguous date such as 11/30/2028 when proving month/day order.
- HTML `<select>` ASSERTION RULE:
  - A user-visible selected label and the DOM `select.value` are different concepts.
  - If the requirement is about the visible selected option name (for example Facility `New York`, Service, Client, Pharmacy or Status label), DO NOT assert `toHaveValue('New York')` unless the live MCP evidence explicitly proved that `New York` is the underlying option value.
  - Prefer `expect(select.locator('option:checked')).toHaveText('New York')` or an equivalent selected-option text assertion.
  - Use `toHaveValue()` only for a backend/internal option value that was actually observed in the live DOM/MCP evidence.

REAL PLAYWRIGHT MCP QA EXECUTION:
$mcpJson

ENVIRONMENT: $environment
DATA MUTATION ALLOWED: YES — ALL QA TEST-DATA ACTIONS AUTHORIZED

TEST DATA MUTATION POLICY — GLOBAL RX2GO QA RULE:
- Mutation of TEST DATA is ALWAYS AUTHORIZED.
- For current-run or clearly identified QA/test entities you may create, edit, update, modify, save, submit, transition status, assign/unassign, link/unlink, remoderate, resolve/reopen, attach/detach, delete, recreate and clean up data whenever needed to complete the test.
- This applies to QA orders, tickets, routes/gigs and other fixtures created for testing, explicitly marked as test data, or explicitly identified by the current Jira task as test fixtures.
- Prefer fresh isolated current-Jira fixtures whenever provenance of an existing entity is unclear.
- NEVER mutate an unmarked pre-existing business/customer entity merely because it is visible in the environment.
- Historical IDs from Knowledge Retrieval are reference-only and are not mutation targets.
- If a required state can be produced safely by changing current-run QA data, do that before returning BLOCKED.
- Cleanup/deletion of current-run QA data is allowed when safe and when it does not destroy evidence required for the report.


MANDATORY RULES:
- Test the exact locked acceptanceMatrix, not a reinterpreted Jira and not generic page loading.
- Every contract AC must have a deterministic assertion.
- Also encode deterministic versions of the high-value additional NEGATIVE / BOUNDARY / REGRESSION / INTEGRATION checks that MCP actually executed with reliable evidence.
- Do not generate speculative extra tests that MCP skipped or could not prove.
- A directly impacted additional regression marked affectsOverallResult=true is part of the deterministic task suite.
- Treat the MCP QA execution as primary evidence for routes, controls, selectors and run-scoped test IDs.
- Generated Playwright may create/update/modify/transition/link/delete/recreate/cleanup current-run QA fixtures as needed to reproduce the live-proven scenario.
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
    $selectSafety = Test-SmartSpecSelectAssertionSafety -Code $code -McpExecution $McpExecution
    $repairReason = ''

    if (-not $runtimeSafety.Success) {
        $repairReason = [string]$runtimeSafety.Error
        Append-AgentLog "QA Reviewer CDP navigation guard → FAIL | $repairReason"
    }
    elseif (-not $dataSafety.Success) {
        $repairReason = [string]$dataSafety.Error
        Append-AgentLog "QA Reviewer data safety guard → FAIL | $repairReason"
    }
    elseif (-not $selectSafety.Success) {
        $repairReason = [string]$selectSafety.Error
        Append-AgentLog "QA Reviewer select assertion guard → FAIL | $repairReason"
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
LOCKED CONTRACT:
$contractJson

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
- HTML `<select>` ASSERTION RULE:
  - A user-visible selected label and the DOM `select.value` are different concepts.
  - If the requirement is about the visible selected option name (for example Facility `New York`, Service, Client, Pharmacy or Status label), DO NOT assert `toHaveValue('New York')` unless the live MCP evidence explicitly proved that `New York` is the underlying option value.
  - Prefer `expect(select.locator('option:checked')).toHaveText('New York')` or an equivalent selected-option text assertion.
  - Use `toHaveValue()` only for a backend/internal option value that was actually observed in the live DOM/MCP evidence.
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

    $selectSafety = Test-SmartSpecSelectAssertionSafety -Code $repairCode -McpExecution $McpExecution
    if (-not $selectSafety.Success) {
        $script:JiraGenerationError = [string]$selectSafety.Error
        Set-AgentStatus -Agent QAReviewer -State FAIL -Details 'unsafe select label assertion'
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

        if (@($McpExecution.additionalResults).Count -gt 0) {
            $lines += 'LIVE ADDITIONAL RISK-BASED RESULTS:'
            foreach ($r in @($McpExecution.additionalResults)) {
                if ($r) {
                    $lines += "- [$($r.type)/$($r.status)] $($r.case) — $($r.evidence)"
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

    $mutating = 'YES — ALL QA TEST-DATA ACTIONS AUTHORIZED'
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

TEST DATA MUTATION POLICY — GLOBAL RX2GO QA RULE:
- Mutation of TEST DATA is ALWAYS AUTHORIZED.
- For current-run or clearly identified QA/test entities you may create, edit, update, modify, save, submit, transition status, assign/unassign, link/unlink, remoderate, resolve/reopen, attach/detach, delete, recreate and clean up data whenever needed to complete the test.
- This applies to QA orders, tickets, routes/gigs and other fixtures created for testing, explicitly marked as test data, or explicitly identified by the current Jira task as test fixtures.
- Prefer fresh isolated current-Jira fixtures whenever provenance of an existing entity is unclear.
- NEVER mutate an unmarked pre-existing business/customer entity merely because it is visible in the environment.
- Historical IDs from Knowledge Retrieval are reference-only and are not mutation targets.
- If a required state can be produced safely by changing current-run QA data, do that before returning BLOCKED.
- Cleanup/deletion of current-run QA data is allowed when safe and when it does not destroy evidence required for the report.


RULES:
- Test the acceptance criterion itself, not only page loading.
- Current bug behavior is not expected behavior.
- QA comment is execution guidance.
- Use existing authenticated fixtures and URL helpers.
- Never hard-code credentials or tokens.
- All necessary actions on clearly identified QA/test data are authorized; never mutate unmarked business/customer data.
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



function Test-TaskUnderstandingContract {
    param($Analysis,[string]$JiraText)

    $errors = New-Object System.Collections.ArrayList
    $warnings = New-Object System.Collections.ArrayList

    if (-not $Analysis) {
        [void]$errors.Add('Requirements Analyst returned no Task Understanding Contract.')
    }
    else {
        $goal = ([string]$Analysis.taskGoal).Trim()
        if ($goal.Length -lt 12) { [void]$errors.Add('Task goal is missing or too vague.') }

        $criteria = @($Analysis.acceptanceCriteria | Where-Object { $_ })
        $matrix = @($Analysis.acceptanceMatrix | Where-Object { $_ })
        if ($criteria.Count -eq 0) { [void]$errors.Add('No acceptance criteria were extracted.') }
        if ($matrix.Count -eq 0) { [void]$errors.Add('Acceptance matrix is missing.') }
        if ($matrix.Count -lt $criteria.Count) { [void]$errors.Add("Acceptance matrix has fewer rows ($($matrix.Count)) than acceptance criteria ($($criteria.Count)).") }

        $expectedIndex = 1
        foreach ($item in $matrix) {
            $expectedId = "AC$expectedIndex"
            $id = ([string]$item.id).Trim().ToUpperInvariant()
            $sourceType = ([string]$item.sourceType).Trim().ToUpperInvariant()
            $requirement = ([string]$item.requirement).Trim()
            $expected = ([string]$item.expected).Trim()
            $sourceQuote = ([string]$item.sourceQuote).Trim()
            if ($id -ne $expectedId) { [void]$errors.Add("Acceptance matrix ID sequence is invalid: expected $expectedId, received '$id'.") }
            if ($sourceType -notin @('DESCRIPTION','JIRA_COMMENT')) { [void]$errors.Add("$id uses forbidden acceptance source '$sourceType'.") }
            if ($requirement.Length -lt 5) { [void]$errors.Add("$id has no usable requirement.") }
            if ($expected.Length -lt 4) { [void]$errors.Add("$id has no observable expected result.") }
            if ($sourceQuote.Length -lt 3) { [void]$errors.Add("$id has no source trace.") }
            if (@($item.evidenceNeeded | Where-Object { $_ }).Count -eq 0) { [void]$errors.Add("$id has no evidenceNeeded definition.") }
            $expectedIndex++
        }

        $audit = $Analysis.selfAudit
        if (-not $audit) { [void]$errors.Add('Requirements self-audit is missing.') }
        else {
            foreach ($name in @('currentBehaviorNotUsedAsAcceptance','qaCommentNotUsedAsRequirement','memoryNotUsedAsRequirement','screenshotNotUsedAsRequirement','latestScopeApplied','noInventedRequirements')) {
                $value = $false
                if ($audit.PSObject.Properties.Name -contains $name) { $value = [bool]$audit.$name }
                if (-not $value) { [void]$errors.Add("Requirements self-audit failed: $name.") }
            }
        }

        $confidence = 0
        try { $confidence = [int]$Analysis.confidence } catch { $confidence = 0 }
        if ($confidence -lt 70) { [void]$errors.Add("Requirements confidence is too low: $confidence%.") }
        elseif ($confidence -lt 82) { [void]$warnings.Add("Requirements confidence is moderate: $confidence%.") }

        foreach ($ambiguity in @($Analysis.ambiguities | Where-Object { $_ })) {
            $severity = ([string]$ambiguity.severity).ToUpperInvariant()
            if ($severity -eq 'HIGH') { [void]$errors.Add("High-impact ambiguity: $([string]$ambiguity.text)") }
            elseif ($severity -eq 'MEDIUM') { [void]$warnings.Add("Ambiguity: $([string]$ambiguity.text)") }
        }

        foreach ($contradiction in @($Analysis.contradictions | Where-Object { $_ })) {
            if (-not [bool]$contradiction.resolved) { [void]$errors.Add("Unresolved requirement contradiction: $([string]$contradiction.text)") }
        }

        $latestScope = Get-CurrentIterationScopeFromComments -JiraText $JiraText
        if (-not [string]::IsNullOrWhiteSpace($latestScope)) {
            if (@($Analysis.inScope | Where-Object { $_ }).Count -eq 0) { [void]$errors.Add('Latest Jira comment narrows scope, but inScope is empty.') }
            if ([string]::IsNullOrWhiteSpace([string]$Analysis.scopeDecision)) { [void]$errors.Add('Latest Jira comment exists, but scopeDecision is missing.') }
        }
    }

    return [pscustomobject]@{ Success=($errors.Count -eq 0); Error=($errors -join ' | '); Warnings=@($warnings) }
}

function New-TaskUnderstandingContractId {
    param([string]$Key,[string]$Goal,$AcceptanceMatrix,$InScope)
    $seed = @([string]$Key,[string]$Goal,(@($AcceptanceMatrix | ForEach-Object { "$($_.id)|$($_.requirement)|$($_.expected)" }) -join "`n"),(@($InScope) -join "`n")) -join "`n---`n"
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($seed)
        $hash = $sha.ComputeHash($bytes)
        $hex = -join ($hash | ForEach-Object { $_.ToString('x2') })
        return $hex.Substring(0,16)
    }
    finally { $sha.Dispose() }
}

function Get-TaskUnderstandingContractJson {
    param($Task)
    if (-not $Task) { return '{}' }
    $contract = [ordered]@{
        contractId=[string]$Task.ContractId; key=[string]$Task.Key; title=[string]$Task.Title; module=[string]$Task.Module;
        goal=[string]$Task.TaskGoal; primaryBusinessObject=[string]$Task.PrimaryBusinessObject; trigger=[string]$Task.Trigger;
        preconditions=@($Task.Preconditions); inScope=@($Task.InScope); outOfScope=@($Task.OutOfScope);
        currentBehavior=@($Task.CurrentBehavior); expectedBehavior=@($Task.ExpectedBehavior);
        expectedStateChanges=@($Task.ExpectedStateChanges); forbiddenStateChanges=@($Task.ForbiddenStateChanges);
        acceptanceMatrix=@($Task.AcceptanceMatrix); executionGuidance=@($Task.ExecutionGuidance); constraints=@($Task.Constraints);
        confidence=[int]$Task.UnderstandingConfidence
    }
    return ($contract | ConvertTo-Json -Depth 12 -Compress)
}

function Get-TaskUnderstandingSummary {
    param($Task)
    if (-not $Task) { return 'TASK UNDERSTANDING: unavailable' }
    $lines = New-Object System.Collections.ArrayList
    [void]$lines.Add('КАК СИСТЕМА ПОНЯЛА ЗАДАЧУ:')
    [void]$lines.Add("Contract: $($Task.ContractId)")
    [void]$lines.Add("Цель: $($Task.TaskGoal)")
    [void]$lines.Add("Объект: $($Task.PrimaryBusinessObject)")
    [void]$lines.Add("Триггер: $($Task.Trigger)")
    [void]$lines.Add("Уверенность: $($Task.UnderstandingConfidence)%")
    [void]$lines.Add('')
    if (@($Task.InScope).Count -gt 0) { [void]$lines.Add('В ЭТОМ ПРОГОНЕ ПРОВЕРЯЕМ:'); foreach($x in @($Task.InScope)){[void]$lines.Add("- $x")}; [void]$lines.Add('') }
    if (@($Task.OutOfScope).Count -gt 0) { [void]$lines.Add('НЕ ОПРЕДЕЛЯЕТ РЕЗУЛЬТАТ ЭТОГО ПРОГОНА:'); foreach($x in @($Task.OutOfScope)){[void]$lines.Add("- $x")}; [void]$lines.Add('') }
    if (@($Task.ExpectedStateChanges).Count -gt 0) { [void]$lines.Add('ЧТО ДОЛЖНО ИЗМЕНИТЬСЯ:'); foreach($x in @($Task.ExpectedStateChanges)){[void]$lines.Add("- $x")}; [void]$lines.Add('') }
    if (@($Task.ForbiddenStateChanges).Count -gt 0) { [void]$lines.Add('ЧЕГО НЕ ДОЛЖНО ПРОИСХОДИТЬ:'); foreach($x in @($Task.ForbiddenStateChanges)){[void]$lines.Add("- $x")}; [void]$lines.Add('') }
    if (@($Task.AcceptanceMatrix).Count -gt 0) {
        [void]$lines.Add('ACCEPTANCE MATRIX:')
        foreach($ac in @($Task.AcceptanceMatrix)) { if($ac){ [void]$lines.Add("[$($ac.id)] $($ac.requirement)"); [void]$lines.Add("    Действие: $($ac.action)"); [void]$lines.Add("    Ожидаемо: $($ac.expected)"); [void]$lines.Add("    Источник: $($ac.sourceType) - $($ac.sourceQuote)") } }
        [void]$lines.Add('')
    }
    if (@($Task.ExecutionGuidance).Count -gt 0) { [void]$lines.Add('ИНСТРУКЦИИ QA - КАК ТЕСТИРОВАТЬ, НЕ НОВЫЕ ТРЕБОВАНИЯ:'); foreach($x in @($Task.ExecutionGuidance)){[void]$lines.Add("- $x")} }
    return (@($lines) -join "`r`n")
}

function Get-JiraTaskInfo([string]$rawText, $aiAnalysis = $null, [string]$qaComment = '', [string[]]$projectRules = @()) {
    $raw = if ($rawText) { $rawText.Trim() } else { '' }
    $key = 'ADHOC'; $m=[regex]::Match($raw,'(?i)\b([A-Z][A-Z0-9]+-\d+)\b'); if($m.Success){$key=$m.Groups[1].Value.ToUpperInvariant()}
    $title = if($script:LoadedJiraIssue -and $script:LoadedJiraIssue.key -eq $key){[string]$script:LoadedJiraIssue.summary}else{$key}
    $low=$raw.ToLowerInvariant(); $module='Unknown'
    if($low -match 'ticket queue|tickets queue|related tickets|ticket|тикет'){$module='Tickets Queue'} elseif($low -match 'show chat|chat|чат'){$module='Chat'} elseif($low -match 'scanner|сканер'){$module='Scanner'} elseif($low -match 'dispatcher|диспетчер'){$module='Dispatcher'} elseif($low -match 'qaqc|qa/qc'){$module='QAQC'} elseif($low -match 'order|заказ'){$module='Orders'}
    $current=@();$expected=@();$repro=@();$criteria=@();$risk=@();$negativeRisk=@();$boundaryRisk=@();$regressionRisk=@()
    $taskGoal='';$primaryBusinessObject='other';$trigger='';$preconditions=@();$inScope=@();$outOfScope=@();$expectedStateChanges=@();$forbiddenStateChanges=@();$acceptanceMatrix=@();$executionGuidance=@();$constraints=@();$ambiguities=@();$contradictions=@();$understandingConfidence=0;$scopeDecision='';$source='Local fallback'
    if($aiAnalysis){
        if($aiAnalysis.title){$title=[string]$aiAnalysis.title};$allowed=@('Tickets Queue','Chat','Scanner','Dispatcher','QAQC','Orders','Unknown');if($aiAnalysis.module -and $allowed -contains [string]$aiAnalysis.module){$module=[string]$aiAnalysis.module}
        $current=@($aiAnalysis.currentBehavior|?{$_}|%{([string]$_).Trim()});$expected=@($aiAnalysis.expectedBehavior|?{$_}|%{([string]$_).Trim()});$repro=@($aiAnalysis.reproductionSteps|?{$_}|%{([string]$_).Trim()});$criteria=@($aiAnalysis.acceptanceCriteria|?{$_}|%{([string]$_).Trim()});$risk=@($aiAnalysis.riskAreas|?{$_});$negativeRisk=@($aiAnalysis.negativeRiskIdeas|?{$_});$boundaryRisk=@($aiAnalysis.boundaryRiskIdeas|?{$_});$regressionRisk=@($aiAnalysis.regressionRiskIdeas|?{$_})
        $taskGoal=([string]$aiAnalysis.taskGoal).Trim();$primaryBusinessObject=([string]$aiAnalysis.primaryBusinessObject).Trim();$trigger=([string]$aiAnalysis.trigger).Trim();$preconditions=@($aiAnalysis.preconditions|?{$_});$inScope=@($aiAnalysis.inScope|?{$_});$outOfScope=@($aiAnalysis.outOfScope|?{$_});$expectedStateChanges=@($aiAnalysis.expectedStateChanges|?{$_});$forbiddenStateChanges=@($aiAnalysis.forbiddenStateChanges|?{$_});$acceptanceMatrix=@($aiAnalysis.acceptanceMatrix|?{$_});$executionGuidance=@($aiAnalysis.executionGuidance|?{$_});$constraints=@($aiAnalysis.constraints|?{$_});$ambiguities=@($aiAnalysis.ambiguities|?{$_});$contradictions=@($aiAnalysis.contradictions|?{$_});try{$understandingConfidence=[int]$aiAnalysis.confidence}catch{$understandingConfidence=0};$scopeDecision=[string]$aiAnalysis.scopeDecision;$source='ChatGPT OAuth / Codex + Understanding Gate'
    }
    if($criteria.Count -eq 0){$section='';foreach($rawLine in @($raw -split "`r?`n")){$line=$rawLine.Trim();if(-not $line){continue};if($line -match '(?i)^(сейчас|текущее поведение|current|actual)\s*:?\s*$'){$section='current';continue};if($line -match '(?i)^(ожидаемо|expected)\s*:?\s*$'){$section='expected';continue};if($line -match '(?i)^(как воспроизвести|steps to reproduce|repro)\s*:?\s*$'){$section='repro';continue};if($line -match '(?i)^(критерий при[её]мки|acceptance criteria|необходимо)\s*:?\s*$'){$section='acceptance';continue};$clean=$line -replace '^(?:[-*•]|\d+[.)])\s*','';if(-not $clean){continue};switch($section){'current'{$current+=$clean};'expected'{$expected+=$clean;$criteria+=$clean};'repro'{$repro+=$clean};'acceptance'{$criteria+=$clean}}}}
    $criteria=@($criteria|Select-Object -Unique);if($criteria.Count -eq 0){$criteria=@('Требование не удалось выделить автоматически - проверь импорт Jira.')};if([string]::IsNullOrWhiteSpace($taskGoal)){$taskGoal="$key - verify current acceptance criteria without adding assumptions."};if([string]::IsNullOrWhiteSpace($primaryBusinessObject)){$primaryBusinessObject='other'}
    $contractId=New-TaskUnderstandingContractId -Key $key -Goal $taskGoal -AcceptanceMatrix $acceptanceMatrix -InScope $inScope
    return [pscustomobject]@{Key=$key;Title=$title;Module=$module;Raw=$raw;TaskGoal=$taskGoal;PrimaryBusinessObject=$primaryBusinessObject;Trigger=$trigger;Preconditions=@($preconditions);InScope=@($inScope);OutOfScope=@($outOfScope);CurrentBehavior=@($current|Select-Object -Unique);ExpectedBehavior=@($expected|Select-Object -Unique);ExpectedStateChanges=@($expectedStateChanges);ForbiddenStateChanges=@($forbiddenStateChanges);ReproductionSteps=@($repro|Select-Object -Unique);Criteria=$criteria;AcceptanceMatrix=@($acceptanceMatrix);ContractId=$contractId;ExecutionGuidance=@($executionGuidance);Constraints=@($constraints);UnderstandingConfidence=$understandingConfidence;ScopeDecision=$scopeDecision;Ambiguities=@($ambiguities);Contradictions=@($contradictions);Automated=$false;AnalysisSource=$source;RiskAreas=@($risk);NegativeRiskIdeas=@($negativeRisk);BoundaryRiskIdeas=@($boundaryRisk);RegressionRiskIdeas=@($regressionRisk);QAComment=$qaComment;ProjectRules=@($projectRules);JiraComments=if($script:LoadedJiraIssue -and $script:LoadedJiraIssue.key -eq $key){@($script:LoadedJiraIssue.comments)}else{@()}}
}

function New-JiraTestPlan($task) {
    $lines=New-Object System.Collections.ArrayList
    [void]$lines.Add("$($task.Key) - $($task.Title)");[void]$lines.Add("MODULE: $($task.Module)");[void]$lines.Add("ENVIRONMENT: $([string]$jiraEnvironmentCombo.SelectedItem)");[void]$lines.Add("ANALYSIS: $($task.AnalysisSource)");[void]$lines.Add("JIRA COMMENTS IMPORTED: $(@($task.JiraComments).Count)");[void]$lines.Add('');[void]$lines.Add((Get-TaskUnderstandingSummary -Task $task));[void]$lines.Add('')
    if(@($task.CurrentBehavior).Count -gt 0){[void]$lines.Add('CURRENT / BUG BEHAVIOR:');foreach($x in @($task.CurrentBehavior)){[void]$lines.Add("- $x")};[void]$lines.Add('')}
    if(@($task.ExpectedBehavior).Count -gt 0){[void]$lines.Add('EXPECTED:');foreach($x in @($task.ExpectedBehavior)){[void]$lines.Add("- $x")};[void]$lines.Add('')}
    if(@($task.ReproductionSteps).Count -gt 0){[void]$lines.Add('REPRODUCTION STEPS:');$i=1;foreach($x in @($task.ReproductionSteps)){[void]$lines.Add("$i. $x");$i++};[void]$lines.Add('')}
    [void]$lines.Add('PLANNED CHECKS:');[void]$lines.Add('- Core acceptance: каждый AC из Task Understanding Contract должен получить отдельный live verdict.');[void]$lines.Add('- Positive: основной рабочий сценарий и сохранение состояния, если релевантно.');[void]$lines.Add('- Negative: минимум один связанный негативный сценарий, если применимо.');[void]$lines.Add('- Boundary: граничные значения, если применимо.')
    if($jiraUiCheck.Checked){[void]$lines.Add('- UI: acceptance + risk-based UI behavior.')};if($jiraApiCheck.Checked){[void]$lines.Add('- API/Data consistency: запросы, ответы и UI/backend.')};if($jiraNetworkCheck.Checked){[void]$lines.Add('- Network/Console: failed requests / console errors.')};if($jiraRegressionCheck.Checked){[void]$lines.Add('- Regression: только непосредственно связанный функционал из Knowledge Base.')};[void]$lines.Add('')
    if($script:SmartCoverageDesign){[void]$lines.Add((New-SmartCoveragePlanSummary -Coverage $script:SmartCoverageDesign));[void]$lines.Add('')}
    [void]$lines.Add($(if($task.Automated){'AUTOMATION STATUS: TASK-SPEC READY'}else{'AUTOMATION STATUS: TASK-SPEC NOT READY'}))
    return (@($lines) -join "`r`n")
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
        acceptanceMatrix = @($task.AcceptanceMatrix)
        contractId = [string]$task.ContractId
        taskGoal = [string]$task.TaskGoal
        inScope = @($task.InScope)
        outOfScope = @($task.OutOfScope)
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
        acceptanceMatrix = @($script:CurrentJiraTask.AcceptanceMatrix)
        contractId = [string]$script:CurrentJiraTask.ContractId
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



function Test-KnowledgeLearningSafeText {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }

    $value = $Text.Trim()

    if ($value.Length -gt 1200) { return $false }

    # Never persist credentials/session material.
    if (
        $value -match '(?i)\b(password|парол|token|secret|api[ _-]?key|authorization|bearer|cookie|session(?:id)?|access[ _-]?key|client[ _-]?secret)\b'
    ) {
        return $false
    }

    # Do not turn transient run-scoped entity IDs into project memory.
    # Stable Client/Account IDs explicitly described as configuration are allowed.
    if (
        $value -match '(?i)\b(order|ticket|route|заказ|тикет|маршрут)\b.{0,40}\b\d{6,}\b' -and
        $value -notmatch '(?i)\b(client|account|facility)\s*(id|#)?\b'
    ) {
        return $false
    }

    return $true
}


function Get-SafeKnowledgeLearningStrings {
    param($Values)

    $result = New-Object System.Collections.ArrayList

    foreach ($value in @($Values)) {
        if ($null -eq $value) { continue }

        $textValue = ([string]$value).Trim()

        if (Test-KnowledgeLearningSafeText -Text $textValue) {
            if (-not $result.Contains($textValue)) {
                [void]$result.Add($textValue)
            }
        }
    }

    return @($result)
}


function Merge-UniqueKnowledgeLearningStrings {
    param(
        $Existing,
        $NewValues
    )

    $result = New-Object System.Collections.ArrayList

    foreach ($value in @($Existing) + @($NewValues)) {
        if ($null -eq $value) { continue }

        $textValue = ([string]$value).Trim()
        if (-not (Test-KnowledgeLearningSafeText -Text $textValue)) {
            continue
        }

        $already = $false

        foreach ($current in @($result)) {
            if (
                [string]::Equals(
                    [string]$current,
                    $textValue,
                    [System.StringComparison]::OrdinalIgnoreCase
                )
            ) {
                $already = $true
                break
            }
        }

        if (-not $already) {
            [void]$result.Add($textValue)
        }
    }

    return @($result)
}


function Test-KnowledgeAutoLearningSelfTest {
    try {
        $probe = New-Object System.Collections.ArrayList
        [void]$probe.Add('alpha')
        [void]$probe.Add('beta')

        $snapshot = @($probe)

        if ($snapshot.Count -ne 2) { return $false }

        $merged = @(
            Merge-UniqueKnowledgeLearningStrings `
                -Existing @('alpha') `
                -NewValues @('ALPHA','gamma')
        )

        if ($merged.Count -ne 2) { return $false }

        $safe = @(Get-SafeKnowledgeLearningStrings @('one','one','two'))

        if ($safe.Count -ne 2) { return $false }

        $jsonProbe = [ordered]@{
            verifiedAcceptance = @(
                [pscustomobject]@{
                    criterion = 'probe'
                    status = 'PASS'
                    evidence = 'current live evidence'
                }
            )
            facts = $merged
        } | ConvertTo-Json -Depth 5

        if ([string]::IsNullOrWhiteSpace($jsonProbe)) { return $false }

        return $true
    }
    catch {
        Append-AgentLog "KNOWLEDGE SELF-TEST → FAIL | $($_.Exception.Message)"
        return $false
    }
}

function Get-KnowledgeLearningModuleSlug {
    param([string]$Module)

    $slug = if ([string]::IsNullOrWhiteSpace($Module)) {
        'unknown'
    }
    else {
        $Module.ToLowerInvariant()
    }

    $slug = $slug -replace '[^a-z0-9]+','-'
    $slug = $slug.Trim('-')

    if ([string]::IsNullOrWhiteSpace($slug)) {
        $slug = 'unknown'
    }

    return $slug
}

function Get-KnowledgeLearningSourceText {
    if (
        $jiraImportedBox -and
        -not [string]::IsNullOrWhiteSpace([string]$jiraImportedBox.Text)
    ) {
        return [string]$jiraImportedBox.Text
    }

    if ($script:CurrentJiraTask -and $script:CurrentJiraTask.Raw) {
        return [string]$script:CurrentJiraTask.Raw
    }

    return ''
}

function Get-KnowledgeLearningCurrentResult {
    try {
        return [string](Get-JiraReportOverallResult)
    }
    catch {
        if ($script:LastSummary) {
            if ($script:LastSummary.Fail -gt 0) { return 'FAIL' }
            if ($script:LastSummary.Pass -gt 0) { return 'PASS' }
        }

        return 'UNKNOWN'
    }
}

function Invoke-PostRunKnowledgeCurator {
    param(
        $Task,
        $Summary
    )

    if (-not $Task -or -not $Task.Key) { return $null }

    $jiraSource = Get-KnowledgeLearningSourceText
    if ($jiraSource.Length -gt 14000) {
        $jiraSource = $jiraSource.Substring(0,14000) + "`n[TRUNCATED]"
    }

    $mcpJson = if ($script:AgentMcpExecution) {
        $script:AgentMcpExecution | ConvertTo-Json -Depth 14
    }
    else {
        '{}'
    }

    if ($mcpJson.Length -gt 18000) {
        $mcpJson = $mcpJson.Substring(0,18000) + "`n[TRUNCATED]"
    }

    $triageJson = if ($script:FailureTriage) {
        $script:FailureTriage | ConvertTo-Json -Depth 8
    }
    else {
        '{}'
    }

    $existingMemory = Get-KnowledgeMemoryPrompt
    if ($existingMemory.Length -gt 9000) {
        $existingMemory = $existingMemory.Substring(0,9000) + "`n[TRUNCATED]"
    }

    $productResult = Get-KnowledgeLearningCurrentResult

    $prompt = @"
You are the Rx2GO POST-RUN KNOWLEDGE CURATOR.

The QA test has finished. Distill only durable, reusable project knowledge that should help future Jira testing.

CURRENT TASK:
$($Task.Key) — $($Task.Title)
Module: $($Task.Module)
Product result: $productResult

CURRENT JIRA SOURCE USED FOR THIS RUN:
$jiraSource

CURRENT LIVE SMART QA EXECUTION:
$mcpJson

CURRENT FAILURE TRIAGE:
$triageJson

PREVIOUS RETRIEVED MEMORY:
$existingMemory

Return ONLY valid JSON:
{
  "status": "LEARNED|NO_NEW_KNOWLEDGE",
  "summary": "short summary in Russian",
  "stableProductFacts": ["durable verified fact"],
  "navigationFacts": ["reusable navigation/UI location fact"],
  "apiNetworkFacts": ["reusable API/network contract observed"],
  "testDataRules": ["stable reusable test-data rule"],
  "automationLessons": ["lesson that prevents future automation false failures"],
  "regressionCandidates": ["reusable regression scenario candidate"],
  "projectRuleCandidates": ["candidate global rule; advisory only"]
}

STRICT CURATION RULES:
- Learn only from CURRENT Jira source + CURRENT live MCP evidence + CURRENT Failure Triage.
- Previous retrieved memory is deduplication/reference context only; never promote an old claim just because it exists.
- Do not save PASS/FAIL itself as a permanent product fact.
- A current product defect may be saved only as a narrowly scoped observed issue/lesson, not as intended behavior.
- Persist stable field names, module behavior, navigation, expected contracts, locale/date behavior, reusable setup rules and automation pitfalls.
- Never persist passwords, tokens, cookies, auth headers, API keys, secrets or session data.
- Never persist temporary order/ticket/route IDs, current timestamps, random generated names, screenshot paths, browser PIDs or one-run-only data.
- A stable configured Client ID / Account ID / Facility rule may be saved only when explicitly stated in the current Jira source as reusable configuration.
- Do not invent selectors, routes, API endpoints or business rules not proven by current evidence.
- Keep each item concise and independently useful.
- Prefer fewer high-confidence facts over many weak ones.
- Avoid duplicates already present in PREVIOUS RETRIEVED MEMORY.
- automationLessons should capture TEST_AUTOMATION_BUG / environment / native-control / data-isolation lessons when relevant.
- regressionCandidates should describe behavior to recheck, not implementation details.
"@

    Append-AgentLog "KNOWLEDGE AUTO-LEARN → curator started for $($Task.Key)"

    $raw = Invoke-CodexAgent `
        -AgentSlug '05-knowledge-curator' `
        -Prompt $prompt `
        -TimeoutSec 150 `
        -ReasoningEffort low

    if (-not $raw) {
        Append-AgentLog "KNOWLEDGE AUTO-LEARN → curator unavailable; deterministic run snapshot will still be saved."
        return $null
    }

    $parsed = Convert-AgentJson $raw

    if (-not $parsed) {
        Append-AgentLog "KNOWLEDGE AUTO-LEARN → curator JSON invalid; deterministic run snapshot will still be saved."
        return $null
    }

    return $parsed
}

function Save-PostRunKnowledge {
    param(
        $Task,
        $Summary,
        $Curated
    )

    if (-not $Task -or -not $Task.Key) { return $null }

    $moduleSlug = Get-KnowledgeLearningModuleSlug -Module ([string]$Task.Module)
    $dir = Join-Path $script:ProjectRoot "knowledge\learned\$moduleSlug"
    New-Item -ItemType Directory -Path $dir -Force | Out-Null

    $safeKey = ([string]$Task.Key -replace '[^A-Za-z0-9_.-]','_')
    $path = Join-Path $dir "$safeKey.json"

    $existing = $null
    if (Test-Path $path) {
        try {
            $existingRaw = Get-Content -Raw -Path $path -ErrorAction Stop
            if (-not [string]::IsNullOrWhiteSpace($existingRaw)) {
                $existing = $existingRaw | ConvertFrom-Json -ErrorAction Stop
            }
        }
        catch {
            $existing = $null
        }
    }

    $curatedStable = if ($Curated) {
        Get-SafeKnowledgeLearningStrings $Curated.stableProductFacts
    } else { @() }

    $curatedNavigation = if ($Curated) {
        Get-SafeKnowledgeLearningStrings $Curated.navigationFacts
    } else { @() }

    $curatedApi = if ($Curated) {
        Get-SafeKnowledgeLearningStrings $Curated.apiNetworkFacts
    } else { @() }

    $curatedDataRules = if ($Curated) {
        Get-SafeKnowledgeLearningStrings $Curated.testDataRules
    } else { @() }

    $curatedAutomation = if ($Curated) {
        Get-SafeKnowledgeLearningStrings $Curated.automationLessons
    } else { @() }

    $curatedRegression = if ($Curated) {
        Get-SafeKnowledgeLearningStrings $Curated.regressionCandidates
    } else { @() }

    $curatedRuleCandidates = if ($Curated) {
        Get-SafeKnowledgeLearningStrings $Curated.projectRuleCandidates
    } else { @() }

    # Machine-grounded acceptance snapshot is always saved when available,
    # even if the optional AI curator fails.
    $verifiedAcceptance = New-Object System.Collections.ArrayList

    if ($script:AgentMcpExecution) {
        foreach ($item in @($script:AgentMcpExecution.acceptanceResults)) {
            if (-not $item) { continue }

            $criterion = [string]$item.criterion
            $evidence = [string]$item.evidence
            $status = ([string]$item.status).ToUpperInvariant()

            if (
                (Test-KnowledgeLearningSafeText -Text $criterion) -and
                (Test-KnowledgeLearningSafeText -Text $evidence)
            ) {
                [void]$verifiedAcceptance.Add([pscustomobject]@{
                    criterion = $criterion
                    status = $status
                    evidence = $evidence
                })
            }
        }
    }

    $existingStable = if ($existing) { @($existing.stableProductFacts) } else { @() }
    $existingNavigation = if ($existing) { @($existing.navigationFacts) } else { @() }
    $existingApi = if ($existing) { @($existing.apiNetworkFacts) } else { @() }
    $existingDataRules = if ($existing) { @($existing.testDataRules) } else { @() }
    $existingAutomation = if ($existing) { @($existing.automationLessons) } else { @() }
    $existingRegression = if ($existing) { @($existing.regressionCandidates) } else { @() }
    $existingRuleCandidates = if ($existing) { @($existing.projectRuleCandidates) } else { @() }

    $productResult = Get-KnowledgeLearningCurrentResult

    $failureLesson = $null
    if ($script:FailureTriage) {
        $failureSummary = [string]$script:FailureTriage.summary
        $failureAction = [string]$script:FailureTriage.recommendedAction

        if (
            (Test-KnowledgeLearningSafeText -Text $failureSummary) -and
            (Test-KnowledgeLearningSafeText -Text $failureAction)
        ) {
            $failureLesson = [pscustomobject]@{
                classification = [string]$script:FailureTriage.classification
                confidence = [string]$script:FailureTriage.confidence
                summary = $failureSummary
                recommendedAction = $failureAction
            }
        }
    }

    $dataStrategy = $null
    if ($script:AgentMcpExecution -and $script:AgentMcpExecution.testData) {
        $dataStrategy = [pscustomobject]@{
            created = [bool]$script:AgentMcpExecution.testData.created
            currentTaskVerified = [bool]$script:AgentMcpExecution.testData.currentTaskVerified
            selectionReason = [string]$script:AgentMcpExecution.testData.selectionReason
        }
    }

    $doc = [ordered]@{
        schemaVersion = 1
        jiraKey = [string]$Task.Key
        title = [string]$Task.Title
        module = [string]$Task.Module
        updatedAt = (Get-Date).ToString('o')
        lastProductResult = $productResult
        source = 'current Jira source + current live Smart QA + current Failure Triage'
        curatorStatus = if ($Curated -and $Curated.status) {
            [string]$Curated.status
        } else {
            'DETERMINISTIC_ONLY'
        }
        curatorSummary = if (
            $Curated -and
            (Test-KnowledgeLearningSafeText -Text ([string]$Curated.summary))
        ) {
            [string]$Curated.summary
        } else {
            'Current-run verified acceptance snapshot saved automatically.'
        }
        verifiedAcceptance = @($verifiedAcceptance)
        testDataStrategy = $dataStrategy
        failureLesson = $failureLesson
        stableProductFacts = @(
            Merge-UniqueKnowledgeLearningStrings `
                -Existing $existingStable `
                -NewValues $curatedStable
        )
        navigationFacts = @(
            Merge-UniqueKnowledgeLearningStrings `
                -Existing $existingNavigation `
                -NewValues $curatedNavigation
        )
        apiNetworkFacts = @(
            Merge-UniqueKnowledgeLearningStrings `
                -Existing $existingApi `
                -NewValues $curatedApi
        )
        testDataRules = @(
            Merge-UniqueKnowledgeLearningStrings `
                -Existing $existingDataRules `
                -NewValues $curatedDataRules
        )
        automationLessons = @(
            Merge-UniqueKnowledgeLearningStrings `
                -Existing $existingAutomation `
                -NewValues $curatedAutomation
        )
        regressionCandidates = @(
            Merge-UniqueKnowledgeLearningStrings `
                -Existing $existingRegression `
                -NewValues $curatedRegression
        )
        projectRuleCandidates = @(
            Merge-UniqueKnowledgeLearningStrings `
                -Existing $existingRuleCandidates `
                -NewValues $curatedRuleCandidates
        )
    }

    $json = $doc | ConvertTo-Json -Depth 12
    Write-Utf8NoBomFile -Path $path -Content $json

    $learnedCount = (
        @($doc.stableProductFacts).Count +
        @($doc.navigationFacts).Count +
        @($doc.apiNetworkFacts).Count +
        @($doc.testDataRules).Count +
        @($doc.automationLessons).Count +
        @($doc.regressionCandidates).Count +
        @($doc.projectRuleCandidates).Count
    )

    $script:LastKnowledgeLearning = [pscustomobject]@{
        JiraKey = [string]$Task.Key
        Module = [string]$Task.Module
        File = $path
        LearnedCount = $learnedCount
        AcceptanceCount = @($verifiedAcceptance).Count
        CuratorStatus = [string]$doc.curatorStatus
    }
    $script:LastKnowledgeLearningFile = $path

    Append-AgentLog "KNOWLEDGE AUTO-LEARN → saved $learnedCount reusable item(s) + $(@($verifiedAcceptance).Count) verified acceptance result(s)."
    Append-AgentLog "KNOWLEDGE AUTO-LEARN FILE → $path"

    if ($knowledgeSyncInfo) {
        $knowledgeSyncInfo.Text = "Auto-Learning: $($Task.Key) → $learnedCount новых/накопленных знаний. Готово для Commit / Synchronize."
        $knowledgeSyncInfo.ForeColor = [System.Drawing.Color]::FromArgb(32,120,72)
    }

    Refresh-KnowledgeUI -PreserveActionText

    return $script:LastKnowledgeLearning
}

function Update-KnowledgeFromCompletedRun {
    param(
        $Task,
        $Summary
    )

    if (-not $Task -or -not $Summary) { return $null }

    # Trust boundary: only a completed live Smart QA result may teach project facts.
    # If MCP never produced a result, skip auto-learning instead of learning from guesses.
    if (-not $script:AgentMcpExecution) {
        $script:LastKnowledgeWriteWarning = 'Новые знания не сохранены: отсутствует завершённое live Smart QA evidence.'
        Append-AgentLog "KNOWLEDGE AUTO-LEARN → skipped | $($script:LastKnowledgeWriteWarning)"
        return $null
    }

    try {
        if (-not (Test-KnowledgeAutoLearningSelfTest)) {
            $script:LastKnowledgeWriteWarning = 'Knowledge Base self-test не пройден. Новые знания не записаны, чтобы не повредить базу.'
            Append-AgentLog "KNOWLEDGE AUTO-LEARN → self-test blocked write."
            return $null
        }

        Append-AgentLog 'KNOWLEDGE SELF-TEST → PASS'

        $jiraTaskStatus.Text = "$(Get-KnowledgeLearningCurrentResult) — тест завершён; обновляю Knowledge Base…"
        $jiraTaskStatus.ForeColor = [System.Drawing.Color]::FromArgb(37,99,235)
        [System.Windows.Forms.Application]::DoEvents()

        $curated = Invoke-PostRunKnowledgeCurator `
            -Task $Task `
            -Summary $Summary

        $saved = Save-PostRunKnowledge `
            -Task $Task `
            -Summary $Summary `
            -Curated $curated

        if (-not $saved) {
            $script:LastKnowledgeWriteWarning = 'Не удалось сохранить новые знания в локальную Knowledge Base.'
        }
        else {
            $script:LastKnowledgeWriteWarning = $null
        }

        return $saved
    }
    catch {
        # Auto-learning must never rewrite the product verdict.
        $script:LastKnowledgeWriteWarning = "Не удалось сохранить новые знания: $($_.Exception.Message)"
        Append-AgentLog "KNOWLEDGE AUTO-LEARN → warning: $($script:LastKnowledgeWriteWarning)"
        return $null
    }
}


function Get-AutoGitSyncResultLabel {
    param($Result)

    if (-not $Result) { return 'not-run' }

    if ($Result.Success -and $Result.Pushed) { return 'pushed' }
    if ($Result.Success -and $Result.Committed) { return 'committed-local' }
    if ($Result.Success) { return 'already-synced' }

    return 'warning'
}

function Invoke-AutoGitCommitPushAfterJiraRun {
    param(
        $Task,
        $Summary
    )

    $result = [ordered]@{
        Success = $false
        Committed = $false
        Pushed = $false
        CommitHash = ''
        Branch = ''
        Message = ''
        Warning = ''
        FinishedAt = (Get-Date).ToString('o')
    }

    if (-not $script:AutoGitAfterJiraRun) {
        $result.Success = $true
        $result.Message = 'Automatic Git sync is disabled.'
        return [pscustomobject]$result
    }

    if (-not $Task -or -not $Task.Key) {
        $result.Warning = 'No Jira task context for automatic Git sync.'
        return [pscustomobject]$result
    }

    if ($script:GitBusy) {
        $result.Warning = 'Git is busy; automatic sync skipped.'
        return [pscustomobject]$result
    }

    $script:GitBusy = $true

    try {
        Append-AgentLog "AUTO GIT → preparing managed project changes for $($Task.Key)"

        if (-not (Test-GitInstalled)) {
            $result.Warning = 'Git is not installed.'
            Append-AgentLog "AUTO GIT → warning | $($result.Warning)"
            return [pscustomobject]$result
        }

        Initialize-KnowledgeGit -Silent

        $git = Get-GitState
        if (-not $git.Repository) {
            $result.Warning = 'Git repository is not available.'
            Append-AgentLog "AUTO GIT → warning | $($result.Warning)"
            return [pscustomobject]$result
        }

        if (-not (Set-KnowledgeOriginToSsh)) {
            $result.Warning = 'Could not configure SSH origin.'
            Append-AgentLog "AUTO GIT → warning | $($result.Warning)"
            return [pscustomobject]$result
        }

        $git = Get-GitState
        $result.Branch = [string]$git.Branch

        # Stage only explicitly whitelisted safe project paths.
        $pathArgs = @(Get-KnowledgeGitPathArgs)
        if ($pathArgs.Count -eq 0) {
            $result.Warning = 'Managed Git path list is empty.'
            Append-AgentLog "AUTO GIT → warning | $($result.Warning)"
            return [pscustomobject]$result
        }

        $addArgs = New-Object System.Collections.ArrayList
        [void]$addArgs.Add('add')
        [void]$addArgs.Add('-A')
        [void]$addArgs.Add('--')

        foreach ($path in $pathArgs) {
            [void]$addArgs.Add([string]$path)
        }

        $addResult = Invoke-Git @($addArgs) 120000
        if ($addResult.ExitCode -ne 0) {
            $result.Warning = "git add failed: $($addResult.Error) $($addResult.Output)".Trim()
            Append-AgentLog "AUTO GIT → warning | $($result.Warning)"
            return [pscustomobject]$result
        }

        $staged = Invoke-Git @('diff','--cached','--name-only') 15000
        $stagedFiles = @()

        if ($staged.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($staged.Output)) {
            $stagedFiles = @(
                $staged.Output -split "`r?`n" |
                    Where-Object { $_ }
            )

            $productResult = try {
                Get-JiraReportOverallResult
            }
            catch {
                if ($Summary -and $Summary.Fail -gt 0) { 'FAIL' } else { 'PASS' }
            }

            $commitMessage = "Auto QA $($Task.Key) $productResult " + (Get-Date -Format 'yyyy-MM-dd HH:mm')

            $commit = Invoke-Git @(
                'commit','-m',$commitMessage
            ) 30000

            if ($commit.ExitCode -ne 0) {
                $combinedCommit = (
                    ([string]$commit.Error) + "`n" +
                    ([string]$commit.Output)
                ).Trim()

                if ($combinedCommit -notmatch '(?i)nothing to commit') {
                    $result.Warning = "git commit failed: $combinedCommit"
                    Append-AgentLog "AUTO GIT → warning | $($result.Warning)"
                    return [pscustomobject]$result
                }
            }
            else {
                $result.Committed = $true

                $hash = Invoke-Git @('rev-parse','--short','HEAD') 10000
                if ($hash.ExitCode -eq 0) {
                    $result.CommitHash = [string]$hash.Output
                }

                Append-AgentLog "AUTO GIT → commit created | files=$($stagedFiles.Count) | hash=$($result.CommitHash)"
            }
        }
        else {
            Append-AgentLog 'AUTO GIT → no new managed file changes to commit.'
        }

        # Push previously unpushed local commits too.
        $privateKey = Get-GitHubSshPrivateKeyPath

        if (-not (Test-Path $privateKey)) {
            $result.Warning = 'SSH key is not configured. Local commit is preserved.'
            $result.Success = $result.Committed
            Append-AgentLog "AUTO GIT → warning | $($result.Warning)"
            return [pscustomobject]$result
        }

        $auth = Invoke-SshGitHubAuthCheck
        if (-not $auth.Success) {
            $result.Warning = "SSH authentication is not ready: $($auth.Message)"
            $result.Success = $result.Committed
            Append-AgentLog "AUTO GIT → warning | local commit preserved | $($result.Warning)"
            return [pscustomobject]$result
        }

        $git = Get-GitState
        $branch = [string]$git.Branch
        $result.Branch = $branch

        if ([string]::IsNullOrWhiteSpace($branch) -or $branch -eq 'detached') {
            $result.Warning = 'Cannot auto-push a detached Git HEAD.'
            $result.Success = $result.Committed
            Append-AgentLog "AUTO GIT → warning | $($result.Warning)"
            return [pscustomobject]$result
        }

        $remoteBranch = Invoke-Git @(
            'ls-remote','--exit-code','--heads','origin',$branch
        ) 30000

        if ($remoteBranch.ExitCode -ne 0) {
            $remoteMessage = (
                ([string]$remoteBranch.Error) + "`n" +
                ([string]$remoteBranch.Output)
            ).Trim()

            if (
                $remoteBranch.ExitCode -eq 2 -or
                [string]::IsNullOrWhiteSpace($remoteMessage)
            ) {
                $firstPush = Invoke-Git @(
                    'push','-u','origin',$branch
                ) 60000

                if ($firstPush.ExitCode -ne 0) {
                    $pushReason = (
                        ([string]$firstPush.Error) + "`n" +
                        ([string]$firstPush.Output)
                    ).Trim()

                    $result.Warning = "Initial push failed: $pushReason"
                    $result.Success = $result.Committed
                    Append-AgentLog "AUTO GIT → warning | local commit preserved | $($result.Warning)"
                    return [pscustomobject]$result
                }

                $result.Pushed = $true
                $result.Success = $true
                $result.Message = "Initial push completed to origin/$branch."
                Append-AgentLog "AUTO GIT → PUSH PASS | created origin/$branch"

                return [pscustomobject]$result
            }

            $result.Warning = "Could not inspect remote branch: $remoteMessage"
            $result.Success = $result.Committed
            Append-AgentLog "AUTO GIT → warning | $($result.Warning)"

            return [pscustomobject]$result
        }

        $fetch = Invoke-Git @(
            'fetch','origin',$branch
        ) 60000

        if ($fetch.ExitCode -ne 0) {
            $fetchReason = (
                ([string]$fetch.Error) + "`n" +
                ([string]$fetch.Output)
            ).Trim()

            $result.Warning = "Fetch failed: $fetchReason"
            $result.Success = $result.Committed
            Append-AgentLog "AUTO GIT → warning | local commit preserved | $($result.Warning)"

            return [pscustomobject]$result
        }

        $remoteRef = "origin/$branch"

        $behindRaw = (Invoke-Git @(
            'rev-list','--count',"HEAD..$remoteRef"
        ) 10000).Output

        $aheadRaw = (Invoke-Git @(
            'rev-list','--count',"$remoteRef..HEAD"
        ) 10000).Output

        $behind = 0
        $ahead = 0

        [void][int]::TryParse([string]$behindRaw, [ref]$behind)
        [void][int]::TryParse([string]$aheadRaw, [ref]$ahead)

        if ($behind -gt 0) {
            $git = Get-GitState

            if ($git.OtherChanges -gt 0) {
                $result.Warning = "Remote is ahead by $behind commit(s), but $($git.OtherChanges) unrelated local change(s) exist. Local commit preserved; auto-push paused for safety."
                $result.Success = $result.Committed
                Append-AgentLog "AUTO GIT → SAFE PAUSE | $($result.Warning)"

                return [pscustomobject]$result
            }

            $rebase = Invoke-Git @(
                'rebase',$remoteRef
            ) 60000

            if ($rebase.ExitCode -ne 0) {
                [void](Invoke-Git @('rebase','--abort') 15000)

                $rebaseReason = (
                    ([string]$rebase.Error) + "`n" +
                    ([string]$rebase.Output)
                ).Trim()

                $result.Warning = "Automatic rebase failed; rebase aborted and local commit preserved: $rebaseReason"
                $result.Success = $result.Committed
                Append-AgentLog "AUTO GIT → SAFE PAUSE | $($result.Warning)"

                return [pscustomobject]$result
            }

            Append-AgentLog "AUTO GIT → rebased onto $remoteRef"
        }

        $aheadRaw = (Invoke-Git @(
            'rev-list','--count',"$remoteRef..HEAD"
        ) 10000).Output

        $ahead = 0
        [void][int]::TryParse([string]$aheadRaw, [ref]$ahead)

        if ($ahead -le 0) {
            $result.Success = $true
            $result.Message = 'GitHub is already synchronized.'
            Append-AgentLog 'AUTO GIT → already synchronized.'

            return [pscustomobject]$result
        }

        $push = Invoke-Git @(
            'push','-u','origin',$branch
        ) 60000

        if ($push.ExitCode -ne 0) {
            $pushReason = (
                ([string]$push.Error) + "`n" +
                ([string]$push.Output)
            ).Trim()

            $result.Warning = "Push failed; local commit preserved: $pushReason"
            $result.Success = $result.Committed
            Append-AgentLog "AUTO GIT → warning | $($result.Warning)"

            return [pscustomobject]$result
        }

        $result.Pushed = $true
        $result.Success = $true
        $result.Message = "Pushed $ahead commit(s) to origin/$branch."

        Append-AgentLog "AUTO GIT → PUSH PASS | $($result.Message)"

        return [pscustomobject]$result
    }
    catch {
        $result.Warning = $_.Exception.Message
        $result.Success = $result.Committed
        Append-AgentLog "AUTO GIT → exception | local commit state preserved | $($result.Warning)"

        return [pscustomobject]$result
    }
    finally {
        $result.FinishedAt = (Get-Date).ToString('o')
        $script:GitBusy = $false
        Refresh-KnowledgeUI -PreserveActionText
    }
}

function Update-AutoGitUiStatus {
    param($GitResult)

    if (-not $GitResult) { return }

    if ($GitResult.Success -and $GitResult.Pushed) {
        if ($knowledgeSyncInfo) {
            $knowledgeSyncInfo.Text = "Auto Git: Commit + Push ✓  $($GitResult.CommitHash) → origin/$($GitResult.Branch)"
            $knowledgeSyncInfo.ForeColor = [System.Drawing.Color]::FromArgb(32,120,72)
        }

        return
    }

    if ($GitResult.Success -and -not [string]::IsNullOrWhiteSpace([string]$GitResult.Message)) {
        if ($knowledgeSyncInfo) {
            $knowledgeSyncInfo.Text = "Auto Git: $($GitResult.Message)"
            $knowledgeSyncInfo.ForeColor = [System.Drawing.Color]::FromArgb(32,120,72)
        }

        return
    }

    if ($knowledgeSyncInfo) {
        $knowledgeSyncInfo.Text = "Auto Git warning: $($GitResult.Warning)"
        $knowledgeSyncInfo.ForeColor = [System.Drawing.Color]::FromArgb(161,98,7)
    }
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

        # Automatic post-run learning:
        # persists verified current-run knowledge before the readable Jira report
        # so the report can state exactly what was learned.
        [void](Update-KnowledgeFromCompletedRun `
            -Task $script:CurrentJiraTask `
            -Summary $s)

        $script:LastAutoGitSync = Invoke-AutoGitCommitPushAfterJiraRun `
            -Task $script:CurrentJiraTask `
            -Summary $s

        Update-AutoGitUiStatus -GitResult $script:LastAutoGitSync

        if ($script:LastKnowledgeLearning) {
            try {
                Refresh-KnowledgeSaveState -VerifyRemote
            }
            catch { }
        }

        Show-KnowledgeWriteWarningAfterRun

        [void](Save-JiraReadableReport)
    }

    $notifyResult = Get-JiraProductNotificationResult

    if ($notifyResult -eq 'PASS') {
        if ($script:LastKnowledgeLearning -and $script:LastAutoGitSync -and $script:LastAutoGitSync.Pushed) {
            $jiraTaskStatus.Text = "PASS — тест завершён; Knowledge обновлена; GitHub синхронизирован автоматически"
        }
        elseif ($script:LastKnowledgeLearning -and $script:LastAutoGitSync -and -not $script:LastAutoGitSync.Pushed) {
            $jiraTaskStatus.Text = "PASS — тест завершён; Knowledge обновлена; Git sync warning"
        }
        elseif ($script:LastKnowledgeLearning) {
            $jiraTaskStatus.Text = "PASS — тест завершён; Knowledge Base обновлена ($($script:LastKnowledgeLearning.LearnedCount) знаний)"
        }
        else {
            $jiraTaskStatus.Text = 'PASS — тест завершён'
        }
        $jiraTaskStatus.ForeColor = [System.Drawing.Color]::FromArgb(32,120,72)
    }
    elseif ($notifyResult -eq 'FAIL') {
        if ($script:LastKnowledgeLearning -and $script:LastAutoGitSync -and $script:LastAutoGitSync.Pushed) {
            $jiraTaskStatus.Text = "FAIL — тест завершён; Knowledge обновлена; GitHub синхронизирован автоматически"
        }
        elseif ($script:LastKnowledgeLearning -and $script:LastAutoGitSync -and -not $script:LastAutoGitSync.Pushed) {
            $jiraTaskStatus.Text = "FAIL — тест завершён; Knowledge обновлена; Git sync warning"
        }
        elseif ($script:LastKnowledgeLearning) {
            $jiraTaskStatus.Text = "FAIL — тест завершён; Knowledge Base обновлена ($($script:LastKnowledgeLearning.LearnedCount) знаний)"
        }
        $jiraTaskStatus.ForeColor = [System.Drawing.Color]::Firebrick
    }

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

    # Final overwrite after RCA + Knowledge Auto-Learning + Git sync + final UI result.
    # This prevents an earlier intermediate report from remaining on disk with
    # "ФИНАЛЬНЫЙ PLAYWRIGHT: ещё не завершён".
    [void](Save-JiraReadableReport)
    Append-AgentLog 'JIRA REPORT FINALIZED → contains final Playwright/RCA/Knowledge/Git state.'

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

    if ($script:QueueWorkerMode) {
        $queueResult = if ($notifyResult -in @('PASS','FAIL')) { $notifyResult } else { 'ERROR' }
        Complete-QueueWorkerResult -Result $queueResult -Details ([string]$jiraTaskStatus.Text)
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

RETRIEVED KNOWLEDGE MEMORY:
$(Get-KnowledgeMemoryPrompt)

RULES:
- Use prior failure patterns only as supporting comparison; diagnose the current failure from current evidence.
- Do not automatically call every FAIL a product bug.
- Distinguish bad selector/assertion, auth, missing test data, environment/network and genuine product behavior.
- Prefer concrete runtime evidence over assumptions.
- For date-format tasks, if FAIL was inferred only from a native input[type=date] screenshot captured under the wrong browser locale, classify it as TEST_AUTOMATION_BUG or ENVIRONMENT_ERROR, not PRODUCT_BUG.
- Reusing test data visibly marked with another Jira key is TEST_DATA_ERROR, not product evidence.
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
            if (-not $script:QueueWorkerMode) {
                [System.Windows.Forms.MessageBox]::Show(
                    "Codex runner не прошёл self-test.`r`n`r`n$($script:LastAgentError)`r`n`r`nСмотри reports\ai\agents\SELFTEST.",
                    'Rx2GO QA — Codex','OK','Error'
                ) | Out-Null
            }
            return
        }
        $script:CodexRunnerVerified = $true
    }

    if (-not (Ensure-PlaywrightDependencies)) {
        $jiraTaskStatus.Text = "Playwright precheck failed: $($script:LastAgentError)"
        $jiraTaskStatus.ForeColor = [System.Drawing.Color]::Firebrick
        return
    }

    if (-not $script:IntegrityGuardVerified) {
        $jiraTaskStatus.Text = 'Проверяю Result Integrity Guard…'
        $jiraTaskStatus.ForeColor = [System.Drawing.Color]::FromArgb(37,99,235)
        [System.Windows.Forms.Application]::DoEvents()

        if (-not (Test-SmartQaIntegrityGuardSelfTest)) {
            $jiraTaskStatus.Text = 'Result Integrity Guard self-test failed'
            $jiraTaskStatus.ForeColor = [System.Drawing.Color]::Firebrick
            if (-not $script:QueueWorkerMode) {
                [System.Windows.Forms.MessageBox]::Show(
                    'Встроенная проверка Result Integrity Guard не прошла. Тест остановлен, чтобы не получить ложный PASS/FAIL.',
                    'Rx2GO QA — Integrity Guard','OK','Error'
                ) | Out-Null
            }
            return
        }

        $script:IntegrityGuardVerified = $true
        Append-AgentLog 'RESULT INTEGRITY SELF-TEST → PASS'
    }

    if (-not (Ensure-PlaywrightMcpForCodex)) {
        $jiraTaskStatus.Text = "Playwright MCP precheck failed: $($script:LastAgentError)"
        $jiraTaskStatus.ForeColor = [System.Drawing.Color]::Firebrick
        if (-not $script:QueueWorkerMode) {
            [System.Windows.Forms.MessageBox]::Show(
                "Microsoft Playwright MCP не подключён к Codex.`r`n`r`n$($script:LastAgentError)`r`n`r`nSmart QA не будет продолжать тест вслепую.",
                'Rx2GO QA — Playwright MCP','OK','Error'
            ) | Out-Null
        }
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
                $script:SuppressJiraImportedEditEvent = $true
                try {
                    $jiraImportedBox.Text = Format-JiraIssueForPreview $jiraIssue
                }
                finally {
                    $script:SuppressJiraImportedEditEvent = $false
                }
                $script:JiraImportedEdited = $false
                $jiraImportedInfo.Text = "$issueKey загружена • Jira comments: $(@($jiraIssue.comments).Count) • поле редактируемое"
            }
        }

        if (-not $jiraIssue) {
            if (-not $script:QueueWorkerMode) {
                [System.Windows.Forms.MessageBox]::Show(
                    "Не удалось загрузить $issueKey через Jira API.`r`n`r`n$($script:JiraFetchedSource)",
                    'Rx2GO QA','OK','Error'
                ) | Out-Null
            }
            return
        }
    }

    $qaComment = $jiraQaCommentBox.Text.Trim()
    $projectRules = @(Get-Rx2GOProjectRules)

    if (
        $jiraIssue -and
        $jiraImportedBox -and
        -not [string]::IsNullOrWhiteSpace([string]$jiraImportedBox.Text)
    ) {
        $analysisText = $jiraImportedBox.Text.Trim()

        if ($script:JiraImportedEdited) {
            Append-AgentLog "JIRA SOURCE → editable imported Description/comments (MANUALLY EDITED)."
        }
        else {
            Append-AgentLog "JIRA SOURCE → editable imported Description/comments (unchanged from Jira load)."
        }
    }
    else {
        $analysisText = $rawInput
        Append-AgentLog "JIRA SOURCE → direct task input."
    }

    # Knowledge Retrieval runs BEFORE AI analysis.
    # It safely fetches the remote Git snapshot without changing the working tree,
    # then retrieves only task-relevant prior cases/scenarios/tests/helpers.
    $jiraTaskStatus.Text = 'Knowledge Retrieval: ищу релевантный опыт в GitHub/local repository…'
    $jiraTaskStatus.ForeColor = [System.Drawing.Color]::FromArgb(37,99,235)
    [System.Windows.Forms.Application]::DoEvents()

    $preMemory = Get-RelevantKnowledgeContext `
        -JiraText $analysisText `
        -QaComment $qaComment `
        -IssueKey $issueKey `
        -Stage 'pre-analysis'

    $preMemoryContext = if ($preMemory) {
        [string]$preMemory.Context
    } else {
        'No relevant retrieved memory available.'
    }

    if ($preMemory) {
        Append-AgentLog "KNOWLEDGE RETRIEVAL PRE → $($preMemory.Count) relevant file(s) | $($preMemory.RemoteSnapshot)"
        Append-AgentLog "KNOWLEDGE RETRIEVAL ARTIFACT → $($preMemory.TextArtifact)"
        Show-KnowledgeReadWarningOnce -RemoteStatus ([string]$preMemory.RemoteSnapshot)
    }
    else {
        Show-KnowledgeReadWarningOnce -RemoteStatus 'LOCAL ONLY'
    }

    # 1/3 — Requirements Analyst
    $jiraTaskStatus.Text = '1/3 Requirements Analyst: строю и проверяю понимание задачи…'
    $jiraTaskStatus.ForeColor = [System.Drawing.Color]::FromArgb(37,99,235)
    $aiAnalysis = Invoke-AgentJiraAnalyst `
        -JiraText $analysisText `
        -QaComment $qaComment `
        -ProjectRules $projectRules `
        -KnowledgeContext $preMemoryContext

    if (-not $aiAnalysis) {
        $jiraTaskStatus.Text = "Requirements Analyst failed: $($script:LastAgentError)"
        $jiraTaskStatus.ForeColor = [System.Drawing.Color]::Firebrick
        Show-AgentPipelineFailure -Stage '1/3 — Requirements Analyst' -Reason $script:LastAgentError
        return
    }

    $script:TaskUnderstandingGate = Test-TaskUnderstandingContract -Analysis $aiAnalysis -JiraText $analysisText
    if (-not $script:TaskUnderstandingGate.Success) {
        $understandingError = [string]$script:TaskUnderstandingGate.Error
        $jiraAutomationValue.Text = 'TASK UNDERSTANDING - BLOCKED'
        $jiraAutomationValue.ForeColor = [System.Drawing.Color]::FromArgb(197,119,0)
        $jiraTaskStatus.Text = "ЗАДАЧА ПОНЯТА НЕОДНОЗНАЧНО - $understandingError"
        $jiraTaskStatus.ForeColor = [System.Drawing.Color]::FromArgb(197,119,0)
        $jiraPlanBox.Text = "TASK UNDERSTANDING GATE: BLOCKED`r`n`r`n$understandingError`r`n`r`nИсправь/уточни редактируемое описание Jira и запусти проверку повторно."
        Append-AgentLog "TASK UNDERSTANDING GATE -> BLOCKED | $understandingError"
        if ($script:QueueWorkerMode) { Complete-QueueWorkerResult -Result BLOCKED -Details "[TASK_UNDERSTANDING] $understandingError" }
        return
    }
    Append-AgentLog "TASK UNDERSTANDING GATE -> PASS | confidence $([int]$aiAnalysis.confidence)%"
    foreach($understandingWarning in @($script:TaskUnderstandingGate.Warnings)){if($understandingWarning){Append-AgentLog "TASK UNDERSTANDING WARNING -> $understandingWarning"}}

    $task = Get-JiraTaskInfo $analysisText $aiAnalysis $qaComment $projectRules
    $script:CurrentJiraTask = $task

    # Refine retrieval now that the Analyst resolved the module and acceptance.
    $refinedMemoryText = @(
        $analysisText
        $qaComment
        [string]$task.Module
        (@($task.Criteria) -join "`n")
        (@($task.RiskAreas) -join "`n")
    ) -join "`n"

    $refinedMemory = Get-RelevantKnowledgeContext `
        -JiraText $refinedMemoryText `
        -QaComment $qaComment `
        -IssueKey $task.Key `
        -Module ([string]$task.Module) `
        -Stage 'refined'

    if ($refinedMemory) {
        $script:LastKnowledgeRetrieval = $refinedMemory
        $script:LastKnowledgeContext = [string]$refinedMemory.Context
        Append-AgentLog "KNOWLEDGE RETRIEVAL REFINED → $($refinedMemory.Count) relevant file(s) | module $($task.Module)"
        Append-AgentLog "KNOWLEDGE RETRIEVAL ARTIFACT → $($refinedMemory.TextArtifact)"
    }
    else {
        $script:LastKnowledgeRetrieval = $preMemory
        $script:LastKnowledgeContext = $preMemoryContext
    }

    $jiraTaskStatus.Text = 'Проектирую дополнительные негативные и регрессионные кейсы…'
    $script:SmartCoverageDesign = Invoke-SmartCoverageDesigner `
        -Task $task `
        -JiraText $analysisText `
        -QaComment $qaComment `
        -ProjectRules $projectRules `
        -KnowledgeContext (Get-KnowledgeMemoryPrompt)

    $jiraModuleValue.Text = $task.Module
    $jiraAutomationValue.Text = 'SMART QA RUNNING'
    $jiraAutomationValue.ForeColor = [System.Drawing.Color]::FromArgb(37,99,235)

    $memoryPlan = Get-KnowledgeMemorySummary
    $jiraPlanBox.Text = (New-JiraTestPlan $task) + "`r`n`r`nMEMORY:`r`n$memoryPlan"
    [System.Windows.Forms.Application]::DoEvents()

    # Bootstrap ONE authenticated Chrome only.
    # Do NOT run the old Live Browser Context diagnostic here: MCP itself
    # owns live page discovery and must work against this exact persistent session.
    $env:RX2GO_BROWSER_LOCALE = 'en-US'
    if (Test-TaskRequiresUsDateLocale -JiraText $analysisText -QaComment $qaComment) {
        Append-AgentLog 'BROWSER LOCALE → en-US (required by MM/DD/YYYY task).'
    }
    else {
        Append-AgentLog 'BROWSER LOCALE → en-US (Rx2GO QA default).'
    }

    $jiraTaskStatus.Text = 'Browser bootstrap: авторизация и запуск одной Chrome-сессии…'
    if (-not (Bootstrap-PersistentBrowserSession -Environment ([string]$jiraEnvironmentCombo.SelectedItem))) {
        $jiraAutomationValue.Text = 'BROWSER BOOTSTRAP FAILED'
        $jiraAutomationValue.ForeColor = [System.Drawing.Color]::Firebrick
        $jiraTaskStatus.Text = "Browser bootstrap failed: $($script:LastAgentError)"
        $jiraTaskStatus.ForeColor = [System.Drawing.Color]::Firebrick

        Append-AgentLog 'PIPELINE STOPPED before MCP preflight.'
        Append-AgentLog 'Chrome is intentionally NOT killed on bootstrap failure when a session was created.'

        if (-not $script:QueueWorkerMode) {
            [System.Windows.Forms.MessageBox]::Show(
                "Browser bootstrap не завершён.`r`n`r`n$($script:LastAgentError)`r`n`r`nЕсли Chrome успел открыться, он оставлен открытым для проверки.",
                'Rx2GO QA — Browser bootstrap','OK','Error'
            ) | Out-Null
        }

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
        -ProjectRules $projectRules `
        -KnowledgeContext (Get-KnowledgeMemoryPrompt) `
        -CoverageDesign $script:SmartCoverageDesign

    if (-not $mcpExecution) {
        if (
            [string]$script:LastAgentFailureKind -eq 'CODEX_USAGE_LIMIT' -or
            (Test-CodexUsageLimitText -Text ([string]$script:LastAgentError))
        ) {
            $limitMessage = Get-CodexFailureUserMessage `
                -FailureKind 'CODEX_USAGE_LIMIT' `
                -ErrorText ([string]$script:LastAgentError)

            $jiraAutomationValue.Text = 'CODEX LIMIT — ПАУЗА'
            $jiraAutomationValue.ForeColor = [System.Drawing.Color]::FromArgb(197,119,0)
            $jiraTaskStatus.Text = "ПРОВЕРКА ПРЕРВАНА — $limitMessage"
            $jiraTaskStatus.ForeColor = [System.Drawing.Color]::FromArgb(197,119,0)

            Append-AgentLog "PIPELINE PAUSED → CODEX_USAGE_LIMIT | $limitMessage"

            # No product PASS/FAIL and no Knowledge Auto-Learning:
            # the live Smart QA execution did not produce a complete verdict.
            $jiraCopyReportButton.Enabled = $false
            $jiraRegressionButton.Enabled = $true

            if ($script:QueueWorkerMode) {
                try { Stop-PersistentBrowserSession } catch {}
                Complete-QueueWorkerResult `
                    -Result BLOCKED `
                    -Details "[CODEX_USAGE_LIMIT] $limitMessage"
            }

            return
        }

        $jiraAutomationValue.Text = 'MCP QA FAILED'
        $jiraAutomationValue.ForeColor = [System.Drawing.Color]::Firebrick
        $jiraTaskStatus.Text = "Playwright MCP QA failed: $($script:LastAgentError)"
        $jiraTaskStatus.ForeColor = [System.Drawing.Color]::Firebrick
        Show-AgentPipelineFailure -Stage '2/3 — Playwright MCP QA' -Reason $script:LastAgentError
        return
    }

    if (([string]$mcpExecution.status).ToUpperInvariant() -eq 'BLOCKED') {
        $task.Automated = $false

        $blockReason = (@($mcpExecution.blockers) | Where-Object { $_ } | Select-Object -First 1)
        if (-not $blockReason) {
            $blockReason = 'Не удалось получить достаточно данных для полного доказательства acceptance criteria.'
        }

        $jiraAutomationValue.Text = 'НЕДОСТАТОЧНО ДАННЫХ'
        $jiraAutomationValue.ForeColor = [System.Drawing.Color]::FromArgb(197,119,0)

        $jiraTaskStatus.Text = "НЕДОСТАТОЧНО ДАННЫХ — $blockReason"
        $jiraTaskStatus.ForeColor = [System.Drawing.Color]::FromArgb(197,119,0)

        Append-AgentLog "FINAL LIVE STATE → НЕДОСТАТОЧНО ДАННЫХ | $blockReason"

        Complete-JiraBlockedLiveRun `
            -Task $task `
            -McpExecution $mcpExecution `
            -Reason ([string]$blockReason)

        return
    }

    $freshDataRequired = Test-RunRequiresFreshData -Task $task -QaComment $qaComment
    Append-AgentLog "FRESH DATA POLICY → $(if ($freshDataRequired) { 'REQUIRED' } else { 'OPTIONAL / NOT REQUIRED' })"

    if (-not (Test-McpFreshDataSatisfied -Task $task -McpExecution $mcpExecution -QaComment $qaComment)) {
        $task.Automated = $false
        $jiraAutomationValue.Text = 'НЕДОСТАТОЧНО ДАННЫХ — FRESH FIXTURE'
        $jiraAutomationValue.ForeColor = [System.Drawing.Color]::FromArgb(197,119,0)
        $jiraTaskStatus.Text = "НЕДОСТАТОЧНО ДАННЫХ — $($script:LastAgentError)"
        $jiraTaskStatus.ForeColor = [System.Drawing.Color]::FromArgb(197,119,0)
        Append-AgentLog "FRESH DATA GUARD → НЕДОСТАТОЧНО ДАННЫХ | $($script:LastAgentError)"

        Complete-JiraBlockedLiveRun `
            -Task $task `
            -McpExecution $mcpExecution `
            -Reason ([string]$script:LastAgentError)

        return
    }

    # 3/3 — Reviewer turns proven live evidence into deterministic Playwright.
    $jiraTaskStatus.Text = '3/3 QA Reviewer: собираю Playwright из реальных действий MCP…'
    $generatedSpec = Invoke-AgentSmartReviewer `
        -Task $task `
        -McpExecution $mcpExecution `
        -McpExecutionRaw $script:AgentMcpExecutionRaw `
        -QaComment $qaComment `
        -ProjectRules $projectRules `
        -KnowledgeContext (Get-KnowledgeMemoryPrompt) `
        -CoverageDesign $script:SmartCoverageDesign

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
    $plan += "`r`n`r`nKNOWLEDGE MEMORY USED:`r`n$(Get-KnowledgeMemorySummary)"
    if ($script:LastKnowledgeRetrieval -and $script:LastKnowledgeRetrieval.Items) {
        foreach ($memoryItem in @($script:LastKnowledgeRetrieval.Items | Select-Object -First 10)) {
            $plan += "`r`n- [$($memoryItem.Category)/$($memoryItem.Source)] $($memoryItem.Path)"
        }
    }
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
    $jiraMutatingCheck.Checked = $true
    $mutatingCheck.Checked = $true

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
        [ValidateSet('PASS','FAIL','BLOCKED')]
        [string]$Result,
        [string]$Title = '',
        [string]$Details = '',
        [int]$DurationMs = 6500
    )

    if ($script:QueueWorkerMode) { return }

    try {
        $isPass = ($Result -eq 'PASS')
        $isBlocked = ($Result -eq 'BLOCKED')

        if ($isPass) {
            try { [System.Media.SystemSounds]::Asterisk.Play() } catch {}
        }
        elseif ($isBlocked) {
            try { [System.Media.SystemSounds]::Exclamation.Play() } catch {}
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
        elseif ($isBlocked) {
            $toast.BackColor = [System.Drawing.Color]::FromArgb(202, 138, 4)
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
        elseif ($isBlocked) {
            '⚠ НЕДОСТАТОЧНО ДАННЫХ'
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
        'BLOCKED' { return '⚠ НЕДОСТАТОЧНО ДАННЫХ' }
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
    if ($script:LoadedJiraIssueKey) {
        $lines.Add("*Jira source:* $(if ($script:JiraImportedEdited) { 'импортированный текст отредактирован вручную перед тестом' } else { 'импортированный текст без ручных изменений' })")
    }
    if ($script:AgentMcpExecution -and $script:AgentMcpExecution.integrity) {
        $lines.Add("*Result Integrity Gate:* PASS")
    }
    if ($script:LastKnowledgeRetrieval) {
        $lines.Add("*Knowledge Memory:* $($script:LastKnowledgeRetrieval.Count) релевантных файлов; $($script:LastKnowledgeRetrieval.RemoteSnapshot)")
    }
    if ($script:LastKnowledgeLearning) {
        $lines.Add("*Knowledge Auto-Learning:* сохранено/накоплено $($script:LastKnowledgeLearning.LearnedCount) reusable знаний + $($script:LastKnowledgeLearning.AcceptanceCount) verified acceptance result(s)")
        $lines.Add("*Knowledge file:* knowledge/learned/$(Get-KnowledgeLearningModuleSlug -Module ([string]$script:LastKnowledgeLearning.Module))/$($script:LastKnowledgeLearning.JiraKey).json")
    }
    if ($script:LastAutoGitSync) {
        $gitLabel = Get-AutoGitSyncResultLabel -Result $script:LastAutoGitSync
        $lines.Add("*Auto Git:* $gitLabel")

        if ($script:LastAutoGitSync.CommitHash) {
            $lines.Add("*Git commit:* $($script:LastAutoGitSync.CommitHash)")
        }

        if ($script:LastAutoGitSync.Message) {
            $lines.Add("*Git sync:* $($script:LastAutoGitSync.Message)")
        }

        if ($script:LastAutoGitSync.Warning) {
            $lines.Add("*Git sync warning:* $($script:LastAutoGitSync.Warning)")
        }
    }
    $lines.Add("*Действия с тестовыми данными:* ВСЕГДА РАЗРЕШЕНЫ — create / update / modify / transition / link / assign / delete / recreate / cleanup по необходимости")
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

        $additionalCases = @($mcp.additionalResults | Where-Object { $_ })
        if ($additionalCases.Count -gt 0) {
            $lines.Add('')
            $lines.Add('*ДОПОЛНИТЕЛЬНЫЕ НЕГАТИВНЫЕ / ГРАНИЧНЫЕ / РЕГРЕССИОННЫЕ КЕЙСЫ*')

            foreach ($extra in $additionalCases) {
                $status = if ($extra.status) {
                    ([string]$extra.status).ToUpperInvariant()
                } else {
                    'BLOCKED'
                }

                $mark = Get-JiraStatusMark $status
                $type = if ($extra.type) { [string]$extra.type } else { 'ADDITIONAL' }
                $priority = if ($extra.priority) { [string]$extra.priority } else { 'P1' }
                $caseText = if ($extra.case) { [string]$extra.case } else { 'Risk-based check' }

                $lines.Add("$caseNo. $mark — [$type/$priority] $caseText")

                if (-not [string]::IsNullOrWhiteSpace([string]$extra.evidence)) {
                    $lines.Add("   Проверено: $([string]$extra.evidence)")
                }

                if ([bool]$extra.affectsOverallResult) {
                    $lines.Add('   Влияет на итог задачи: да')
                }
                else {
                    $lines.Add('   Влияет на итог задачи: нет / advisory')
                }

                $caseNo++
            }
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

    if ($script:LastKnowledgeRetrieval -and @($script:LastKnowledgeRetrieval.Items).Count -gt 0) {
        $lines.Add('')
        $lines.Add('*ИСПОЛЬЗОВАННАЯ ПАМЯТЬ*')
        foreach ($memoryItem in @($script:LastKnowledgeRetrieval.Items | Select-Object -First 8)) {
            $lines.Add("- [$($memoryItem.Category)/$($memoryItem.Source)] $($memoryItem.Path)")
        }
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
    $mutatingCheck.Enabled = $false
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

    if ($script:QueueWorkerMode -and $script:JiraRunActive) {
        Write-QueueWorkerStatus -Status 'RUNNING' -Phase 'PLAYWRIGHT' -Detail 'Deterministic Playwright execution'
    }

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

if ($script:QueueWorkerMode) {
    $form.ShowInTaskbar = $false
    $form.WindowState = [System.Windows.Forms.FormWindowState]::Minimized
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
    $form.Location = New-Object System.Drawing.Point(-32000,-32000)
    $form.Opacity = 0.01
}

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
$mutatingCheck.Text = 'Тестовые данные: любые изменения всегда разрешены'
$mutatingCheck.Font = New-Font 9
$mutatingCheck.Checked = $true
$mutatingCheck.Enabled = $false
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
    if ($script:QueueWorkerMode) { return }

    $queueActive = @($script:QueueItems | Where-Object { $_.Status -in @('STARTING','ANALYZING','TESTING','REVIEWING','PLAYWRIGHT','RCA','SYNCING') }).Count
    if ($queueActive -gt 0) {
        $answerQueue = [System.Windows.Forms.MessageBox]::Show(
            "В Jira Queue ещё выполняется $queueActive Worker(s). Остановить их и закрыть Launcher?",
            'Rx2GO QA — Jira Queue','YesNo','Warning'
        )
        if ($answerQueue -ne [System.Windows.Forms.DialogResult]::Yes) {
            $_.Cancel = $true
            return
        }
        Stop-AllQueueWorkers
    }

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

$queueTab = New-Object System.Windows.Forms.TabPage
$queueTab.Text = 'Jira Queue'
$queueTab.BackColor = [System.Drawing.Color]::FromArgb(246,248,251)
$queueTab.AutoScroll = $false
$tabs.TabPages.Add($queueTab) | Out-Null

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
    $script:JiraImportedEdited = $false
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
$jiraImportedBox.ReadOnly = $false
$jiraImportedBox.Font = New-Object System.Drawing.Font('Consolas', 9)
$jiraImportedBox.BackColor = [System.Drawing.Color]::White
$jiraImportedBox.Location = New-Object System.Drawing.Point(18, 240)
$jiraImportedBox.Size = New-Object System.Drawing.Size(1132, 150)
$jiraImportedBox.Anchor = 'Top,Left,Right'
$jiraImportedBox.Text = 'Нажми «Загрузить Jira». Здесь будут реальный Description и все Jira comments. После загрузки текст можно редактировать — Smart QA использует именно этот вариант.'
$jiraTab.Controls.Add($jiraImportedBox)

$jiraImportedBox.Add_TextChanged({
    if (
        -not $script:SuppressJiraImportedEditEvent -and
        $script:LoadedJiraIssueKey
    ) {
        $script:JiraImportedEdited = $true

        if ($jiraImportedInfo) {
            $jiraImportedInfo.Text = "$($script:LoadedJiraIssueKey) • изменено вручную • этот текст пойдёт в Smart QA"
            $jiraImportedInfo.ForeColor = [System.Drawing.Color]::FromArgb(161,98,7)
        }
    }
})


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
$jiraMutatingCheck.Text = 'Тестовые данные: любые изменения всегда разрешены'
$jiraMutatingCheck.Checked = $true
$jiraMutatingCheck.Enabled = $false
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
$knowledgeHint.Text = 'Переносимые знания хранятся в GitHub через SSH. Browser OAuth для GitHub не используется. Секреты, отчёты, screenshots и traces в репозиторий не попадают.'
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
$knowledgeExplorerValue = Add-KnowledgeCard 'Explored modules' 860

# Knowledge Explorer controls are reparented into a responsive TableLayoutPanel
# inside Apply-ResponsiveLayout. No absolute layout is used for the final UI.

$knowledgeExplorerEnvironmentCombo = New-Object System.Windows.Forms.ComboBox
$knowledgeExplorerEnvironmentCombo.DropDownStyle = 'DropDownList'
[void]$knowledgeExplorerEnvironmentCombo.Items.Add('ADM')
[void]$knowledgeExplorerEnvironmentCombo.Items.Add('HOT')
[void]$knowledgeExplorerEnvironmentCombo.Items.Add('BRANCH')
$knowledgeExplorerEnvironmentCombo.SelectedIndex = 0
$knowledgeExplorerEnvironmentCombo.Add_SelectedIndexChanged({
    Update-KnowledgeExplorerEnvironmentUi
})

$knowledgeExplorerBaselineValueLabel = New-Object System.Windows.Forms.Label
$knowledgeExplorerBaselineValueLabel.Text = '—  основная база'
$knowledgeExplorerBaselineValueLabel.AutoEllipsis = $true

$knowledgeExplorerModeCombo = New-Object System.Windows.Forms.ComboBox
$knowledgeExplorerModeCombo.DropDownStyle = 'DropDownList'
[void]$knowledgeExplorerModeCombo.Items.Add('Быстрый crawl — структура')
[void]$knowledgeExplorerModeCombo.Items.Add('Глубокий crawl — UI + API + Network')
[void]$knowledgeExplorerModeCombo.Items.Add('Полный проект — карта + все модули')
[void]$knowledgeExplorerModeCombo.Items.Add('Изучить модуль')
[void]$knowledgeExplorerModeCombo.Items.Add('Изучить workflow')
[void]$knowledgeExplorerModeCombo.Items.Add('Обновить устаревшие знания')
$knowledgeExplorerModeCombo.SelectedIndex = 0
$knowledgeExplorerModeCombo.Add_SelectedIndexChanged({
    Update-KnowledgeExplorerModeUi
})

$knowledgeExplorerModuleCombo = New-Object System.Windows.Forms.ComboBox
$knowledgeExplorerModuleCombo.DropDownStyle = 'DropDownList'

foreach ($module in @(Get-KnowledgeExplorerModuleDefinitions)) {
    [void]$knowledgeExplorerModuleCombo.Items.Add([string]$module.Name)
}

$knowledgeExplorerModuleCombo.SelectedIndex = 0

$knowledgeExplorerTargetBox = New-Object System.Windows.Forms.TextBox
$knowledgeExplorerTargetBox.Text = ''
$knowledgeExplorerTargetBox.Font = New-Font 9

$knowledgeAdmDailyPasswordLabel = New-Object System.Windows.Forms.Label
$knowledgeAdmDailyPasswordLabel.Text = 'ADM код Telegram'
$knowledgeAdmDailyPasswordLabel.Font = New-Font 8 ([System.Drawing.FontStyle]::Bold)
$knowledgeAdmDailyPasswordLabel.AutoEllipsis = $true

$knowledgeAdmDailyPasswordBox = New-Object System.Windows.Forms.TextBox
$knowledgeAdmDailyPasswordBox.UseSystemPasswordChar = $true
$knowledgeAdmDailyPasswordBox.Font = New-Font 9
$knowledgeAdmDailyPasswordBox.Text = if ($dailyPassword) { [string]$dailyPassword.Text } else { '' }
$knowledgeAdmDailyPasswordBox.Add_TextChanged({
    Sync-AdmDailyPasswordFields `
        -Source 'Knowledge' `
        -Value ([string]$knowledgeAdmDailyPasswordBox.Text)
})

if ($dailyPassword) {
    $dailyPassword.Add_TextChanged({
        Sync-AdmDailyPasswordFields `
            -Source 'QuickRun' `
            -Value ([string]$dailyPassword.Text)
    })
}

$knowledgeExplorerStartButton = New-Object System.Windows.Forms.Button
$knowledgeExplorerStartButton.Text = '▶ ИЗУЧИТЬ ADM'
$knowledgeExplorerStartButton.Font = New-Font 9 ([System.Drawing.FontStyle]::Bold)
$knowledgeExplorerStartButton.Add_Click({ Start-KnowledgeExplorer })

$knowledgeExplorerStopButton = New-Object System.Windows.Forms.Button
$knowledgeExplorerStopButton.Text = '■ Стоп'
$knowledgeExplorerStopButton.Enabled = $false
$knowledgeExplorerStopButton.Add_Click({ Stop-KnowledgeExplorer })

$knowledgeExplorerOpenButton = New-Object System.Windows.Forms.Button
$knowledgeExplorerOpenButton.Text = '📂 Knowledge files'
$knowledgeExplorerOpenButton.Add_Click({ Open-KnowledgeExplorerFolder })

$knowledgeExplorerProgress = New-Object System.Windows.Forms.ProgressBar
$knowledgeExplorerProgress.Minimum = 0
$knowledgeExplorerProgress.Maximum = 8
$knowledgeExplorerProgress.Value = 0

$knowledgeExplorerStatusLabel = New-Object System.Windows.Forms.Label
$knowledgeExplorerStatusLabel.Text = 'ADM = основная база знаний / baseline.'
$knowledgeExplorerStatusLabel.ForeColor = [System.Drawing.Color]::DimGray
$knowledgeExplorerStatusLabel.AutoEllipsis = $true

$knowledgeExplorerLogBox = New-Object System.Windows.Forms.RichTextBox
$knowledgeExplorerLogBox.ReadOnly = $true
$knowledgeExplorerLogBox.BackColor = [System.Drawing.Color]::FromArgb(17,24,39)
$knowledgeExplorerLogBox.ForeColor = [System.Drawing.Color]::FromArgb(229,231,235)
$knowledgeExplorerLogBox.Font = New-Object System.Drawing.Font('Consolas',8)
$knowledgeExplorerLogBox.Text = ''

Update-KnowledgeExplorerEnvironmentUi
Update-KnowledgeExplorerModeUi

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

$knowledgeSshStatusCaption = New-Object System.Windows.Forms.Label
$knowledgeSshStatusCaption.Text = 'GitHub SSH:'
$knowledgeSshStatusCaption.Font = New-Font 8 ([System.Drawing.FontStyle]::Bold)
$knowledgeSshStatusCaption.AutoSize = $true
$knowledgeSshStatusCaption.Location = New-Object System.Drawing.Point(16,67)
$knowledgeGitPanel.Controls.Add($knowledgeSshStatusCaption)

$knowledgeSshStatusValue = New-Object System.Windows.Forms.Label
$knowledgeSshStatusValue.Text = 'SSH: not checked'
$knowledgeSshStatusValue.AutoEllipsis = $true
$knowledgeSshStatusValue.ForeColor = [System.Drawing.Color]::DimGray
$knowledgeSshStatusValue.Location = New-Object System.Drawing.Point(94,66)
$knowledgeSshStatusValue.Size = New-Object System.Drawing.Size(470,20)
$knowledgeGitPanel.Controls.Add($knowledgeSshStatusValue)

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
$knowledgeSetupButton.Text = 'Проверить SSH'
$knowledgeSetupButton.Size = New-Object System.Drawing.Size(175,36)
$knowledgeSetupButton.Location = New-Object System.Drawing.Point(625,18)
$knowledgeSetupButton.Add_Click({ Test-KnowledgeGitHubConnection })
$knowledgeGitPanel.Controls.Add($knowledgeSetupButton)

$knowledgeSshCreateButton = New-Object System.Windows.Forms.Button
$knowledgeSshCreateButton.Text = 'Создать SSH key'
$knowledgeSshCreateButton.Font = New-Font 8
$knowledgeSshCreateButton.Size = New-Object System.Drawing.Size(210, 34)
$knowledgeSshCreateButton.Location = New-Object System.Drawing.Point(790, 76)
$knowledgeSshCreateButton.Add_Click({ [void](Configure-KnowledgeGitHubSsh) })
$knowledgeGitPanel.Controls.Add($knowledgeSshCreateButton)

$knowledgeSshCopyButton = New-Object System.Windows.Forms.Button
$knowledgeSshCopyButton.Text = 'Копировать public key'
$knowledgeSshCopyButton.Font = New-Font 8
$knowledgeSshCopyButton.Size = New-Object System.Drawing.Size(210, 34)
$knowledgeSshCopyButton.Location = New-Object System.Drawing.Point(790, 114)
$knowledgeSshCopyButton.Add_Click({ [void](Copy-GitHubSshPublicKey) })
$knowledgeGitPanel.Controls.Add($knowledgeSshCopyButton)

$knowledgeSyncButton = New-Object System.Windows.Forms.Button
$knowledgeSyncButton.Text = 'Git Sync'
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

$knowledgeChangesButton = New-Object System.Windows.Forms.Button
$knowledgeChangesButton.Text = 'Показать изменения'
$knowledgeChangesButton.Size = New-Object System.Drawing.Size(175,32)
$knowledgeChangesButton.Location = New-Object System.Drawing.Point(625,142)
$knowledgeChangesButton.Add_Click({ Show-GitLocalChanges })
$knowledgeGitPanel.Controls.Add($knowledgeChangesButton)

$knowledgeSaveStatusValue = New-Object System.Windows.Forms.Label
$knowledgeSaveStatusValue.Text = '⚪ СТАТУС ЗНАНИЙ НЕ ПРОВЕРЕН'
$knowledgeSaveStatusValue.Font = New-Font 11 ([System.Drawing.FontStyle]::Bold)
$knowledgeSaveStatusValue.AutoEllipsis = $true
$knowledgeSaveStatusValue.ForeColor = [System.Drawing.Color]::DimGray

$knowledgeSaveDetailsLabel = New-Object System.Windows.Forms.Label
$knowledgeSaveDetailsLabel.Text = 'Статус GitHub ещё не проверен.'
$knowledgeSaveDetailsLabel.AutoEllipsis = $true
$knowledgeSaveDetailsLabel.ForeColor = [System.Drawing.Color]::DimGray

$knowledgeSaveButton = New-Object System.Windows.Forms.Button
$knowledgeSaveButton.Text = '☁ СОХРАНИТЬ ЗНАНИЯ В GITHUB'
$knowledgeSaveButton.Font = New-Font 10 ([System.Drawing.FontStyle]::Bold)
$knowledgeSaveButton.Add_Click({ Save-AllKnowledgeToGitHub })

$knowledgeCommitLabel = New-Object System.Windows.Forms.Label
$knowledgeCommitLabel.Text = 'Технический commit message'
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
$knowledgeCommitButton.Text = 'Commit локально'
$knowledgeCommitButton.Font = New-Font 9 ([System.Drawing.FontStyle]::Bold)
$knowledgeCommitButton.Size = New-Object System.Drawing.Size(245,34)
$knowledgeCommitButton.Location = New-Object System.Drawing.Point(605,418)
$knowledgeCommitButton.Add_Click({ Commit-KnowledgeChanges })
$knowledgeTab.Controls.Add($knowledgeCommitButton)

$knowledgeSyncInfo = New-Object System.Windows.Forms.Label
$knowledgeSyncInfo.Text = 'Commit/Git Sync — дополнительные инструменты. Главный статус выше показывает, сохранены ли знания в GitHub.'
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




# --- Jira Queue tab (fully responsive: no absolute-position content) ---
$queueRoot = New-Object System.Windows.Forms.Panel
$queueRoot.Dock = 'Fill'
$queueRoot.Padding = New-Object System.Windows.Forms.Padding(12)
$queueRoot.BackColor = [System.Drawing.Color]::FromArgb(246,248,251)
$queueTab.Controls.Add($queueRoot) | Out-Null

$queueLayout = New-Object System.Windows.Forms.TableLayoutPanel
$queueLayout.Dock = 'Fill'
$queueLayout.ColumnCount = 1
$queueLayout.RowCount = 4
$queueLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent,100))) | Out-Null
$queueLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute,82))) | Out-Null
$queueLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute,118))) | Out-Null
$queueLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent,100))) | Out-Null
$queueLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute,125))) | Out-Null
$queueRoot.Controls.Add($queueLayout) | Out-Null

$queueHeaderGroup = New-Object System.Windows.Forms.GroupBox
$queueHeaderGroup.Text = 'Очередь Jira задач'
$queueHeaderGroup.Dock = 'Fill'
$queueHeaderGroup.Padding = New-Object System.Windows.Forms.Padding(10)
$queueLayout.Controls.Add($queueHeaderGroup,0,0)

$queueHeaderPanel = New-Object System.Windows.Forms.TableLayoutPanel
$queueHeaderPanel.Dock = 'Fill'
$queueHeaderPanel.ColumnCount = 2
$queueHeaderPanel.RowCount = 1
$queueHeaderPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent,70))) | Out-Null
$queueHeaderPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent,30))) | Out-Null
$queueHeaderGroup.Controls.Add($queueHeaderPanel) | Out-Null

$queueHintLabel = New-Object System.Windows.Forms.Label
$queueHintLabel.Text = 'До 3 задач одновременно. Каждая задача запускается в отдельном Worker-процессе и отдельной Chrome/CDP-сессии. Knowledge читается перед стартом Worker, Auto-Learning объединяется после завершения, Git commit/push выполняется последовательно основным Launcher.'
$queueHintLabel.Dock = 'Fill'
$queueHintLabel.AutoEllipsis = $true
$queueHintLabel.TextAlign = 'MiddleLeft'
$queueHintLabel.ForeColor = [System.Drawing.Color]::DimGray
$queueHeaderPanel.Controls.Add($queueHintLabel,0,0)

$queueSummaryLabel = New-Object System.Windows.Forms.Label
$queueSummaryLabel.Text = 'WAITING 0  •  RUNNING 0/3  •  PASS 0  •  FAIL 0  •  BLOCKED 0'
$queueSummaryLabel.Dock = 'Fill'
$queueSummaryLabel.TextAlign = 'MiddleRight'
$queueSummaryLabel.Font = New-Font 9 ([System.Drawing.FontStyle]::Bold)
$queueHeaderPanel.Controls.Add($queueSummaryLabel,1,0)

$queueControlsGroup = New-Object System.Windows.Forms.GroupBox
$queueControlsGroup.Text = 'Добавить и управлять'
$queueControlsGroup.Dock = 'Fill'
$queueControlsGroup.Padding = New-Object System.Windows.Forms.Padding(8)
$queueLayout.Controls.Add($queueControlsGroup,0,1)

$queueControlsLayout = New-Object System.Windows.Forms.TableLayoutPanel
$queueControlsLayout.Dock = 'Fill'
$queueControlsLayout.ColumnCount = 1
$queueControlsLayout.RowCount = 2
$queueControlsLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent,50))) | Out-Null
$queueControlsLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent,50))) | Out-Null
$queueControlsGroup.Controls.Add($queueControlsLayout) | Out-Null

$queueAddFlow = New-Object System.Windows.Forms.FlowLayoutPanel
$queueAddFlow.Dock = 'Fill'
$queueAddFlow.WrapContents = $false
$queueAddFlow.AutoScroll = $true
$queueControlsLayout.Controls.Add($queueAddFlow,0,0)

$queueInputLabel = New-Object System.Windows.Forms.Label
$queueInputLabel.Text = 'Jira key/URL:'
$queueInputLabel.AutoSize = $true
$queueInputLabel.Margin = New-Object System.Windows.Forms.Padding(0,9,6,0)
$queueAddFlow.Controls.Add($queueInputLabel) | Out-Null

$queueInputBox = New-Object System.Windows.Forms.TextBox
$queueInputBox.Width = 320
$queueInputBox.Font = New-Font 9
$queueInputBox.Margin = New-Object System.Windows.Forms.Padding(0,5,10,0)
$queueAddFlow.Controls.Add($queueInputBox) | Out-Null

$queueEnvironmentLabel = New-Object System.Windows.Forms.Label
$queueEnvironmentLabel.Text = 'Окружение:'
$queueEnvironmentLabel.AutoSize = $true
$queueEnvironmentLabel.Margin = New-Object System.Windows.Forms.Padding(0,9,6,0)
$queueAddFlow.Controls.Add($queueEnvironmentLabel) | Out-Null

$queueEnvironmentCombo = New-Object System.Windows.Forms.ComboBox
$queueEnvironmentCombo.DropDownStyle = 'DropDownList'
$queueEnvironmentCombo.Items.AddRange(@('BRANCH','HOT','ADM'))
$queueEnvironmentCombo.SelectedItem = 'HOT'
$queueEnvironmentCombo.Width = 105
$queueEnvironmentCombo.Margin = New-Object System.Windows.Forms.Padding(0,4,10,0)
$queueAddFlow.Controls.Add($queueEnvironmentCombo) | Out-Null

$queueParallelLabel = New-Object System.Windows.Forms.Label
$queueParallelLabel.Text = 'Параллельно:'
$queueParallelLabel.AutoSize = $true
$queueParallelLabel.Margin = New-Object System.Windows.Forms.Padding(0,9,6,0)
$queueAddFlow.Controls.Add($queueParallelLabel) | Out-Null

$queueParallelNumeric = New-Object System.Windows.Forms.NumericUpDown
$queueParallelNumeric.Minimum = 1
$queueParallelNumeric.Maximum = 3
$queueParallelNumeric.Value = 3
$queueParallelNumeric.Width = 55
$queueParallelNumeric.Margin = New-Object System.Windows.Forms.Padding(0,4,10,0)
$queueParallelNumeric.Add_ValueChanged({ $script:QueueMaxParallel = [int]$queueParallelNumeric.Value; Refresh-QueueGrid; Save-QueueState })
$queueAddFlow.Controls.Add($queueParallelNumeric) | Out-Null

$queueAddButton = New-Object System.Windows.Forms.Button
$queueAddButton.Text = '+ Добавить Jira'
$queueAddButton.Size = New-Object System.Drawing.Size(135,32)
$queueAddButton.Margin = New-Object System.Windows.Forms.Padding(0,2,0,0)
$queueAddButton.Add_Click({ Add-QueueTasksFromInput })
$queueAddFlow.Controls.Add($queueAddButton) | Out-Null

$queueActionFlow = New-Object System.Windows.Forms.FlowLayoutPanel
$queueActionFlow.Dock = 'Fill'
$queueActionFlow.WrapContents = $false
$queueActionFlow.AutoScroll = $true
$queueControlsLayout.Controls.Add($queueActionFlow,0,1)

function Add-QueueActionButton([string]$Text,[int]$Width,[scriptblock]$Handler) {
    $button = New-Object System.Windows.Forms.Button
    $button.Text = $Text
    $button.Size = New-Object System.Drawing.Size($Width,32)
    $button.Margin = New-Object System.Windows.Forms.Padding(0,3,8,0)
    $button.Add_Click($Handler)
    $queueActionFlow.Controls.Add($button) | Out-Null
    return $button
}

$queueStartButton = Add-QueueActionButton '▶ Start Queue' 130 { Start-JiraQueue }
$queuePauseButton = Add-QueueActionButton 'Pause' 85 { Pause-JiraQueue }
$queueResumeButton = Add-QueueActionButton 'Resume' 85 { Resume-JiraQueue }
$queueRetryButton = Add-QueueActionButton 'Retry' 80 { Retry-SelectedQueueItem }
$queueStopButton = Add-QueueActionButton 'Stop Worker' 105 { Stop-SelectedQueueWorker }
$queueRemoveButton = Add-QueueActionButton 'Удалить' 85 { Remove-SelectedQueueItem }
$queueUpButton = Add-QueueActionButton '↑' 45 { Move-SelectedQueueItem -Direction -1 }
$queueDownButton = Add-QueueActionButton '↓' 45 { Move-SelectedQueueItem -Direction 1 }
$queueLogsButton = Add-QueueActionButton 'Открыть логи' 115 { Open-SelectedQueueLogs }

$queueGridGroup = New-Object System.Windows.Forms.GroupBox
$queueGridGroup.Text = 'Задачи'
$queueGridGroup.Dock = 'Fill'
$queueGridGroup.Padding = New-Object System.Windows.Forms.Padding(8)
$queueLayout.Controls.Add($queueGridGroup,0,2)

$queueGrid = New-Object System.Windows.Forms.DataGridView
$queueGrid.Dock = 'Fill'
$queueGrid.ReadOnly = $true
$queueGrid.AllowUserToAddRows = $false
$queueGrid.AllowUserToDeleteRows = $false
$queueGrid.AllowUserToResizeRows = $false
$queueGrid.RowHeadersVisible = $false
$queueGrid.SelectionMode = 'FullRowSelect'
$queueGrid.MultiSelect = $false
$queueGrid.AutoGenerateColumns = $false
$queueGrid.BackgroundColor = [System.Drawing.Color]::White
$queueGrid.BorderStyle = 'FixedSingle'
$queueGrid.AutoSizeRowsMode = 'DisplayedCells'
$queueGrid.DefaultCellStyle.WrapMode = [System.Windows.Forms.DataGridViewTriState]::False
$queueGrid.ColumnHeadersHeightSizeMode = 'AutoSize'
$queueGridGroup.Controls.Add($queueGrid) | Out-Null

function Add-QueueGridColumn([string]$Name,[string]$Header,[int]$Width,[string]$AutoSizeMode='None') {
    $col = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $col.Name = $Name
    $col.HeaderText = $Header
    if ($AutoSizeMode -eq 'Fill') { $col.AutoSizeMode = [System.Windows.Forms.DataGridViewAutoSizeColumnMode]::Fill }
    else { $col.Width = $Width }
    [void]$queueGrid.Columns.Add($col)
}
Add-QueueGridColumn 'Order' '#' 42
Add-QueueGridColumn 'Key' 'Jira' 120
Add-QueueGridColumn 'Environment' 'Env' 70
Add-QueueGridColumn 'Status' 'Status' 120
Add-QueueGridColumn 'Worker' 'Worker' 70
Add-QueueGridColumn 'Started' 'Started' 82
Add-QueueGridColumn 'Result' 'Result' 85
Add-QueueGridColumn 'Details' 'Details' 200 'Fill'
$queueGrid.Add_CellDoubleClick({ if ($_.RowIndex -ge 0) { Open-SelectedQueueLogs } })

$queueLogGroup = New-Object System.Windows.Forms.GroupBox
$queueLogGroup.Text = 'Queue log'
$queueLogGroup.Dock = 'Fill'
$queueLogGroup.Padding = New-Object System.Windows.Forms.Padding(8)
$queueLayout.Controls.Add($queueLogGroup,0,3)

$queueLogLayout = New-Object System.Windows.Forms.TableLayoutPanel
$queueLogLayout.Dock = 'Fill'
$queueLogLayout.ColumnCount = 1
$queueLogLayout.RowCount = 2
$queueLogLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent,100))) | Out-Null
$queueLogLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute,24))) | Out-Null
$queueLogGroup.Controls.Add($queueLogLayout) | Out-Null

$queueLogBox = New-Object System.Windows.Forms.RichTextBox
$queueLogBox.Dock = 'Fill'
$queueLogBox.ReadOnly = $true
$queueLogBox.BackColor = [System.Drawing.Color]::FromArgb(17,24,39)
$queueLogBox.ForeColor = [System.Drawing.Color]::FromArgb(229,231,235)
$queueLogBox.Font = New-Object System.Drawing.Font('Consolas',8.5)
$queueLogLayout.Controls.Add($queueLogBox,0,0)

$queueStatusLabel = New-Object System.Windows.Forms.Label
$queueStatusLabel.Text = 'Готово. Добавь Jira задачи и нажми Start Queue.'
$queueStatusLabel.Dock = 'Fill'
$queueStatusLabel.TextAlign = 'MiddleLeft'
$queueStatusLabel.ForeColor = [System.Drawing.Color]::DimGray
$queueLogLayout.Controls.Add($queueStatusLabel,0,1)

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
    $queueTab.SuspendLayout()

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
    $jiraImportedGroup.Text = 'Импортированное описание и комментарии Jira — можно редактировать'
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
    $knowledgeGrid.RowCount = 6
    Add-ColumnStylePercent $knowledgeGrid 100
    Add-RowStyleAbsolute $knowledgeGrid 72
    Add-RowStyleAbsolute $knowledgeGrid 108
    Add-RowStyleAbsolute $knowledgeGrid 245
    Add-RowStyleAbsolute $knowledgeGrid 220
    Add-RowStyleAbsolute $knowledgeGrid 110
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

    foreach ($card in @(
        $knowledgeRulesValue.Parent,
        $knowledgeJiraValue.Parent,
        $knowledgeRegressionValue.Parent,
        $knowledgeTestsValue.Parent,
        $knowledgeExplorerValue.Parent
    )) {
        $card.Size = New-Object System.Drawing.Size(210, 82)
        Move-ControlToParent $card $knowledgeStatsFlow
    }

    # --------------------------------------------------------------
    # Knowledge Explorer — managed layout only
    # --------------------------------------------------------------
    
$knowledgeExplorerGroup = New-Object System.Windows.Forms.GroupBox
    $knowledgeExplorerGroup.Text = 'Knowledge Explorer — ADM baseline / HOT delta / BRANCH temporary'
    $knowledgeExplorerGroup.Dock = 'Fill'
    $knowledgeExplorerGroup.Padding = New-Object System.Windows.Forms.Padding(10)
    $knowledgeGrid.Controls.Add($knowledgeExplorerGroup, 0, 2)

    $knowledgeExplorerGrid = New-Object System.Windows.Forms.TableLayoutPanel
    $knowledgeExplorerGrid.Dock = 'Fill'
    $knowledgeExplorerGrid.ColumnCount = 6
    $knowledgeExplorerGrid.RowCount = 5
    Add-ColumnStyleAbsolute $knowledgeExplorerGrid 145
    Add-ColumnStylePercent $knowledgeExplorerGrid 28
    Add-ColumnStyleAbsolute $knowledgeExplorerGrid 115
    Add-ColumnStylePercent $knowledgeExplorerGrid 30
    Add-ColumnStyleAbsolute $knowledgeExplorerGrid 145
    Add-ColumnStyleAbsolute $knowledgeExplorerGrid 105
    Add-RowStyleAbsolute $knowledgeExplorerGrid 34
    Add-RowStyleAbsolute $knowledgeExplorerGrid 34
    Add-RowStyleAbsolute $knowledgeExplorerGrid 34
    Add-RowStyleAbsolute $knowledgeExplorerGrid 24
    Add-RowStylePercent $knowledgeExplorerGrid 100
    $knowledgeExplorerGroup.Controls.Add($knowledgeExplorerGrid) | Out-Null

    $knowledgeExplorerEnvironmentLabel = New-Object System.Windows.Forms.Label
    $knowledgeExplorerEnvironmentLabel.Text = 'Окружение'
    $knowledgeExplorerEnvironmentLabel.Dock = 'Fill'
    $knowledgeExplorerEnvironmentLabel.TextAlign = 'MiddleLeft'
    $knowledgeExplorerGrid.Controls.Add($knowledgeExplorerEnvironmentLabel,0,0)

    $knowledgeExplorerEnvironmentCombo.Dock = 'Fill'
    $knowledgeExplorerEnvironmentCombo.Margin = New-Object System.Windows.Forms.Padding(0,3,8,3)
    $knowledgeExplorerGrid.Controls.Add($knowledgeExplorerEnvironmentCombo,1,0)

    $knowledgeExplorerBaselineLabel = New-Object System.Windows.Forms.Label
    $knowledgeExplorerBaselineLabel.Text = 'Baseline'
    $knowledgeExplorerBaselineLabel.Dock = 'Fill'
    $knowledgeExplorerBaselineLabel.TextAlign = 'MiddleLeft'
    $knowledgeExplorerGrid.Controls.Add($knowledgeExplorerBaselineLabel,2,0)

    $knowledgeExplorerBaselineValueLabel.Dock = 'Fill'
    $knowledgeExplorerBaselineValueLabel.TextAlign = 'MiddleLeft'
    $knowledgeExplorerBaselineValueLabel.Margin = New-Object System.Windows.Forms.Padding(0,0,8,0)
    $knowledgeExplorerGrid.Controls.Add($knowledgeExplorerBaselineValueLabel,3,0)

    $knowledgeExplorerStartButton.Dock = 'Fill'
    $knowledgeExplorerStartButton.Margin = New-Object System.Windows.Forms.Padding(0,2,6,2)
    Style-PrimaryButton $knowledgeExplorerStartButton
    $knowledgeExplorerGrid.Controls.Add($knowledgeExplorerStartButton,4,0)

    $knowledgeExplorerStopButton.Dock = 'Fill'
    $knowledgeExplorerStopButton.Margin = New-Object System.Windows.Forms.Padding(0,2,0,2)
    Style-SecondaryButton $knowledgeExplorerStopButton
    $knowledgeExplorerGrid.Controls.Add($knowledgeExplorerStopButton,5,0)

    $knowledgeExplorerModeLabel = New-Object System.Windows.Forms.Label
    $knowledgeExplorerModeLabel.Text = 'Режим'
    $knowledgeExplorerModeLabel.Dock = 'Fill'
    $knowledgeExplorerModeLabel.TextAlign = 'MiddleLeft'
    $knowledgeExplorerGrid.Controls.Add($knowledgeExplorerModeLabel,0,1)

    $knowledgeExplorerModeCombo.Dock = 'Fill'
    $knowledgeExplorerModeCombo.Margin = New-Object System.Windows.Forms.Padding(0,3,8,3)
    $knowledgeExplorerGrid.Controls.Add($knowledgeExplorerModeCombo,1,1)

    $knowledgeExplorerModuleLabel = New-Object System.Windows.Forms.Label
    $knowledgeExplorerModuleLabel.Text = 'Модуль'
    $knowledgeExplorerModuleLabel.Dock = 'Fill'
    $knowledgeExplorerModuleLabel.TextAlign = 'MiddleLeft'
    $knowledgeExplorerGrid.Controls.Add($knowledgeExplorerModuleLabel,2,1)

    $knowledgeExplorerModuleCombo.Dock = 'Fill'
    $knowledgeExplorerModuleCombo.Margin = New-Object System.Windows.Forms.Padding(0,3,8,3)
    $knowledgeExplorerGrid.Controls.Add($knowledgeExplorerModuleCombo,3,1)

    $knowledgeExplorerOpenButton.Dock = 'Fill'
    $knowledgeExplorerOpenButton.Margin = New-Object System.Windows.Forms.Padding(0,2,0,2)
    Style-SecondaryButton $knowledgeExplorerOpenButton
    $knowledgeExplorerGrid.Controls.Add($knowledgeExplorerOpenButton,4,1)
    $knowledgeExplorerGrid.SetColumnSpan($knowledgeExplorerOpenButton,2)

    $knowledgeExplorerTargetLabel = New-Object System.Windows.Forms.Label
    $knowledgeExplorerTargetLabel.Text = 'Workflow / цель'
    $knowledgeExplorerTargetLabel.Dock = 'Fill'
    $knowledgeExplorerTargetLabel.TextAlign = 'MiddleLeft'
    $knowledgeExplorerGrid.Controls.Add($knowledgeExplorerTargetLabel,0,2)

    $knowledgeExplorerTargetBox.Dock = 'Fill'
    $knowledgeExplorerTargetBox.Margin = New-Object System.Windows.Forms.Padding(0,3,8,3)
    $knowledgeExplorerGrid.Controls.Add($knowledgeExplorerTargetBox,1,2)
    $knowledgeExplorerGrid.SetColumnSpan($knowledgeExplorerTargetBox,3)

    $knowledgeAdmDailyPasswordLabel.Dock = 'Fill'
    $knowledgeAdmDailyPasswordLabel.TextAlign = 'MiddleLeft'
    $knowledgeAdmDailyPasswordLabel.Margin = New-Object System.Windows.Forms.Padding(0,0,6,0)
    Move-ControlToParent $knowledgeAdmDailyPasswordLabel $knowledgeExplorerGrid
    $knowledgeExplorerGrid.Controls.Add($knowledgeAdmDailyPasswordLabel,4,2)

    $knowledgeAdmDailyPasswordBox.Dock = 'Fill'
    $knowledgeAdmDailyPasswordBox.Margin = New-Object System.Windows.Forms.Padding(0,3,0,3)
    Move-ControlToParent $knowledgeAdmDailyPasswordBox $knowledgeExplorerGrid
    $knowledgeExplorerGrid.Controls.Add($knowledgeAdmDailyPasswordBox,5,2)

    $knowledgeExplorerStatusLabel.Dock = 'Fill'
    $knowledgeExplorerStatusLabel.TextAlign = 'MiddleLeft'
    $knowledgeExplorerStatusLabel.Margin = New-Object System.Windows.Forms.Padding(0,0,8,0)
    $knowledgeExplorerGrid.Controls.Add($knowledgeExplorerStatusLabel,0,3)
    $knowledgeExplorerGrid.SetColumnSpan($knowledgeExplorerStatusLabel,4)

    $knowledgeExplorerProgress.Dock = 'Fill'
    $knowledgeExplorerProgress.Margin = New-Object System.Windows.Forms.Padding(0,4,0,4)
    $knowledgeExplorerGrid.Controls.Add($knowledgeExplorerProgress,4,3)
    $knowledgeExplorerGrid.SetColumnSpan($knowledgeExplorerProgress,2)

    $knowledgeExplorerLogBox.Dock = 'Fill'
    $knowledgeExplorerLogBox.Margin = New-Object System.Windows.Forms.Padding(0,4,0,0)
    $knowledgeExplorerGrid.Controls.Add($knowledgeExplorerLogBox,0,4)
    $knowledgeExplorerGrid.SetColumnSpan($knowledgeExplorerLogBox,6)

$knowledgeGitGroup = New-Object System.Windows.Forms.GroupBox
    $knowledgeGitGroup.Text = 'Git repository'
    $knowledgeGitGroup.Dock = 'Fill'
    $knowledgeGitGroup.Padding = New-Object System.Windows.Forms.Padding(10)
    $knowledgeGrid.Controls.Add($knowledgeGitGroup, 0, 3)

    # Replace the old fixed-coordinate Git panel with a responsive two-column grid.
    $knowledgeGitPanel.BorderStyle = 'None'
    $knowledgeGitPanel.Dock = 'Fill'
    Move-ControlToParent $knowledgeGitPanel $knowledgeGitGroup
    $knowledgeGitPanel.Controls.Clear()

    $knowledgeGitGrid = New-Object System.Windows.Forms.TableLayoutPanel
    $knowledgeGitGrid.Dock = 'Fill'
    $knowledgeGitGrid.ColumnCount = 2
    $knowledgeGitGrid.RowCount = 1
    Add-ColumnStylePercent $knowledgeGitGrid 66
    Add-ColumnStylePercent $knowledgeGitGrid 34
    Add-RowStylePercent $knowledgeGitGrid 100
    $knowledgeGitPanel.Controls.Add($knowledgeGitGrid) | Out-Null

    $knowledgeGitInfoPanel = New-Object System.Windows.Forms.TableLayoutPanel
    $knowledgeGitInfoPanel.Dock = 'Fill'
    $knowledgeGitInfoPanel.ColumnCount = 2
    $knowledgeGitInfoPanel.RowCount = 7
    Add-ColumnStyleAbsolute $knowledgeGitInfoPanel 92
    Add-ColumnStylePercent $knowledgeGitInfoPanel 100
    Add-RowStyleAbsolute $knowledgeGitInfoPanel 36
    Add-RowStyleAbsolute $knowledgeGitInfoPanel 28
    Add-RowStyleAbsolute $knowledgeGitInfoPanel 24
    Add-RowStyleAbsolute $knowledgeGitInfoPanel 24
    Add-RowStyleAbsolute $knowledgeGitInfoPanel 24
    Add-RowStyleAbsolute $knowledgeGitInfoPanel 24
    Add-RowStylePercent $knowledgeGitInfoPanel 100
    $knowledgeGitGrid.Controls.Add($knowledgeGitInfoPanel, 0, 0)

    $knowledgeGitTitle.Visible = $false

    $knowledgeSaveStatusValue.Dock = 'Fill'
    $knowledgeSaveStatusValue.TextAlign = 'MiddleLeft'
    $knowledgeSaveStatusValue.Margin = New-Object System.Windows.Forms.Padding(2,0,2,0)
    Move-ControlToParent $knowledgeSaveStatusValue $knowledgeGitInfoPanel
    $knowledgeGitInfoPanel.Controls.Add($knowledgeSaveStatusValue,0,0)
    $knowledgeGitInfoPanel.SetColumnSpan($knowledgeSaveStatusValue,2)

    $knowledgeSaveDetailsLabel.Dock = 'Fill'
    $knowledgeSaveDetailsLabel.TextAlign = 'MiddleLeft'
    $knowledgeSaveDetailsLabel.Margin = New-Object System.Windows.Forms.Padding(2,0,2,0)
    Move-ControlToParent $knowledgeSaveDetailsLabel $knowledgeGitInfoPanel
    $knowledgeGitInfoPanel.Controls.Add($knowledgeSaveDetailsLabel,0,1)
    $knowledgeGitInfoPanel.SetColumnSpan($knowledgeSaveDetailsLabel,2)

    $knowledgeGitStatus.Dock = 'Fill'
    $knowledgeGitStatus.TextAlign = 'MiddleLeft'
    $knowledgeGitStatus.Margin = New-Object System.Windows.Forms.Padding(2,0,2,0)
    Move-ControlToParent $knowledgeGitStatus $knowledgeGitInfoPanel
    $knowledgeGitInfoPanel.Controls.Add($knowledgeGitStatus,0,2)
    $knowledgeGitInfoPanel.SetColumnSpan($knowledgeGitStatus,2)

    $knowledgeSshStatusCaption.Dock = 'Fill'
    $knowledgeSshStatusCaption.TextAlign = 'MiddleLeft'
    $knowledgeSshStatusCaption.Margin = New-Object System.Windows.Forms.Padding(2,0,4,0)
    Move-ControlToParent $knowledgeSshStatusCaption $knowledgeGitInfoPanel
    $knowledgeGitInfoPanel.Controls.Add($knowledgeSshStatusCaption,0,3)

    $knowledgeSshStatusValue.Dock = 'Fill'
    $knowledgeSshStatusValue.TextAlign = 'MiddleLeft'
    $knowledgeSshStatusValue.Margin = New-Object System.Windows.Forms.Padding(0)
    Move-ControlToParent $knowledgeSshStatusValue $knowledgeGitInfoPanel
    $knowledgeGitInfoPanel.Controls.Add($knowledgeSshStatusValue,1,3)

    foreach ($pair in @(
        @($branchCaption,$knowledgeBranchValue,4),
        @($remoteCaption,$knowledgeRemoteValue,5),
        @($commitCaption,$knowledgeCommitValue,6)
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
    $knowledgeGitActions.ColumnCount = 2
    $knowledgeGitActions.RowCount = 4
    Add-ColumnStylePercent $knowledgeGitActions 50
    Add-ColumnStylePercent $knowledgeGitActions 50
    Add-RowStyleAbsolute $knowledgeGitActions 52
    Add-RowStylePercent $knowledgeGitActions 33
    Add-RowStylePercent $knowledgeGitActions 33
    Add-RowStylePercent $knowledgeGitActions 34
    $knowledgeGitActions.Padding = New-Object System.Windows.Forms.Padding(8,2,2,2)
    $knowledgeGitGrid.Controls.Add($knowledgeGitActions, 1, 0)

    $knowledgeSaveButton.Dock = 'Fill'
    $knowledgeSaveButton.Margin = New-Object System.Windows.Forms.Padding(2,3,2,5)
    Move-ControlToParent $knowledgeSaveButton $knowledgeGitActions
    $knowledgeGitActions.Controls.Add($knowledgeSaveButton,0,0)
    $knowledgeGitActions.SetColumnSpan($knowledgeSaveButton,2)

    foreach ($action in @(
        @($knowledgeSetupButton,0,1),
        @($knowledgeSshCreateButton,1,1),
        @($knowledgeSshCopyButton,0,2),
        @($knowledgeRefreshButton,1,2),
        @($knowledgeChangesButton,0,3),
        @($knowledgeSyncButton,1,3)
    )) {
        $button = $action[0]
        $column = [int]$action[1]
        $row = [int]$action[2]
        $button.Dock = 'Fill'
        $button.Margin = New-Object System.Windows.Forms.Padding(2,3,2,3)
        Move-ControlToParent $button $knowledgeGitActions
        $knowledgeGitActions.Controls.Add($button,$column,$row)
    }

    $knowledgeCommitGroup = New-Object System.Windows.Forms.GroupBox
    $knowledgeCommitGroup.Text = 'Git — дополнительные инструменты'
    $knowledgeCommitGroup.Dock = 'Fill'
    $knowledgeCommitGroup.Padding = New-Object System.Windows.Forms.Padding(10)
    $knowledgeGrid.Controls.Add($knowledgeCommitGroup, 0, 4)

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
    $knowledgeGrid.Controls.Add($knowledgeRecentGroup, 0, 5)

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
    $queueTab.ResumeLayout($true)
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

    foreach ($tab in @($quickTab,$jiraTab,$queueTab,$knowledgeTab)) {
        $tab.BackColor = [System.Drawing.Color]::FromArgb(248,250,252)
    }

    Style-PrimaryButton $runButton
    Style-PrimaryButton $jiraRunButton
    Style-PrimaryButton $knowledgeSaveButton
    Style-PrimaryButton $queueStartButton
    Style-PrimaryButton $queueAddButton

    foreach ($button in @(
        $cancelButton,$jiraButton,$htmlButton,$credentialButton,$quickChatGptButton,$quickRecheckConnectionsButton,
        $chatGptConnectButton,$jiraConnectButton,$jiraLoadButton,
        $jiraSaveRuleButton,$jiraCopyReportButton,$jiraRegressionButton,
        $knowledgeSetupButton,$knowledgeRefreshButton,$knowledgeCommitButton,$knowledgeSyncButton,$knowledgeChangesButton,
        $openAgentLogsButton,$clearAgentLogsButton,
        $queuePauseButton,$queueResumeButton,$queueRetryButton,$queueStopButton,$queueRemoveButton,$queueUpButton,$queueDownButton,$queueLogsButton
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
        $knowledgeCommitGroup,$knowledgeRecentGroup,
        $queueHeaderGroup,$queueControlsGroup,$queueGridGroup,$queueLogGroup
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
    foreach ($tab in @($quickTab,$jiraTab,$queueTab,$knowledgeTab)) {
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
    if ($script:QueueWorkerMode) {
        Refresh-KnowledgeUI
        return
    }

    if (Test-GitInstalled) {
        Initialize-KnowledgeGit -Silent
    }

    $git = Get-GitState

    if (
        -not $git.Repository -or
        $git.Remote -eq 'не настроен' -or
        $git.Dirty
    ) {
        Refresh-KnowledgeUI
        return
    }

    if (([string]$git.Remote) -match '^https?://') {
        [void](Set-KnowledgeOriginToSsh)
        $git = Get-GitState
    }

    $privateKey = Get-GitHubSshPrivateKeyPath

    if (
        ([string]$git.Remote) -notmatch '^git@github\.com:' -or
        -not (Test-Path $privateKey)
    ) {
        if ($knowledgeSyncInfo) {
            $knowledgeSyncInfo.Text = 'Startup sync: SSH ещё не готов; используется локальная Knowledge Base.'
            $knowledgeSyncInfo.ForeColor = [System.Drawing.Color]::DimGray
        }

        Refresh-KnowledgeUI -PreserveActionText
        return
    }

    $sshCheck = Invoke-SshGitHubAuthCheck

    if (-not $sshCheck.Success) {
        if ($knowledgeSyncInfo) {
            $knowledgeSyncInfo.Text = 'Startup sync: SSH авторизация не готова; browser auth не запускается.'
            $knowledgeSyncInfo.ForeColor = [System.Drawing.Color]::DimGray
        }

        Refresh-KnowledgeUI -PreserveActionText
        return
    }

    $remoteBranch = Invoke-Git @(
        'ls-remote','--exit-code','--heads','origin',$git.Branch
    ) 10000

    if ($remoteBranch.ExitCode -ne 0) {
        if ($knowledgeSyncInfo) {
            $knowledgeSyncInfo.Text = 'Startup sync: remote-ветка ещё не создана; кнопка «СОХРАНИТЬ ЗНАНИЯ В GITHUB» создаст её автоматически.'
            $knowledgeSyncInfo.ForeColor = [System.Drawing.Color]::DimGray
        }

        Refresh-KnowledgeUI -PreserveActionText
        return
    }

    $pull = Invoke-Git @(
        'pull','--ff-only','origin',$git.Branch
    ) 20000

    if ($knowledgeSyncInfo) {
        if ($pull.ExitCode -eq 0) {
            $knowledgeSyncInfo.Text = 'Startup sync: последние knowledge-изменения получены по SSH.'
            $knowledgeSyncInfo.ForeColor = [System.Drawing.Color]::FromArgb(32,120,72)
        }
        else {
            $knowledgeSyncInfo.Text = 'Startup sync не выполнен. Используй «СОХРАНИТЬ ЗНАНИЯ В GITHUB» для безопасной синхронизации.'
            $knowledgeSyncInfo.ForeColor = [System.Drawing.Color]::FromArgb(161,98,7)
        }
    }

    Refresh-KnowledgeUI -PreserveActionText
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

    try {
        Refresh-KnowledgeSaveState -VerifyRemote
    }
    catch { }
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


# Jira Queue timer is owned by the parent Launcher only.
if (-not $script:QueueWorkerMode) {
    New-Item -ItemType Directory -Path $script:QueueWorkersRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $script:QueueJobsRoot -Force | Out-Null

    $script:QueueTimer = New-Object System.Windows.Forms.Timer
    $script:QueueTimer.Interval = 1000
    $script:QueueTimer.Add_Tick({ Process-QueueTick })

    Load-QueueState
    if ($queueParallelNumeric) {
        $queueParallelNumeric.Value = [Math]::Max(1,[Math]::Min(3,$script:QueueMaxParallel))
    }

    if (-not (Test-QueueEngineSelfTest)) {
        $queueStatusLabel.Text = 'Queue self-test FAILED — очередь отключена, основной Launcher доступен.'
        $queueStatusLabel.ForeColor = [System.Drawing.Color]::FromArgb(197,119,0)
        $queueStartButton.Enabled = $false
        Write-QueueLog 'QUEUE SELF-TEST FAILED → Queue disabled; main Launcher remains available.'
    }
    else {
        Refresh-QueueGrid
    }
}

# Isolated Queue Worker auto-starts exactly one Jira task and exits itself when finished.
if ($script:QueueWorkerMode) {
    $script:AutoGitAfterJiraRun = $false
    $keepBrowserOpenCheck.Checked = $false
    $headedCheck.Checked = $true
    $jiraMutatingCheck.Checked = $true
    $mutatingCheck.Checked = $true

    if (-not [string]::IsNullOrWhiteSpace([string]$env:RX2GO_QUEUE_DAILY_PASSWORD)) {
        $dailyPassword.Text = [string]$env:RX2GO_QUEUE_DAILY_PASSWORD
    }

    $script:QueueWorkerKickoffTimer = New-Object System.Windows.Forms.Timer
    $script:QueueWorkerKickoffTimer.Interval = 1000
    $script:QueueWorkerWaitStarted = Get-Date

    $script:QueueWorkerKickoffTimer.Add_Tick({
        if ($script:QueueWorkerFinalWritten) {
            $script:QueueWorkerKickoffTimer.Stop()
            try { Stop-PersistentBrowserSession } catch {}
            try { $form.Close() } catch {}
            return
        }

        if (-not $script:QueueWorkerStarted) {
            $elapsed = ((Get-Date) - $script:QueueWorkerWaitStarted).TotalSeconds

            if (-not $script:ChatGPTConnected) {
                Write-QueueWorkerStatus -Status 'RUNNING' -Phase 'STARTING' -Detail 'Waiting for Codex/ChatGPT startup precheck'
                if ($elapsed -gt 120) {
                    Complete-QueueWorkerResult -Result ERROR -Details 'Codex/ChatGPT startup timeout in Queue Worker.'
                }
                return
            }

            if ([string]::IsNullOrWhiteSpace($script:QueueWorkerTaskKey)) {
                Complete-QueueWorkerResult -Result ERROR -Details 'Queue Worker task key is missing.'
                return
            }

            $targetEnv = if ($script:QueueWorkerEnvironment -in @('BRANCH','HOT','ADM')) { $script:QueueWorkerEnvironment } else { 'HOT' }
            $jiraTaskBox.Text = $script:QueueWorkerTaskKey
            $jiraEnvironmentCombo.SelectedItem = $targetEnv
            $environmentCombo.SelectedItem = $targetEnv
            $keepBrowserOpenCheck.Checked = $false
            $headedCheck.Checked = $true
            $jiraMutatingCheck.Checked = $true
            $mutatingCheck.Checked = $true

            $script:QueueWorkerStarted = $true
            $script:QueueWorkerStartedAt = Get-Date
            Write-QueueWorkerStatus -Status 'RUNNING' -Phase 'STARTING' -Detail "Starting $($script:QueueWorkerTaskKey) on $targetEnv"

            try {
                Start-JiraTaskCheck

                # Start-JiraTaskCheck returns immediately only when final deterministic Playwright is launched,
                # or returns after an early terminal error/BLOCKED. PASS/FAIL completion is written by Complete-JiraRun.
                if (-not $script:QueueWorkerFinalWritten) {
                    $hasRunningPlaywright = ($script:RunningProcess -and -not $script:RunningProcess.HasExited)
                    if (-not $hasRunningPlaywright -and -not $script:JiraRunActive) {
                        $detail = if ($jiraTaskStatus -and $jiraTaskStatus.Text) { [string]$jiraTaskStatus.Text } elseif ($script:LastAgentError) { [string]$script:LastAgentError } else { 'Queue Worker ended before final test result.' }
                        Complete-QueueWorkerResult -Result ERROR -Details $detail
                    }
                }
            }
            catch {
                Complete-QueueWorkerResult -Result ERROR -Details $_.Exception.Message
            }
        }
    })

    $form.Add_Shown({
        Write-QueueWorkerStatus -Status 'RUNNING' -Phase 'STARTING' -Detail 'Queue Worker process initialized'
        $script:QueueWorkerKickoffTimer.Start()
    })
}

[void]$form.ShowDialog()

