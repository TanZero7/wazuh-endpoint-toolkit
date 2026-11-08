@echo off
REM ===================================================================
REM  Full endpoint setup: install Suricata, configure it, wire the
REM  Wazuh agent, then verify. Right-click > Run as administrator,
REM  or just double-click and accept the UAC prompt.
REM
REM  WHY A .CMD WRAPPER EXISTS
REM  PowerShell blocks .ps1 files by default ("running scripts is
REM  disabled on this system"). This launcher passes
REM  -ExecutionPolicy Bypass for THIS PROCESS ONLY, so nothing about
REM  the machine's security posture is changed permanently.
REM ===================================================================
setlocal
cd /d "%~dp0"

REM --- self-elevate if not already running as administrator ---
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo Requesting administrator rights...
    powershell -NoProfile -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)

echo.
echo ==========================================================
echo   Suricata + Wazuh endpoint setup
echo ==========================================================
echo.

set PS=powershell -NoProfile -ExecutionPolicy Bypass -File

echo [1/5] Preflight...
%PS% ".\scripts\00-preflight.ps1"
if errorlevel 1 goto :failed

echo.
echo [2/5] Installing Suricata and the ruleset...
%PS% ".\scripts\02-install-suricata.ps1"
if errorlevel 1 goto :failed

echo.
echo [3/5] Configuring Suricata...
%PS% ".\scripts\03-configure-suricata.ps1"
if errorlevel 1 goto :failed

echo.
echo [4/5] Wiring the Wazuh agent to eve.json...
%PS% ".\scripts\04-wire-wazuh-agent.ps1"
if errorlevel 1 goto :failed

echo.
echo [5/5] Verifying...
%PS% ".\scripts\05-verify.ps1"

echo.
echo ==========================================================
echo   Endpoint setup finished.
echo   Next: install the manager rules from suricata\ in wazuh-manager-toolkit.
echo ==========================================================
pause
exit /b 0

:failed
echo.
echo ==========================================================
echo   A step failed. Read the output above, and check the
echo   transcript in  logs\  for the full detail.
echo ==========================================================
pause
exit /b 1
