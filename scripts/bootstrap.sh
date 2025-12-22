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
  k3d registry create ${K3D_REGISTRY_NAME} --port ${K3D_REGISTRY_PORT} --default-network "${K3D_NETWORK:-bridge}"
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
    --port "8081:30081@server:0" \
    --port "8088:30888@server:0" \
    --port "32443:32443@server:0" \
    --network "${K3D_NETWORK:-bridge}" \
    --registry-use ${K3D_REGISTRY_NAME}:${K3D_REGISTRY_PORT} \
    --registry-config /workspace/scripts/registries.yaml \
    --k3s-arg "--disable=traefik@server:0"
}

ensure_loadbalancer_config() {
  local lb="k3d-${K3D_CLUSTER_NAME}-serverlb"
  if ! docker inspect "$lb" >/dev/null 2>&1; then
    log "loadbalancer ${lb} not found"
    return
  fi

  if docker exec "$lb" test -s /etc/confd/values.yaml >/dev/null 2>&1; then
    log "loadbalancer config already in place"
  else
    log "generating loadbalancer config for ${lb}"
    local tmpfile
    tmpfile="$(mktemp)"
    local get_ips_cmd='{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}'
    add_nodes() {
      local role_filter="$1"
      k3d node list --no-headers | awk -v role="$role_filter" '
        role == "server" && $2 == "server" {print $1}
        role == "all" && ($2 == "server" || $2 == "agent") {print $1}
      ' | while read -r node; do
        ip=$(docker inspect -f "${get_ips_cmd}" "$node" 2>/dev/null || true)
        [ -n "$ip" ] && printf "    - %s\n" "$ip"
      done
    }
    {
      echo "ports:"
      echo "  6443.tcp:"
      add_nodes "server"
      echo "  80.tcp:"
      add_nodes "all"
      echo "  30081.tcp:"
      add_nodes "server"
      echo "  30888.tcp:"
      add_nodes "server"
      echo "  32443.tcp:"
      add_nodes "server"
      echo "settings:"
      echo "  workerConnections: 1024"
    } >"$tmpfile"

    docker cp "$tmpfile" "${lb}:/etc/confd/values.yaml"
    rm -f "$tmpfile"
  fi

  docker start "$lb" >/dev/null 2>&1 || true
}

ensure_kubeconfig() {
  export KUBECONFIG=${KUBECONFIG:-$HOME/.kube/config}
  mkdir -p "$(dirname "$KUBECONFIG")"
  if [ ! -s "$KUBECONFIG" ]; then
    log "fetching kubeconfig for ${K3D_CLUSTER_NAME}"
    k3d kubeconfig get ${K3D_CLUSTER_NAME} > "$KUBECONFIG"
  fi
  # k3d иногда кладет 0.0.0.0/localhost в адрес API - переведем на 127.0.0.1, чтобы не было попыток уйти на IPv6
  sed -i "s|https://0.0.0.0:${K3D_API_PORT}|https://127.0.0.1:${K3D_API_PORT}|g" "$KUBECONFIG"
  sed -i "s|https://localhost:${K3D_API_PORT}|https://127.0.0.1:${K3D_API_PORT}|g" "$KUBECONFIG"

  # Для внутреннего доступа из bootstrap-контейнера удобнее ходить прямо в сервер по его IP/6443 (есть в сертификате)
  local server_ip
  server_ip=$(docker inspect -f "{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}" "k3d-${K3D_CLUSTER_NAME}-server-0" 2>/dev/null || true)
  if [ -n "$server_ip" ]; then
    sed -i "s|https://127.0.0.1:${K3D_API_PORT}|https://${server_ip}:6443|g" "$KUBECONFIG"
  fi
}

wait_for_k8s_api() {
  local attempts=0
  until kubectl --request-timeout=5s get nodes >/dev/null 2>&1; do
    attempts=$((attempts + 1))
    if [ "$attempts" -ge 30 ]; then
      log "k8s API is still unavailable after ${attempts} attempts"
      kubectl get nodes || true
      return 1
    fi
    log "waiting for k8s API on localhost:${K3D_API_PORT} (attempt ${attempts})..."
    sleep 3
  done
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
  ensure_loadbalancer_config
  ensure_kubeconfig
  wait_for_k8s_api
  install_argocd
  
  # Wait for Gitea and Woodpecker to be up (TCP check)
  log "Waiting for Gitea..."
  /workspace/scripts/wait-for.sh "http://gitea:3000"
  
  log "Waiting for Woodpecker..."
  /workspace/scripts/wait-for.sh "http://woodpecker-server:8000"

  log "Initializing Gitea..."
  /workspace/scripts/init-gitea.sh

  log "Initializing Woodpecker..."
  /workspace/scripts/init-woodpecker.sh

  log "Initializing Argo CD..."
  /workspace/scripts/init-argocd.sh

  apply_root_app
}

log "starting bootstrap";
bootstrap
log "bootstrap completed"

log "--------------------------------------------------------"
log "DASHBOARD URLs (Host):"
log " Gitea:              http://gitea.localhost:3000"
log " Woodpecker:         http://woodpecker.localhost:8000"
log " Argo CD:            http://argocd.localhost:8081"
log " Ingress/LB (apps):  http://localhost:8080"
log " Demo App:           http://demo.localhost:8088"
log " K8s Dashboard:      https://localhost:32443"
log "--------------------------------------------------------"
log "Credentials:"
log " User:       ${GITEA_ADMIN_USER:-gitops}"
log " Password:   ${GITEA_ADMIN_PASS:-gitops1234}"
log "--------------------------------------------------------"


tail -f /dev/null
