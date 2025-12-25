#!/usr/bin/env bash
set -euo pipefail

log() { echo "[dashboard-token] $*" >&2; }

log "Waiting for Kubernetes API..."
ready=0
i=1
while [ "$i" -le 30 ]; do
  if kubectl get ns >/dev/null 2>&1; then
    ready=1
    break
  fi
  log "Kubernetes API not ready yet, retrying... (${i}/30)"
  i=$((i + 1))
  sleep 2
done
if [ "$ready" -ne 1 ]; then
  log "Kubernetes API not ready; cannot generate dashboard token"
  exit 1
fi

log "Ensuring Kubernetes Dashboard namespace..."
if ! kubectl get ns kubernetes-dashboard >/dev/null 2>&1; then
  kubectl create ns kubernetes-dashboard >/dev/null 2>&1 || true
fi

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
i=1
while [ "$i" -le 30 ]; do
  token="$(kubectl -n kubernetes-dashboard create token admin-user 2>/dev/null || true)"
  if [ -n "$token" ]; then
    echo "$token"
    exit 0
  fi
  log "Token not ready yet, retrying... (${i}/30)"
  i=$((i + 1))
  sleep 2
done

log "Failed to generate dashboard token"
exit 1
