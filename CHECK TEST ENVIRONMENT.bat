@echo off
cd /d "%~dp0"
echo Rx2GO QA - проверка среды автотестов
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\run-tests.ps1" -CheckOnly
echo.
echo Exit code: %ERRORLEVEL%
pause
