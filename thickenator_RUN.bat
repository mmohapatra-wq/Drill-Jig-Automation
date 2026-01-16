@echo off
Powershell.exe -executionpolicy Unrestricted -File thickenator.ps1
if %ERRORLEVEL% neq 0 (
    echo.
    echo Script exited with error code: %ERRORLEVEL%
    pause
)