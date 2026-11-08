@echo off
setlocal
cd /d "%~dp0"
net session >nul 2>&1
if %errorLevel% neq 0 (
    powershell -NoProfile -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\Verify-LocalAdmin.ps1"
pause
