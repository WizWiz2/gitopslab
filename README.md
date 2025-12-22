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
- Gitea: http://gitea.localhost:3000 (SSH: 2222)
- Registry: http://registry.localhost:5001/v2/ (in-cluster mirror: k3d-registry.localhost:5002)
- Woodpecker: http://woodpecker.localhost:8000
- Argo CD: http://argocd.localhost:8081
- Ingress/LB: http://localhost:8080
- K8s Dashboard: https://dashboard.localhost:32443 (token выводится в dashboard-token.txt после `start.bat`)
- K8s API: https://k8s.localhost:6550 (k3d gitopslab) — 401 в браузере нормально, используйте kubeconfig/token
- Demo app: http://demo.localhost:8088

### Reset

Stop and remove everything, including volumes:

```bash
docker compose down -v
```

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
   - **Windows**: Map the listener pipe or socket. If you are using Podman Desktop, it handles this. Ensure `DOCKER_SOCKET` points to the valid pipe/socket if the default `/var/run/docker.sock` isn't magically handled by your setup (e.g. via WSL link).
   
3. **Run**:
   ```bash
   # Make sure podman-compose is installed
   podman-compose up -d
   ```
   
The `scripts/wipe.sh` script automatically detects `podman-compose` if `docker` is missing.

See `docs/RUNBOOKS.md` for troubleshooting.
