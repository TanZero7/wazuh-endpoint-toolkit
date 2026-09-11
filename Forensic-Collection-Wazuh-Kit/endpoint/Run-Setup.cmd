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
echo   Endpoint forensic snapshot collector - setup
echo ==========================================================
echo.
set PS=powershell -NoProfile -ExecutionPolicy Bypass -File
echo [1/2] Deploying + wiring the collector...
%PS% ".\scripts\wire-collector.ps1"
if errorlevel 1 goto :failed
echo.
echo [2/2] Verifying...
%PS% ".\scripts\verify.ps1"
echo.
echo ==========================================================
echo   Done. Next: install server\ on the Wazuh manager so
echo   snapshot summaries show up as alerts (optional but
echo   recommended - the raw evidence files are saved either way).
echo ==========================================================
pause
exit /b 0
:failed
echo.
echo   A step failed. Read the output above.
pause
exit /b 1
