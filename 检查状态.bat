@echo off
chcp 65001 >nul
title Kingdom Rush 模组 - 检查状态
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" -Status
echo.
echo  按任意键关闭本窗口。
pause >nul
