#!/usr/bin/env bash
set -euo pipefail

log() { echo "[collect-creds] $*"; }

GITEA_USER=${GITEA_ADMIN_USER:-gitops}
GITEA_PASS=${GITEA_ADMIN_PASS:-gitops1234}
WOOD_ADMIN=${WOODPECKER_ADMIN:-gitops}
GITEA_PORT=${GITEA_HTTP_PORT:-3000}
WOOD_PORT=${WOODPECKER_SERVER_PORT:-8000}
ARGO_PORT=${ARGOCD_PORT:-8081}
K8S_PORT=${K3D_API_PORT:-6550}
MLFLOW_PORT=${MLFLOW_PORT:-8090}
MINIO_USER=${MINIO_ROOT_USER:-minioadmin}
MINIO_PASS=${MINIO_ROOT_PASSWORD:-minioadmin123}
MINIO_API_PORT=${MINIO_API_PORT:-9090}
MINIO_CONSOLE_PORT=${MINIO_CONSOLE_PORT:-9091}

get_argocd_pass() {
    kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true
}

get_dashboard_token() {
    kubectl -n kubernetes-dashboard create token admin-user 2>/dev/null || true
}

ARGO_PASS="$(get_argocd_pass)"
DASH_TOKEN="$(get_dashboard_token)"

cat <<EOF
[Gitea]
user=${GITEA_USER}
password=${GITEA_PASS}
url=http://gitea.localhost:${GITEA_PORT}

[Woodpecker]
admin=${WOOD_ADMIN}
url=http://woodpecker.localhost:${WOOD_PORT}

[ArgoCD]
user=admin
password=${ARGO_PASS}
url=http://argocd.localhost:${ARGO_PORT}

[MLflow]
url=http://mlflow.localhost:${MLFLOW_PORT}

[Dashboard]
token=${DASH_TOKEN}
url=https://dashboard.localhost:32443

[MinIO]
user=${MINIO_USER}
password=${MINIO_PASS}
api=http://minio.localhost:${MINIO_API_PORT}
console=http://minio.localhost:${MINIO_CONSOLE_PORT}

[KubeAPI]
url=https://k8s.localhost:${K8S_PORT}
note=kubeconfig: podman exec platform-bootstrap k3d kubeconfig get gitopslab
EOF
