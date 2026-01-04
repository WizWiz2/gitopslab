@echo off
setlocal enabledelayedexpansion

REM Pre-flight checks for GitOps Lab Platform
REM Validates environment before starting services

echo [Preflight] Starting pre-flight checks...

set ERRORS=0
set WARNINGS=0

REM ============================================================================
REM 1. Check if .env exists
REM ============================================================================

if not exist ".env" (
    echo [Preflight] ERROR: .env file not found
    echo [Preflight] Please copy .env.example to .env and configure it
    set /a ERRORS+=1
    goto :summary
)

echo [Preflight] ✓ .env file exists

REM ============================================================================
REM 2. Check if Podman is running
REM ============================================================================

podman version >nul 2>&1
if errorlevel 1 (
    echo [Preflight] ERROR: Podman not found or not running
    set /a ERRORS+=1
    goto :summary
)

echo [Preflight] ✓ Podman is available

REM ============================================================================
REM 3. Check Podman machine status
REM ============================================================================

podman machine list | findstr /C:"Currently running" >nul 2>&1
if errorlevel 1 (
    echo [Preflight] WARN: Podman machine not running
    echo [Preflight] Will attempt to start it...
    set /a WARNINGS+=1
)

REM ============================================================================
REM 4. Check if k3d network exists
REM ============================================================================

podman network inspect k3d >nul 2>&1
if errorlevel 1 (
    echo [Preflight] WARN: k3d network does not exist
    echo [Preflight] Will be created during startup
    set /a WARNINGS+=1
) else (
    echo [Preflight] ✓ k3d network exists
)

REM ============================================================================
REM 5. Validate .env critical variables
REM ============================================================================

findstr /C:"WOODPECKER_GITEA_CLIENT=replace-me" .env >nul 2>&1
if not errorlevel 1 (
    echo [Preflight] WARN: WOODPECKER_GITEA_CLIENT not configured
    echo [Preflight] OAuth will need manual setup after first start
    set /a WARNINGS+=1
)

findstr /C:"HOST_GATEWAY_IP=10.88.0.1" .env >nul 2>&1
if not errorlevel 1 (
    echo [Preflight] ERROR: HOST_GATEWAY_IP still set to old value 10.88.0.1
    echo [Preflight] Please update to 10.89.0.1 in .env
    set /a ERRORS+=1
)

REM ============================================================================
REM 6. Check .woodpecker.yml for correct IP
REM ============================================================================

if exist ".woodpecker.yml" (
    findstr /C:"10.88.0.1" .woodpecker.yml >nul 2>&1
    if not errorlevel 1 (
        echo [Preflight] ERROR: .woodpecker.yml contains old IP 10.88.0.1
        echo [Preflight] Please update DOCKER_HOST to 10.89.0.1
        set /a ERRORS+=1
    ) else (
        echo [Preflight] ✓ .woodpecker.yml has correct IP
    )
)

REM ============================================================================
REM 7. Check Python availability for podman-compose
REM ============================================================================

py -3.12 --version >nul 2>&1
if errorlevel 1 (
    py -3.11 --version >nul 2>&1
    if errorlevel 1 (
        echo [Preflight] ERROR: Python 3.11 or 3.12 not found
        echo [Preflight] Required for podman-compose
        set /a ERRORS+=1
    ) else (
        echo [Preflight] ✓ Python 3.11 available
    )
) else (
    echo [Preflight] ✓ Python 3.12 available
)

REM ============================================================================
REM 8. Check disk space
REM ============================================================================

for /f "tokens=3" %%a in ('dir /-c ^| findstr /C:"bytes free"') do set FREE_SPACE=%%a
set FREE_SPACE=%FREE_SPACE:,=%

REM Check if less than 10GB free (10737418240 bytes)
if %FREE_SPACE% LSS 10737418240 (
    echo [Preflight] WARN: Low disk space ^(less than 10GB free^)
    set /a WARNINGS+=1
) else (
    echo [Preflight] ✓ Sufficient disk space
)

REM ============================================================================
REM Summary
REM ============================================================================

:summary
echo.
echo [Preflight] ========================================
echo [Preflight] Pre-flight check complete
echo [Preflight] Errors: %ERRORS%, Warnings: %WARNINGS%
echo [Preflight] ========================================

if %ERRORS% GTR 0 (
    echo [Preflight] FAILED: Please fix errors before starting
    exit /b 1
)

if %WARNINGS% GTR 0 (
    echo [Preflight] PASSED with warnings
    exit /b 0
)

echo [Preflight] ✓ All checks PASSED
exit /b 0
