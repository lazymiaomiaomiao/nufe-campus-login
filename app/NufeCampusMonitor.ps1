param(
    [int]$IntervalSeconds = 300
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$baseDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$mainScript = Join-Path $baseDir 'NufeCampusLogin.ps1'
$mutexName = 'Local\NufeCampusLoginMonitor'

$createdNew = $false
$mutex = [System.Threading.Mutex]::new($true, $mutexName, [ref]$createdNew)
if (-not $createdNew) {
    exit 0
}

try {
    while ($true) {
        try {
            & $mainScript -Quiet | Out-Null
        }
        catch {
            $line = '{0} [ERROR] Monitor loop failed: {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $_.Exception.Message
            Add-Content -LiteralPath (Join-Path $baseDir 'login.log') -Value $line -Encoding UTF8
        }

        Start-Sleep -Seconds $IntervalSeconds
    }
}
finally {
    $mutex.ReleaseMutex() | Out-Null
    $mutex.Dispose()
}
