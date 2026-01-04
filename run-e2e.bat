@echo off
setlocal

REM Run end-to-end test: commit in Gitea -> Woodpecker -> ArgoCD -> deploy
REM Usage: run-e2e.bat [timeoutSeconds]

set "TIMEOUT_SEC=%~1"
if "%TIMEOUT_SEC%"=="" set "TIMEOUT_SEC=600"

powershell -NoProfile -ExecutionPolicy Bypass -Command "chcp 65001 >$null; & '%~dp0tests\e2e.ps1' -TimeoutSec %TIMEOUT_SEC%; exit $LASTEXITCODE"
if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%

endlocal
