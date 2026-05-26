Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms

$installDir = Join-Path $env:LOCALAPPDATA 'NufeCampusLogin'
$startupLauncher = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup\NufeCampusMonitor.vbs'

Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -match 'NufeCampusMonitor\.ps1' } |
    ForEach-Object {
        try {
            Invoke-CimMethod -InputObject $_ -MethodName Terminate | Out-Null
        }
        catch {}
    }

Remove-Item -LiteralPath $startupLauncher -Force -ErrorAction SilentlyContinue

$answer = [System.Windows.Forms.MessageBox]::Show('已关闭开机自启。是否同时删除本机保存的账号配置？', 'NUFE 校园网登录', 'YesNo', 'Question')
if ($answer -eq [System.Windows.Forms.DialogResult]::Yes) {
    Remove-Item -LiteralPath $installDir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host '已处理完成。'
