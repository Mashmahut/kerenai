@echo off
:: Claude Code setup for Windows - double-click to install.
:: Do NOT right-click "Run as administrator": the script asks for
:: permission by itself, only for the parts that need it.
setlocal
title Claude Code setup
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0installer.ps1" %*
echo.
pause
