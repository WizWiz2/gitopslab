# Demo script (5–7 minutes)

1. Run `docker compose up -d` and wait for containers to become healthy. The bootstrap container will create k3d, install Argo CD, and apply GitOps apps.
2. Open Argo CD at `http://localhost:8080` (default admin password is printed by bootstrap via `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d`). Confirm `root-app` and `hello-api` are Healthy/Synced.
3. Open Gitea (`http://localhost:3000`) and browse the repository containing this code.
4. Make a small code change in `hello-api/main.py` (e.g., tweak the root message) via Gitea's UI and commit to `main`.
5. Watch Woodpecker at `http://localhost:8000` execute stages: test → build → Trivy scan → push → update gitops.
6. Argo CD will detect the GitOps commit and deploy the new image. Refresh the Argo CD app to see sync status.
7. Check the running version via `curl http://localhost:8080/version` and confirm it matches the new commit hash.
8. (Optional) Introduce drift: `kubectl -n apps scale deploy/hello-api --replicas=0` then watch Argo CD self-heal back to the declared replica count.
