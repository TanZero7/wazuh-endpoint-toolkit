@echo off
REM ===================================================================
REM  Full endpoint setup: install Sysmon + config, wire the Wazuh agent,
REM  then verify. Right-click > Run as administrator.
REM ===================================================================
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
echo   Sysmon + Wazuh endpoint setup
echo ==========================================================
echo.

set PS=powershell -NoProfile -ExecutionPolicy Bypass -File

echo [1/3] Installing Sysmon + SwiftOnSecurity config...
%PS% ".\scripts\install-sysmon.ps1"
if errorlevel 1 goto :failed

echo.
echo [2/3] Wiring the Wazuh agent to the Sysmon channel...
%PS% ".\scripts\wire-wazuh-agent.ps1"
if errorlevel 1 goto :failed

echo.
echo [3/3] Verifying...
%PS% ".\scripts\verify.ps1"

echo.
echo ==========================================================
echo   Endpoint setup finished. Wazuh's built-in Sysmon ruleset
echo   (rules 61600-61699 / 0330,0595,0800-0950) starts firing
echo   immediately -- no server-side step needed.
echo ==========================================================
pause
exit /b 0

:failed
echo.
echo   A step failed. Read the output above.
pause
exit /b 1
