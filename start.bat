@echo off
setlocal EnableDelayedExpansion
set "MSYS_NO_PATHCONV=1"

echo [Start] Checking environment...

REM Run pre-flight checks
if exist "scripts\preflight-check.bat" (
    call scripts\preflight-check.bat
    if errorlevel 1 (
        echo [Start] Pre-flight checks failed. Please fix errors before continuing.
        pause
        exit /b 1
    )
)

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
where ssh >nul 2>nul
if !errorlevel! neq 0 (
    echo [Error] ssh not found. Please install OpenSSH or Git for Windows.
    pause
    exit /b 1
)

REM Avoid creating NUL known_hosts files when Podman uses ssh
set "SSH_WRAPPER_DIR=%~dp0scripts\bin"
if exist "%SSH_WRAPPER_DIR%\ssh.cmd" (
    set "PATH=%SSH_WRAPPER_DIR%;!PATH!"
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
            echo [Start] Start failed. Attempting to initialize new Podman machine with more resources...
            REM Remove old machine if exists (failed start usually means broken or old config)
            podman machine rm -f >nul 2>nul
            
            REM Initialize with explicit resources: 4 CPUs, 8GB RAM, 50GB Disk
            podman machine init --cpus 4 --memory 8192 --disk-size 50
            
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
        echo [Start] Fixing DNS in Podman machine...
        podman machine ssh -- "echo 'nameserver 8.8.8.8' | sudo tee /etc/resolv.conf"
    ) else (
        echo [Start] Ensuring DNS is fixed in Podman machine...
        podman machine ssh -- "echo 'nameserver 8.8.8.8' | sudo tee /etc/resolv.conf"
    )

    if "!PODMAN_GATEWAY!"=="" set "PODMAN_GATEWAY=10.89.0.1"
    set "PODMAN_SERVICE_PORT=2375"
    set "DOCKER_HOST=tcp://!PODMAN_GATEWAY!:!PODMAN_SERVICE_PORT!"
    set "PODMAN_DOCKER_HOST=!DOCKER_HOST!"
    echo [Start] Configuring Podman VM registry access...
    set "HOSTS_NAMES=registry.localhost gitea.localhost woodpecker.localhost argocd.localhost demo.localhost mlflow.localhost minio.localhost apps.localhost k8s.localhost dashboard.localhost"
    set "HOSTS_PATTERN=registry\.localhost|gitea\.localhost|woodpecker\.localhost|argocd\.localhost|demo\.localhost|mlflow\.localhost|minio\.localhost|apps\.localhost|k8s\.localhost|dashboard\.localhost"
    podman machine ssh -- "grep -v -E '!HOSTS_PATTERN!' /etc/hosts > /tmp/hosts && printf '!PODMAN_GATEWAY! !HOSTS_NAMES!\n' >> /tmp/hosts && cat /tmp/hosts | sudo tee /etc/hosts > /dev/null"
    podman machine ssh -- "grep -q 'registry.localhost:5002' /etc/containers/registries.conf || printf '\n[[registry]]\nlocation = \"registry.localhost:5002\"\ninsecure = true\n' | sudo tee -a /etc/containers/registries.conf > /dev/null"
    podman machine ssh -- "pkill -f 'podman system service' || true"
    echo [Start] Ensuring Podman API service on !PODMAN_GATEWAY!:!PODMAN_SERVICE_PORT! ...
    podman machine ssh -- "systemd-run --user --unit=podman-tcp --remain-after-exit podman system service --time=0 tcp://0.0.0.0:!PODMAN_SERVICE_PORT! >/tmp/podman-system-service.log 2>&1" || podman machine ssh -- "nohup podman system service --time=0 tcp://0.0.0.0:!PODMAN_SERVICE_PORT! >/tmp/podman-system-service.log 2>&1 &"
    if !errorlevel! neq 0 (
        echo [Error] Failed to start Podman API service inside the VM.
        pause
        exit /b 1
    )
    
    REM Create k3d network with DNS enabled (required for k3d clusters)
    echo [Start] Creating k3d network with DNS...
    podman network exists k3d >nul 2>nul
    if !errorlevel! neq 0 (
        podman network create k3d
        if !errorlevel! neq 0 (
            echo [Error] Failed to create k3d network.
            pause
            exit /b 1
        )
    ) else (
        echo [Start] k3d network already exists
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
    set "CONTAINER_HOST="
    set "PODMAN_HOST="
    set "COMPOSE_CONVERT_WINDOWS_PATHS=0"
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
    echo [Start] cleaning up old bootstrap...
    podman rm -f platform-bootstrap >nul 2>&1
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
set "TOKEN_SIZE=0"
if exist dashboard-token.txt (
    for %%I in (dashboard-token.txt) do set "TOKEN_SIZE=%%~zI"
)
if !TOKEN_SIZE! gtr 40 (
    echo [Start] Dashboard token saved to dashboard-token.txt
) else (
    del /q dashboard-token.txt 2>nul
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
echo GitOps Stack:
echo   Gitea:       http://gitea.localhost:%GITEA_HTTP_PORT%
echo   Gitea SSH:   ssh://git@gitea.localhost:%GITEA_SSH_PORT%
echo   Woodpecker:  http://woodpecker.localhost:%WOODPECKER_SERVER_PORT%
echo   Registry:    http://registry.localhost:%REGISTRY_HTTP_PORT%/v2/
echo   Argo CD:     http://argocd.localhost:%ARGOCD_PORT%
echo MLOps Stack:
echo   MLflow:      http://mlflow.localhost:%MLFLOW_PORT%
echo   MinIO API:   http://minio.localhost:%MINIO_API_PORT%
echo   MinIO UI:    http://minio.localhost:%MINIO_CONSOLE_PORT%
echo   Demo App:    http://demo.localhost:8088
echo   ML Predict:  http://demo.localhost:8088/predict
echo Platform:
echo   Ingress/LB:  http://apps.localhost:8080
echo   K8s API:     https://k8s.localhost:%K3D_API_PORT%  (k3d %K3D_CLUSTER_NAME%)
echo   K8s Dashboard: https://dashboard.localhost:32443
echo   K8s Dashboard (apps): https://dashboard.localhost:32443/#/overview?namespace=apps
echo --------------------------------------------------------
"%SystemRoot%\System32\timeout.exe" /t 5 /nobreak >nul 2>&1
exit /b 0
