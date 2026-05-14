@echo off
REM Gripenator launcher batch file
REM This batch file launches the gripenator.ps1 PowerShell script with appropriate execution policy

powershell.exe -ExecutionPolicy Bypass -NoProfile -File "%~dp0gripenator.ps1" %*
pause
