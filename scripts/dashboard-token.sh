#!/usr/bin/env bash
set -euo pipefail

log() { echo "[dashboard-token] $*"; }

# Wait until dashboard pods are ready (dashboard is deployed via kustomize/Argo)
log "Waiting for Kubernetes Dashboard pods..."
kubectl wait --for=condition=Ready pods -n kubernetes-dashboard --all --timeout=180s >/dev/null

# Ensure admin ServiceAccount/CRB exist (idempotent)
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: admin-user
  namespace: kubernetes-dashboard
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: admin-user
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
  - kind: ServiceAccount
    name: admin-user
    namespace: kubernetes-dashboard
EOF

# Emit a fresh token to stdout
log "Generating dashboard token..."
kubectl -n kubernetes-dashboard create token admin-user
