@echo off
chcp 65001 >nul
title Build kotek-antigravity-helper Release
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0build_release.ps1"
echo.
pause
