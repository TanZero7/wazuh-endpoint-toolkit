@echo off
setlocal
cd /d "%~dp0"
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo Requesting administrator rights...
    powershell -NoProfile -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)
echo.
echo ==========================================================
echo   Local admin account setup
echo   Creates/resets 'admin', demotes every other account,
echo   disables the built-in Administrator account.
echo ==========================================================
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\Setup-Local-Admin.ps1"
if errorlevel 1 goto :failed
echo.
echo ==========================================================
echo   Done. Now proceed to the Wazuh agent install.
echo ==========================================================
pause
exit /b 0
:failed
echo.
echo   Setup failed. Read the output above before re-running.
pause
exit /b 1
