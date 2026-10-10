@echo off
rem 双击即可构建（等价于用 PowerShell 跑 build-apk.ps1）
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0build-apk.ps1" %*
echo.
pause
