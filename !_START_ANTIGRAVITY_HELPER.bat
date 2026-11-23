@echo off
chcp 65001 >nul
title Kotek Antigravity Helper
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0antigravity_helper.ps1" -Action menu
if errorlevel 1 (
    echo.
    pause
)
