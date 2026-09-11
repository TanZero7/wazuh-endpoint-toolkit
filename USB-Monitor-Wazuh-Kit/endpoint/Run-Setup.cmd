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
echo   USB storage monitor - endpoint setup
echo ==========================================================
echo.
set PS=powershell -NoProfile -ExecutionPolicy Bypass -File
echo [1/2] Enabling the channel and wiring the agent...
%PS% ".\scripts\wire-usb-channel.ps1"
if errorlevel 1 goto :failed
echo.
echo [2/2] Verifying...
%PS% ".\scripts\verify.ps1"
echo.
echo ==========================================================
echo   Endpoint setup finished.
echo   Next: install server\ on the Wazuh manager, then plug in
echo   a real USB drive to prove it end to end.
echo ==========================================================
pause
exit /b 0
:failed
echo.
echo   A step failed. Read the output above.
pause
exit /b 1
