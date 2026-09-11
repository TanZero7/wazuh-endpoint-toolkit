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
echo   FIM (Desktop + Downloads) - endpoint setup
echo ==========================================================
echo.
set PS=powershell -NoProfile -ExecutionPolicy Bypass -File
echo [1/3] Adding the FIM scope...
%PS% ".\scripts\install-fim-scope.ps1"
if errorlevel 1 goto :failed
echo.
echo [2/3] Disabling the agent anti-flood buffer (so no events are ever dropped)...
%PS% ".\scripts\set-no-event-loss.ps1"
if errorlevel 1 goto :failed
echo.
echo [3/3] Verifying...
%PS% ".\scripts\verify.ps1"
echo.
echo ==========================================================
echo   Done. Nothing to install on the server - Wazuh's
echo   built-in FIM rules (550/554/553) handle alerting.
echo ==========================================================
pause
exit /b 0
:failed
echo.
echo   A step failed. Read the output above.
pause
exit /b 1
