#!/usr/bin/env bash
set -euo pipefail

log() { echo "[bootstrap] $*"; }

: "${K3D_CLUSTER_NAME:=gitopslab}"
: "${K3D_API_PORT:=6550}"
: "${K3D_REGISTRY_NAME:=registry.localhost}"
: "${K3D_REGISTRY_PORT:=5000}"
: "${ARGOCD_VERSION:=2.10.7}"

if ! command -v k3d >/dev/null 2>&1; then
  log "k3d not available; container build is expected to install it"
  exit 1
fi

create_registry() {
  if k3d registry list | grep -q "${K3D_REGISTRY_NAME}"; then
    log "registry ${K3D_REGISTRY_NAME} already exists"
    return
  fi
  log "creating k3d registry ${K3D_REGISTRY_NAME}"
  k3d registry create ${K3D_REGISTRY_NAME} --port ${K3D_REGISTRY_PORT}
}

create_cluster() {
  if k3d cluster list | grep -q "${K3D_CLUSTER_NAME}"; then
    log "cluster ${K3D_CLUSTER_NAME} already exists"
    return
  fi
  log "creating k3d cluster ${K3D_CLUSTER_NAME}"
  k3d cluster create ${K3D_CLUSTER_NAME} \
    --api-port ${K3D_API_PORT} \
    --servers 1 --agents 1 \
    --port "8080:80@loadbalancer" \
    --registry-use ${K3D_REGISTRY_NAME}:${K3D_REGISTRY_PORT} \
    --k3s-arg "--disable=traefik@server:0"
}

install_argocd() {
  if kubectl get ns argocd >/dev/null 2>&1; then
    log "Argo CD already installed"
    return
  fi
  log "installing Argo CD"
  kubectl create namespace argocd
  kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/v${ARGOCD_VERSION}/manifests/install.yaml
}

apply_root_app() {
  log "applying root application"
  kubectl apply -f /workspace/gitops/argocd/root-app.yaml
}

bootstrap() {
  create_registry
  create_cluster
  install_argocd
  apply_root_app
}

log "starting bootstrap";
bootstrap
log "bootstrap completed"

tail -f /dev/null
