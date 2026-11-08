@echo off
REM ===================================================================
REM  Health check. Read-only, changes nothing. Run this any time you
REM  want to know whether the integration is actually working.
REM
REM  Bypasses the PowerShell execution policy for this process only,
REM  which is why you can run it without the "running scripts is
REM  disabled on this system" error.
REM ===================================================================
setlocal
cd /d "%~dp0"

net session >nul 2>&1
if %errorLevel% neq 0 (
    echo Requesting administrator rights...
    powershell -NoProfile -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)

powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\05-verify.ps1"
echo.
pause
