@echo off
chcp 65001 >nul
title Sync Antigravity Signatures
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0sync_signatures.ps1"
echo.
pause
