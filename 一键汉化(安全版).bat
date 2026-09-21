@echo off
chcp 65001 >nul
title Antigravity 汉化与更新自愈工具
echo =======================================================
echo     Antigravity 界面汉化与更新自愈工具
echo =======================================================
echo.
echo  标准说明: 恢复以完全重启 Antigravity 为标准流程。
echo.
echo  [1] 完全退出 Antigravity 并执行汉化 (推荐, 100%% 原子替换成功)
echo  [2] 免杀后台汉化 (带 --no-kill, 若文件被占用会保留官方原版)
echo  [3] 启动后台“官方更新自动汉化守护进程”
echo.
set /p choice=请选择操作编号 (默认 1): 
if "%choice%"=="" set choice=1

if "%choice%"=="1" (
    echo.
    echo 正在安全退出 Antigravity...
    taskkill /F /IM Antigravity.exe >nul 2>&1
    taskkill /F /IM language_server.exe >nul 2>&1
    timeout /t 2 >nul
    echo 正在执行汉化打包与原子替换...
    node "%~dp0localize.js" --now
    echo.
    echo 汉化流程执行完毕。请重新启动 Antigravity 体验完整中文界面。
    pause
    exit /b
)

if "%choice%"=="2" (
    echo.
    echo 正在以 --no-kill 模式执行汉化...
    node "%~dp0localize.js" --now --no-kill
    echo.
    echo 提示: 恢复以完整重启为标准流程，若原子替换成功请完全重启软件生效。
    pause
    exit /b
)

if "%choice%"=="3" (
    echo.
    echo 正在启动后台自动汉化守护服务...
    cscript //nologo "%~dp0start-auto-localize.vbs"
    echo 后台守护程序已启动！官方每次更新后将自动检测并重新汉化。
    timeout /t 3 >nul
    exit /b
)
