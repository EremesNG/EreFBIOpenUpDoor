@echo off
setlocal

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0sync_mod.ps1"
set "SyncExitCode=%ERRORLEVEL%"

if /I not "%~1"=="--no-pause" pause
exit /b %SyncExitCode%
