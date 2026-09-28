@echo off
rem WarRoom dashboard server launcher. Double-click = this PC only (http://127.0.0.1:8765/).
rem Extra options are passed through, e.g.:  serve.bat -Lan -Port 9000
rem -ExecutionPolicy Bypass applies to THIS process only; it does not change system settings.
setlocal
title WarRoom dashboard server
set "PSEXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PSEXE%" set "PSEXE=powershell.exe"
"%PSEXE%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0serve.ps1" %*
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" (
  echo.
  echo Server exited with code %RC%.
  pause
)
endlocal & exit /b %RC%
