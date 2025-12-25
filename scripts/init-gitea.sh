#!/usr/bin/env bash
set -euo pipefail

log() { echo "[init-gitea] $*"; }

GITEA_URL="${GITEA_INTERNAL_URL:-http://gitea:3000}"
ADMIN_USER="${GITEA_ADMIN_USER:-gitops}"
ADMIN_PASS="${GITEA_ADMIN_PASSWORD:-${GITEA_ADMIN_PASS:-gitops1234}}"
REPO_NAME="platform"
WOODPECKER_INTERNAL_URL="${WOODPECKER_INTERNAL_URL:-http://woodpecker-server:8000}"

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

set_env_value() {
    local key="$1"
    local value="$2"
    local env_file="/workspace/.env"
    local tmp
    if [ ! -f "$env_file" ]; then
        log "Missing .env at $env_file; skipping update for $key"
        return
    fi
    tmp="$(mktemp)"
    awk -v k="$key" -v v="$value" 'BEGIN{done=0}
        $0 ~ "^"k"=" {print k"="v; done=1; next}
        {print}
        END{if(!done) print k"="v}
    ' "$env_file" > "$tmp"
    if ! cat "$tmp" > "$env_file"; then
        log "Failed to update $env_file (resource busy)."
        rm -f "$tmp"
        return
    fi
    rm -f "$tmp"
}

get_env_value() {
    local key="$1"
    local env_file="/workspace/.env"
    if [ ! -f "$env_file" ]; then
        return
    fi
    grep -E "^${key}=" "$env_file" | head -n1 | cut -d= -f2- | tr -d '\r'
}

hash_value() {
    local value="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        printf "%s" "$value" | sha256sum | awk '{print $1}'
    else
        printf "%s" "$value"
    fi
}

restart_woodpecker_server() {
    if ! command -v docker >/dev/null 2>&1; then
        log "docker CLI not available; please restart start.bat"
        return
    fi
    if ! docker compose version >/dev/null 2>&1; then
        if command -v apk >/dev/null 2>&1; then
            log "docker compose missing; installing..."
            apk add --no-cache docker-cli-compose >/dev/null 2>&1 || true
        fi
    fi
    if docker compose version >/dev/null 2>&1; then
        log "Recreating woodpecker-server to apply OAuth credentials..."
        (docker compose -f /workspace/docker-compose.yml --env-file /workspace/.env up -d --force-recreate woodpecker-server) >/dev/null 2>&1 || \
            log "Failed to recreate woodpecker-server; please rerun start.bat"
    else
        log "docker compose not available; please restart start.bat"
    fi
}

ensure_woodpecker_oauth() {
    local oauth_name="${WOODPECKER_OAUTH_NAME:-woodpecker}"
    local wood_host="${WOODPECKER_HOST:-http://woodpecker.localhost:8000}"
    local callback="${wood_host%/}/authorize"
    local apps_json
    local app_id
    local app_client_id=""
    local redirect_ok="false"
    local confidential_ok="false"
    local need_recreate="false"
    local need_patch="false"
    local sync_hash=""
    local current_sync=""

    if [ -n "${WOODPECKER_GITEA_SECRET:-}" ]; then
        sync_hash=$(hash_value "${WOODPECKER_GITEA_SECRET}")
        current_sync=$(get_env_value "WOODPECKER_OAUTH_LAST_SYNC" || true)
        if [ -z "$current_sync" ] || [ "$current_sync" != "$sync_hash" ]; then
            need_recreate="true"
        fi
    fi

    log "Ensuring Woodpecker OAuth app redirect: ${callback}"
    apps_json=$(curl -s -u "${ADMIN_USER}:${ADMIN_PASS}" "${GITEA_URL}/api/v1/user/applications/oauth2" || true)
    if ! echo "$apps_json" | jq -e . >/dev/null 2>&1; then
        apps_json="[]"
    fi
    app_id=$(echo "$apps_json" | jq -r --arg name "$oauth_name" '.[] | select(.name==$name) | .id' | head -n1)
    if [ -n "$app_id" ]; then
        app_client_id=$(echo "$apps_json" | jq -r --arg name "$oauth_name" '.[] | select(.name==$name) | .client_id' | head -n1)
        if echo "$apps_json" | jq -r --arg name "$oauth_name" '.[] | select(.name==$name) | .redirect_uris[]?' | grep -Fx "$callback" >/dev/null 2>&1; then
            redirect_ok="true"
        fi
        if echo "$apps_json" | jq -r --arg name "$oauth_name" '.[] | select(.name==$name) | .confidential_client' | grep -Fx "true" >/dev/null 2>&1; then
            confidential_ok="true"
        fi
    fi

    if [ -n "$app_id" ] && { [ "$redirect_ok" != "true" ] || [ "$confidential_ok" != "true" ]; }; then
        need_patch="true"
    fi

    if [ "$need_patch" = "true" ]; then
        log "Updating Woodpecker OAuth settings..."
        local patch_code
        patch_code=$(curl -s -o /dev/null -w "%{http_code}" -X PATCH -u "${ADMIN_USER}:${ADMIN_PASS}" \
            -H "Content-Type: application/json" \
            -d "{\"name\":\"${oauth_name}\",\"redirect_uris\":[\"${callback}\"],\"confidential_client\":true}" \
            "${GITEA_URL}/api/v1/user/applications/oauth2/${app_id}")
        if [ "$patch_code" = "200" ] || [ "$patch_code" = "201" ]; then
            redirect_ok="true"
            confidential_ok="true"
        else
            need_recreate="true"
        fi
    fi

    if [ -z "$app_id" ] || [ "$confidential_ok" != "true" ]; then
        need_recreate="true"
    fi
    if [ -n "${WOODPECKER_GITEA_CLIENT:-}" ] && [ -n "$app_client_id" ] && [ "$app_client_id" != "$WOODPECKER_GITEA_CLIENT" ]; then
        log "Woodpecker client id mismatch; recreating OAuth app"
        need_recreate="true"
    fi
    if [ -z "${WOODPECKER_GITEA_CLIENT:-}" ] || [ -z "${WOODPECKER_GITEA_SECRET:-}" ]; then
        need_recreate="true"
    fi

    if [ "$need_recreate" = "true" ]; then
        if [ -n "$app_id" ]; then
            log "Deleting Woodpecker OAuth app (id=${app_id})"
            curl -s -X DELETE -u "${ADMIN_USER}:${ADMIN_PASS}" "${GITEA_URL}/api/v1/user/applications/oauth2/${app_id}" >/dev/null || true
        fi
        log "Creating Woodpecker OAuth app..."
        local create_json
        create_json=$(curl -s -u "${ADMIN_USER}:${ADMIN_PASS}" \
            -H "Content-Type: application/json" \
            -d "{\"name\":\"${oauth_name}\",\"redirect_uris\":[\"${callback}\"],\"confidential_client\":true}" \
            "${GITEA_URL}/api/v1/user/applications/oauth2")
        local new_client
        local new_secret
        new_client=$(echo "$create_json" | jq -r '.client_id // empty')
        new_secret=$(echo "$create_json" | jq -r '.client_secret // empty')
        if [ -z "$new_client" ] || [ -z "$new_secret" ]; then
            log "Failed to create Woodpecker OAuth app: $create_json"
            return
        fi
        set_env_value "WOODPECKER_GITEA_CLIENT" "$new_client"
        set_env_value "WOODPECKER_GITEA_SECRET" "$new_secret"
        if [ -n "$new_secret" ]; then
            local new_hash
            new_hash=$(hash_value "$new_secret")
            set_env_value "WOODPECKER_OAUTH_LAST_SYNC" "$new_hash"
        fi
        log "Woodpecker OAuth credentials updated in .env"
        restart_woodpecker_server
    else
        log "Woodpecker OAuth app already configured"
    fi
}

ensure_woodpecker_oauth

log "Ensuring Woodpecker internal/public URLs..."
set_env_value "WOODPECKER_GITEA_URL" "${GITEA_URL}"
if [ -n "${GITEA_PUBLIC_URL:-}" ]; then
    set_env_value "WOODPECKER_EXPERT_FORGE_OAUTH_HOST" "${GITEA_PUBLIC_URL}"
fi
set_env_value "WOODPECKER_EXPERT_WEBHOOK_HOST" "${WOODPECKER_INTERNAL_URL}"

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

git config --global user.email "gitops@example.com"
git config --global user.name "GitOps Bot"

if [ ! -d "/tmp/repo_clone/.git" ]; then
    # We clone the empty/autoinited repo to /tmp/repo_clone
    git clone "http://${ADMIN_USER}:${ADMIN_PASS}@gitea:3000/${ADMIN_USER}/${REPO_NAME}.git" /tmp/repo_clone
fi

cd /tmp/repo_clone
git fetch origin main || true
git checkout main || git checkout -b main
git reset --hard origin/main || true

# Replace working tree contents with /workspace (include dotfiles, exclude .git)
find /tmp/repo_clone -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
tar --exclude=.git -C /workspace -cf - . | tar -C /tmp/repo_clone -xf -

git add -A
git commit -m "chore(e2e): sync workspace into Gitea [skip ci]" || echo "Nothing to commit"
git push origin main
log "Repository synced with workspace content."

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
