#!/usr/bin/env bash
set -euo pipefail

# Health Check Script for GitOps Lab Platform
# Validates network, services, and configuration consistency

log() { echo "[health] $*"; }
error() { echo "[health] ERROR: $*" >&2; }
warn() { echo "[health] WARN: $*" >&2; }

ERRORS=0
WARNINGS=0

# Load .env if exists
if [ -f "/workspace/.env" ]; then
    set -a
    source /workspace/.env
    set +a
fi

# ============================================================================
# 1. NETWORK CHECKS
# ============================================================================

check_network() {
    log "Checking network configuration..."
    
    # Check if k3d network exists
    if ! docker network inspect k3d >/dev/null 2>&1; then
        error "k3d network does not exist"
        ((ERRORS++))
        return
    fi
    
    # Get k3d gateway IP
    local k3d_gateway
    k3d_gateway=$(docker network inspect k3d --format '{{range .IPAM.Config}}{{.Gateway}}{{end}}' 2>/dev/null || echo "")
    
    if [ -z "$k3d_gateway" ]; then
        error "Failed to get k3d gateway IP"
        ((ERRORS++))
        return
    fi
    
    log "k3d gateway IP: $k3d_gateway"
    
    # Check if HOST_GATEWAY_IP matches k3d gateway
    local expected_ip="${HOST_GATEWAY_IP:-10.89.0.1}"
    if [ "$k3d_gateway" != "$expected_ip" ]; then
        error "HOST_GATEWAY_IP mismatch: .env has $expected_ip, k3d network has $k3d_gateway"
        ((ERRORS++))
    else
        log "✓ HOST_GATEWAY_IP matches k3d gateway"
    fi
    
    # Check Docker API accessibility
    if ! curl -s --max-time 2 "http://${k3d_gateway}:2375/version" >/dev/null 2>&1; then
        error "Docker API not accessible at ${k3d_gateway}:2375"
        ((ERRORS++))
    else
        log "✓ Docker API accessible at ${k3d_gateway}:2375"
    fi
}

# ============================================================================
# 2. REGISTRY CHECKS
# ============================================================================

check_registry() {
    log "Checking registry connectivity..."
    
    local registry_url="${REGISTRY_URL:-registry.localhost:5002}"
    local gateway_ip="${HOST_GATEWAY_IP:-10.89.0.1}"
    
    # Check if registry is accessible via gateway IP
    if ! curl -s --max-time 3 "http://${gateway_ip}:5002/v2/" >/dev/null 2>&1; then
        error "Registry not accessible at ${gateway_ip}:5002"
        ((ERRORS++))
    else
        log "✓ Registry accessible at ${gateway_ip}:5002"
    fi
    
    # Check if k3d-registry container exists
    if ! docker ps --filter "name=k3d-registry" --format "{{.Names}}" | grep -q "k3d-registry"; then
        error "k3d-registry container not running"
        ((ERRORS++))
    else
        log "✓ k3d-registry container running"
    fi
}

# ============================================================================
# 3. SERVICE CONNECTIVITY CHECKS
# ============================================================================

check_service_connectivity() {
    log "Checking inter-service connectivity..."
    
    local services=("gitea:3000" "woodpecker-server:8000" "woodpecker-server:9000")
    
    for service in "${services[@]}"; do
        local host="${service%%:*}"
        local port="${service##*:}"
        
        if ! docker run --rm --network k3d alpine:3.20 sh -c "timeout 3 nc -zv $host $port" >/dev/null 2>&1; then
            warn "Service $service not reachable from k3d network"
            ((WARNINGS++))
        else
            log "✓ Service $service reachable"
        fi
    done
}

# ============================================================================
# 4. OAUTH CONFIGURATION CHECKS
# ============================================================================

check_oauth_config() {
    log "Checking Woodpecker OAuth configuration..."
    
    local client_id="${WOODPECKER_GITEA_CLIENT:-}"
    local client_secret="${WOODPECKER_GITEA_SECRET:-}"
    
    if [ -z "$client_id" ] || [ "$client_id" = "replace-me" ]; then
        error "WOODPECKER_GITEA_CLIENT not configured in .env"
        ((ERRORS++))
    else
        log "✓ WOODPECKER_GITEA_CLIENT configured"
    fi
    
    if [ -z "$client_secret" ] || [ "$client_secret" = "replace-me" ]; then
        error "WOODPECKER_GITEA_SECRET not configured in .env"
        ((ERRORS++))
    else
        log "✓ WOODPECKER_GITEA_SECRET configured"
    fi
    
    # Check if Gitea has matching OAuth app
    local gitea_url="${GITEA_INTERNAL_URL:-http://gitea:3000}"
    local gitea_user="${GITEA_ADMIN_USER:-gitops}"
    local gitea_pass="${GITEA_ADMIN_PASSWORD:-gitops1234}"
    
    if [ -n "$client_id" ] && [ "$client_id" != "replace-me" ]; then
        local apps_json
        apps_json=$(curl -s -u "${gitea_user}:${gitea_pass}" "${gitea_url}/api/v1/user/applications/oauth2" 2>/dev/null || echo "[]")
        
        if echo "$apps_json" | jq -e --arg id "$client_id" '.[] | select(.client_id==$id)' >/dev/null 2>&1; then
            log "✓ OAuth app exists in Gitea with matching client_id"
        else
            warn "OAuth app with client_id $client_id not found in Gitea"
            ((WARNINGS++))
        fi
    fi
}

# ============================================================================
# 5. WOODPECKER DATABASE CHECKS
# ============================================================================

check_woodpecker_db() {
    log "Checking Woodpecker database..."
    
    local db_volume="${COMPOSE_PROJECT_NAME:-gitopslab}_woodpecker-data"
    local repo_owner="${GITEA_ADMIN_USER:-gitops}"
    
    # Check if user exists in Woodpecker DB
    local user_row
    user_row=$(docker run --rm -v "${db_volume}:/data" nouchka/sqlite3 /data/woodpecker.sqlite \
        "select login from users where login='${repo_owner}' limit 1;" 2>/dev/null | tr -d '\r' || echo "")
    
    if [ -z "$user_row" ]; then
        warn "Woodpecker user '${repo_owner}' not found in database. Login required at http://woodpecker.localhost:8000"
        ((WARNINGS++))
    else
        log "✓ Woodpecker user '${repo_owner}' exists in database"
    fi
}

# ============================================================================
# 6. FILE CONSISTENCY CHECKS
# ============================================================================

check_file_consistency() {
    log "Checking configuration file consistency..."
    
    local gateway_ip="${HOST_GATEWAY_IP:-10.89.0.1}"
    
    # Check .woodpecker.yml for correct DOCKER_HOST
    if [ -f "/workspace/.woodpecker.yml" ]; then
        if grep -q "DOCKER_HOST:.*${gateway_ip}" /workspace/.woodpecker.yml; then
            log "✓ .woodpecker.yml has correct DOCKER_HOST IP"
        else
            error ".woodpecker.yml has incorrect DOCKER_HOST IP (should be ${gateway_ip})"
            ((ERRORS++))
        fi
    fi
    
    # Check docker-compose.yml for correct default IPs
    if [ -f "/workspace/docker-compose.yml" ]; then
        if grep -q "${gateway_ip}" /workspace/docker-compose.yml; then
            log "✓ docker-compose.yml references correct gateway IP"
        else
            warn "docker-compose.yml may have outdated gateway IP references"
            ((WARNINGS++))
        fi
    fi
}

# ============================================================================
# 7. K3D CLUSTER CHECKS
# ============================================================================

check_k3d_cluster() {
    log "Checking k3d cluster..."
    
    local cluster_name="${K3D_CLUSTER_NAME:-gitopslab}"
    
    # Check if cluster exists
    if ! docker ps --filter "name=k3d-${cluster_name}-server" --format "{{.Names}}" | grep -q "k3d-${cluster_name}-server"; then
        error "k3d cluster '${cluster_name}' not running"
        ((ERRORS++))
        return
    fi
    
    log "✓ k3d cluster '${cluster_name}' running"
    
    # Check if kubectl works
    if ! docker exec "k3d-${cluster_name}-server-0" kubectl get nodes >/dev/null 2>&1; then
        error "kubectl not working in k3d cluster"
        ((ERRORS++))
    else
        log "✓ kubectl accessible in k3d cluster"
    fi
    
    # Check ArgoCD pods
    local argocd_pods
    argocd_pods=$(docker exec "k3d-${cluster_name}-server-0" kubectl get pods -n argocd --no-headers 2>/dev/null | wc -l || echo "0")
    
    if [ "$argocd_pods" -lt 5 ]; then
        warn "ArgoCD may not be fully deployed (found $argocd_pods pods)"
        ((WARNINGS++))
    else
        log "✓ ArgoCD deployed ($argocd_pods pods)"
    fi
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

main() {
    log "Starting health checks..."
    log "========================================="
    
    check_network
    check_registry
    check_service_connectivity
    check_oauth_config
    check_woodpecker_db
    check_file_consistency
    check_k3d_cluster
    
    log "========================================="
    log "Health check complete"
    log "Errors: $ERRORS, Warnings: $WARNINGS"
    
    if [ "$ERRORS" -gt 0 ]; then
        error "Health check FAILED with $ERRORS error(s)"
        exit 1
    elif [ "$WARNINGS" -gt 0 ]; then
        warn "Health check PASSED with $WARNINGS warning(s)"
        exit 0
    else
        log "✓ All checks PASSED"
        exit 0
    fi
}

main "$@"
