# Runbooks

## k3d did not start
- Check bootstrap logs: `docker compose logs -f bootstrap`
- Ensure Docker is available inside the bootstrap container: `docker ps`
- Retry bootstrap by restarting the container: `docker compose restart bootstrap`

## Argo CD unavailable
- Verify pods: `kubectl -n argocd get pods`
- Fetch server logs: `kubectl -n argocd logs deploy/argocd-server`
- Confirm k3d cluster exists: `k3d cluster list`

## Registry HTTP/SSL issues
- Validate registry health: `curl -v http://localhost:5000/v2/`
- Check that k3d registry entry exists: `k3d registry list`
- Recreate registry: `k3d registry delete $K3D_REGISTRY_NAME && k3d registry create $K3D_REGISTRY_NAME --port $K3D_REGISTRY_PORT`

## CI clone URL issues
- Woodpecker must use the internal clone URL: `${GITEA_INTERNAL_URL}`.
- Validate settings in `.env` and `.woodpecker.yml`.
- Inspect Woodpecker logs: `docker compose logs -f woodpecker-server woodpecker-agent`.

## CI loop
- The GitOps update commit includes `[skip ci]` to avoid recursion. If loops appear, confirm commit messages and Woodpecker settings.

## General commands
- Tail compose logs: `docker compose logs -f <service>`
- List all pods: `kubectl get pods -A`
- List clusters: `k3d cluster list`
