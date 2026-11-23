@echo off
chcp 65001 >nul
title Publish Kotek Antigravity Helper to GitHub
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0publish_github.ps1"
echo.
pause
