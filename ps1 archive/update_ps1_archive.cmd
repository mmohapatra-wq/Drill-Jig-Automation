@echo off
setlocal enabledelayedexpansion

echo ========================================
echo   PS1 Archive Update Utility
echo ========================================
echo.
echo This script extracts PowerShell content from .cmd files
echo in the parent directory and saves them as .ps1 files here.
echo.

REM List of script names to process
set "SCRIPTS=flipenator gripenator nodelator radinator surfenator thickenator"

REM Process each script
for %%s in (%SCRIPTS%) do (
    if exist "..\tools\%%s.cmd" (
        echo Processing ..\tools\%%s.cmd...

        REM Use PowerShell to extract lines after line 6 (skip the batch wrapper)
        powershell -NoProfile -Command "$content = Get-Content '..\tools\%%s.cmd' -Raw -Encoding UTF8; $lines = $content -split \"`r?`n\"; $ps1Content = $lines[6..($lines.Length-1)] -join \"`r`n\"; [System.IO.File]::WriteAllText('%%s.ps1', $ps1Content, [System.Text.Encoding]::UTF8)"

        if exist "%%s.ps1" (
            echo   ^-^> Updated %%s.ps1
        ) else (
            echo   ^! Failed to create %%s.ps1
        )
    ) else (
        echo   ^! ..\tools\%%s.cmd not found, skipping
    )
)

echo.
echo ========================================
echo Update complete!
echo ========================================
echo.
pause
