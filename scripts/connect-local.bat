@echo off
rem connect-local.bat —— Windows 双击入口：调用同目录的 connect-local.ps1
rem
rem 为什么包一层 bat：PowerShell 脚本默认不能双击运行（执行策略与文件关联都不对），
rem 用 bat 显式以 -ExecutionPolicy Bypass 启动，用户双击即可，不必改系统策略。
rem
rem 用法：双击运行后按提示输入 NAS 地址；也可在 CMD 里带参数：
rem   connect-local.bat <NAS-IP> root 22
setlocal
set "SCRIPT_DIR=%~dp0"
set "NAS_HOST=%~1"
set "NAS_USER=%~2"
set "SSH_PORT=%~3"

if "%NAS_HOST%"=="" (
  set /p NAS_HOST=请输入 NAS 局域网地址（如 192.168.1.10）:
)
if "%NAS_USER%"=="" set "NAS_USER=root"
if "%SSH_PORT%"=="" set "SSH_PORT=22"

powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%connect-local.ps1" -NasHost "%NAS_HOST%" -NasUser "%NAS_USER%" -SshPort %SSH_PORT%
endlocal
