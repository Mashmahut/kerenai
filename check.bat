@echo off
:: Shows what is installed and connected. Changes nothing.
setlocal
title Claude Code setup - status
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0installer.ps1" -Check
echo.
pause
