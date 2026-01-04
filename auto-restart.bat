@echo off
REM Auto-restart without prompts

echo [Auto-Restart] Stopping with full cleanup...
call stop.bat --clean

echo.
echo [Auto-Restart] Waiting 3 seconds...
timeout /t 3 /nobreak >nul

echo.
echo [Auto-Restart] Starting platform...
call start.bat

echo.
echo [Auto-Restart] Complete!
