#!/bin/bash
set -e

# Initialize ArgoCD
# - Install in k8s (already done in bootstrap.sh presumably, or here?)
# - Configure repo
# - Apply App of Apps

source /workspace/.env

# The bootstrap container has argocd CLI installed.
# We need to access the k3d cluster.
# KUBECONFIG should be set up by bootstrap.sh

ARGOCD_SERVER="argocd-server.argocd.svc.cluster.local"
# Since we are inside the cluster network (via k3d networking)? No, we are in bootstrap container on docker network.
# But k3d exposes the API server.
# We can use port-forwarding or just use `kubectl` to manage argocd resources directly (declarative setup).
# Using CLI is harder because we need to reach the ArgoCD API server.
# It is better to use `kubectl apply` for initial configuration.

# 1. Add Repository Creds (Secret)
# We need to add the git repo credentials so ArgoCD can pull.
GITEA_URL="${GITEA_INTERNAL_URL:-http://gitea:3000}"
ADMIN_USER="${GITEA_ADMIN_USER:-gitea_admin}"
GITEA_TOKEN=$(cat /workspace/.gitea_token)

echo "Configuring ArgoCD Repository Credentials..."
kubectl create secret generic platform-repo-creds \
    -n argocd \
    --from-literal=url="$GITEA_URL/$ADMIN_USER/platform.git" \
    --from-literal=username="$ADMIN_USER" \
    --from-literal=password="$GITEA_TOKEN" \
    --from-literal=type="git" \
    --dry-run=client -o yaml | kubectl apply -f -

kubectl label secret platform-repo-creds -n argocd "argocd.argoproj.io/secret-type=repository" --overwrite

# 2. Apply Root App
echo "Applying Root App..."
# We need to substitute variables in root-app.yaml if any?
# gitops/argocd/root-app.yaml usually points to the repo URL.
# If the repo URL is hardcoded, we might need to change it.
# Let's check root-app.yaml content.

ROOT_APP_PATH="/workspace/gitops/argocd/root-app.yaml"
# Ensure the repo URL in root-app.yaml matches our internal URL.
# We can use sed to replace if needed.
# Assuming standard template: repoURL: http://gitea:3000/gitea_admin/platform.git

# Let's inspect/modify root-app.yaml
sed -i "s|repoURL: .*|repoURL: $GITEA_URL/$ADMIN_USER/platform.git|g" "$ROOT_APP_PATH"

kubectl apply -f "$ROOT_APP_PATH" -n argocd

echo "ArgoCD initialization complete."
