#!/usr/bin/env bash
set -euo pipefail

log() { echo "[bootstrap] $*"; }

: "${K3D_CLUSTER_NAME:=gitopslab}"
: "${K3D_API_PORT:=6550}"
: "${K3D_REGISTRY_NAME:=registry.localhost}"
: "${K3D_REGISTRY_PORT:=5000}"
: "${ARGOCD_VERSION:=2.10.7}"
: "${MLFLOW_PORT:=8090}"
: "${MINIO_API_PORT:=9090}"
: "${MINIO_CONSOLE_PORT:=9091}"
: "${MLFLOW_IMAGE:=registry.localhost:5002/mlflow:lite}"

if ! command -v k3d >/dev/null 2>&1; then
  log "k3d not available; container build is expected to install it"
  exit 1
fi

create_registry() {
  local registry_container="k3d-${K3D_REGISTRY_NAME}"
  
  log "ensuring registry ${K3D_REGISTRY_NAME} exists on network ${K3D_NETWORK:-k3d}"
  # Force delete existing registry to avoid port conflicts
  k3d registry delete "${K3D_REGISTRY_NAME}" >/dev/null 2>&1 || true
  docker rm -f "${registry_container}" >/dev/null 2>&1 || true
  
  log "creating k3d registry ${K3D_REGISTRY_NAME} on port 5002"
  k3d registry create "${K3D_REGISTRY_NAME}" --port 5002 --default-network "${K3D_NETWORK:-k3d}"

  log "waiting for registry container ${registry_container} to be ready"
  local attempts=0
  until docker ps --filter "name=${registry_container}" --format "{{.Status}}" | grep -q "Up"; do
    attempts=$((attempts + 1))
    if [ "$attempts" -ge 30 ]; then
      log "registry container did not start"
      return 1
    fi
    sleep 2
  done
}

build_mlflow_image() {
  if [ ! -d /workspace/mlflow ]; then
    log "mlflow build context not found; skipping image build"
    return
  fi
  
  log "preparing mlflow image"
  docker build -t mlflow:lite /workspace/mlflow
  
  # Try pushing to registry within k3d network first, fallback to host port
  local push_success=false
  for registry_addr in "k3d-registry.localhost:5000" "registry.localhost:5002"; do
    local push_image="${registry_addr}/mlflow:lite"
    log "attempting to push mlflow image to ${push_image}"
    docker tag mlflow:lite "${push_image}"
    if docker push "${push_image}" 2>&1; then
      log "successfully pushed to ${push_image}"
      push_success=true
      break
    else
      log "failed to push to ${push_image}, trying next option..."
    fi
  done
  
  if [ "$push_success" = false ]; then
    log "ERROR: failed to push mlflow image to any registry"
    return 1
  fi
}

create_cluster() {
  if k3d cluster list | grep -q "${K3D_CLUSTER_NAME}"; then
    log "cluster ${K3D_CLUSTER_NAME} already exists"
    local lb="k3d-${K3D_CLUSTER_NAME}-serverlb"
    local needs_recreate="false"
    if ! docker port "$lb" 30900/tcp >/dev/null 2>&1; then
      needs_recreate="true"
    fi
    if ! docker port "$lb" 30901/tcp >/dev/null 2>&1; then
      needs_recreate="true"
    fi
    if ! docker port "$lb" 30902/tcp >/dev/null 2>&1; then
      needs_recreate="true"
    fi
    if [ "$needs_recreate" = "true" ]; then
      log "loadbalancer is missing ML ports; recreating cluster"
      k3d cluster delete ${K3D_CLUSTER_NAME} >/dev/null 2>&1 || true
    else
      k3d node list --no-headers | awk -v prefix="k3d-${K3D_CLUSTER_NAME}-" '$1 ~ "^"prefix {print $1}' | while read -r node; do
        [ -n "$node" ] && docker start "$node" >/dev/null 2>&1 || true
      done
      docker start "$lb" >/dev/null 2>&1 || true
      return
    fi
  fi
  log "creating k3d cluster ${K3D_CLUSTER_NAME}"
  k3d cluster create ${K3D_CLUSTER_NAME} --wait=false --image rancher/k3s:v1.27.4-k3s1 \
    --api-port ${K3D_API_PORT} \
    --servers 1 --agents 0 \
    --port "8080:80@loadbalancer" \
    --port "8081:30081@server:0" \
    --port "8088:30888@server:0" \
    --port "${MLFLOW_PORT}:30902@server:0" \
    --port "${MINIO_API_PORT}:30900@server:0" \
    --port "${MINIO_CONSOLE_PORT}:30901@server:0" \
    --port "32443:32443@server:0" \
    --network "${K3D_NETWORK:-bridge}" \
    --registry-use ${K3D_REGISTRY_NAME}:${K3D_REGISTRY_PORT} \
    --registry-config /workspace/scripts/registries.yaml \
    --k3s-arg "--snapshotter=native@server:0"
}

ensure_loadbalancer_config() {
  local lb="k3d-${K3D_CLUSTER_NAME}-serverlb"
  if ! docker inspect "$lb" >/dev/null 2>&1; then
    log "loadbalancer ${lb} not found"
    return
  fi

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
    echo "  30902.tcp:"
    add_nodes "server"
    echo "  30900.tcp:"
    add_nodes "server"
    echo "  30901.tcp:"
    add_nodes "server"
    echo "  32443.tcp:"
    add_nodes "server"
    echo "settings:"
    echo "  workerConnections: 1024"
  } >"$tmpfile"

  docker cp "$tmpfile" "${lb}:/etc/confd/values.yaml"
  rm -f "$tmpfile"

  docker start "$lb" >/dev/null 2>&1 || true
}

patch_registry_hosts() {
  local host_ip
  host_ip=$(docker network inspect "${K3D_NETWORK:-podman}" -f "{{range .IPAM.Config}}{{.Gateway}}{{end}}" 2>/dev/null || true)
  if [ -z "$host_ip" ]; then
    host_ip=$(docker inspect -f "{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}" "k3d-${K3D_CLUSTER_NAME}-serverlb" 2>/dev/null || true)
  fi
  if [ -z "$host_ip" ]; then
    log "ERROR: could not determine host IP for registry.localhost"
    return 1
  fi
  log "using host IP ${host_ip} for registry.localhost, minio.localhost, mlflow.localhost in k3d nodes"
  k3d node list --no-headers | awk '{print $1}' | while read -r node; do
    [ -z "$node" ] && continue
    docker exec "$node" sh -c "grep -v 'registry.localhost' /etc/hosts > /tmp/hosts && echo \"${host_ip} registry.localhost\" >> /tmp/hosts && cat /tmp/hosts > /etc/hosts"
    docker exec "$node" sh -c "grep -v 'minio.localhost' /etc/hosts > /tmp/hosts && echo \"${host_ip} minio.localhost\" >> /tmp/hosts && cat /tmp/hosts > /etc/hosts"
    docker exec "$node" sh -c "grep -v 'mlflow.localhost' /etc/hosts > /tmp/hosts && echo \"${host_ip} mlflow.localhost\" >> /tmp/hosts && cat /tmp/hosts > /etc/hosts"
  done
}

ensure_kubeconfig() {
  export KUBECONFIG=${KUBECONFIG:-$HOME/.kube/config}
  mkdir -p "$(dirname "$KUBECONFIG")"
  if [ ! -s "$KUBECONFIG" ]; then
    log "fetching kubeconfig for ${K3D_CLUSTER_NAME}"
    k3d kubeconfig get ${K3D_CLUSTER_NAME} > "$KUBECONFIG"
  fi
  local server_host="k3d-${K3D_CLUSTER_NAME}-server-0"
  
  log "Using k8s API server at ${server_host}:6443"
  sed -i "s|https://0.0.0.0:${K3D_API_PORT}|https://${server_host}:6443|g" "$KUBECONFIG"
  sed -i "s|https://localhost:${K3D_API_PORT}|https://${server_host}:6443|g" "$KUBECONFIG"
  sed -i "s|https://127.0.0.1:${K3D_API_PORT}|https://${server_host}:6443|g" "$KUBECONFIG"
  sed -i "s|https://host.containers.internal:${K3D_API_PORT}|https://${server_host}:6443|g" "$KUBECONFIG"
  # Replace any IP address pattern (e.g., 10.88.0.1, 10.89.0.1, etc.)
  sed -i "s|https://[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}:${K3D_API_PORT}|https://${server_host}:6443|g" "$KUBECONFIG"
  sed -i "s|https://:6443|https://${server_host}:6443|g" "$KUBECONFIG"
}

wait_for_k8s_api() {
  local attempts=0
  until kubectl --insecure-skip-tls-verify --request-timeout=5s get nodes > /dev/null 2>&1; do
    attempts=$((attempts + 1))
    if [ "$attempts" -ge 30 ]; then
      log "k8s API is still unavailable after ${attempts} attempts"
      kubectl --insecure-skip-tls-verify get nodes || true
      return 1
    fi
    log "waiting for k8s API (attempt ${attempts})..."
    sleep 3
  done
  log "k8s API is ready"
}

install_argocd() {
  if kubectl get ns argocd >/dev/null 2>&1; then
    log "Argo CD already installed"
    return
  fi
  log "installing Argo CD"
  kubectl create namespace argocd
  local manifest="/workspace/scripts/argocd-install.yaml"
  if [[ -f "$manifest" ]]; then
    log "using bundled ArgoCD manifest"
    kubectl apply -n argocd -f "$manifest"
  else
    log "bundled manifest not found, downloading from GitHub"
    kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/v${ARGOCD_VERSION}/manifests/install.yaml
  fi
}

apply_root_app() {
  log "applying root application"
  kubectl apply -f /workspace/gitops/argocd/root-app.yaml
}

bootstrap() {
  create_registry
  # MLflow image is now built and pushed from host (start.bat) before bootstrap runs
  create_cluster
  ensure_loadbalancer_config
  patch_registry_hosts
  ensure_kubeconfig
  wait_for_k8s_api
  install_argocd
  
  log "Waiting for Gitea..."
  bash /workspace/scripts/wait-for.sh "http://gitea:3000"
  
  log "Waiting for Woodpecker..."
  bash /workspace/scripts/wait-for.sh "http://woodpecker-server:8000"

  log "Initializing Gitea..."
  bash /workspace/scripts/init-gitea.sh

  log "Initializing Woodpecker..."
  bash /workspace/scripts/init-woodpecker.sh

  log "Initializing Argo CD..."
  bash /workspace/scripts/init-argocd.sh

  apply_root_app
}

log "starting bootstrap";
bootstrap
log "bootstrap completed"

log "--------------------------------------------------------"
log "STACK URLs (Host):"
log " GitOps Stack:"
log "  Gitea:             http://gitea.localhost:3000"
log "  Woodpecker:        http://woodpecker.localhost:8000"
log "  Argo CD:           http://argocd.localhost:8081"
log "  Registry:          http://registry.localhost:5001/v2/"
log " MLOps Stack:"
log "  MLflow:            http://mlflow.localhost:${MLFLOW_PORT}"
log "  MinIO API:         http://minio.localhost:${MINIO_API_PORT}"
log "  MinIO Console:     http://minio.localhost:${MINIO_CONSOLE_PORT}"
log "  Demo App:          http://demo.localhost:8088"
log "  ML Predict:        http://demo.localhost:8088/predict"
log " Platform:"
log "  Ingress/LB (apps): http://apps.localhost:8080"
log "  K8s Dashboard:     https://dashboard.localhost:32443"
log "--------------------------------------------------------"
log "Credentials:"
log " User:       ${GITEA_ADMIN_USER:-gitops}"
log " Password:   ${GITEA_ADMIN_PASS:-gitops1234}"
log "--------------------------------------------------------"

exit 0
