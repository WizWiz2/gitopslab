# IDP-in-a-Box (gitopslab)

One-command demo platform showcasing GitOps-first delivery with k3d, Argo CD, Gitea, Woodpecker CI, and a sample FastAPI service.

## Quick start

```bash
cp .env.example .env
docker compose up -d
```

The `bootstrap` container provisions k3d, installs Argo CD, and applies the GitOps root application automatically.

### URLs
- Gitea: http://localhost:${GITEA_HTTP_PORT:-3000}
- Woodpecker: http://localhost:${WOODPECKER_SERVER_PORT:-8000}
- Argo CD: http://localhost:${ARGOCD_PORT:-8080}
- Demo app (via k3d servicelb): http://localhost:8080/version

### Reset

Stop and remove everything, including volumes:

```bash
docker compose down -v
```

See `docs/RUNBOOKS.md` for troubleshooting.
