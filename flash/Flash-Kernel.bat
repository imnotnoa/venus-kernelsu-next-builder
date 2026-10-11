@echo off
rem Launcher for flash-kernel.ps1 (Windows PowerShell 5.1, no install needed).
rem Example: Flash-Kernel.bat -Image Image -StockBoot boot.img
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0flash-kernel.ps1" %*
set RC=%ERRORLEVEL%
echo.
pause
exit /b %RC%
