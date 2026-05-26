@echo off
chcp 65001 >nul
set "LOG=%LOCALAPPDATA%\NufeCampusLogin\login.log"
if not exist "%LOG%" (
  echo 暂时还没有日志。请先运行“一键部署.cmd”或“一键重登.cmd”。
  pause
  exit /b 0
)
notepad.exe "%LOG%"
