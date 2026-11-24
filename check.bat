@echo off
:: Shows what is installed and connected. Changes nothing.
setlocal
title kerenai status
if not exist "%~dp0installer.ps1" (
  echo installer.ps1 was not found next to this file.
  echo If you opened this from inside a ZIP file: right-click the ZIP,
  echo choose "Extract All", then run check.bat from the extracted folder.
  echo.
  pause
  exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0installer.ps1" -Check
echo.
pause
