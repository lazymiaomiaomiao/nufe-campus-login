Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$appSource = Split-Path -Parent $MyInvocation.MyCommand.Path
$installDir = Join-Path $env:LOCALAPPDATA 'NufeCampusLogin'

function Stop-ExistingMonitor {
    param([string]$InstallDir)

    $escaped = [regex]::Escape((Join-Path $InstallDir 'NufeCampusMonitor.ps1'))
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match $escaped } |
        ForEach-Object {
            try {
                Invoke-CimMethod -InputObject $_ -MethodName Terminate | Out-Null
            }
            catch {}
        }
}

New-Item -ItemType Directory -Force -LiteralPath $installDir | Out-Null
Stop-ExistingMonitor -InstallDir $installDir

foreach ($name in @('NufeCampusLogin.ps1', 'NufeCampusMonitor.ps1', 'ConfigGui.ps1')) {
    Copy-Item -LiteralPath (Join-Path $appSource $name) -Destination (Join-Path $installDir $name) -Force
}

& (Join-Path $installDir 'ConfigGui.ps1') -InstallDir $installDir -CreateStartup -StartMonitorAfterSave
