@echo off
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Fix-Claude-Desktop.ps1"
set "repairExitCode=%ERRORLEVEL%"
if not "%repairExitCode%"=="0" pause
exit /b %repairExitCode%
