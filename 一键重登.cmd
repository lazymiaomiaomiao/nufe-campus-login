@echo off
chcp 65001 >nul
set "SCRIPT=%LOCALAPPDATA%\NufeCampusLogin\NufeCampusLogin.ps1"
if not exist "%SCRIPT%" (
  echo 尚未部署，请先运行“一键部署.cmd”。
  pause
  exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -ForceLogin
pause
