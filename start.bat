@echo off
setlocal EnableDelayedExpansion

echo [Start] Checking environment...

if not exist .env (
    echo [Start] .env not found. Creating from .env.example...
    copy .env.example .env >nul
    if !errorlevel! neq 0 (
        echo [Error] Failed to create .env
        pause
        exit /b 1
    )
)

REM Load .env values (skip commented lines)
for /f "usebackq eol=# tokens=1,2 delims==" %%A in (.env) do (
    if not "%%~A"=="" set "%%A=%%B"
)

REM Ensure ssh-keygen is available (required by podman machine init)
where ssh-keygen >nul 2>nul
if !errorlevel! neq 0 (
    echo [Start] ssh-keygen not found in PATH. Adding common locations...
    set "PATH=C:\Windows\System32\OpenSSH;!PATH!"
    set "PATH=C:\Program Files\Git\usr\bin;!PATH!"
    set "PATH=C:\Program Files (x86)\Git\usr\bin;!PATH!"
)
where ssh-keygen >nul 2>nul
if !errorlevel! neq 0 (
    echo [Error] ssh-keygen not found. Please install OpenSSH or Git for Windows.
    pause
    exit /b 1
)

REM Ensure local Docker CLI (used to talk to Podman Docker API)
set "DOCKER_CLI_DIR=%CD%\docker-cli\docker"
if not exist "%DOCKER_CLI_DIR%\docker.exe" (
    echo [Start] Docker CLI not found. Downloading...
    powershell -NoProfile -Command "$ErrorActionPreference='Stop'; $url='https://download.docker.com/win/static/stable/x86_64/docker-27.3.1.zip'; $zip='docker-cli.zip'; Invoke-WebRequest -Uri $url -OutFile $zip; Expand-Archive -Path $zip -DestinationPath 'docker-cli' -Force"
    if not exist "%DOCKER_CLI_DIR%\docker.exe" (
        echo [Error] Failed to download Docker CLI.
        pause
        exit /b 1
    )
)
set "PATH=%DOCKER_CLI_DIR%;%PATH%"

echo [Start] Detecting container runtime...

REM Check for Podman
where podman >nul 2>nul
if !errorlevel! equ 0 (
    echo [Start] Podman found.
    
    echo [Start] Checking Podman status...
    podman info >nul 2>nul
    if !errorlevel! neq 0 (
        echo [Start] Podman machine seems to be stopped or missing. Attempting to start...
        podman machine start >nul 2>nul
        if !errorlevel! neq 0 (
            echo [Start] Start failed. Attempting to initialize new Podman machine...
            podman machine init
            if !errorlevel! neq 0 (
                echo [Error] Failed to initialize Podman machine. Please install WSL2 and Podman correctly.
                pause
                exit /b 1
            )
            echo [Start] Machine initialized. Starting...
            podman machine start
            if !errorlevel! neq 0 (
                 echo [Error] Failed to start Podman machine after init.
                 pause
                 exit /b 1
            )
        )
         REM Wait a bit for the socket to be ready
        "%SystemRoot%\System32\timeout.exe" /t 10 /nobreak >nul
    )

    REM Point Docker-compatible clients to the Podman machine socket
    set "DOCKER_HOST=npipe:////./pipe/podman-machine-default"
    set "CONTAINER_HOST=!DOCKER_HOST!"
    set "PODMAN_HOST=!DOCKER_HOST!"

    REM Prefer docker-compose when using Podman; fallback to podman compose if not installed
    where docker-compose >nul 2>nul
    if !errorlevel! equ 0 (
        set "COMPOSE_CMD=docker-compose"
    ) else (
        set "COMPOSE_CMD=podman compose"
    )
    echo [Start] Using !COMPOSE_CMD!
    goto :run
)

REM Check for Docker
where docker >nul 2>nul
if !errorlevel! equ 0 (
    echo [Start] Docker found.
    set "COMPOSE_CMD=docker compose"
    goto :run
)

echo [Error] Neither Docker nor Podman found. Please install one of them.
pause
exit /b 1

:run
echo [Start] Starting services with !COMPOSE_CMD!...
!COMPOSE_CMD! up -d
if !errorlevel! neq 0 (
    echo [Error] Failed to start services.
    pause
    exit /b 1
)

echo [Start] Done! You can now access the dashboards.
echo --------------------------------------------------------
echo Gitea:       http://localhost:%GITEA_HTTP_PORT%
echo Gitea SSH:   ssh://git@localhost:%GITEA_SSH_PORT%
echo Woodpecker:  http://localhost:%WOODPECKER_SERVER_PORT%
echo Registry:    http://localhost:%REGISTRY_HTTP_PORT%/v2/
echo Argo CD:     http://localhost:%ARGOCD_PORT%
echo Ingress/LB:  http://localhost:8080
echo K8s API:     https://localhost:%K3D_API_PORT%  (k3d %K3D_CLUSTER_NAME%)
echo Demo App:    http://localhost:8088
echo --------------------------------------------------------
"%SystemRoot%\System32\timeout.exe" /t 5 /nobreak >nul
