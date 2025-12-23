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
    set "PATH=C:\Program Files ^(x86^)\Git\usr\bin;!PATH!"
)
where ssh-keygen >nul 2>nul
if !errorlevel! neq 0 (
    echo [Error] ssh-keygen not found. Please install OpenSSH or Git for Windows.
    pause
    exit /b 1
)

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

    REM Prefer podman-compose; podman compose falls back to docker-compose and breaks on Windows here
    set "COMPOSE_BIN="
    set "COMPOSE_ARGS="
    set "COMPOSE_LABEL="
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
            echo [Error] Python launcher py.exe not found. Required for podman-compose.
            pause
            exit /b 1
        )
        set "PY_VERSION="
        for %%V in (3.12 3.11) do (
            if "!PY_VERSION!"=="" (
                "!PY_LAUNCHER!" -%%V -c "import sys" >nul 2>nul
                if !errorlevel! equ 0 set "PY_VERSION=%%V"
            )
        )
        if "!PY_VERSION!"=="" (
            echo [Error] Python 3.11+ not found. Install Python 3.11 or 3.12 for podman-compose.
            pause
            exit /b 1
        )
        "!PY_LAUNCHER!" -!PY_VERSION! -m pip --version >nul 2>nul
        if !errorlevel! neq 0 (
            "!PY_LAUNCHER!" -!PY_VERSION! -m ensurepip --upgrade >nul 2>nul
        )
        "!PY_LAUNCHER!" -!PY_VERSION! -m pip show podman-compose >nul 2>nul
        if !errorlevel! neq 0 (
            echo [Start] Installing podman-compose for Python !PY_VERSION!...
            "!PY_LAUNCHER!" -!PY_VERSION! -m pip install --user podman-compose
            if !errorlevel! neq 0 (
                echo [Error] Failed to install podman-compose for Python !PY_VERSION!.
                pause
                exit /b 1
            )
        )
        set "COMPOSE_BIN=!PY_LAUNCHER!"
        set "COMPOSE_ARGS=-!PY_VERSION! -m podman_compose"
        set "COMPOSE_LABEL=podman-compose py !PY_VERSION!"
    )
    set "DOCKER_HOST="
    set "CONTAINER_HOST="
    set "PODMAN_HOST="
    echo [Start] Using !COMPOSE_LABEL!
    goto :run
)

REM Check for Docker
where docker >nul 2>nul
if !errorlevel! equ 0 (
    echo [Start] Docker found.
    set "COMPOSE_CMD=docker compose"
    REM If Podman socket exists, point docker client to it as an optional fallback
    if exist "\\\\.\\pipe\\podman-machine-default" (
        set "DOCKER_HOST=npipe:////./pipe/podman-machine-default"
    )
    goto :run
)

echo [Error] Neither Docker nor Podman found. Please install one of them.
pause
exit /b 1

:run
if not "%COMPOSE_BIN%"=="" (
    echo [Start] Starting services with !COMPOSE_BIN! !COMPOSE_ARGS!...
    "!COMPOSE_BIN!" !COMPOSE_ARGS! up -d --remove-orphans --force-recreate
) else (
    echo [Start] Starting services with !COMPOSE_CMD!...
    !COMPOSE_CMD! up -d
)
if !errorlevel! neq 0 (
    echo [Error] Failed to start services.
    pause
    exit /b 1
)

REM Detect container CLI for follow-up commands (token, kubeconfig)
set "CTR_BIN=podman"
where podman >nul 2>nul
if !errorlevel! neq 0 (
    set "CTR_BIN=docker"
)

REM Generate dashboard token and save locally
echo [Start] Fetching Kubernetes Dashboard token...
%CTR_BIN% exec platform-bootstrap /workspace/scripts/dashboard-token.sh > dashboard-token.txt 2>nul
if exist dashboard-token.txt (
    echo [Start] Dashboard token saved to dashboard-token.txt
) else (
    echo [Warn] Could not fetch dashboard token automatically. Use podman exec platform-bootstrap /workspace/scripts/dashboard-token.sh
)

REM Collect credentials/tokens for convenience
echo [Start] Collecting credentials...
%CTR_BIN% exec platform-bootstrap /workspace/scripts/collect-creds.sh > credentials.txt 2>nul
if exist credentials.txt (
    echo [Start] Credentials saved to credentials.txt
) else (
    echo [Warn] Could not collect credentials automatically.
)

echo [Start] Done! You can now access the dashboards.
echo --------------------------------------------------------
echo Gitea:       http://gitea.localhost:%GITEA_HTTP_PORT%
echo Gitea SSH:   ssh://git@localhost:%GITEA_SSH_PORT%
echo Woodpecker:  http://woodpecker.localhost:%WOODPECKER_SERVER_PORT%
echo Registry:    http://registry.localhost:%REGISTRY_HTTP_PORT%/v2/
echo Argo CD:     http://argocd.localhost:%ARGOCD_PORT%
echo MLflow:      http://mlflow.localhost:%MLFLOW_PORT%
echo MinIO API:   http://minio.localhost:%MINIO_API_PORT%
echo MinIO UI:    http://minio.localhost:%MINIO_CONSOLE_PORT%
echo Ingress/LB:  http://localhost:8080
echo K8s API:     https://k8s.localhost:%K3D_API_PORT%  (k3d %K3D_CLUSTER_NAME%)
echo Demo App:    http://demo.localhost:8088
echo ML Predict:  http://demo.localhost:8088/predict
echo K8s Dashboard: https://dashboard.localhost:32443
echo --------------------------------------------------------
"%SystemRoot%\System32\timeout.exe" /t 5 /nobreak >nul 2>&1
exit /b 0
