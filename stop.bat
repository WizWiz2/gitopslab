@echo off
setlocal EnableDelayedExpansion

echo [Stop] Preparing Docker/Podman environment...

set "CTR_BIN="
set "COMPOSE_BIN="
set "COMPOSE_ARGS="
set "COMPOSE_CMD="
set "COMPOSE_LABEL="

REM Prefer Podman when available
where podman >nul 2>&1
if !errorlevel! equ 0 (
    set "CTR_BIN=podman"
    podman-compose --version >nul 2>nul
    if !errorlevel! equ 0 (
        set "COMPOSE_BIN=podman-compose"
        set "COMPOSE_LABEL=podman-compose"
    ) else (
        set "PY_LAUNCHER="
        for /f "usebackq delims=" %%P in (`where py 2^>nul`) do (
            if "!PY_LAUNCHER!"=="" set "PY_LAUNCHER=%%P"
        )
        if "!PY_LAUNCHER!"=="" (
            echo [Warn] Python launcher py.exe not found. Skipping podman-compose.
        ) else (
            set "PY_VERSION="
            for %%V in (3.12 3.11) do (
                if "!PY_VERSION!"=="" (
                    "!PY_LAUNCHER!" -%%V -c "import sys" >nul 2>nul
                    if !errorlevel! equ 0 set "PY_VERSION=%%V"
                )
            )
            if "!PY_VERSION!"=="" (
                echo [Warn] Python 3.11+ not found. Skipping podman-compose.
            ) else (
                "!PY_LAUNCHER!" -!PY_VERSION! -m pip --version >nul 2>nul
                if !errorlevel! neq 0 (
                    "!PY_LAUNCHER!" -!PY_VERSION! -m ensurepip --upgrade >nul 2>nul
                )
                "!PY_LAUNCHER!" -!PY_VERSION! -m pip show podman-compose >nul 2>nul
                if !errorlevel! neq 0 (
                    echo [Stop] Installing podman-compose for Python !PY_VERSION!...
                    "!PY_LAUNCHER!" -!PY_VERSION! -m pip install --user podman-compose
                )
                "!PY_LAUNCHER!" -!PY_VERSION! -m pip show podman-compose >nul 2>nul
                if !errorlevel! equ 0 (
                    set "COMPOSE_BIN=!PY_LAUNCHER!"
                    set "COMPOSE_ARGS=-!PY_VERSION! -m podman_compose"
                    set "COMPOSE_LABEL=podman-compose py !PY_VERSION!"
                )
            )
        )
    )
) else (
    where docker >nul 2>&1
    if errorlevel 1 (
        echo [Error] Neither Docker nor Podman found. Please install one of them.
        exit /b 1
    )
    set "CTR_BIN=docker"
    set "COMPOSE_CMD=docker compose"
    docker compose version >nul 2>&1
    if errorlevel 1 (
        where docker-compose >nul 2>&1
        if not errorlevel 1 (
            set "COMPOSE_CMD=docker-compose"
        )
    )
)

echo [Stop] Stopping compose services...
if not "%COMPOSE_BIN%"=="" (
    echo [Stop] Using !COMPOSE_LABEL!
    "!COMPOSE_BIN!" !COMPOSE_ARGS! down --remove-orphans >nul 2>&1
) else if not "%COMPOSE_CMD%"=="" (
    echo [Stop] Using !COMPOSE_CMD!
    %COMPOSE_CMD% down --remove-orphans >nul 2>&1
)

echo [Stop] Stopping standalone containers...
for %%N in (platform-bootstrap woodpecker-server woodpecker-agent gitea registry k3d-registry.localhost) do (
    %CTR_BIN% stop %%N >nul 2>&1
    %CTR_BIN% rm %%N >nul 2>&1
)

echo [Stop] Stopping k3d containers...
for /f %%I in ('%CTR_BIN% ps -a -q --filter "name=k3d-"') do %CTR_BIN% stop %%I >nul 2>&1

echo [Stop] Done.

endlocal
