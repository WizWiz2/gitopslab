#!/usr/bin/env bash
# Pre-provision Woodpecker OAuth credentials before first start
set -euo pipefail

log() { echo "[pre-oauth] $*"; }

GITEA_URL="${GITEA_INTERNAL_URL:-http://gitea:3000}"
ADMIN_USER="${GITEA_ADMIN_USER:-gitops}"
ADMIN_PASS="${GITEA_ADMIN_PASSWORD:-gitops1234}"
WOODPECKER_HOST="${WOODPECKER_HOST:-http://woodpecker.localhost:8000}"
OAUTH_NAME="${WOODPECKER_OAUTH_NAME:-woodpecker}"
CALLBACK="${WOODPECKER_HOST%/}/authorize"
ENV_FILE="/workspace/.env"

# Wait for Gitea to be ready
log "Waiting for Gitea..."
/workspace/scripts/wait-for.sh "${GITEA_URL}/api/v1/version"

# Check if OAuth app already exists and credentials are in .env
EXISTING_CLIENT=$(grep "^WOODPECKER_GITEA_CLIENT=" "$ENV_FILE" 2>/dev/null | cut -d= -f2 | tr -d '\r' || echo "")
EXISTING_SECRET=$(grep "^WOODPECKER_GITEA_SECRET=" "$ENV_FILE" 2>/dev/null | cut -d= -f2 | tr -d '\r' || echo "")

if [ -n "$EXISTING_CLIENT" ] && [ -n "$EXISTING_SECRET" ]; then
    # Verify OAuth app exists in Gitea
    apps_json=$(curl -s -u "${ADMIN_USER}:${ADMIN_PASS}" "${GITEA_URL}/api/v1/user/applications/oauth2" || echo "[]")
    if echo "$apps_json" | jq -e ".[] | select(.client_id==\"$EXISTING_CLIENT\")" > /dev/null 2>&1; then
        log "OAuth app already configured with client_id: ${EXISTING_CLIENT:0:8}..."
        exit 0
    else
        log "OAuth credentials in .env but app not found in Gitea, recreating..."
    fi
fi

# Delete old OAuth app if exists
log "Checking for existing OAuth app '${OAUTH_NAME}'..."
apps_json=$(curl -s -u "${ADMIN_USER}:${ADMIN_PASS}" "${GITEA_URL}/api/v1/user/applications/oauth2" || echo "[]")
# Ensure apps_json is an array before processing
app_id=$(echo "$apps_json" | jq -r 'if type=="array" then .[] | select(.name=="'"$OAUTH_NAME"'") | .id else empty end' | head -n1)

if [ -n "$app_id" ]; then
    log "Deleting existing OAuth app (id=${app_id})..."
    curl -s -X DELETE -u "${ADMIN_USER}:${ADMIN_PASS}" "${GITEA_URL}/api/v1/user/applications/oauth2/${app_id}" > /dev/null || true
fi

# Create new OAuth app
log "Creating OAuth app '${OAUTH_NAME}' with callback: ${CALLBACK}"
create_json=$(curl -s -u "${ADMIN_USER}:${ADMIN_PASS}" \
    -H "Content-Type: application/json" \
    -d "{\"name\":\"${OAUTH_NAME}\",\"redirect_uris\":[\"${CALLBACK}\"],\"confidential_client\":true}" \
    "${GITEA_URL}/api/v1/user/applications/oauth2")

new_client=$(echo "$create_json" | jq -r '.client_id // empty')
new_secret=$(echo "$create_json" | jq -r '.client_secret // empty')

if [ -z "$new_client" ] || [ -z "$new_secret" ]; then
    log "ERROR: Failed to create OAuth app: $create_json"
    exit 1
fi

log "OAuth app created successfully"
log "Client ID: ${new_client:0:8}..."
log "Secret: ${new_secret:0:8}..."

# Update .env file
log "Updating .env with OAuth credentials..."
tmp=$(mktemp)

# Remove old credentials if present
grep -v "^WOODPECKER_GITEA_CLIENT=" "$ENV_FILE" | grep -v "^WOODPECKER_GITEA_SECRET=" | grep -v "^WOODPECKER_OAUTH_LAST_SYNC=" > "$tmp" || true

# Add new credentials
echo "WOODPECKER_GITEA_CLIENT=$new_client" >> "$tmp"
echo "WOODPECKER_GITEA_SECRET=$new_secret" >> "$tmp"

# Calculate hash for sync tracking
if command -v sha256sum > /dev/null 2>&1; then
    sync_hash=$(printf "%s" "$new_secret" | sha256sum | awk '{print $1}')
    echo "WOODPECKER_OAUTH_LAST_SYNC=$sync_hash" >> "$tmp"
fi

cat "$tmp" > "$ENV_FILE"
rm -f "$tmp"

log "OAuth credentials saved to .env"
log "Woodpecker can now start with correct OAuth configuration"
