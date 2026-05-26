@echo off
chcp 65001 >nul
set "ROOT=%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%ROOT%app\ConfigGui.ps1" -InstallDir "%LOCALAPPDATA%\NufeCampusLogin" -CreateStartup -StartMonitorAfterSave
pause
