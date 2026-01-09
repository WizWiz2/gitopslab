# IDP-in-a-Box (gitopslab)

One-command demo platform showcasing GitOps-first delivery with k3d, Argo CD, Gitea, Woodpecker CI, and a sample FastAPI service.

## Quick start

```bash
cp .env.example .env
docker compose up -d
```

### One-Click Start (Windows)
Just run `start.bat`. It will create the configuration file, download a local Docker CLI (if missing), and start the containers using Docker or Podman automatically. The `bootstrap` container provisions k3d, installs Argo CD, and applies the GitOps root application automatically.

### URLs
- Gitea: http://gitea.localhost:3000 
- Registry: http://registry.localhost:5001/v2/ 
- Woodpecker: http://woodpecker.localhost:8000
- Argo CD: http://argocd.localhost:8081
- MLflow: http://mlflow.localhost:8090
- MinIO API: http://minio.localhost:9090
- MinIO UI: http://minio.localhost:9091
- Ingress/LB: http://apps.localhost:8080
- K8s Dashboard: https://dashboard.localhost:32443 
- K8s API: https://k8s.localhost:6550 (k3d gitopslab) 
- Demo app: http://demo.localhost:8088
- ML Predict: http://demo.localhost:8088/predict

### First-Time Setup

> **⚠️ IMPORTANT**: On first run, you need to complete a one-time manual step to activate Woodpecker CI.

After running `start.bat`, the platform will start but Woodpecker repository won't be activated automatically. To complete the setup:

1. **Open Woodpecker**: http://woodpecker.localhost:8000
2. **Click "Login with Gitea"**
3. **Authorize the application** (you'll be redirected to Gitea)
4. **Re-run `start.bat`** to complete automatic repository activation

**Default Credentials:**
- Username: `gitops`
- Password: `gitops1234`

This is a **ONE-TIME** step. After the first login, all subsequent runs of `start.bat` will be fully automated.

> **Why is this needed?** Woodpecker uses OAuth authentication with Gitea. The first login creates your user account in Woodpecker's database, which is required before the automation scripts can activate repositories and configure webhooks.

### Lifecycle Management

**Start Platform:**
```batch
start.bat
```

**Stop Platform (preserve data):**
```batch
stop.bat
```

**Stop Platform (full cleanup):**
```batch
stop.bat --clean
```

**Quick Restart (full cleanup + start):**
```batch
restart.bat
```

**Health Checks:**
```batch
health-check.bat smoke    # Quick validation
health-check.bat full     # Comprehensive check
```

**E2E Tests:**
```batch
run-e2e.bat
```

📚 **See [docs/LIFECYCLE.md](docs/LIFECYCLE.md) for detailed lifecycle management guide**  
🏥 **See [docs/HEALTH_CHECKS.md](docs/HEALTH_CHECKS.md) for health check system documentation**


### Podman Support

This project can be run with Podman.

1. **Start Podman Service**: Ensure the Podman system service is providing a compatible socket.
   ```bash
   podman system service -t 0 &
   ```
2. **Set Socket Path**:
   - **Linux/Mac**: Podman usually listens on a unix socket.
     ```bash
     export DOCKER_SOCKET=/run/user/$(id -u)/podman/podman.sock
     ```
   - **Windows**: When using podman-compose, disable path conversion and keep the socket as a linux path:
     ```bash
     set COMPOSE_CONVERT_WINDOWS_PATHS=0
     set DOCKER_SOCKET=/run/podman/podman.sock
     ```
   
3. **Run**:
   ```bash
   # Make sure podman-compose is installed
   podman-compose up -d
   ```
   
The `scripts/wipe.sh` script automatically detects `podman-compose` if `docker` is missing.

See `docs/RUNBOOKS.md` for troubleshooting.
