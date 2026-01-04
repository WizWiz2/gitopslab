@echo off
REM Quick restart script - stops and starts platform with clean state

echo ============================================================
echo GitOps Lab - Quick Restart
echo ============================================================
echo.
echo This will:
echo   1. Stop all services
echo   2. Clean all data (volumes, k3d cluster)
echo   3. Start fresh
echo.

choice /C YN /M "Continue with full restart?"
if errorlevel 2 (
    echo Aborted by user.
    exit /b 0
)

echo.
echo [Restart] Step 1/3: Stopping services...
call stop.bat --clean

if errorlevel 1 (
    echo [Restart] Stop failed!
    pause
    exit /b 1
)

echo.
echo [Restart] Step 2/3: Waiting 5 seconds...
timeout /t 5 /nobreak >nul

echo.
echo [Restart] Step 3/3: Starting services...
call start.bat

if errorlevel 1 (
    echo [Restart] Start failed!
    pause
    exit /b 1
)

echo.
echo ============================================================
echo Restart Complete!
echo ============================================================
echo.
echo Platform is starting up. Please wait for bootstrap to complete.
echo You can monitor progress with: podman logs -f platform-bootstrap
echo.

pause
