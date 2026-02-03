@echo off
REM Radinator Launcher - Handles PowerShell execution policy automatically
REM This batch file ensures the script runs even if execution policy is restricted

echo ========================================
echo   RADINATOR
echo   Node-to-Stiffener Radius Tool
echo ========================================
echo.

REM Run PowerShell with bypass for this session only (doesn't change system policy)
powershell.exe -ExecutionPolicy Bypass -NoProfile -File "%~dp0radinator.ps1" %*

REM Keep window open if there was an error
if %ERRORLEVEL% neq 0 (
    echo.
    echo Script exited with error code: %ERRORLEVEL%
    pause
)
