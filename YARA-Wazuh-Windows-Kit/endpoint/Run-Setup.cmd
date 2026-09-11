@echo off
REM ===================================================================
REM  Full endpoint setup: install YARA + rule pack, wire the active-
REM  response scripts, then verify. Right-click > Run as administrator.
REM
REM  This is the ENDPOINT half only. The server\ folder still needs to be
REM  installed on the Wazuh manager (rules + an active-response block in
REM  ossec.conf) before anything actually fires -- see INTEGRATION-GUIDE.md.
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
echo   YARA + Wazuh endpoint setup
echo ==========================================================
echo.

set PS=powershell -NoProfile -ExecutionPolicy Bypass -File

echo [1/3] Installing YARA + signature-base rule pack...
%PS% ".\scripts\install-yara.ps1"
if errorlevel 1 goto :failed

echo.
echo [2/3] Wiring the active-response scripts...
%PS% ".\scripts\wire-active-response.ps1"
if errorlevel 1 goto :failed

echo.
echo [3/3] Verifying...
%PS% ".\scripts\verify.ps1"

echo.
echo ==========================================================
echo   Endpoint setup finished.
echo   Next: install the server\ folder on the Wazuh manager.
echo ==========================================================
pause
exit /b 0

:failed
echo.
echo   A step failed. Read the output above.
pause
exit /b 1
