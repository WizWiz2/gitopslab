@echo off
REM Health Check Runner for GitOps Lab Platform
REM Runs all available health checks

setlocal enabledelayedexpansion

echo ============================================================
echo GitOps Lab Platform - Health Check Suite
echo ============================================================
echo.

set CHECK_TYPE=%1
if "%CHECK_TYPE%"=="" set CHECK_TYPE=all

REM ============================================================================
REM Pre-flight checks (before start)
REM ============================================================================

if "%CHECK_TYPE%"=="preflight" goto :run_preflight
if "%CHECK_TYPE%"=="all" goto :run_preflight
goto :skip_preflight

:run_preflight
echo [Health] Running pre-flight checks...
call scripts\preflight-check.bat
if errorlevel 1 (
    echo [Health] Pre-flight checks FAILED
    if "%CHECK_TYPE%"=="preflight" exit /b 1
) else (
    echo [Health] ✓ Pre-flight checks PASSED
)
echo.

:skip_preflight

REM ============================================================================
REM Smoke tests (quick validation)
REM ============================================================================

if "%CHECK_TYPE%"=="smoke" goto :run_smoke
if "%CHECK_TYPE%"=="all" goto :run_smoke
goto :skip_smoke

:run_smoke
echo [Health] Running smoke tests...
python tests\smoke.py
if errorlevel 1 (
    echo [Health] Smoke tests FAILED
    if "%CHECK_TYPE%"=="smoke" exit /b 1
) else (
    echo [Health] ✓ Smoke tests PASSED
)
echo.

:skip_smoke

REM ============================================================================
REM Full health check (comprehensive)
REM ============================================================================

if "%CHECK_TYPE%"=="full" goto :run_full
if "%CHECK_TYPE%"=="all" goto :run_full
goto :skip_full

:run_full
echo [Health] Running full health check...
podman run --rm --network k3d ^
    -v "%CD%:/workspace" ^
    -v /run/podman/podman.sock:/var/run/docker.sock ^
    --env-file .env ^
    gitopslab_bootstrap /workspace/scripts/health-check.sh

if errorlevel 1 (
    echo [Health] Full health check FAILED
    if "%CHECK_TYPE%"=="full" exit /b 1
) else (
    echo [Health] ✓ Full health check PASSED
)
echo.

:skip_full

REM ============================================================================
REM Summary
REM ============================================================================

echo ============================================================
echo Health Check Suite Complete
echo ============================================================
echo.
echo Usage:
echo   health-check.bat [preflight^|smoke^|full^|all]
echo.
echo   preflight - Run before starting platform
echo   smoke     - Quick validation of running platform
echo   full      - Comprehensive health check
echo   all       - Run all checks (default)
echo.

exit /b 0
