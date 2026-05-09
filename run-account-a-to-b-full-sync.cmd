@echo off
setlocal
chcp 65001 >nul
title ChatGPT A to B Full Sync

set "SCRIPT_DIR=%~dp0"

if not exist "%SCRIPT_DIR%run-full-shared-link-migration.ps1" goto missing
if not exist "%SCRIPT_DIR%run-account-b-restore-projects.ps1" goto missing

cd /d "%SCRIPT_DIR%"

if /I "%GPTSYNC_CMD_SELFTEST%"=="1" (
  echo CMD launcher self-test OK.
  echo SCRIPT_DIR=%SCRIPT_DIR%
  exit /b 0
)

echo ============================================================
echo  ChatGPT account A -^> account B full sync
echo ============================================================
echo.
echo This will run:
echo   1. Account A: create shared links, export projects, download files
echo   2. Account B: import shared links and create conversation copies
echo   3. Account B: restore projects, move chats, upload files
echo.
echo It assumes both dedicated browser profiles are already logged in.
echo It will use the current Windows proxy settings and will not close Upnet/VPN.
echo.

"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%run-full-shared-link-migration.ps1" -AssumeYes -NoPause
if errorlevel 1 goto failed

"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%run-account-b-restore-projects.ps1" -AssumeYes -NoPause
if errorlevel 1 goto failed

echo.
echo ============================================================
echo  Sync finished.
echo  Reports are in:
echo  %SCRIPT_DIR%outputs
echo ============================================================
echo.
pause
exit /b 0

:missing
echo.
echo Cannot find required PowerShell scripts.
echo Checked:
echo   %SCRIPT_DIR%
echo.
pause
exit /b 1

:failed
echo.
echo ============================================================
echo  Sync failed. Check the error above and output logs.
echo  Reports/logs are in:
echo  %SCRIPT_DIR%outputs
echo ============================================================
echo.
pause
exit /b 1
