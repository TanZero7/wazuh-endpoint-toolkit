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
echo   CDAC Security Baseline SCA policy - endpoint setup
echo ==========================================================
echo.
set PS=powershell -NoProfile -ExecutionPolicy Bypass -File
echo [1/2] Installing the policy...
%PS% ".\scripts\install-baseline-policy.ps1"
if errorlevel 1 goto :failed
echo.
echo [2/2] Verifying...
%PS% ".\scripts\verify.ps1"
echo.
echo ==========================================================
echo   Done. Nothing to install on the server - this is a
echo   pure SCA policy, evaluated entirely on the agent.
echo ==========================================================
pause
exit /b 0
:failed
echo.
echo   A step failed. Read the output above.
pause
exit /b 1
