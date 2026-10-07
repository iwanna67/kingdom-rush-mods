@echo off
chcp 65001 >nul
title Kingdom Rush 模组 - 一键安装
echo.
echo  正在安装 Kingdom Rush 模组...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1"
echo.
echo  按任意键关闭本窗口。
pause >nul
