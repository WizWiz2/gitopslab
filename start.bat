@echo off
setlocal EnableDelayedExpansion
set "MSYS_NO_PATHCONV=1"

REM ============================================================================
REM PHASE 0: Environment Check (NO Podman commands)
REM ============================================================================
echo.
echo ========================================
echo [Start] Phase 0: Environment Check
echo ========================================

REM Check Podman CLI availability
where podman >nul 2>nul
if !errorlevel! neq 0 (
    echo [ERROR] Podman not found
    echo [FIX] Install from: https://podman.io
    pause
    exit /b 1
)
echo [Start] √ Podman CLI found

REM Check .env file
if not exist .env (
    if not exist .env.example (
        echo [ERROR] .env.example not found
        pause
        exit /b 1
    )
    echo [Start] Creating .env from .env.example...
    copy .env.example .env >nul
)
echo [Start] √ .env file exists

REM Load .env values
for /f "usebackq eol=# tokens=1,2 delims==" %%A in (.env) do (
    if not "%%~A"=="" set "%%A=%%B"
)

REM Check SSH tools
where ssh-keygen >nul 2>nul
if !errorlevel! neq 0 (
    echo [Start] Adding SSH tools to PATH...
    set "PATH=C:\Windows\System32\OpenSSH;!PATH!"
    set "PATH=C:\Program Files\Git\usr\bin;!PATH!"
)

echo [Start] √ Environment OK

REM ============================================================================
REM PHASE 1: Podman Machine (Idempotent)
REM ============================================================================
echo.
echo ========================================
echo [Start] Phase 1: Podman Machine
echo ========================================

REM Check if machine exists using podman machine list
podman machine list 2>nul | findstr /C:"podman-machine-default" >nul 2>nul
if !errorlevel! neq 0 (
    echo [Start] No Podman machine found. Creating...
    podman machine init --cpus 4 --memory 8192 --rootful --now
    if !errorlevel! neq 0 (
        echo [ERROR] Failed to create Podman machine
        echo [FIX] Check WSL2 installation: wsl --status
        pause
        exit /b 1
    )
    echo [Start] √ Podman machine created
    goto :machine_ready
)

echo [Start] Machine found. Checking if running...
REM Check if machine is running
podman machine list | findstr /C:"Currently running" >nul 2>nul
if !errorlevel! neq 0 (
    echo [Start] Machine stopped. Starting...
    podman machine start
    if !errorlevel! neq 0 (
        echo [ERROR] Failed to start machine
        echo [FIX] Try: podman machine rm -f, then run start.bat again
        pause
        exit /b 1
    )
)

:machine_ready
echo [Start] √ Podman machine running

REM ============================================================================
REM PHASE 2: Verify Podman API (Fail-Fast)
REM ============================================================================
echo.
echo ========================================
echo [Start] Phase 2: Verifying Podman API
echo ========================================

podman ps >nul 2>nul
if !errorlevel! neq 0 (
    echo [ERROR] Podman API not responding
    echo [ERROR] This means API forwarding is broken
    echo.
    echo [FIX] Run these commands:
    echo   1. wsl --terminate podman-machine-default
    echo   2. podman machine rm -f
    echo   3. start.bat
    echo.
    pause
    exit /b 1
)

echo [Start] √ Podman API working

REM ============================================================================
REM PHASE 3: Configure Podman Machine
REM ============================================================================
echo.
echo ========================================
echo [Start] Phase 3: Configuring Machine
echo ========================================

REM Fix DNS
echo [Start] Configuring DNS...
podman machine ssh -- "echo 'nameserver 8.8.8.8' | sudo tee /etc/resolv.conf" >nul 2>nul

REM Auto-detect k3d network gateway
for /f "tokens=*" %%i in ('podman network inspect k3d --format "{{range .IPAM.Config}}{{.Gateway}}{{end}}" 2^>nul') do set "PODMAN_GATEWAY=%%i"
if "!PODMAN_GATEWAY!"=="" (
    set "PODMAN_GATEWAY=10.89.0.1"
    echo [Start] Using default gateway: 10.89.0.1
) else (
    echo [Start] Detected gateway: !PODMAN_GATEWAY!
)

REM Update HOST_GATEWAY_IP in .env
powershell -NoProfile -Command "(Get-Content .env) -replace '^HOST_GATEWAY_IP=.*', 'HOST_GATEWAY_IP=!PODMAN_GATEWAY!' | Set-Content .env" >nul

REM Configure /etc/hosts in VM
set "HOSTS_NAMES=registry registry.localhost k3d-registry.localhost gitea.localhost woodpecker.localhost argocd.localhost demo.localhost mlflow.localhost minio.localhost apps.localhost k8s.localhost dashboard.localhost"
set "HOSTS_PATTERN=registry\\.localhost|k3d-registry\\.localhost|gitea\\.localhost|woodpecker\\.localhost|argocd\\.localhost|demo\\.localhost|mlflow\\.localhost|minio\\.localhost|apps\\.localhost|k8s\\.localhost|dashboard\\.localhost"
podman machine ssh -- "grep -v -E '!HOSTS_PATTERN!' /etc/hosts > /tmp/hosts && printf '!PODMAN_GATEWAY! !HOSTS_NAMES!\n' >> /tmp/hosts && cat /tmp/hosts | sudo tee /etc/hosts > /dev/null" >nul 2>nul

REM Configure insecure registries
for /f "tokens=*" %%i in ('podman network inspect k3d --format "{{range .IPAM.Config}}{{.Subnet}}{{end}}" 2^>nul') do set "K3D_SUBNET=%%i"
if "!K3D_SUBNET!"=="" set "K3D_SUBNET=10.89.0.0/16"
podman machine ssh -- "grep -q '!K3D_SUBNET!' /etc/containers/registries.conf || printf '\n[[registry]]\nlocation = \"!K3D_SUBNET!\"\ninsecure = true\n\n[[registry]]\nlocation = \"registry.localhost:5002\"\ninsecure = true\n' | sudo tee -a /etc/containers/registries.conf > /dev/null" >nul 2>nul

echo [Start] √ Machine configured

REM ============================================================================
REM PHASE 4: Create Network with DNS
REM ============================================================================
echo.
echo ========================================
echo [Start] Phase 4: Creating Network
echo ========================================

podman network create gitopslab 2>nul
echo [Start] √ gitopslab network ready

REM ============================================================================
REM PHASE 5: Start Services (Native Podman Run)
REM ============================================================================
echo.
echo ========================================
echo [Start] Phase 5: Starting Services
echo ========================================

REM Preflight: Check for zombie registry containers
echo [Start] Checking for zombie registry containers...
set "ZOMBIE_COUNT=0"
for /f "tokens=*" %%i in ('podman ps -a --filter "ancestor=docker.io/library/registry:2" --format "{{.ID}}" 2^>nul') do (
    set /a ZOMBIE_COUNT+=1
    echo [Start] ! Found zombie registry container: %%i
)
if !ZOMBIE_COUNT! gtr 0 (
    echo [Start] ! WARNING: Found !ZOMBIE_COUNT! zombie registry container^(s^) from old compose versions
    echo [Start] ! These will be removed to free port 5002
)

REM Clean up old containers
echo [Start] Cleaning up old containers...
podman rm -f gitea woodpecker-server woodpecker-agent platform-bootstrap k3d-registry.localhost k3d-gitopslab-server-0 k3d-gitopslab-serverlb >nul 2>nul

REM Kill ALL registry containers (including zombies)
echo [Start] Removing all registry containers...
for /f "tokens=*" %%i in ('podman ps -a --filter "ancestor=docker.io/library/registry:2" --format "{{.ID}}" 2^>nul') do (
    echo [Start]   Removing registry container %%i
    podman rm -f %%i >nul 2>nul
)
for /f "tokens=*" %%i in ('podman ps -a --filter "name=registry" --format "{{.ID}}" 2^>nul') do (
    podman rm -f %%i >nul 2>nul
)

REM Create volumes
echo [Start] Creating volumes...
podman volume create gitea-data >nul 2>nul
podman volume create woodpecker-data >nul 2>nul
echo [Start] √ Volumes created

REM Start Gitea
echo [Start] Starting Gitea...
podman run -d ^
  --name gitea ^
  --restart unless-stopped ^
  --network gitopslab ^
  -p %GITEA_HTTP_PORT%:3000 ^
  -p %GITEA_SSH_PORT%:22 ^
  -v gitea-data:/data ^
  --add-host gitea.localhost:%HOST_GATEWAY_IP% ^
  --add-host woodpecker.localhost:%HOST_GATEWAY_IP% ^
  --add-host argocd.localhost:%HOST_GATEWAY_IP% ^
  --add-host demo.localhost:%HOST_GATEWAY_IP% ^
  --add-host minio.localhost:%HOST_GATEWAY_IP% ^
  --add-host mlflow.localhost:%HOST_GATEWAY_IP% ^
  -e USER_UID=1000 ^
  -e USER_GID=1000 ^
  -e GITEA__security__INSTALL_LOCK=true ^
  -e GITEA__server__DOMAIN=gitea.localhost ^
  -e GITEA__server__ROOT_URL=%GITEA_PUBLIC_URL% ^
  gitea/gitea:%GITEA_VERSION%

if !errorlevel! neq 0 (
    echo [ERROR] Failed to start Gitea
    echo [FIX] Check logs: podman logs gitea
    pause
    exit /b 1
)

REM Wait for Gitea
echo [Start] Waiting for Gitea...
:wait_gitea
podman exec gitea curl -f -s http://localhost:3000/api/healthz >nul 2>nul
if errorlevel 1 (
    "%SystemRoot%\System32\timeout.exe" /t 2 /nobreak >nul
    goto :wait_gitea
)
echo [Start] √ Gitea ready

REM Pre-provision OAuth
echo [Start] Pre-provisioning Woodpecker OAuth...
podman run --rm --network gitopslab ^
  -v "%CD%:/workspace:ro" ^
  -v "%CD%\.env:/workspace/.env:rw" ^
  -e GITEA_INTERNAL_URL=http://gitea:3000 ^
  -e GITEA_ADMIN_USER=%GITEA_ADMIN_USER% ^
  -e GITEA_ADMIN_PASSWORD=%GITEA_ADMIN_PASSWORD% ^
  -e WOODPECKER_HOST=%WOODPECKER_HOST% ^
  localhost/gitopslab_bootstrap:latest bash /workspace/scripts/pre-provision-oauth.sh

if !errorlevel! equ 0 (
    echo [Start] √ OAuth configured
    REM Reload .env
    for /f "usebackq eol=# tokens=1,2 delims==" %%A in (.env) do (
        if not "%%~A"=="" set "%%A=%%B"
    )
)

REM Start Woodpecker Server
echo [Start] Starting Woodpecker Server...
podman run -d ^
  --name woodpecker-server ^
  --restart unless-stopped ^
  --network gitopslab ^
  -p %WOODPECKER_SERVER_PORT%:8000 ^
  -v woodpecker-data:/var/lib/woodpecker ^
  --add-host localhost:%HOST_GATEWAY_IP% ^
  --add-host gitea.localhost:%HOST_GATEWAY_IP% ^
  --add-host woodpecker.localhost:%HOST_GATEWAY_IP% ^
  --add-host argocd.localhost:%HOST_GATEWAY_IP% ^
  --add-host demo.localhost:%HOST_GATEWAY_IP% ^
  --add-host minio.localhost:%HOST_GATEWAY_IP% ^
  --add-host mlflow.localhost:%HOST_GATEWAY_IP% ^
  -e WOODPECKER_OPEN=true ^
  -e WOODPECKER_HOST=%WOODPECKER_HOST% ^
  -e WOODPECKER_GITEA=true ^
  -e WOODPECKER_GITEA_URL=%WOODPECKER_GITEA_URL% ^
  -e WOODPECKER_EXPERT_FORGE_OAUTH_HOST=%WOODPECKER_EXPERT_FORGE_OAUTH_HOST% ^
  -e WOODPECKER_EXPERT_WEBHOOK_HOST=%WOODPECKER_EXPERT_WEBHOOK_HOST% ^
  -e WOODPECKER_GITEA_CLIENT=%WOODPECKER_GITEA_CLIENT% ^
  -e WOODPECKER_GITEA_SECRET=%WOODPECKER_GITEA_SECRET% ^
  -e WOODPECKER_AGENT_SECRET=%WOODPECKER_AGENT_SECRET% ^
  -e WOODPECKER_ADMIN=%WOODPECKER_ADMIN% ^
  woodpeckerci/woodpecker-server:%WOODPECKER_VERSION%

if !errorlevel! neq 0 (
    echo [ERROR] Failed to start Woodpecker Server
    echo [FIX] Check logs: podman logs woodpecker-server
    pause
    exit /b 1
)
echo [Start] √ Woodpecker Server started

REM Start Woodpecker Agent
echo [Start] Starting Woodpecker Agent...
podman run -d ^
  --name woodpecker-agent ^
  --restart unless-stopped ^
  --network gitopslab ^
  -v /run/podman/podman.sock:/var/run/docker.sock ^
  --add-host gitea.localhost:%HOST_GATEWAY_IP% ^
  --add-host woodpecker.localhost:%HOST_GATEWAY_IP% ^
  --add-host argocd.localhost:%HOST_GATEWAY_IP% ^
  --add-host demo.localhost:%HOST_GATEWAY_IP% ^
  --add-host minio.localhost:%HOST_GATEWAY_IP% ^
  --add-host mlflow.localhost:%HOST_GATEWAY_IP% ^
  -e WOODPECKER_SERVER=woodpecker-server:9000 ^
  -e WOODPECKER_AGENT_SECRET=%WOODPECKER_AGENT_SECRET% ^
  -e WOODPECKER_BACKEND=docker ^
  -e WOODPECKER_BACKEND_DOCKER_NETWORK=gitopslab ^
  -e WOODPECKER_BACKEND_DOCKER_DNS=8.8.8.8 ^
  woodpeckerci/woodpecker-agent:%WOODPECKER_VERSION%

if !errorlevel! neq 0 (
    echo [ERROR] Failed to start Woodpecker Agent
    echo [FIX] Check logs: podman logs woodpecker-agent
    pause
    exit /b 1
)
echo [Start] √ Woodpecker Agent started

REM Build Bootstrap image
echo [Start] Building bootstrap image...
podman build -t localhost/gitopslab_bootstrap:latest bootstrap
if !errorlevel! neq 0 (
    echo [ERROR] Failed to build bootstrap image
    pause
    exit /b 1
)

REM Start Bootstrap
echo [Start] Starting bootstrap...
podman run -d ^
  --name platform-bootstrap ^
  --network gitopslab ^
  -v /run/podman/podman.sock:/var/run/docker.sock ^
  -v "%CD%\.env:/workspace/.env" ^
  -v "%CD%\docker-compose.yml:/workspace/docker-compose.yml:ro" ^
  -v "%CD%\.woodpecker.yml:/workspace/.woodpecker.yml:ro" ^
  -v "%CD%\gitops:/workspace/gitops" ^
  -v "%CD%\hello-api:/workspace/hello-api" ^
  -v "%CD%\ml:/workspace/ml" ^
  -v "%CD%\scripts:/workspace/scripts:ro" ^
  -v "%CD%\mlflow:/workspace/mlflow:ro" ^
  --add-host registry.localhost:%HOST_GATEWAY_IP% ^
  --add-host registry:%HOST_GATEWAY_IP% ^
  --add-host gitea.localhost:%HOST_GATEWAY_IP% ^
  -e BOOTSTRAP_TRACE=true ^
  -e K3D_NETWORK=gitopslab ^
  --entrypoint /workspace/scripts/bootstrap.sh ^
  localhost/gitopslab_bootstrap:latest

if !errorlevel! neq 0 (
    echo [ERROR] Failed to start bootstrap
    echo [FIX] Check logs: podman logs platform-bootstrap
    pause
    exit /b 1
)
echo [Start] √ Services started

REM ============================================================================
REM PHASE 6: Build and Push MLflow Image
REM ============================================================================
echo.
echo ========================================
echo [Start] Phase 6: MLflow Image
echo ========================================

if exist "mlflow\Dockerfile" (
    echo [Start] Building MLflow image...
    podman build -t localhost:5002/mlflow:lite mlflow
    if !errorlevel! equ 0 (
        echo [Start] Waiting for k3d registry...
        :wait_registry
        curl -f -s http://localhost:5002/v2/ >nul 2>nul
        if errorlevel 1 (
            "%SystemRoot%\System32\timeout.exe" /t 5 /nobreak >nul
            goto :wait_registry
        )
        
        echo [Start] Pushing MLflow image to registry...
        podman push localhost:5002/mlflow:lite
        if !errorlevel! equ 0 (
            echo [Start] √ MLflow image pushed
        ) else (
            echo [WARN] Failed to push MLflow image
            echo [WARN] Run manually: podman push localhost:5002/mlflow:lite
        )
    ) else (
        echo [WARN] Failed to build MLflow image
    )
)
:skip_mlflow

REM ============================================================================
REM PHASE 7: Wait for Bootstrap
REM ============================================================================
echo.
echo ========================================
echo [Start] Phase 7: Platform Bootstrap
echo ========================================

echo [Start] Waiting for bootstrap...
:wait_bootstrap
REM Check if bootstrap exited successfully
podman ps -a --filter "name=platform-bootstrap" --format "{{.Status}}" | findstr /C:"Exited (0)" >nul 2>nul
if !errorlevel! equ 0 (
    goto :bootstrap_success
)

REM Check if bootstrap exited with error
podman ps -a --filter "name=platform-bootstrap" --format "{{.Status}}" | findstr /C:"Exited" >nul 2>nul
if !errorlevel! equ 0 (
    echo.
    echo [ERROR] Bootstrap failed! Last 30 lines of logs:
    echo ========================================
    podman logs --tail 30 platform-bootstrap
    echo ========================================
    echo.
    pause
    exit /b 1
)

REM Still running, wait more
"%SystemRoot%\System32\timeout.exe" /t 2 /nobreak >nul
goto :wait_bootstrap

:bootstrap_success

echo [Start] √ Bootstrap complete

REM ============================================================================
REM DONE
REM ============================================================================
echo.
echo ========================================
echo [Start] Platform Ready!
echo ========================================
echo.
echo GitOps Stack:
echo   Gitea:       http://gitea.localhost:%GITEA_HTTP_PORT%
echo   Woodpecker:  http://woodpecker.localhost:%WOODPECKER_SERVER_PORT%
echo   Argo CD:     http://argocd.localhost:%ARGOCD_PORT%
echo.
echo MLOps Stack:
echo   MLflow:      http://mlflow.localhost:%MLFLOW_PORT%
echo   MinIO:       http://minio.localhost:%MINIO_CONSOLE_PORT%
echo.
echo Platform:
echo   K8s Dashboard: https://dashboard.localhost:32443
echo.
echo ========================================
echo FIRST-TIME SETUP (if needed):
echo ========================================
echo If Woodpecker repository is not activated:
echo   1. Open: http://woodpecker.localhost:%WOODPECKER_SERVER_PORT%
echo   2. Click "Login with Gitea"
echo   3. Authorize the application
echo   4. Re-run start.bat to complete setup
echo.
echo Credentials:
echo   Username: %GITEA_ADMIN_USER%
echo   Password: %GITEA_ADMIN_PASSWORD%
echo ========================================
echo.
echo.
echo [Start] Collecting credentials to credentials.txt...
podman exec platform-bootstrap bash /workspace/scripts/collect-creds.sh > credentials.txt 2>nul
if !errorlevel! equ 0 (
    echo [Start] √ Credentials saved to credentials.txt
) else (
    echo [Start] ! Could not collect credentials (cluster may not be ready)
)
echo.
timeout /t 5 /nobreak >nul 2>nul
exit /b 0
