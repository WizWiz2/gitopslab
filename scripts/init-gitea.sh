#!/usr/bin/env bash
set -euo pipefail

log() { echo "[init-gitea] $*"; }

GITEA_URL="${GITEA_INTERNAL_URL:-http://gitea:3000}"
ADMIN_USER="${GITEA_ADMIN_USER:-gitops}"
ADMIN_PASS="${GITEA_ADMIN_PASS:-gitops1234}"
REPO_NAME="platform"

# Wait for Gitea
/workspace/scripts/wait-for.sh "${GITEA_URL}/api/v1/version"

log "Creating admin user ${ADMIN_USER}..."
# Create admin user via CLI execution inside the container would be easier, usually available via 'gitea admin user create'
# But we are in 'bootstrap' container, not 'gitea' container. So we must use API or ssh?
# Actually, the initial gitea install might need setup.
# If Gitea allows auto-install via env vars (GITEA__security__...) which we have in docker-compose,
# then we can create user via API if we have an admin token?
# Or we can create the first user via 'gitea admin' command via docker exec?
# The `bootstrap` container has access to docker socket? Yes.

if ! docker exec -u 1000 gitea gitea admin user list | grep -q "${ADMIN_USER}"; then
    docker exec -u 1000 gitea gitea admin user create --username "${ADMIN_USER}" --password "${ADMIN_PASS}" --email "gitops@example.com" --admin
    log "Admin user created"
else
    log "Admin user already exists"
fi

# Generate Token
# We need a token to use the API. Gitea CLI can generate tokens?
# 'gitea admin user generate-access-token'
BLOCK_TOKEN_CREATION=false
if docker exec -u 1000 gitea gitea admin user generate-access-token --username "${ADMIN_USER}" --token-name "bootstrap-token" --scopes "all" > /tmp/gitea_token 2>/dev/null; then
    GITEA_TOKEN=$(awk '/Access token:/ {print $3}' /tmp/gitea_token | tr -d '[:space:]')
    log "Generated new token: ${GITEA_TOKEN:0:5}***"
else
    # Token might already exist or command failed.
    # If we cannot get the token, we can't proceed with API calls easily.
    # Let's try to regenerate or just fail if we can't.
    log "Could not generate token (maybe already exists with that name). Attempting to delete and recreate."
    # List tokens not easily possible via CLI for specific name? 
    # Actually, proceed with caution.
    # For idempotency, maybe we can ignore this or assume we saved it somewhere?
    # In a real scenario, we might want to store this token in a secret or file.
    # For this demo, let's keep it simple: try to create, if fail, assume we can't get it and fail?
    # Or maybe we leverage the fact that we set the password and can use Basic Auth for API?
    # Gitea API supports Basic Auth with user/password.
    log "Using Basic Auth for API interactions."
fi

# Create Repo
log "Creating repository ${REPO_NAME}..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -u "${ADMIN_USER}:${ADMIN_PASS}" \
    -H "Content-Type: application/json" \
    -d "{\"name\": \"${REPO_NAME}\", \"private\": false, \"auto_init\": true}" \
    "${GITEA_URL}/api/v1/admin/users/${ADMIN_USER}/repos")

if [[ "$HTTP_CODE" == "201" ]]; then
    log "Repository created."
elif [[ "$HTTP_CODE" == "409" ]]; then
    log "Repository already exists."
else
    log "Failed to create repo. Status: $HTTP_CODE"
    exit 1
fi

# Push initial code
# We have the code in /workspace (platform repo root).
# We need to push it to Gitea.
# Access via internal URL?
# git push http://${ADMIN_USER}:${ADMIN_PASS}@gitea:3000/${ADMIN_USER}/${REPO_NAME}.git
# But we need to configure git inside bootstrap container.

if [ ! -d "/tmp/repo_clone" ]; then
    git config --global user.email "gitops@example.com"
    git config --global user.name "GitOps Bot"
    
    # We clone the empty/autoinited repo to /tmp/repo_clone
    git clone "http://${ADMIN_USER}:${ADMIN_PASS}@gitea:3000/${ADMIN_USER}/${REPO_NAME}.git" /tmp/repo_clone
    
    # Copy files from /workspace to /tmp/repo_clone (excluding .git)
    # /workspace is mounted from current dir (host).
    # We want to copy everything except .git
    
    cp -r /workspace/* /tmp/repo_clone/
    
    cd /tmp/repo_clone
    git add .
    git commit -m "Initial commit from bootstrap" || echo "Nothing to commit"
    git push origin main
    log "Repository seeded with initial content."
else
    log "Repo interaction skipped."
fi

# Save credentials for other scripts
# We'll export variables to a shared file or just rely on env vars being consistent?
# TechSpec says we need a PAT for Argo and Woodpecker.
# Start by creating a dedicated token for CI/CD if possible, or reuse admin basic auth?
# TechSpec 7.1.5 "create PAT (for CI/Argo)"
# Let's try to create a persistent token via API using Basic Auth
TOKEN_NAME="cicd-token"
# Delete old if exists (idempotency hard via API without listing)
# Simple approach: Create a new one every time? No.
# Let's save it to a file required by subsequent scripts.

EXISTING_TOKEN=$(curl -s -u "${ADMIN_USER}:${ADMIN_PASS}" "${GITEA_URL}/api/v1/users/${ADMIN_USER}/tokens" \
    | grep -o '"name":"'"$TOKEN_NAME"'","sha1":"[^"]*"' | head -n1 | cut -d'"' -f6 || echo "")

if [ -z "$EXISTING_TOKEN" ]; then
    log "Creating CI/CD token..."
    NEW_TOKEN_RESP=$(curl -s -u "${ADMIN_USER}:${ADMIN_PASS}" \
        -H "Content-Type: application/json" \
        -d "{\"name\": \"${TOKEN_NAME}\", \"scopes\": [\"all\"]}" \
        "${GITEA_URL}/api/v1/users/${ADMIN_USER}/tokens")
    
    # Extract token (sha1)
    GITEA_PAT=$(echo "$NEW_TOKEN_RESP" | grep -o '"sha1":"[^"]*"' | head -n1 | cut -d'"' -f4)
    if [ -n "$GITEA_PAT" ]; then
         echo "$GITEA_PAT" > /workspace/.gitea_token
         log "Token saved to .gitea_token"
    else
         log "Failed to create token: $NEW_TOKEN_RESP"
    fi
else
    log "Token '${TOKEN_NAME}' seems to exist. We cannot retrieve the secret hash again."
    # If we lost it, we should delete and recreate?
    # For now, let's assume if .gitea_token exists on disk, we are good.
    if [ ! -f /workspace/.gitea_token ]; then
        log "Token exists in Gitea but lost locally. Deleting and recreating..."
        curl -X DELETE -u "${ADMIN_USER}:${ADMIN_PASS}" "${GITEA_URL}/api/v1/users/${ADMIN_USER}/tokens/$TOKEN_NAME"
        # Retry creation
         NEW_TOKEN_RESP=$(curl -s -u "${ADMIN_USER}:${ADMIN_PASS}" \
            -H "Content-Type: application/json" \
            -d "{\"name\": \"${TOKEN_NAME}\", \"scopes\": [\"all\"]}" \
            "${GITEA_URL}/api/v1/users/${ADMIN_USER}/tokens")
         GITEA_PAT=$(echo "$NEW_TOKEN_RESP" | grep -o '"sha1":"[^"]*"' | head -n1 | cut -d'"' -f4)
         echo "$GITEA_PAT" > /workspace/.gitea_token
    fi
fi
