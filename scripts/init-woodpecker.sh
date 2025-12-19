#!/usr/bin/env bash
set -euo pipefail

log() { echo "[init-woodpecker] $*"; }

WOODPECKER_URL="${WOODPECKER_INTERNAL_URL:-http://woodpecker-server:8000}"
REPO_OWNER="${GITEA_ADMIN_USER:-gitops}"
REPO_NAME="platform"

# Wait for Woodpecker
/workspace/scripts/wait-for.sh "${WOODPECKER_URL}/healthz"

log "Configuring Woodpecker..."

# We need to enable the repository.
# This requires a Woodpecker Token.
# Since getting a token automatically is hard without using the CLI on the server which might be authenticated,
# We will try to use `docker exec` to run CLI commands inside woodpecker-server if available.

if docker exec woodpecker-server woodpecker-cli --version >/dev/null 2>&1; then
    log "Woodpecker CLI found in container. Attempting configuration..."
    
    # We need to find the user. The user is created on first login.
    # We haven't logged in yet.
    # Can we force create/sync?
    # 'woodpecker-cli user add' might work if we have admin rights on the socket? No, CLI connects to API.
    # The CLI inside the container might be pre-configured? Unlikely.
    
    log "WARNING: Woodpecker automation halted. Please log in to Woodpecker (http://localhost:8000) to sync repos."
    log "REQUIRED: Enable 'platform' repository and mark 'Trusted' in settings."
else
    log "Woodpecker CLI not found. Manual configuration required."
    log "1. Login to http://localhost:8000"
    log "2. Enable repository '${REPO_OWNER}/${REPO_NAME}'"
    log "3. Go to Settings -> Trusted: Enable (Critical for docker socket access)"
    log "4. Add Secrets if needed (e.g. REGISTRY credentials if not using internal network)"
fi

# Ideally we would:
# 1. woodpecker-cli repo add ${REPO_OWNER}/${REPO_NAME}
# 2. woodpecker-cli repo update --trusted ${REPO_OWNER}/${REPO_NAME}

log "Woodpecker init script finished (partially manual)."
