@echo off
cd /d "%~dp0"
chcp 65001 >nul
echo Проверка конфигурации Playwright...
call npx playwright test --list
echo.
echo Exit code: %ERRORLEVEL%
pause

