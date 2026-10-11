$ErrorActionPreference = 'Stop'

$launcher = Join-Path $PSScriptRoot 'Rx2GO-QA-Launcher.ps1'
$log = Join-Path $PSScriptRoot 'startup-error.log'

function Repair-LauncherEncoding {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        throw "Launcher file not found: $Path"
    }

    # Read raw bytes and collapse any number of leading UTF-8 BOM markers to exactly one.
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $bom = [byte[]](0xEF, 0xBB, 0xBF)

    $offset = 0
    while (
        ($bytes.Length - $offset) -ge 3 -and
        $bytes[$offset] -eq 0xEF -and
        $bytes[$offset + 1] -eq 0xBB -and
        $bytes[$offset + 2] -eq 0xBF
    ) {
        $offset += 3
    }

    # A correct file has exactly one BOM (offset == 3).
    if ($offset -ne 3) {
        $payload = if ($offset -lt $bytes.Length) {
            $bytes[$offset..($bytes.Length - 1)]
        } else {
            [byte[]]@()
        }

        $fixed = New-Object byte[] ($bom.Length + $payload.Length)
        [Array]::Copy($bom, 0, $fixed, 0, $bom.Length)
        if ($payload.Length -gt 0) {
            [Array]::Copy($payload, 0, $fixed, $bom.Length, $payload.Length)
        }

        [System.IO.File]::WriteAllBytes($Path, $fixed)
    }
}

try {
    if (Test-Path $log) {
        Remove-Item $log -Force -ErrorAction SilentlyContinue
    }

    Repair-LauncherEncoding -Path $launcher
    & $launcher
}
catch {
    $details = @(
        "Rx2GO AI QA startup error"
        "Date: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        ''
        $_.Exception.ToString()
        ''
        $_.ScriptStackTrace
    ) -join "`r`n"

    $details | Set-Content -Path $log -Encoding UTF8

    try {
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.MessageBox]::Show(
            "Launcher не запустился.`r`n`r`n$($_.Exception.Message)`r`n`r`nПодробности: $log",
            'Rx2GO AI QA',
            'OK',
            'Error'
        ) | Out-Null
    }
    catch {
        Write-Host $details
        Read-Host 'Press Enter'
    }
}

