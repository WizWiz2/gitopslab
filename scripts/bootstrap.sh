#!/bin/bash
set -e

# Main Bootstrap Script
# Orchestrates the setup.

source /workspace/.env

echo "Starting Platform Bootstrap..."

# 1. Wait for services
/workspace/scripts/wait-for.sh gitea 3000
/workspace/scripts/wait-for.sh registry 5000
/workspace/scripts/wait-for.sh woodpecker-server 8000

# 2. Create k3d cluster
CLUSTER_NAME="${K3D_CLUSTER_NAME:-gitopslab}"
echo "Creating k3d cluster '$CLUSTER_NAME'..."
if k3d cluster list "$CLUSTER_NAME" >/dev/null 2>&1; then
    echo "Cluster already exists."
else
    # We need to expose ports for ArgoCD (8081) and Demo App (8088)
    # Mapping: 8081:80@loadbalancer, 8088:30080@agent?
    # Or just use Ingress.
    # TechSpec says: Argo CD: http://argocd.localhost:8081
    # Demo App: http://localhost:8088

    # We use registries.yaml
    k3d cluster create "$CLUSTER_NAME" \
        --registry-use k3d-registry.localhost:5000 \
        --registry-config /workspace/scripts/registries.yaml \
        --port "8081:80@loadbalancer" \
        --port "8088:8088@loadbalancer" \
        --agents 1

    # Wait for cluster
    kubectl wait --for=condition=Ready nodes --all --timeout=60s
fi

# 3. Connect Registry (Handled by --registry-config above, but maybe network connect needed?)
# k3d manages its own network. Docker compose services are on another network.
# k3d cluster runs in docker. We need to connect k3d containers to the docker-compose network.
COMPOSE_NETWORK="${COMPOSE_PROJECT_NAME:-platform}_default"
# Or just "default" or "podman" as per docker-compose.yml
# In docker-compose.yml, bootstrap is on 'default' and 'podman'.
# k3d creates a network named 'k3d-<cluster>'.
# We need to connect the registry to k3d network OR connect k3d nodes to compose network.
# Easier to connect k3d nodes to compose network.

echo "Connecting k3d nodes to network '$COMPOSE_NETWORK'..."
for node in $(k3d node list -c "$CLUSTER_NAME" --no-headers | awk '{print $1}'); do
    docker network connect "$COMPOSE_NETWORK" "$node" || true
done

# 4. Install ArgoCD
echo "Installing ArgoCD..."
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd -f /workspace/scripts/argocd-install.yaml

echo "Waiting for ArgoCD..."
kubectl wait --for=condition=Available deployment/argocd-server -n argocd --timeout=300s

# Patch ArgoCD Service to LoadBalancer or Ingress?
# We mapped 8081:80@loadbalancer. So we should expose argocd-server as LoadBalancer on port 80?
# Or use Ingress.
# By default argocd-install.yaml sets ClusterIP.
# Let's patch it to LoadBalancer.
kubectl patch svc argocd-server -n argocd -p '{"spec": {"type": "LoadBalancer", "ports": [{"port": 80, "targetPort": 8080}]}}'

# 5. Init Gitea
/workspace/scripts/init-gitea.sh

# 6. Init Woodpecker
/workspace/scripts/init-woodpecker.sh

# 7. Init ArgoCD (Configure App)
/workspace/scripts/init-argocd.sh

# 8. Final Output
echo "=== Bootstrap Complete ==="
echo "Gitea:      ${GITEA_PUBLIC_URL}"
echo "Woodpecker: ${WOODPECKER_PUBLIC_URL}"
echo "ArgoCD:     ${ARGOCD_PUBLIC_URL}"
echo "Demo App:   ${DEMO_APP_URL:-http://localhost:8088}"
echo ""
echo "Credentials:"
echo "Gitea Admin: $GITEA_ADMIN_USER / $GITEA_ADMIN_PASSWORD"
echo "ArgoCD Admin: admin / (initial password is the pod name of argocd-server)"
# Actually retrieve ArgoCD password
ARGO_PWD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)
echo "ArgoCD Admin Password: $ARGO_PWD"
