@echo off
setlocal

echo [E2E] Initializing The Ritual of Stabilization (Pytest Flow)...

REM Check Python
where python >nul 2>nul
if %errorlevel% neq 0 (
    echo [E2E] Python not found!
    exit /b 1
)

REM Ensure pytest is installed
python -c "import pytest" >nul 2>nul
if %errorlevel% neq 0 (
    echo [E2E] Installing dependencies...
    pip install -r tests/requirements.txt
)

REM Run the tests
echo [E2E] Running tests/test_e2e_flow.py...
python -m pytest tests/test_e2e_flow.py -v --capture=tee-sys -s

if %errorlevel% neq 0 (
    echo.
    echo [E2E] RITUAL FAILED. The system is unstable.
    echo [E2E] Check the logs above for the exact point of failure.
    exit /b 1
)

echo.
echo [E2E] RITUAL COMPLETE. Balance is restored.
endlocal
