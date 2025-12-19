#!/usr/bin/env bash
set -euo pipefail

log() { echo "[init-argocd] $*"; }

ARGOCD_SERVER="argocd-server.argocd.svc.cluster.local"
# We access Argo CD via kubectl or internal URL.
# Bootstrap container has kubectl configured for k3d.

# Wait for Argo CD server pod
log "Waiting for Argo CD pods..."
kubectl wait --for=condition=Ready pods --all -n argocd --timeout=300s

# Экспонируем argocd-server наружу через k3d servicelb
log "Patching Argo CD service to LoadBalancer..."
kubectl patch svc argocd-server -n argocd -p '{"spec":{"type":"LoadBalancer","ports":[{"name":"http","port":80,"targetPort":8080}]}}' >/dev/null

# Get Gitea Token
if [ -f /workspace/.gitea_token ]; then
    GITEA_TOKEN=$(cat /workspace/.gitea_token)
else
    log "ERROR: Gitea token not found. Cannot configure Argo CD repository."
    exit 1
fi

GITEA_INTERNAL_URL="${GITEA_INTERNAL_URL:-http://gitea:3000}"
GITEA_K3D_URL="${GITEA_K3D_URL:-${GITEA_INTERNAL_URL}}"
REPO_URL="${GITEA_K3D_URL}/${GITEA_ADMIN_USER:-gitops}/platform.git"

log "Configuring Repository in Argo CD..."
# We use declarative setup via Secret usually, or CLI "argocd repo add".
# Since we don't have argocd CLI potentially, we will apply a Secret K8s resource.
# This is the GitOps way!

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: repo-platform
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: git
  url: ${REPO_URL}
  password: ${GITEA_TOKEN}
  username: ${GITEA_ADMIN_USER:-gitops}
  insecure: "true"
EOF

log "Repository secret applied."

# Apply Root App
log "Applying Root App..."
kubectl apply -f /workspace/gitops/argocd/root-app.yaml

log "Argo CD initialization completed."
