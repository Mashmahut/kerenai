@echo off
:: kerenai: Claude Code setup for Windows. Double-click to install.
:: Do NOT right-click "Run as administrator": the script asks for
:: permission by itself, only for the parts that need it.
setlocal
title kerenai setup
if not exist "%~dp0installer.ps1" (
  echo installer.ps1 was not found next to this file.
  echo If you opened this from inside a ZIP file: right-click the ZIP,
  echo choose "Extract All", then run install.bat from the extracted folder.
  echo.
  pause
  exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0installer.ps1" %*
echo.
pause
